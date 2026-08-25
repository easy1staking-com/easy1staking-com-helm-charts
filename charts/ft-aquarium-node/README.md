# ft-aquarium-node

Helm chart for the **FluidTokens Aquarium node** on Cardano **preview**.

The Aquarium node is a Spring Boot service that indexes the chain with
`yaci-store` into Postgres, serves a read-only loans API, and runs the
FluidTokens Lending v4 liquidation bot. It is a **client of everything it talks
to** — a Cardano relay, Blockfrost, the FluidTokens oracle — and needs **no
inbound access from outside the cluster**.

```bash
helm install aquarium ./charts/ft-aquarium-node \
  -f ./charts/ft-aquarium-node/values-preview.yaml \
  --namespace cardano-pv \
  --set config.db.host=<postgres-host> \
  --set config.store.cardano.host=<relay-host> \
  --set secret.name=<secret-name>
```

---

## Read these before you deploy

Each of these has a specific way of wasting a day.

### 1. The image does not contain the liquidation work

| | |
|---|---|
| repository | `fluidtokens/ft-aquarium-node` |
| tag | `2026.07.13` (`latest` currently resolves to the same digest) |
| digest (informational, **not** a default) | `sha256:3e016ea1aeb0cb38dda13ec29bb16a40f560abaf345378b7cb335fe9875eeb2a` |
| platform | **linux/amd64 only** — confirm the node's architecture before deploying |

**This is FluidTokens' build from their `main`. It does NOT contain the
Lending v4 liquidation work**, which lives on a feature branch and has never been
published. It is sufficient for indexing and for syncing to tip — that is
`yaci-store`'s job and works in any version — and **not** sufficient for the bot
to liquidate anything.

So: **if the bot appears to do nothing on this image, that is expected**, not a
defect and not a chart bug. Closing the gap is a build-pipeline question on
FluidTokens' side; we neither build nor publish this image.

**`image.digest` is empty by default, and that is deliberate.** The chart used to
ship FluidTokens' published digest as the default — which meant an operator who
pointed `repository` and `tag` at their own rebuild got *that* digest appended to
*their* repository, and an image that could not exist. **A default digest can only
ever be correct for one deployer.** The failure surfaced as an `ImagePullBackOff`
naming a digest nobody had typed.

**A digest is not repository-independent**: it identifies a manifest inside one
repository, and the chart has no way to tell whether a digest belongs to the
repository you configured. So pin a digest you resolved *from the repository you
set*, and expect no help from the chart if you do not. Two things it can and does
check: a digest set alongside an explicit `tag` is **refused at render** rather
than silently winning, and a digest that is not `sha256:` plus 64 hex characters
is refused too — which catches a truncated paste, and catches a *config* digest
mistaken for a manifest digest before it becomes a pull failure.

### 2. A 200 from `/healthcheck` does not mean ready

`/healthcheck` returns **HTTP 200 with the plain body `...syncing...`** while the
node is still catching up, and a JSON body only once it is caught up. **There is
currently no endpoint that means "ready".**

The initial preview sync starts at slot **71,971,209** against a tip near
**120,955,928** — roughly **49 million slots, about 567 days of chain**. A
readiness or liveness gate that fails while that runs restarts the pod, which
restarts the sync. Forever.

So this chart ships:

| Probe | Path | Why |
|---|---|---|
| `startupProbe` | `/actuator/health` | absorbs a slow Flyway migration on an empty database; 10 min default |
| `livenessProbe` | `/actuator/health` | Spring's own health — process and datasource, not sync state |
| `readinessProbe` | **none** | no endpoint would be correct |

The `startupProbe` is what makes the tight liveness probe safe: liveness does not
begin until startup succeeds. Its `failureThreshold` is **unverified** — the real
boot-to-healthy time on an empty database has not been measured, and 10 minutes
is deliberately generous. Too short is a `CrashLoopBackOff` before the node
reaches its first block.

If you add a readiness probe later, it must treat the literal body
`...syncing...` as not-ready. A status code alone cannot tell you.

> **The failure these probes structurally cannot catch:** if the chain source is
> unreachable, the node **logs and keeps retrying** — it does not fail fast. So
> *probes green, Argo `Synced` and `Healthy`, and zero sync progress* is a
> reachable state. The tell is `/healthcheck` returning `...syncing...` forever
> while the block height never moves. Check progress, not health.

