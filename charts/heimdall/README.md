# heimdall

Easy1Staking's node in the **Bifrost** BTC↔Cardano bridge. Preprod pilot now,
mainnet later.

A single Rust/musl binary (`/usr/bin/heimdall`) from `ghcr.io/lantr-io/heimdall`.
It is **not** a JVM service — none of this repo's `JAVA_TOOL_OPTIONS`,
`MaxRAMPercentage` or heap-sizing conventions apply, and nothing is built
locally.

---

## ⛔ CrashLoopBackOff before registration is CORRECT. Do not fix it.

**Before registration completes, the daemon refuses to start.** In Kubernetes
that is a `CrashLoopBackOff`, and it will continue until the node is registered.

This is upstream's deliberate design, not a misconfiguration: *an unregistered
node is in no roster and would contribute nothing, so it says so rather than
running as an idle process that looks healthy.*

**Do not add a probe, a `sleep`, an init container, or a wrapper script to
paper over it.** Every one of those converts a loud, correct, self-describing
refusal into a pod that reports Ready while doing nothing — which is strictly
worse, because nothing then tells you the node is absent from the roster.

If you are seeing this and registration *has* completed, that is a real fault
and worth investigating. Before then, it is the expected state.

## ⛔ There is no readinessProbe, and adding one would be a regression

`/health` answers **"is this process up"**, not "is this node healthy". It says
nothing about roster membership, sync state, or ceremony participation, and
**no endpoint exists that does**.

So a readiness probe here could only assert something it cannot know. Worse, a
*failing* readiness probe removes the pod from the Service — breaking precisely
the peer reachability every DKG and signing ceremony depends on.

`livenessProbe` on `/health` is fine: that is exactly what `/health` reports.
The generous startup budget lives in `startupProbe`, never in
`livenessProbe.initialDelaySeconds`.

There is also **no `ServiceMonitor`**: upstream has no operator metrics surface
yet (WI-058). A dashboard cannot be built from an endpoint that does not exist.

## ⛔ The state volume is the thing that loses money

`/var/lib/heimdall`, `ReadWriteOnce`, annotated `helm.sh/resource-policy: keep`
so **`helm uninstall` leaves it behind**.

It holds the epoch's DKG signing share and `federation-key.json`:

- a container replaced without it **comes back unable to resume**;
- the federation share is **the only copy** — once surviving shares fall below
  the threshold, **the recovery path is gone for good**. It never regenerates.

`emptyDir` is not an option at any size. When replacing a container onto state
that already exists — stage 3 of the pilot — set `persistence.existingClaim` so
the chart adopts the claim instead of provisioning a fresh one.

## Required values

`helm template` **fails** rather than rendering an empty string. That is
deliberate: this is a public chart repository, and a stranger running
`helm install` must get an error, never a node that joins a federation or spends
from a wallet.

| Value | Why it has no default |
|---|---|
| `image.tag` | Run the build **the roster runs**. Peers compare `version` *and* `blueprint_digest` before every ceremony; a mismatched node is dropped. ⚠ **The GHCR tag has no `v`** — `0.1-M5.3`, not `v0.1-M5.3` (that is the git release tag, and pasting it gives an image that does not exist) |
| `advertisedUrl` | What peers dial, written **on chain** at registration — a one-way door, and an input to the registration signatures |
| `listenPort` | What the daemon binds inside the container. **Not the same value** |
| `cardano.network` | heimdall refuses to start without it, and an **unresolvable network is treated as mainnet** — a typo falls forward onto real funds, not back to preprod |
| `cardano.configAddress`, `configNftPolicyId`, `configNftAssetName` | The three bridge identifiers naming the on-chain config UTxO. The **asset name is a third one**: the right policy with the wrong asset finds the wrong UTxO |
| `blockfrost.secretName` | Names an existing Secret holding the project id |
| `mnemonic.secretName` | Names an existing Secret holding the wallet mnemonic |

