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

# Set from argv in __main__; see the note there.
UPSTREAM_HAS_V4 = False

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
    # ⚠ Added after a THIRD session hit "NOT IN THE ALLOWLIST" on it against a
    # different deployment. The overlay has emitted this since nodeAddresses was
    # added; the allowlist was last touched two commits later and did not catch
    # up. A hand-maintained allowlist beside moving templates drifts — and the
    # author never trips it, because the author only runs it on the case they
    # built. See README for the standing task to derive it instead.
    "acropolis.module.peer-network-interface.node-addresses",
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

    # ⚠ THE EXPLICIT-NULL INVARIANT THAT WAS HERE IS REMOVED, AND THAT IS THE
    # POINT RATHER THAN A RETREAT. It asserted that every disabled key appear as
    # a literal `null` — and `null` is only legal where upstream's field is
    # `Option<T>`. On a plain `T` it is a TYPE ERROR that refuses the whole
    # config at startup (measured: "invalid type: unit value, expected a string
    # for key protocol.v4.execution.scooper-secret-key").
    #
    # ⇒ So the check would have REFUSED the correct configuration and PASSED the
    # crashing one — a test enforcing a broken pattern, which is worse than no
    # test. It comes back type-aware, per key, once each field's Rust type is
    # read from source. The inheritances it was defending against are all still
    # real; see README.

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
    if v4_keys and not want_v4 and not UPSTREAM_HAS_V4:
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
    # `--upstream-has-v4` says the upstream config files you pass ALREADY carry a
    # protocol.v4 block, so the overlay emitting protocol.v4 keys with
    # v4.enabled=false is expected rather than a partial-block bug. It is a flag
    # here and NOT a chart value: nothing a consumer sets could change it, since
    # the explicit-null mechanism it used to gate no longer exists.
    args = [a for a in sys.argv[1:] if a != "--upstream-has-v4"]
    globals()["UPSTREAM_HAS_V4"] = "--upstream-has-v4" in sys.argv[1:]
    if not args:
        sys.exit("usage: verify-config-schema.py [--upstream-has-v4] <values.yaml>")
    main(args[0])