> The application repo's own `CLAUDE.md` documents this path as
> `/__internal__/healthcheck`. The controller maps `/healthcheck`, with no
> servlet context path. The stale line would send you to a 404.

### 3. Some startup failures are the system working

These kill the process by design, and `loans.enabled` defaults to **true** in the
preview profile, so the verifiers do run:

| What fails | When |
|---|---|
| `LoansConfigVerifier` | derived script hashes do not match the live config datums — **the redeploy detector** |
| `LoansReferenceScriptVerifier` | a configured reference-script coordinate's on-chain hash ≠ the derived one |
| `AccountConfig` | `wallet.mnemonic` has no default — an absent mnemonic fails context startup |
| `AppConfig` | `aquarium.genesis.tx-hash` has no default — same |

**Do not paper over these with a lenient probe, a longer `initialDelaySeconds`,
or a restart policy that hides them.** A hard fail here means the node would
otherwise have run against the **wrong contracts**. A `CrashLoopBackOff` with one
of these in the log is correct behaviour, and the log line names the fix.

This does not conflict with the generous `startupProbe` above: **that budget is
for sync time, not for masking a configuration error.** These checks fail the
*process*, so the container exits — no probe setting can suppress them, and none
should try.

### 4. `extraEnv` coordinates and the image blueprint are a matched pair

The `LOANS_*` coordinates *can* be set by environment variable — Spring's relaxed
binding reaches them. But the registry derives every script hash by applying
those policy ids to the **blueprint baked into the image**, so the two are a
matched pair:

- **unset** → boots clean, verifies clean, indexes an older deployment — the
  quiet bot described in §1, and expected
- **set to a newer deployment's values on an older image** → the blueprint cannot
  derive those hashes and `LoansConfigVerifier` hard-fails → `CrashLoopBackOff`

Measured, not theorised: an attempt pairing the `ff005fb` blueprint with the
fourth deployment's policy ids produced **10 hash mismatches** and the verifier
refused to start.

> **`LOANS_*` coordinates may only be overridden on an image whose blueprint
> matches the target deployment. On `fluidtokens/ft-aquarium-node:2026.07.13`,
> leave them UNSET. A quiet bot on this image is expected; a crash loop after
> setting them is this trap. Targeting a newer deployment requires a new IMAGE,
> not new environment variables.**

This trap looks exactly like a chart bug: the operator sees an idle bot, reads
that coordinates are overridable, sets them "as the fix", and converts a working
node into a crash loop whose log line is about script hashes and explains
nothing. `extraEnv` is the door they walk through, which is why the sign is here.

### 5. Arming the bot is not a chart concern

Submitting a liquidation **burns a loan NFT and moves someone's collateral.**
Arming takes **two independent flags**, by design, so one flipped by accident
does nothing:

| Variable | Value in the image's preview profile |
|---|---|
| `AQUARIUM_LIQUIDATION_MODE` | `shadow` |
| `AQUARIUM_LIQUIDATION_ENABLED` | `false` |

The chart exposes them as typed keys, **empty by default**:

```yaml
liquidation:
  mode: ""       # "" | disabled | shadow | live
  enabled: ""    # "" | false | true
```

Empty means the chart sets nothing and the image's own profile governs. **Both are
required to submit** — `mode: live` alone does nothing, `enabled: true` alone does
nothing. Invalid values are **refused at render time** rather than silently
treated as not-armed, because an operator who believes they armed the bot and did
not is a worse failure than a failed `helm template`.

**No values file in this chart sets either one, and none ever should** — not even
commented out and ready. This chart is published to a public repository and is
installable by anyone; a preset that arms a transaction-signing bot arms it for
everybody who runs `helm install`. Arming is a deliberate act in the deploying
operator's own values, outside this repo. **If a future reader finds no `live`
preset here, that is the design and not an omission.**

**Why these are their own keys and not `extraEnv` entries**, when `extraEnv` would
carry them perfectly well: in a values diff, *"operator set a policy id"* and
*"operator armed a bot that moves other people's collateral"* look identical
inside a passthrough map. A safety-critical flag needs a home where a reviewer can
see it for what it is.

> **⚠ Setting either key restarts the pod, and restart is where the fatal boot
> verifiers run again (§3).** A node that has been up and quiet may not come back
> — and that would be the system working, not the arming failing. Read the first
> thirty seconds of logs and expect a *named* error. `strategy: Recreate` means
> the old pod is deleted before the new one starts, so expect a brief gap.

