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
REQUIRED = {
    "log.level", "log.format",
    "server.address",
    "persistence.sqlite.filename",
    "acropolis.global.startup.network-name",
    "protocol.v4.execution.scooper-secret-key-file",
}
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
    for k in sorted(got - REQUIRED - OPTIONAL - set(FORBIDDEN)):
        print(f"  FAIL  NOT IN THE ALLOWLIST: {k} — a key with no upstream source, "
              f"or the right key on the wrong path (both load SILENTLY)"); bad += 1
    for k in sorted(REQUIRED - got):
        print(f"  FAIL  REQUIRED KEY MISSING: {k}"); bad += 1
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
