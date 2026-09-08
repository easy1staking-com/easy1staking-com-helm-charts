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
| `image.tag` | Run the build **the roster runs**. Peers compare `version` *and* `blueprint_digest` before every ceremony; a mismatched node is named by pool id and dropped |
| `port` | The node's URL is registered **on chain** and this is the port inside it. Changing it later is a chain write |
| `config.network` | heimdall refuses to start without it, and an **unresolvable network is treated as mainnet** — a typo falls forward onto real funds, not back to preprod |
| `config.blockfrostProjectId` | A credential |
| `config.configAddress`, `config.configNftPolicyId` | The on-chain config UTxO |
| `config.stakeSource`, `config.minStakeLovelace` | Roster-wide stake policy |
| `mnemonic.secretName` | Names an existing Secret; the chart never contains one |

`config.demoLiveStake` also has no default and is **not** required. Demo values
are a roster-wide agreement, refused on mainnet — a default would not merely be
wrong for one node, it would **split the roster**, since nodes disagreeing on
demo stake compute different rosters and stop signing together.

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

## Where the credential lives

`heimdall.toml` is rendered into a **Secret, never a ConfigMap**, because it
carries `blockfrost_project_id` — the same reason the upstream Debian package
installs it `0640 root:heimdall`.

⚠ **This means `config.blockfrostProjectId` reaches a rendered Kubernetes
Secret.** Supply it from a private values file or `--set` at install time. It
must **never** be written into this repository, which is public and carries no
secret in any form, tracked or untracked.

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

## ⚠ The one thing that needs checking before this is deployed

**The TOML *section layout* in `templates/secret-config.yaml` is inferred, not
verified.** The key *names* come from the operator guide; their grouping into
`[cardano]` and `[bifrost]` is an inference from the single documented
dotted-path reference, `cardano.mnemonic`.

Every key could be correct and the file still rejected if a section boundary is
wrong. **Confirm the layout against the upstream guide before the first deploy.**
A render proves the chart produces the file it intends to; it cannot prove the
binary accepts it.
