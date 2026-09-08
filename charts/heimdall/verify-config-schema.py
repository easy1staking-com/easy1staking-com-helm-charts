#!/usr/bin/env python3
"""
Assert that the config this chart assembles contains EXACTLY the (section, key)
pairs it is supposed to — no more, no fewer.

⛔ WHY THIS EXISTS, AND WHY A COMMENT WOULD NOT DO.

Measured against the binary with `heimdall doctor`:

  unknown key inside [cardano]        -> SILENTLY IGNORED, config loads
  known key under the WRONG section   -> SILENTLY IGNORED, config loads
  wrong TYPE                          -> refused ("invalid type: string, expected u64")

Only type errors are refused. Exactly one deprecated key (the peg-out freshness
margin) is rejected by name.

⇒ So a mistyped section header in the template produces NO ERROR AND NO EFFECT,
and the daemon silently runs on a compiled default nobody chose — on a node that
signs. `helm template` cannot see it, `helm lint` cannot see it, and the rendered
diff looks fine because the key IS there, just under the wrong header.

This file is the only thing standing between that typo and a silent default,
which is why the allowlist lives HERE as executable data and not in a comment
next to the template. A comment cannot fail.

Usage:  ./verify-config-schema.py <values.yaml>       (from the repo root)
Excluded from `helm package` via .helmignore — it is a repo tool, not a chart
artifact.
"""
import subprocess, sys, tomllib, yaml

CHART = "charts/heimdall"
PLACEHOLDER = "__BLOCKFROST_PROJECT_ID__"

# Every pair the chart is allowed to emit. Taken from the binary's own shipped
# example, /usr/share/heimdall/heimdall.toml.example in
# ghcr.io/lantr-io/heimdall:0.1-M5.3, plus min_stake_lovelace from the guide's
# complete config. Adding a key here without a source is the bug this catches.
REQUIRED = {
    ("protocol", "state_dir"), ("protocol", "poll_interval_ms"),
    ("bitcoin", "network"),
    ("cardano", "network"), ("cardano", "blockfrost_project_id"),
    ("cardano", "config_address"), ("cardano", "config_nft_policy_id"),
    ("cardano", "config_nft_asset_name"), ("cardano", "submit_oracle"),
    ("cardano", "oracle_constructor"), ("cardano", "stake_source"),
    ("http", "bind_address"), ("http", "listen_port"),
    ("health", "enabled"), ("health", "bind"),
    ("bifrost", "skey_path"), ("bifrost", "url"),
    ("log", "level"), ("log", "format"),
}
OPTIONAL = {
    ("cardano", "blockfrost_url"),
    ("cardano", "demo_live_stake"),
    ("cardano", "min_stake_lovelace"),
}
# Present => the chart has a defect that costs money or identity.
FORBIDDEN = {
    ("cardano", "mnemonic"):
        "its PRESENCE disables $HEIMDALL_MNEMONIC, so the wallet would come from "
        "this file instead of the Secret",
    ("cardano", "cold_skey_path"):
        "the POOL COLD KEY must never enter the cluster — the daemon never reads "
        "it and registration is signed on a separate machine",
    ("cardano", "cold_vkey_path"):
        "the pool cold key must never enter the cluster",
}
# u64 in the daemon: a float here is a type error the binary WILL refuse, and it
# is exactly what a values-file number renders as without the numeric helper.
MUST_BE_INT = {
    ("protocol", "poll_interval_ms"), ("http", "listen_port"),
    ("cardano", "oracle_constructor"), ("cardano", "min_stake_lovelace"),
}


def fail(msg):
    print(f"  FAIL  {msg}")
    fail.n += 1
fail.n = 0


def main(values):
    out = subprocess.run(
        ["helm", "template", "t", CHART, "-f", values],
        capture_output=True, text=True)
    if out.returncode:
        print(out.stderr.strip()[:400]); sys.exit(2)

    tmpl = next(d["data"]["heimdall.toml.template"]
                for d in yaml.safe_load_all(out.stdout)
                if d and d.get("kind") == "ConfigMap")
    if PLACEHOLDER not in tmpl:
        fail("the credential placeholder is missing from the template")
    # what the init container produces
    doc = tomllib.loads(tmpl.replace(PLACEHOLDER, "projectIdFromSecret"))

    pairs = {(s, k) for s, body in doc.items() if isinstance(body, dict)
             for k in body}
    scalars = [s for s, b in doc.items() if not isinstance(b, dict)]

    for s in scalars:
        fail(f"top-level key outside any section: {s!r}")
    # FORBIDDEN first: these are also outside the allowlist, but they have a
    # specific consequence and the generic message would bury it.
    for s_, k in sorted(pairs & FORBIDDEN.keys()):
        fail(f"FORBIDDEN KEY PRESENT: [{s_}] {k} — {FORBIDDEN[(s_, k)]}")
    for p in sorted(pairs - REQUIRED - OPTIONAL - set(FORBIDDEN)):
        fail(f"NOT IN THE ALLOWLIST: [{p[0]}] {p[1]} — a key with no source, or "
             f"the right key under the wrong header (both load SILENTLY)")
    for p in sorted(REQUIRED - pairs):
        fail(f"REQUIRED PAIR MISSING: [{p[0]}] {p[1]}")
    for s, k in sorted(pairs & MUST_BE_INT):
        v = doc[s][k]
        if not isinstance(v, int) or isinstance(v, bool):
            fail(f"[{s}] {k} = {v!r} is {type(v).__name__}, must be an integer "
                 f"— the daemon refuses a float here")

    print(f"  {len(pairs)} (section, key) pairs; "
          f"{len(REQUIRED)} required, {len(pairs & OPTIONAL)} optional present")
    if fail.n:
        print(f"  {fail.n} problem(s)"); sys.exit(1)
    print("  schema OK")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else sys.exit("usage: verify-config-schema.py <values.yaml>"))