> **⚠ Nothing has ever armed this bot, in any environment.** The rendering above
> is verified; every step downstream of it — that the app reads these from the
> environment, that `live` + `true` actually arms, that anything then works — is
> unexercised. Treat a first arming as an experiment, not a deployment.

A default install therefore **scans, builds, prices and records liquidations but
never submits** — the `MODE_NOT_LIVE` veto stops it. That is the intended
posture, not an incomplete configuration.

`SUBMITTABLE_NETWORK` is hard-coded to `preview` in the application, so mainnet
is fail-closed regardless of flags. That is also why there is **no
`values-mainnet.yaml`** in this chart.

`AQUARIUM_X_SUBMIT` is **not** an application setting — it gates a manual test
runner and has no effect on the running node. It is absent here on purpose;
including it would imply the node reads it.

### 6. `replicas: 1` is a correctness requirement, not a preference

**Hard-coded in the template. There is no `replicaCount` value, no autoscaling
stanza, and no HPA — deliberately, so nothing invites a 2.**

The node signs and submits from **one wallet**. The application has mechanisms
that *bound* concurrency — per-loan quarantine, and a submit veto that re-reads
both UTxOs immediately before signing — but **there is no on-chain idempotence
key and nothing that makes a duplicate deterministically fail before signing.**
Two replicas would race the same UTxO set, and the loser is rejected by the
ledger **only after both have already signed and submitted.**

`strategy: Recreate` for the same reason: a rolling update overlaps the old and
new pods, which is precisely the state being avoided.

### 7. The durable volume belongs to Postgres, not to this pod

**This chart deploys no database and no PersistentVolumeClaim.** The application
pod is stateless; every byte of state is in Postgres, which is **consumed**, not
deployed — matching the `cardano-db-sync` and `midnight-node` charts in this
repo. Adding a `postgresql` chart dependency here is an escalation under this
repo's constitution, not a chart author's judgment call.

**The consequence is easy to miss: §2's 567 days of chain is what losing the
Postgres volume costs.** If Postgres lands with an ephemeral volume, the first
node drain re-indexes 49 million slots from scratch — and this chart will look
perfectly healthy while it does, reporting `...syncing...` and doing nothing
useful. Whoever provisions Postgres owns that volume, its storage class and its
backup posture.

**`config.db.username` must be the role that owns the database, and the same
role the Secret's `db-password` belongs to.** The default is `aquarium`,
matching the database name, not `postgres`. Two reasons, and the first is the
one that costs a night:

- **A right-password-wrong-user mismatch is reported by Postgres as an
  authentication failure**, so it reads as a bad secret — and on a first deploy
  the hand-created Secret is exactly where everyone looks. The username is not a
  suspect until much later.
- **Flyway needs DDL on an empty database**, and on **Postgres 15+** that is not
  automatic for any role: PG15 revoked `CREATE` on the `public` schema from
  `PUBLIC`. The role must **own the database** — ownership reaches the schema
  through `pg_database_owner` — or have been granted `CREATE` on `public`
  explicitly. A connecting-but-non-owning role fails at the first migration
  rather than at connect, which again points away from the real cause.

Flyway must also reach Postgres before the application is usable.
`waitForPostgres.enabled` adds an init container that blocks until Postgres
accepts TCP. It is **off by default** so the chart declares no image it does not
need; with it off, an unreachable database means Flyway fails and Kubernetes
restarts the pod with backoff — noisy but self-healing and correct.

### 8. There is no measured memory figure for this application

Defaults are `512Mi` request / `1Gi` limit, `250m` / `1` CPU.

Not "not tuned" — **none exists.** The image's entrypoint is the exec form
`["java","-jar","app.jar"]`, with no shell, so the `JAVA_OPTS` the application's
compose file sets **has never been read by anything**. Every number derived from
it — including the application repo's own suggestion — carries no weight, and
nobody has started this node to measure a steady-state RSS or a sync peak.

So treat these as a deliberate starting point. **The initial sync is the peak**,
and it is ~49 million slots: measure there, on the first real run, and correct
them.

