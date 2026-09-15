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
    bad = 0
    for k in sorted(got & FORBIDDEN.keys()):
        print(f"  FAIL  FORBIDDEN: {k} — {FORBIDDEN[k]}"); bad += 1
    for k in sorted(got - REQUIRED - OPTIONAL - V4_GROUP - set(FORBIDDEN)):
        print(f"  FAIL  NOT IN THE ALLOWLIST: {k} — a key with no upstream source, "
              f"or the right key on the wrong path (both load SILENTLY)"); bad += 1
    for k in sorted(REQUIRED - got):
        print(f"  FAIL  REQUIRED KEY MISSING: {k}"); bad += 1
    # ⛔ VALUES vs OUTPUT, not the group's internal completeness.
    #
    # An earlier version of this check tested whether the v4 group was complete,
    # and it did NOT catch the original defect — because the defect was a group
    # that was complete by that definition (one key-file path) emitted when the
    # operator had not asked for v4 at all. Completeness was the wrong question.
    # The right one is whether the output AGREES WITH THE VALUES.
    want_v4 = bool((vals.get("v4") or {}).get("enabled"))
    v4_keys = {k for k in got if k.startswith("protocol.v4.")}
    if v4_keys and not want_v4:
        print(f"  FAIL  protocol.v4 EMITTED WITH v4.enabled FALSE: {sorted(v4_keys)}. "
              f"protocol.v4 is an Option in the binary — its mere PRESENCE switches "
              f"v4 on and then its required fields are demanded one at a time. This "
              f"is the exact defect that failed the first deploy."); bad += 1
    if want_v4 and not (V4_GROUP <= got):
        print(f"  FAIL  v4.enabled but the group is incomplete — missing "
              f"{sorted(V4_GROUP - got)}"); bad += 1
    # ⛔ THE OVERRIDE MUST ACTUALLY BE IN THE OUTPUT, AND MUST BE OURS.
    # "v4 keys present" was not enough last time and it is not enough here: if
    # submit-url is absent from the overlay, upstream's Blockfrost URL — with
    # THEIR project id — survives as the effective value, and the scooper submits
    # through someone else's account. That failure works, which is why only an
    # equality check catches it.
    want_url = vals.get("submitUrl")
    got_url = (((overlay.get("protocol") or {}).get("v4") or {})
               .get("execution") or {}).get("submit-url")
    if want_v4:
        if not got_url:
            print("  FAIL  v4.enabled but the overlay emits NO submit-url. "
                  "Upstream's *-v4.json Blockfrost URL would remain in force, "
                  "spending THEIR project id."); bad += 1
        elif got_url != want_url:
            print(f"  FAIL  submit-url in the overlay does not match values: "
                  f"overlay {got_url!r} vs submitUrl {want_url!r}"); bad += 1
        elif "blockfrost.io" in got_url:
            print(f"  FAIL  submit-url points at blockfrost.io — its project id "
                  f"is in the query string, so this is a credential in config"); bad += 1
    for k in sorted(got & MUST_BE_INT):
        v = overlay
        for part in k.split("."):
            v = v[part]
        if not isinstance(v, int) or isinstance(v, bool):
            print(f"  FAIL  {k} = {v!r} is {type(v).__name__}, must be an integer "
                  f"— a values-file number renders as a float without the helper"); bad += 1

    print(f"  {len(got)} overlay keys; {len(REQUIRED)} required present; "
          f"{len(got & OPTIONAL)} optional present")
    if bad:
        print(f"  {bad} problem(s)"); sys.exit(1)
    print("  overlay schema OK")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else sys.exit("usage: verify-config-schema.py <values.yaml>"))
