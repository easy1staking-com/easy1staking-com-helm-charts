#!/usr/bin/env python3
"""
Assert the chart's config OVERLAY contains exactly the keys it should.

⛔ WHY A COMMENT WOULD NOT DO. scooper-v2 loads config through the `config` crate
with serde and the repository contains NO `deny_unknown_fields`. So:

    an unknown key            -> SILENTLY IGNORED, config loads
    a key under the wrong path -> SILENTLY IGNORED, config loads

⇒ A mistyped key in the overlay produces no error and no effect, and the scooper
runs a compiled default nobody chose — while signing. `helm template`, `helm lint`
and a rendered diff all look correct because the key IS there, just not where the
binary reads it.

The allowlist below is executable data, not prose, because prose cannot fail.
Every path is sourced from upstream's own config files or structs (2026-09-15,
scooper-v2 @ HEAD).

Usage: ./verify-config-schema.py <values.yaml>
Excluded from `helm package` — a repo tool, not a chart artifact.
"""
import json, subprocess, sys, yaml

CHART = "charts/sundae-scooper-v2"

# Always emitted.
# Always emitted, in every mode.
REQUIRED = {
    "log.level", "log.format",
    "server.address",
    "persistence.sqlite.filename",
    "acropolis.global.startup.network-name",
}
# ⛔ REQUIRED **TOGETHER OR NOT AT ALL**. `protocol.v4` is an Option in the
# binary, so its mere presence switches v4 on and then its required fields are
# demanded — ONE AT A TIME, so a partial block is discovered a deploy at a time.
# An earlier chart emitted an execution object holding only the key-file path,
# which is that fatal partial case:
#     missing configuration field "protocol.v4.execution.submit-url"
# ⇒ So this set must be all-present or all-absent, and `protocol` must never be
# emitted by the overlay ALONE — upstream's own config file is its source.
V4_GROUP = {"protocol.v4.execution.scooper-secret-key-file"}
# Emitted only when the corresponding value is set.
OPTIONAL = {
    "server.public_address",
    "protocol.bootstrap.source", "protocol.bootstrap.url",
    "protocol.v4.mempool.socket-path", "protocol.v4.mempool.network-magic",
    "protocol.v4.mempool.execute",
    "protocol.v4.execution.scooper-stake-keyhash",
    "protocol.v4.execution.submit-url",
}
# Present => the chart has a defect that costs a key or a credential.
FORBIDDEN = {
    "protocol.v4.execution.scooper-secret-key":
        "the INLINE key — upstream says prefer the file, and an inline key would "
        "be rendered into a ConfigMap in a PUBLIC repo's chart",
    "protocol.bootstrap.project-id":
        "a Blockfrost CREDENTIAL. It is injected as an env var "
        "(SCOOPER_V2_PROTOCOL__BOOTSTRAP__PROJECT_ID), never rendered into config",
}
MUST_BE_INT = {"protocol.v4.mempool.network-magic"}


def paths(o, p=""):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from paths(v, f"{p}.{k}" if p else k)
    else:
        yield p