This chart passes JVM flags through **`JAVA_TOOL_OPTIONS`**, which the JVM reads
itself. `jvm.opts` defaults to `-XX:MaxRAMPercentage=75` rather than a fixed
`-Xmx` so the heap tracks `resources.limits.memory` instead of silently
diverging from it — 75% of the 1Gi limit is ~768Mi of heap, leaving ~256Mi for
metaspace, code cache, thread stacks and direct buffers. **A JVM whose heap does
not fit inside the container limit is OOMKilled by the kernel, not by the JVM,
and leaves no stack trace** — so if the pod is OOMKilled with no Java
`OutOfMemoryError`, non-heap is the overrun: lower this percentage rather than
raising the limit blindly.

On the ceiling: Kubernetes schedules by **requests**, not usage. On a node where
most memory is already reserved, a request larger than the remaining headroom
leaves the pod `Pending` no matter how much memory is actually free — and **a
namespace is an authorisation boundary, not a resource boundary on a single
node.** Raise `resources.requests.memory` against the target node's real headroom.

### 9. Cursor cleanup — undocumented upstream, and the reason a fresh sync OOMs

**This is the one that took the node down.** A first deploy synced for ~45 minutes, reached the
end of its sync, and then crash-looped **60 times**. The chart was not the cause and the memory
limit was not the fix.

`yaci-store`'s `CursorCleanupScheduler` deletes aged cursor rows with a Spring Data **derived
delete** — no `@Modifying`, no `@Query` — so **every matching row is loaded as a managed entity
before deletion**, inside one transaction. The ~45-minute sync accumulated ~1.65M rows, the first
post-sync run tried to materialise all of them, and the pod died of `OutOfMemoryError` → GC
thrash → liveness timeout → `SIGTERM`.

**It could not recover on its own.** The scheduler's `initialDelay` is 30 seconds, so every fresh
pod re-attempted the same oversized delete half a minute in, before it could make any progress.
That is a **self-perpetuating** restart loop, not a flapping one — no number of restarts helps.

**The lever is the interval, not the limit.** Each run deletes only what aged past the window
since the *previous* run, so the working set is set by how often it runs:

| Property | Env var | Upstream default | This chart |
|---|---|---|---|
| `store.cardano.cursor-cleanup-interval` | `STORE_CARDANO_CURSOR_CLEANUP_INTERVAL` | `3600` | **`60`** |
| `store.cardano.cursor-no-of-blocks-to-keep` | `STORE_CARDANO_CURSOR_NO_OF_BLOCKS_TO_KEEP` | `2160` | `2160` |

At 3600 a fresh sync hands its entire backlog to the first run. At 60 the same sync drains a
minute at a time — order ~36k rows per run instead of 1.65M. The divergence from the upstream
default is deliberate: **this chart's normal case is a from-genesis sync**, which is exactly the
case 3600 fails. Set either value to `null` to omit the variable and inherit upstream's.

> **⚠ Do not set `cursorNoOfBlocksToKeep` to `0`.** Zero does not mean "keep nothing" — it
> disables the cleanup bean entirely, trading a bounded OOM for **unbounded disk growth**
> (~1.65M rows per 45 minutes of sync) and giving up the rollback window with it. The chart
> honours an explicit `0` rather than silently dropping it, so nothing stops you but this line.

**The honest limit: this bounds a sync that is still running. It does not drain a backlog that
already exists.** A node that has already accumulated the rows must survive one large delete
regardless — raising `limits.memory` temporarily is the way through that, and then put it back.

**And the reason this matters more than the incident it came from: the margin was proportion, not
design.** 3Gi happened to fit a 45-minute preview sync at 94% of the ceiling. A modestly longer
sync exceeds any limit you pick, and on mainnet the same mechanism recurs at a larger scale.

**Why configuration rather than an upgrade:** it *is* fixed upstream — `2764ca6`, 2026-08-02,
set-based deletes with constant memory. But the latest release is `v2.0.2.1` from 2026-07-10,
which predates the fix, and the gap from what this image pins is `0.1.7 → 2.0.2.x` — a major
migration, for a fix that release would not even carry. Configuration is not the better answer
here; it is the only one.


---

## Secrets

**Three, and only three.** Nothing else in this chart is a secret.

| Property | Secret key (default) | Blast radius |
|---|---|---|
| `wallet.mnemonic` | `wallet-mnemonic` | **total loss of that wallet's funds** |
| `blockfrost.key` | `blockfrost-key` | quota theft; identifies the operator |
| `spring.datasource.password` **and** `spring.flyway.password` | `db-password` | database access |