`cardano.demoLiveStake` (a **boolean**) also has no default and is **not**
required. Demo values are a roster-wide agreement, refused on mainnet — a default
would not merely be wrong for one node, it would **split the roster**, since nodes
disagreeing on demo stake compute different rosters and stop signing together.
This pilot roster runs `true`.

⛔ **There is no `extraConfig` passthrough, deliberately.** A key heimdall does
not recognise is **refused at load**, not ignored — a former peg-out freshness
margin is now compiled in, and a config that still sets it fails to start. The
chart emits only keys taken from the binary's own shipped example.

## Keys, and which ones may enter the cluster

| | |
|---|---|
| **Wallet mnemonic** | `HEIMDALL_MNEMONIC`, from a Secret you create out of band |
| **Bifrost identity** (`bifrost.skey`) | A `0600` file **you** place in the state volume |
| **Pool cold key** | ⛔ **Never enters the cluster at all** |

**The cold key has no field, mount, Secret key or value in this chart, and that
absence is the design.** The daemon never reads it. Registration is signed
beside the key on a separate machine with `heimdall sign-registration`, which
touches no chain and no network and prints public values to carry across.

**The mnemonic is an env var, not a file — a deliberate divergence** from this
repo's usual posture, where secrets are mounted as files. The binary reads only
`$HEIMDALL_MNEMONIC`; there is no file mode, so inventing one would configure
nothing. It is read **only when `cardano.mnemonic` is absent from the TOML**, so
this chart never emits that key under any values. The absence is the mechanism.

**The identity key is not chart-generated, deliberately.** A chart that
generated it per install would mint a **new identity on every reinstall** and
silently orphan the old one along with its shares. Generate it once, back it up
off-cluster.

## How the credentials reach the daemon — two different mechanisms

| | mechanism |
|---|---|
| Wallet mnemonic | `$HEIMDALL_MNEMONIC`, straight from a Secret |
| Blockfrost project id | **config file only** — no env path exists, so the file is *assembled at container start* |

**There is no `blockfrostProjectId` value and there must never be one.** This
repo is public and carries no secret in any form. Charts here reference Secrets
by name; they never contain their contents, and never render them from values
either — a credential passed via `--set` still lands in the release's stored
manifest.

But heimdall reads the project id from `heimdall.toml` **only**; the shipped
example names exactly one environment variable, and it is `$HEIMDALL_MNEMONIC`.
So the chart assembles the file:

```
ConfigMap (template, placeholder, no secret)  ─┐
                                               ├─► initContainer ─► emptyDir{medium: Memory}
Secret (blockfrost.secretName/secretKey) ──────┘                     /etc/heimdall/heimdall.toml (0400, ro)
```

**The assembled file is never a ConfigMap, never a Secret, never in
`helm get manifest`, and never on the node's disk** — it lives in tmpfs and dies
with the pod.

⛔ **The placeholder cannot survive.** The init container exits non-zero if the
Secret gives an empty value, *and* again if `__BLOCKFROST_PROJECT_ID__` is still
present after substitution. A config carrying the literal placeholder would start
the daemon against a nonexistent project and fail far from the cause.

**The mnemonic is an env var, not a file — a deliberate divergence** from this
repo's usual posture. The binary reads only `$HEIMDALL_MNEMONIC`, so inventing a
file mode would configure nothing. It is read **only when `mnemonic` is absent
from `[cardano]`**, so the chart never emits that key. The absence is the
mechanism.

**The Bifrost identity key is a path on the PVC, not a Secret mount and not
chart-generated.** A chart generating it per install would mint a **new identity
on every reinstall** and orphan the old one with its shares. Generate it once,
`0600`, back it up off-cluster.

**The pool cold key has no field, mount, Secret key or comment in this chart.**
The daemon never reads it. Registration is signed beside the key on a separate
machine with `heimdall sign-registration`, which touches no chain and no network.