def main(values):
    vals = yaml.safe_load(open(values)) or {}
    r = subprocess.run(["helm", "template", "t", CHART, "-f", values],
                       capture_output=True, text=True)
    if r.returncode:
        print(r.stderr.strip()[:500]); sys.exit(2)
    overlay = None
    for d in yaml.safe_load_all(r.stdout):
        if d and d.get("kind") == "ConfigMap" and "zz-chart-overlay.json" in (d.get("data") or {}):
            overlay = json.loads(d["data"]["zz-chart-overlay.json"])
    if overlay is None:
        print("  FAIL  no overlay ConfigMap rendered"); sys.exit(1)

    got = set(paths(overlay))

    def val(path):
        c = overlay
        for part in path.split("."):
            if not isinstance(c, dict) or part not in c:
                return KeyError
            c = c[part]
        return c

    bad = 0

    # ⛔ THE EXPLICIT-NULL INVARIANT, and it is the most load-bearing check here.
    #
    # In a layered last-wins config, NOT WRITING A KEY IS NOT TURNING IT OFF —
    # the lower layer speaks instead, and upstream's layer speaks with THEIR
    # Blockfrost credential, THEIR EC2 filesystem path, THEIR dummy signing key
    # and a PUBLIC listener. Measured live: a deployment nobody had configured
    # for Blockfrost held an open connection to cardano-preview.blockfrost.io.
    #
    # ⇒ So anything this chart claims to disable must appear as an EXPLICIT null.
    # If a future tidy-up deletes one, the inheritance returns silently — which is
    # precisely why this is a test and not a comment.
    must_be_null_when_off = [
        ("server.public_address", not (vals.get("config", {}).get("overlay", {}) or {}).get("publicAddress"),
         "upstream sets server.public_address: 0.0.0.0:9998 — silence OPENS the public listener"),
        ("protocol.bootstrap", not (vals.get("bootstrap") or {}).get("enabled"),
         "upstream's bootstrap block carries THEIR Blockfrost project id, used every startup"),
    ]
    if (vals.get("v4") or {}).get("enabled"):
        must_be_null_when_off += [
            ("protocol.v4.execution.scooper-secret-key", True,
             "upstream's file carries a DUMMY inline key (0202…) which would sign instead"),
            ("protocol.v4.mempool", not (vals.get("mempool") or {}).get("enabled"),
             "upstream's mempool points at /home/ec2-user/… and retries it every 5s"),
        ]
    for path, applies, why in must_be_null_when_off:
        if not applies:
            continue
        v = val(path)
        if v is KeyError:
            print(f"  FAIL  NOT EXPLICITLY DISABLED: {path} is absent, so upstream's "
                  f"value stands — {why}"); bad += 1
        elif v is not None:
            print(f"  FAIL  {path} should be an explicit null here, got {v!r}"); bad += 1

    # ⚑ FORBIDDEN means "carries a REAL VALUE". An explicit null is the FIX, not
    # the fault — which is why this checks the value and not the key's presence.
    for path, why in FORBIDDEN.items():
        v = val(path)
        if v is not KeyError and v is not None:
            print(f"  FAIL  FORBIDDEN VALUE PRESENT: {path} — {why}"); bad += 1

    allowed = REQUIRED | OPTIONAL | V4_GROUP | set(FORBIDDEN) | {
        "server.public_address", "protocol.bootstrap", "protocol.v4.mempool",
        "protocol.v4.execution.scooper-secret-key",
    }
    for p_ in sorted(got - allowed):
        print(f"  FAIL  NOT IN THE ALLOWLIST: {p_} — a key with no upstream source, "
              f"or the right key on the wrong path (both load SILENTLY)"); bad += 1
    for p_ in sorted(REQUIRED - got):
        print(f"  FAIL  REQUIRED KEY MISSING: {p_}"); bad += 1

    want_v4 = bool((vals.get("v4") or {}).get("enabled"))
    v4_keys = {k for k in got if k.startswith("protocol.v4.")}
    if v4_keys and not want_v4 and not (vals.get("config", {}) or {}).get("upstreamHasV4"):
        print(f"  FAIL  protocol.v4 emitted with v4.enabled false and no upstream v4 "
              f"to disable: {sorted(v4_keys)}"); bad += 1
    want_url = vals.get("submitUrl")
    got_url = val("protocol.v4.execution.submit-url")
    if want_v4:
        if got_url is KeyError or not got_url:
            print("  FAIL  v4.enabled but the overlay emits NO submit-url. Upstream's "
                  "Blockfrost URL would remain in force, spending THEIR project id."); bad += 1
        elif got_url != want_url:
            print(f"  FAIL  submit-url mismatch: overlay {got_url!r} vs submitUrl {want_url!r}"); bad += 1
        elif "blockfrost.io" in got_url:
            print("  FAIL  submit-url points at blockfrost.io — a credential in config"); bad += 1
    for k in sorted(got & MUST_BE_INT):
        v = val(k)
        if not isinstance(v, int) or isinstance(v, bool):
            print(f"  FAIL  {k} = {v!r} is {type(v).__name__}, must be an integer"); bad += 1

    print(f"  {len(got)} overlay keys; {len(REQUIRED)} required present; "
          f"{len(got & OPTIONAL)} optional present")
    if bad:
        print(f"  {bad} problem(s)"); sys.exit(1)
    print("  overlay schema OK")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else sys.exit("usage: verify-config-schema.py <values.yaml>"))