This chart **never creates a Secret** and has **no plaintext fallback in either
mode** — a deliberate divergence from the `cardano-db-sync` and `midnight-node`
charts in this repo, which do offer one. Those guard a database password. This
one guards a BIP-39 wallet seed, in a repository that is public, and a fallback
path is a place for someone to type it.

```yaml
secret:
  name: ft-aquarium-node-secrets
  mode: file            # or: env
```

**`mode: file` is the default and the better one.** The Secret is mounted at
`secret.mountPath` (default `/etc/aquarium-secrets`) with `0400` files named for
the Spring properties, read via a Spring Boot config tree:

```
SPRING_CONFIG_IMPORT=optional:configtree:/etc/aquarium-secrets/
```

An environment variable is visible in `kubectl describe pod`, in the pod spec and
in Argo CD's UI, and this process signs and submits transactions with that seed.
A file is strictly better. **It also removes the mnemonic quoting hazard at the
root rather than warning about it** — a `WALLET_MNEMONIC` environment variable is
multi-word and word-splits if a file is ever sourced in a shell, leaking seed
words into stderr and shell history. A file has no word-splitting.

Note that **`db-password` is projected twice**, to
`spring.datasource.password` and `spring.flyway.password`. Flyway has its own
password property, separate from the datasource; miss the second and the
migration fails while the application itself would have connected fine.

**`mode: env` uses classic `secretKeyRef` variables instead.** It exists because
the config-tree path is **reasoned, not booted** against this image — it is
Spring's documented behaviour, but nobody has started the app to watch it bind.
If `file` mode fails with `wallet.mnemonic has no default`, switch to `env` and
the deployment proceeds while the question gets answered. Being wrong should be
cheap, not blocking. Both modes read the **same Secret with the same keys**; only
the projection differs, and neither puts a secret in this repository.

Leave `secret.name` empty and the secrets are absent from the render entirely —
the application then fails at startup with a named error, which is §3 working.

---

## No ingress, deliberately

`kupo` and `ogmios` in this repo both ship an ingress template, disabled by
default. **This chart ships none at all, and that is a decision, not an
omission.**

The node requires no inbound access — it dials out to the relay (TCP 3001),
Blockfrost and the oracle (HTTPS). Port 8080 needs to be reachable **in-cluster
only**, for the kubelet's probes and for Prometheus. And on that one port it
serves the **unauthenticated** `/api/v1` API *and* the Spring actuator, from a pod
holding a wallet seed. A disabled-but-present ingress would make exposing all of
that a one-line edit by anyone who installs the chart.

For debugging, use `kubectl port-forward`. If the loans API or metrics should be
published later, that is a deliberate decision — and it wants a path scoped to
`/api/v1`, not `/`.

---

## Chain source

`config.store.cardano.host` / `.port` — the relay the node dials over
node-to-node. The application's own preview profile ships this empty on purpose,
so it must be supplied; this chart defaults to the **public preview relay**
(`preview-node.world.dev.cardano.org:3001`) so it works out of the box.

An operator running their **own relay** should point this at it. If that relay is
on the **LAN** rather than the internet, the pod needs egress to a private
address range — worth stating because it is not the default assumption anywhere,
and a specific LAN address is deployment state that does not belong in this
public chart. Set it in your own values.

Either way, see the retry warning under §2: an unreachable relay does not fail
fast.

### Egress required

| Destination | Protocol |
|---|---|
| `config.store.cardano.host:3001` | TCP, node-to-node |
| `cardano-preview.blockfrost.io` | HTTPS |
| `testapi.fluidtokens.com` | HTTPS |

---

## Shutdown

`terminationGracePeriodSeconds` defaults to `60`. **Spring graceful shutdown is
not configured in the application**, so the default is immediate. The risk is
narrow but real: the executor signs and submits inside a scheduled cycle, so a
`SIGTERM` mid-submit can kill the process *after* the transaction reached the
network but *before* the decision log records it — the transaction lands and the
node's own record of it is lost. Enabling Spring's graceful shutdown is a
one-line application change, not something this chart can fix.

---

## Values

