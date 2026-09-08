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
| `advertisedUrl` | What peers dial, written **on chain** at registration — a one-way door |
| `listenPort` | What the daemon binds inside the container. **Not the same value** |
| `blockfrost.secretName` | Names an existing Secret holding the project id |
| `config.network` | heimdall refuses to start without it, and an **unresolvable network is treated as mainnet** — a typo falls forward onto real funds, not back to preprod |
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

## Where the credentials live — all by reference, none by value

| | |
|---|---|
| Blockfrost project id | `blockfrost.secretName` / `secretKey` → `BLOCKFROST_PROJECT_ID` |
| Wallet mnemonic | `mnemonic.secretName` / `secretKey` → `HEIMDALL_MNEMONIC` |

**There is no `blockfrostProjectId` value and there must never be one.** This
repository is public and carries no secret in any form, tracked or untracked.
Charts here reference Secrets by name; they never contain their contents — and
never render them from values either, since a credential passed via `--set`
still lands in the release's stored manifest.

`heimdall.toml` is still a **Secret, not a ConfigMap** (the upstream Debian
package installs it `0640 root:heimdall`), but it now carries no credential —
`blockfrost_project_id` is deliberately absent from the rendered file.

The non-credential config stays **templated with `required`**, and that is the
point: those checks are what make the mainnet-by-omission trap impossible.
Handing the whole file to an operator-supplied Secret would drop every one of
them.

## The advertised URL and the listening port are two different values

⛔ **`advertisedUrl` is a one-way door.** It is written **on chain** at
registration, so changing it later is a **chain write** — not a values edit and
a rollout. Decide it once, with whoever runs the roster.

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

## ⚠ The two things that need checking before this is deployed

**1. The TOML section layout is inferred, not verified.** The key *names* come
from the operator guide; their grouping into `[http]`, `[cardano]` and
`[bifrost]` is largely inference — `http.listen_port` and `cardano.mnemonic` are
the only documented dotted paths, and the rest is placed by analogy.

Every key could be correct and the file still rejected if a section boundary is
wrong. **Confirm the layout against the upstream guide before the first deploy.**
A render proves the chart produces the file it intends; it cannot prove the
binary accepts it.

**2. How the Blockfrost project id reaches the daemon is unsettled.** The chart
injects `BLOCKFROST_PROJECT_ID` from a Secret and omits the key from the TOML,
which is complete *if* the daemon reads it from the environment.

If it turns out to be **TOML-only**, exactly two places change: the omission in
`templates/secret-config.yaml`, and the env block in
`templates/deployment.yaml`. The file would then be assembled at container start
from the same env var, so that no credential ever appears in chart output. **The
values surface is identical either way** — which is why it was settled first.