## Two ports, and the difference is a security boundary

| port | what it is | exposed |
|---|---|---|
| `listenPort` (peer) | `/health` for peers, DKG and signing round payloads | Service **and** Ingress |
| `health.port` (18580) | the **operator** surface | Service only — **never the Ingress** |

⛔ **The health port is unauthenticated.** Upstream binds it to `127.0.0.1` by
default for that reason. In Kubernetes it must bind `0.0.0.0` to be reachable by
the kubelet and Prometheus at all, so the containment is the Service: ClusterIP,
and `ingress.yaml` never references it. Do not expose it via Ingress, NodePort or
LoadBalancer.

⚑ **What to alert on: `last_progress_ms` failing to advance.** That is the "up
but wedged" case — and it is exactly what a liveness probe cannot catch, because
a wedged process answers `/health` perfectly.

⛔ **Do not add a watchdog or a liveness probe on progress.** Upstream ships none
deliberately: restarting a wedged signer mid-ceremony is not obviously safer than
leaving it wedged and visible. **Alert a human; do not restart a signer.**

There is no `ServiceMonitor` — upstream has no operator metrics surface yet
(WI-058).

## The advertised URL and the listening port are two different values

⛔ **`advertisedUrl` is a one-way door.** It is written **on chain** at
registration, so changing it later is a **chain write** — not a values edit and
a rollout. Decide it once, with whoever runs the roster.

⛔ **And it is an input to the registration signatures, so the bytes must match
exactly.** It is emitted into the config as `[bifrost].url`, and both
`register-spo` and `sign-registration` read that string. **A trailing slash or a
port difference between them invalidates both signatures.** Copy it once,
character for character.

Two documented shapes, and the roster runs both:

| | `advertisedUrl` | `listenPort` | in front |
|---|---|---|---|
| **Proxy** | `https://heimdall.example.org` (no port) | `8901` | Cloudflare / ingress terminates TLS |
| **Direct** | `http://203.0.113.10:8901` | `8901` | nothing |

⚠ **https is not required by the bridge.** All four live pilot nodes register
plain `http://ip:port`. The proxy shape is the documented alternative, not an
upgrade.

**In the direct shape the two must agree, and the chart enforces it**: if
`advertisedUrl` carries an explicit port that differs from `listenPort`, the
render fails. Registering a port nothing listens on is discovered by peers, and
correcting it costs a chain write. A URL with no port is the proxy shape and is
left alone.

`bind_address` is always `0.0.0.0` in the container — loopback is unreachable
from outside the network namespace even with a published port — and stays
`0.0.0.0` behind an ingress. Reachability is decided by the Service and Ingress,
never by narrowing the bind.

Traffic is ordinary HTTP request/response (`/health` plus DKG and signing round
payloads). No client certificates, no websockets, no long-poll — a standard
reverse proxy or ingress does not break it, and this chart's ingress template is
correspondingly plain.

## Which build to run

The roster currently runs **version `0.1.0`, `blueprint_digest
e8987f35bc2e577f`**. ⚠ **Which release tag that is has not been established** —
so `image.tag` stays required with no default, and this paragraph is a pointer to
ask the roster, not a value to copy.

Before every ceremony each node compares peers' `/health`: both `version` and
`blueprint_digest` must match, and a mismatched peer is named by pool id and left
out of that ceremony.

## Single replica, and `Recreate`

`replicas: 1` is hardcoded. There is no `replicaCount`, no HPA, no autoscaling
stanza — nothing that invites a 2.

This is correctness, not cost: the node signs from one key with no idempotence
key, so **two replicas race the same state and both sign** before either is
rejected.

`strategy: Recreate` for the same reason — `RollingUpdate` deliberately overlaps
old and new pods. ⚠ **The accepted trade: under `Recreate` no deploy fails
safely.** The old pod is gone before the new one starts, so a bad image tag is
downtime rather than a halted rollout with the old pod still serving.

## Sizing

