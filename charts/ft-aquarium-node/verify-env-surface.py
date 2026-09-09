#!/usr/bin/env python3
"""
Assert the env surface this chart hands the container matches the application's
FINAL surface exactly — kept vars present, removed vars absent.

⛔ WHY. The 0.7.0 incident: a variable the application had started reading was not
emitted by any template, so setting it did nothing and the feature silently never
armed. Nothing failed; the pod ran; the operator believed it was on.

⚠ AND typedEnvNames IS NOT THIS CHECK. That list only refuses an `extraEnv` entry
colliding with a typed key — it is a shadowing guard, not a delivery gate. A
variable absent from the templates is absent from the pod whether or not it
appears there. Measured 2026-09-09, after this session asserted the opposite.

Usage: ./verify-env-surface.py <values.yaml>
"""
import subprocess, sys, yaml

CHART = "charts/ft-aquarium-node"

# Must reach the container when their values are set.
KEPT = {
    "AQUARIUM_LIQUIDATION_PROFIT_MARGIN_LOVELACE",
    "AQUARIUM_LIQUIDATION_CHECK_PROFITABILITY",
    "AQUARIUM_LIQUIDATION_IGNORE_PROFIT_CHECK",
    "AQUARIUM_LIQUIDATION_MIN_PROFIT_ABSOLUTE_LOVELACE",
    "AQUARIUM_LIQUIDATION_MIN_EXPECTED_PROFIT_LOVELACE",
    "AQUARIUM_LIQUIDATION_MODE",
    "LOANS_LIQUIDATION_CONVERT_ENABLED",
    "LOANS_LIQUIDATION_CONVERT_DEX_COST_FLOOR_LOVELACE",
    "LOANS_LIQUIDATION_CONVERT_MINSWAP_ORDER_COST_LOVELACE",
    "SCHEDULING_TRANSACTION_PROCESSOR_ENABLED",
    "AQUARIUM_COMPOUND_ENABLED",
    "LOANS_CONFIG_ASSET_NAME",
}
# Deleted from the application. Emitting one is at best inert and at worst a lie
# in the pod spec about what governs this node.
REMOVED = {
    "LOANS_LIQUIDATION_CONVERT_PROFIT_MARGIN_LOVELACE",
    "AQUARIUM_X_SUBMIT",
    "LOANS_SUBMITTABLE_NETWORK",
    "LOANS_ENABLED",
    "AQUARIUM_LIQUIDATION_ENABLED",
}


def main(values):
    r = subprocess.run(["helm", "template", "t", CHART, "-f", values],
                       capture_output=True, text=True)
    if r.returncode:
        print(r.stderr.strip()[:400]); sys.exit(2)
    names = set()
    for d in yaml.safe_load_all(r.stdout):
        if d and d.get("kind") == "StatefulSet":
            for c in d["spec"]["template"]["spec"]["containers"]:
                names |= {e["name"] for e in c.get("env", [])}
    # ⚠ KEPT is checked against the TEMPLATE SOURCE, not against this render.
    # This chart deliberately omits an env var whose value is empty — that is an
    # immunity (a blank policy id must not decode to a zero-length array), not a
    # defect. So "absent from THIS render" proves nothing; the 0.7.0 failure was
    # that NO TEMPLATE LINE EXISTED, so the variable could never be set at all.
    src = open(f"{CHART}/templates/statefulset.yaml").read()
    bad = 0
    for n in sorted(KEPT):
        if n not in src:
            print(f"  FAIL  KEPT but NO EMIT SITE in statefulset.yaml: {n} — "
                  f"there is no values key that could ever set it"); bad += 1
    for n in sorted(REMOVED & names):
        print(f"  FAIL  REMOVED but still emitted: {n}"); bad += 1
    idx = sorted(n for n in names if n.startswith("LOANS_LIQUIDATION_MARKETS_"))
    print(f"  {len(names)} env vars emitted by this values file; "
          f"{sum(1 for n in KEPT if n in src)}/{len(KEPT)} kept have emit sites; "
          f"{len(REMOVED & names)} removed emitted; markets keys: {len(idx)}")
    if bad:
        print(f"  {bad} problem(s)"); sys.exit(1)
    print("  env surface OK")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else sys.exit("usage: verify-env-surface.py <values.yaml>"))