| Key | Default | Notes |
|---|---|---|
| `image.repository` | `fluidtokens/ft-aquarium-node` | FluidTokens' build, not ours |
| `image.tag` | `""` → chart `appVersion` (`2026.07.13`) | refused if `image.digest` is also set |
| `image.digest` | `""` | optional pin; **must belong to `image.repository`** — see §1 |
| `service.type` / `service.port` | `ClusterIP` / `8080` | no NodePort, no Ingress |
| `resources` | 512Mi/1Gi, 250m/1 | §8 — adequate at steady state; do not size from the §9 peak |
| `jvm.opts` | `-XX:MaxRAMPercentage=75` | via `JAVA_TOOL_OPTIONS`; `JAVA_OPTS` is read by nothing |
| `terminationGracePeriodSeconds` | `60` | app has no graceful shutdown |
| `startupProbe` / `livenessProbe` | `/actuator/health` | no readiness probe — §2 |
| `config.springProfile` | `preview` | required by the app; the only supported network |
| `config.db.*` | host `""`, port 5432, db `aquarium`, schema `public`, user `aquarium` | Postgres is consumed, not deployed — §7 on the username |
| `config.db.url` | `""` | composed from the parts above unless overridden |
| `config.store.cardano.host` / `.port` | public preview relay / `3001` | |
| `config.store.cardano.cursorCleanupIntervalSeconds` | `60` | **diverges from upstream's `3600`** — §9; `null` inherits |
| `config.store.cardano.cursorNoOfBlocksToKeep` | `2160` | upstream default; **`0` disables cleanup entirely** — §9 |
| `secret.name` | `""` | empty → no secrets in the render |
| `secret.mode` | `file` | or `env` — same Secret, different projection |
| `secret.keys.*` | `wallet-mnemonic`, `blockfrost-key`, `db-password` | keys within that Secret |
| `secret.mountPath` | `/etc/aquarium-secrets` | `file` mode only |
| `liquidation.mode` | `""` | `disabled\|shadow\|live`; empty → image default. **§5** |
| `liquidation.enabled` | `""` | second arming switch; **both required**. **§5** |
| `extraEnv` | `{}` | Spring property passthrough — **read §4 first** |
| `waitForPostgres.enabled` | `false` | optional TCP-wait init container |
| `serviceMonitor.enabled` | `false` | **off**: a ServiceMonitor against absent CRDs fails the install |
| `serviceMonitor.path` | `/actuator/prometheus` | |

Namespace is **not** a chart value. No chart in this repo sets
`metadata.namespace`; it comes from `helm -n` or Argo's `destination.namespace`.
Hard-coding it would let the chart and the deployment tool disagree.

---

## Verifying a change

`helm lint` alone is far too weak — it passes on charts whose templates fail to
render, and a render producing zero objects exits 0. Assert on what came out:

```bash
helm lint ./charts/ft-aquarium-node
helm template t ./charts/ft-aquarium-node | grep -c '^kind:'                    # 2

helm template t ./charts/ft-aquarium-node \
  -f ./charts/ft-aquarium-node/values-preview.yaml \
  --set secret.name=s --set serviceMonitor.enabled=true | grep -c '^kind:'      # 3

# file mode projects four property files from three keys:
helm template t ./charts/ft-aquarium-node --set secret.name=s \
  | grep -cE 'path: (wallet.mnemonic|blockfrost.key|spring.(datasource|flyway).password)'   # 4

# and the things that must never render, never render:
helm template t ./charts/ft-aquarium-node --set secret.name=s | grep -iE \
  'LIQUIDATION_MODE|LIQUIDATION_ENABLED|AQUARIUM_X_SUBMIT|kind: Ingress|readinessProbe|replicaCount'
# ^ must produce no output
```

## Provenance

Written 2026-08-24 from `ft-aquarium-node:docs/k8s-deployment-requirements.md`
at `2e3945c6` and its §9 answers at `43b4b1c`, plus a direct read of that repo's
`Dockerfile`, `docker/docker-compose.yaml` and
`src/main/resources/application.yaml`. The image digest and platform were
measured from the registry; the blueprint/coordinate mismatch in §4 was observed
on a real boot attempt.

**Unverified and labelled as such:** the `startupProbe` threshold,
`terminationGracePeriodSeconds`, the memory figures, and the config-tree
(`mode: file`) secret path — which is why `mode: env` exists. Everything else
here was read off an artefact rather than inferred.