⚠ The defaults are **unmeasured** — that is "nobody has measured it", not "it
has been tuned low". No upstream figures exist. A single mostly-idle process on
a 6-hour ceremony grid, but treat the numbers as a starting point.

⚠ The target cluster **schedules by requests** and has limited request headroom:
a request larger than that headroom leaves the pod `Pending` however much memory
is actually free.

## Where the config schema comes from — and the guard that keeps it honest

Sections, keys and types come from the binary's own shipped example,
`/usr/share/heimdall/heimdall.toml.example` inside
`ghcr.io/lantr-io/heimdall:0.1-M5.3`, plus `min_stake_lovelace` from the guide's
complete config. An earlier draft guessed and put `skey_path` and `url` under
`[cardano]`; they are under `[bifrost]`.

⛔ **A wrong section header is silent, so the chart has to catch it itself.**
Measured against the binary with `heimdall doctor`:

| | |
|---|---|
| unknown key inside a real section | **silently ignored**, config loads |
| a real key under the **wrong** header | **silently ignored**, config loads |
| wrong **type** | refused — `invalid type: string, expected u64` |

Only type errors are refused, plus exactly one deprecated key by name. So a
typo'd header produces **no error and no effect**, and the daemon runs a compiled
default nobody chose — on a node that signs. `helm template`, `helm lint` and a
rendered diff all look fine, because the key *is* there, just under the wrong
heading.

`verify-config-schema.py` renders the chart, assembles the config, and asserts
the **exact set of `(section, key)` pairs** against an allowlist, plus integer
types where the daemon wants `u64`. **Run it after any edit to
`templates/configmap-config.yaml`:**

```bash
./charts/heimdall/verify-config-schema.py <your-values.yaml>
```

It is mutation-tested: a moved key, a typo'd key, a missing required key, a
stray key, a float where an integer belongs, and each forbidden key are all
caught. Excluded from `helm package` — it is a repo tool, not a chart artifact.

## Values that are agreements, not settings

⛔ `cardano.stakeSource` and `cardano.demoLiveStake` are **published on `/health`
and compared across the roster by name.** A peer that disagrees is **left out of
that ceremony**.

⇒ **Never change one to fix a local symptom.** Doing so does not misconfigure
this node — it *removes* this node from ceremonies, which presents as a peer
problem rather than as a config edit.

⚠ `demo_exclude_unstaked` is also compared, and **this chart cannot set it yet,
deliberately.** Its section and type are unconfirmed, and a guess is no longer
survivable: a key under the wrong section is silently ignored, so the node would
report one thing and run another. Confirm it, then add it beside the other two.

`protocol.pollIntervalMs` is the opposite — a **local** knob the roster does not
compare, safe to change alone.

## Two knobs worth understanding before you change them

**`protocol.pollIntervalMs` defaults to `20000`, not the binary's `5000`.** A
Cardano block is ~20s, so at 5000 roughly four polls in five re-read a tip that
has not moved — Blockfrost budget spent on nothing. Not slower, either: this
bridge's 24h virtual epoch shrinks the DKG join window to ~180s, which is 9 polls
at 20s but only 3 at 60s.

⚑ **Bitcoin is never polled** — heimdall cannot talk to a Bitcoin node at all.
The `[bitcoin]` section invites the opposite assumption.

**`cardano.minStakeLovelace` is optional with no default, and omitting it does
not mean "no minimum"** — it means an unknown compiled default governs the
registration gate. Our epoch-snapshot active stake is zero until epoch 315, so if
that default is above zero, `register-spo` refuses and prints the dry run
instead, which reads as a broken registration rather than a stake threshold.
Setting it to `0` states "no minimum" out loud.

`[protocol].state_dir` is **required by the daemon** — it refuses to start
without one, because an empty trie would **double-pay a peg-out**. The chart
emits it from `persistence.mountPath`, the same key the volume mount uses, so
config and mount cannot diverge.
