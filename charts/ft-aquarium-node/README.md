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

**This is FluidTokens' build from their `main`. It does not contain the
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

> The application repo's own `claude.md` documents this path as
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
> leave them unset. A quiet bot on this image is expected; a crash loop after
> setting them is this trap. Targeting a newer deployment requires a new image,
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

> **Setting either key restarts the pod, and restart is where the fatal boot
> verifiers run again (§3).** A node that has been up and quiet may not come back
> — and that would be the system working, not the arming failing. Read the first
> thirty seconds of logs and expect a *named* error. `strategy: Recreate` means
> the old pod is deleted before the new one starts, so expect a brief gap.

> **Nothing has ever armed this bot, in any environment.** The rendering above
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
stanza, and no hpa — deliberately, so nothing invites a 2.**

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
  automatic for any role: PG15 revoked `create` on the `public` schema from
  `public`. The role must **own the database** — ownership reaches the schema
  through `pg_database_owner` — or have been granted `create` on `public`
  explicitly. A connecting-but-non-owning role fails at the first migration
  rather than at connect, which again points away from the real cause.

Flyway must also reach Postgres before the application is usable.
`waitForPostgres.enabled` adds an init container that blocks until Postgres
accepts tcp. It is **off by default** so the chart declares no image it does not
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

> **Do not set `cursorNoOfBlocksToKeep` to `0`.** Zero does not mean "keep nothing" — it
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

### Secrets: one mechanism, a name and a key per source

There is **no chart-wide `secret.name`** and no chart-wide `secret.keys`. There
were, alongside this form, until 0.3.0 — and two ways to say the same thing is
one way too many, because a reader could not tell from a values file which was in
force.

The per-source form is the one that survived because it is the **superset**.
Point all three at the same Secret and you have exactly what `secret.name` did:

```yaml
secret:
  mnemonic:   {name: aquarium-secrets}
  blockfrost: {name: aquarium-secrets}
  db:         {name: aquarium-secrets}
```

Point them at different Secrets and you get what `secret.name` could not express
— the wallet in a Secret you control, the database credentials in the one the
Postgres operator generates and rotates:

```yaml
secret:
  mnemonic:   {name: aquarium-wallet}
  blockfrost: {name: aquarium-wallet}
  db:
    name: aquarium-db.credentials   # the operator's per-role Secret
    usernameKey: username           # it carries BOTH credentials
    passwordKey: password
```

Every key defaults to the name this chart has always used, so the common case
needs names only.

**Both database credentials can come from the Secret.** `usernameKey` is empty by
default, which leaves the username as the plain `config.db.username` value —
unchanged behaviour. Set it and the username comes from the Secret instead; the
chart then refuses to emit the plain value as well, so the two cannot silently
disagree (Kubernetes keeps the *last* duplicate env var, so the plain one would
have won).

> ⚠ **The username has the same two-property split as the password, and the two
> properties are not named alike.** The datasource wants
> `spring.datasource.username`; Flyway wants `spring.flyway.user` — `user`, not
> `username`. The chart projects both. Miss the Flyway one and the application
> connects as the right role while the *migration* connects as the default
> `fluidtokens`, which surfaces as a permissions error and reads as a broken
> migration rather than a wrong username.

> ⛔ **The key is `secret:`, singular.** A values file that says `secrets:` mounts
> nothing — Helm accepts unknown top-level keys silently and renders as though
> they were absent, so the application starts, resolves an empty mnemonic, and
> dies with `Invalid mnemonic phrase`: a message about the *value*, caused by the
> *key*, three layers from the typo. The chart now refuses that render by name.

**All three or none.** A partial set is refused at render. Naming `mnemonic`
while leaving `blockfrost` unnamed would produce a pod that starts, runs, and
only then fails against an API it cannot authenticate to — both
`wallet.mnemonic` and `blockfrost.key` default to `""` in the application, so
nothing fails fast. Naming nothing at all stays legal.

> **⛔ The seed stays a file.** In `file` mode the pod mounts a **projected**
> volume with one source per Secret, so three independent names land in one
> directory and the wallet mnemonic is still a `0400` file. Implementing this as
> three `secretKeyRef` environment variables would have put the seed in the pod
> spec — visible in `kubectl describe pod` and in Argo's UI — reversing this
> chart's central security decision as a side effect of a refactor.

### The database: off by default, zero-config when on

`postgres.enabled` is **`false`**. Turning it on renders a `postgresql` CR for
the **Zalando Postgres operator**, and `helm install` fails with `no matches for
kind postgresql` on a cluster without that operator's CRD — so it is off, for the
same reason `amaru`'s `serviceMonitor` is: a public chart must not default to on
a cluster capability it cannot verify.

> ⚠ **Our own deployments set it `true` INLINE, in the Argo application — not in
> a values file.** That is why this default disagrees with how we run it. Argo
> supplies values inline, so an operator never opens `values-preview.yaml` and
> would silently inherit `false`; a preset here would read as coverage and give
> none. The switch belongs with the thing that describes the deployment.

**When it is on, no other database value needs setting.**

```bash
helm install aquarium easy1staking/ft-aquarium-node --set postgres.enabled=true
```

is a complete database configuration on its own:

| | derived from |
|---|---|
| credentials | the Secret the operator generates — name computed from `postgres.username` + `postgres.clusterName`, per its `{user}.{cluster}.credentials.postgresql.acid.zalan.do` convention |
| host | the cluster the CR creates (`postgres.clusterName`), resolved in one helper because the host is read three times |
| database | `config.db.database`, the same value the CR asks the operator to create |

Nothing is restated, so nothing can drift: rename the cluster and the Secret
reference, the host and the CR all move together. Set `config.db.*` yourself only
when bringing your own Postgres, with `postgres.enabled: false`.

**Default-wired, never default-valued.** The chart ships a *reference* to a
Secret whose contents it does not create. It ships no credential — this
repository is public.

**The credentials arrive as files, not environment variables** — the chart's
`file` mode, the same projection as the wallet secrets, so the password stays out
of `kubectl describe pod` and Argo's UI. `secret.db.mode: env` gives the classic
`secretKeyRef` pair instead.

A `clusterName` that does not start with `teamId` is refused at render: the
operator enforces that at *reconcile* time, not at apply, so a wrong name is
otherwise accepted and then silently does nothing.

### Migrating from 0.2.0

Breaking for anyone who used the single-name form. The removed paths **fail the
render** with a message rather than being ignored — an unknown key in Helm values
is not an error, so a stale values file would otherwise have rendered a pod with
no secrets at all, silently.

| 0.2.0 | 0.3.0 |
|---|---|
| `secret.name: X` | `secret.mnemonic.name: X`, `secret.blockfrost.name: X`, `secret.db.name: X` |
| `secret.keys.walletMnemonic: K` | `secret.mnemonic.key: K` |
| `secret.keys.blockfrostKey: K` | `secret.blockfrost.key: K` |
| `secret.keys.dbPassword: K` | `secret.db.passwordKey: K` |
| `secret.dbPasswordFrom.secretName: X` | `secret.db.name: X` (and `secret.db.mode: env` if you want the env projection it forced) |
| `secret.dbPasswordFrom.key: K` | `secret.db.passwordKey: K` |

Also new in 0.3.0: the chart can provision the database. `postgres.enabled` is
off by default and changes nothing unless you turn it on. `secret.db.usernameKey`
now defaults to `username` and `passwordKey` to `password` — the Zalando
operator's own key names — so if you bring your own Secret with different key
names, set them explicitly.

**`secret.db.mode`** is the one per-source projection override, because the DB
password is the only one that is operator-owned and rotatable. It follows
`secret.mode` by default.

**You probably do not need `env` for it.** The rotation defect that first
motivated an env var was a stale *copy* of the password inside our own Secret —
not the projection mechanism. Pointing `db.name` straight at the operator's
Secret keeps no copy, so **file mode survives rotation too**, and keeps the
password out of the pod spec. `env` stays available.

⚠ Whichever mode `db` uses, **`spring.datasource.password` and
`spring.flyway.password` are two separate properties**. In env mode one variable
covers both; in file mode each needs its own file, and the chart projects the one
key twice. Miss the Flyway one and the application connects while the migration
fails to authenticate — which reads as a bad secret and is not.

`secret.dbPasswordFrom` is **deprecated** but still honoured, and still forces
`db.mode: env` as it always did, so a values file written against the earlier
shape does not silently change projection on upgrade.

### The DB password can come from the Postgres operator instead

`secret.dbPasswordFrom` points the database password at a Secret **this chart
does not own** — in practice the one the Zalando Postgres operator generates for
its managed role:

```yaml
secret:
  name: ft-aquarium-node-secrets     # still holds the mnemonic and the API key
  dbPasswordFrom:
    secretName: aquarium-db.credentials   # the operator's Secret
    key: password
```

**Why it exists.** The projected copy is a **snapshot**. The operator *rotates*
the role's password; its Secret changes and the copy does not. The running pod
keeps working on its open connection, so nothing looks wrong — and then
**cannot survive its next restart**, because the password it presents is stale.
Referencing the operator's Secret by name removes the copy, and with it the
drift.

**What changes in the render.** Exactly two things: the two `db-password` items
disappear from the file projection, and a `DB_PASSWORD` environment variable
appears, sourced from the named Secret. **One variable covers both Spring
properties** — verified against the shipped `application.yaml`, where
`spring.datasource.password` and `spring.flyway.password` are both
`${DB_PASSWORD:password}`. The "project it twice" rule above is about **file**
mode, where each property needs its own file, and it stays true there.

**The trade-off, stated rather than slipped in.** This makes the DB password an
environment variable — visible in `kubectl describe pod` and in Argo's UI. That
is a genuine regression in hygiene and it is accepted deliberately, because the
argument for `file` mode is about protecting the **signing seed**, and the seed
does not move: `wallet-mnemonic` and `blockfrost-key` stay files. Of the three
secrets, the DB password has the smallest blast radius and is the only one that
is operator-owned and rotatable. Rotation you survive beats a projection you do
not.

Empty `secretName` (the default) changes nothing, and **no values file in this
chart ships it set** — same rule as the liquidation flags: a stranger's
`helm install` must not reference a Secret that exists in one cluster only.

---

## No ingress, deliberately

`kupo` and `ogmios` in this repo both ship an ingress template, disabled by
default. **This chart ships none at all, and that is a decision, not an
omission.**

The node requires no inbound access — it dials out to the relay (tcp 3001),
Blockfrost and the oracle (HTTPS). Port 8080 needs to be reachable **in-cluster
only**, for the kubelet's probes and for Prometheus. And on that one port it
serves the **unauthenticated** `/api/v1` API *and* the Spring actuator, from a pod
holding a wallet seed. A disabled-but-present ingress would make exposing all of
that a one-line edit by anyone who installs the chart.

For debugging, use `kubectl port-forward`. If the loans API or metrics should be
published later, that is a deliberate decision — and it wants a path scoped to
`/api/v1`, not `/`.

### The one exception: `service.type: NodePort`

The operator readiness page is served by this pod and is meant to be opened in a
browser, so `service.type` accepts `NodePort` on **any** network:

```yaml
service:
  type: NodePort
  nodePort: 30080   # empty = Kubernetes assigns one and keeps it across upgrades
```

**Neither this nor the UI is ever on by default.** `values.yaml` is `ClusterIP`
with `loans.ui.enabled` unset on every network; only a deploying operator's own
values turn them on. `values-preview.yaml` does so for Giovanni's preview box
and says why at the value.

Pinning makes the URL knowable in advance and survives the Service being
recreated. **The trade is that a pinned port another Service already holds fails
the apply** — `provided port is already allocated` — where an assigned one
cannot. It must sit inside the node-port range (`30000-32767` by default).

**What a NodePort publishes, and why it is tolerable on a trusted LAN.** Port
8080 carries everything: `/healthcheck`, the actuator, and the unauthenticated
`/api/v1`. Two facts make that read-only, and **both are properties of the
application, not of this chart** — re-check them before widening exposure:

| | |
|---|---|
| Every `/api/v1` route is **GET-only** | no `POST`/`PUT`/`DELETE` exists, so nothing reachable can move funds or arm anything |
| Actuator exposure is `health,prometheus` | set in the application's own configuration with no profile overriding it, so `/env`, `/configprops` and `/beans` are unreachable |

The wallet seed is served by no endpoint. What is exposed is LAN-wide **read**
access to lending positions and the node's wallet address — fine on a home LAN,
not fine on an untrusted network, where `kubectl port-forward` remains the
answer. If the application ever gains a mutating route or widens its actuator
exposure, this trade changes and the Service should go back to `ClusterIP`.

---

## What `application.yaml` does not tell you

Most of this chart's parameters are readable from the application's
`application.yaml`, where each is an `${ENV_VAR}` placeholder. **Four groups are
not there at all** — they are bound in Java, so a chart derived from that file
alone misses them silently. It did, until 0.2.0.

### `loans.submittableNetwork` — the last arming barrier

A node with `liquidation.mode: live` **and** `liquidation.enabled: true` still
submits **nothing** unless the running network matches this string; it records
the `NETWORK_NOT_PREVIEW` veto and stops. One word separates a node that cannot
spend from one that can.

The chart renders `preview` **explicitly** rather than leaving it unset. Unset is
safe today because the image's default is also `preview` — but that default lives
in someone else's code, and the failure direction if it ever moves is a node that
can suddenly spend. **Never set this to `mainnet`.**

### `loans.minswap.*` — mainnet defaults on a network-agnostic chart

Four coordinates for the CONVERT path, and **their built-in defaults are mainnet
values** (`poolAddress` is an `addr1…`). A preview node that inherits them
derives a convert action that cannot exist there. The chart ships all four empty:
there is no value correct on both networks, so the operator must supply them.

### `convert.*` and `markets[]`

`convert.enabled` defaults **true** in the image, unlike most switches here.
`markets` is a **list**, and the only shape the application binds from the
environment is Spring's indexed form, which the chart renders for you:

```yaml
markets:
  - unit: lovelace
    mode: SHADOW          # DISABLED | SHADOW | LIVE
    action: ANTICIPATE    # CONVERT | ANTICIPATE
    cap: 50000000         # MANDATORY for ANTICIPATE, meaningless otherwise
```
→ `LOANS_LIQUIDATION_MARKETS_0_UNIT`, `_MODE`, `_ACTION`, `_CAP`

The global `liquidation.mode` is a **ceiling**: a market's own mode can only be
equal or more restrictive. An unlisted market runs at the node's own mode, so an
empty list is legal and is the default.

**A malformed entry aborts the application's startup** — unknown mode, bad unit,
duplicate unit, or `ANTICIPATE` without a cap. The chart validates all of those
**at render**, so a typo is a refused upgrade rather than a crash-loop.

### The ninth reference script

`liquidation.referenceScripts.lmLiquidateAndConvertAction` does **not** follow
its siblings' naming — the other eight map to `AQUARIUM_LIQUIDATION_REF_*`, this
one is Java-bound and reaches the app as
`LOANS_LIQUIDATION_REFERENCE_SCRIPTS_LM_LIQUIDATE_AND_CONVERT_ACTION`. Omitting
it does not degrade the convert path: that validator then travels inline and the
transaction **exceeds `maxTxSize`**.

> ⚠ **Reference-script coordinates are deliberately empty in every values file
> here.** `LoansReferenceScriptVerifier` hard-fails at boot on a coordinate that
> no longer publishes the expected hash, so a chart shipping stale coordinates
> does not degrade — it crash-loops. A stale coordinate is worse than an absent
> one, which is why this public chart defaults none.

---

## Numbers in a values file were being mangled — fixed in 0.2.0

**Helm parses every number from a values file as `float64`**, and Go's `toString`
renders a large `float64` in scientific notation. Before 0.2.0,
`liquidation.profitMarginLovelace: 1500000` in a values file reached the
container as **`1.5e+06`**, which no Java `long` parses.

It looked fine in testing because `--set` takes a different path and yields an
`int64`. The chart now reformats integral floats before emitting them. If you are
on 0.1.0 and set lovelace amounts through a values file, this affects you.

---

## Compounding is a second arming switch

`compound.enabled` arms the **repayment-escrow** path: collect a repaid loan's
principal from the asset manager and deliver it into the lender's pool, keeping
the pool owner's compounding fee. It is a **different on-chain action** from
liquidation, with its own executor.

**Arming one does not arm the other, in either direction.** A deployment that
has `liquidation.enabled: true` is not compounding, and a deployment that has
`compound.enabled: true` is not liquidating.

Two things about `compound.profitMarginLovelace` are worth knowing before you
set it:

- **`0` is a real setting, not "unset".** It refuses every net loss while
  allowing exact break-even. The chart emits it correctly — any value whose
  string form is non-empty reaches the container, so `0` and `false` are not
  dropped as falsy.
- **A negative value arms compounding for pools that pay nothing.** The fee rate
  is set by the pool owner, not by this node; a zero-fee pool nets exactly minus
  the transaction fee and is refused out of the box. Negative is a figure the
  operator *states and owns* — it still bounds the loss, since anything worse
  than the figure is refused. It is not a protection being switched off, which
  is why there is no `ignoreProfitCheck` twin here. **On mainnet a negative
  value is a hard startup failure by design.**

As with liquidation, **no values file in this repository sets any of it**, and
that absence is the design.

---

## Chain source

`config.store.cardano.host` / `.port` — the relay the node dials over
node-to-node. The application's own preview profile ships this empty on purpose,
so it must be supplied; this chart defaults to the **public preview relay**
(`preview-node.world.dev.cardano.org:3001`) so it works out of the box.

An operator running their **own relay** should point this at it. If that relay is
on the **lan** rather than the internet, the pod needs egress to a private
address range — worth stating because it is not the default assumption anywhere,
and a specific lan address is deployment state that does not belong in this
public chart. Set it in your own values.

Either way, see the retry warning under §2: an unreachable relay does not fail
fast.

### Egress required

| Destination | Protocol |
|---|---|
| `config.store.cardano.host:3001` | tcp, node-to-node |
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

## The application's parameter surface

**Every parameter the application reads is settable here, and every one is empty
by default.** Empty means *the chart says nothing* and the image's own
per-profile default governs — which is safer than the chart restating that
default, because a restated default goes stale silently when the image moves.

Two labels on every row, and they are not decoration:

- **gate** — loosening it can make the node spend funds, submit something it
  should not, or run against unverified contracts. **Tuning.** — tuning; wrong
  values cost throughput or silence, not money.
- **[documented]** — the application's own `application.yaml` maps this exact
  environment variable. **[derived]** — reachable only through Spring's relaxed
  binding; the mapping is asserted from Spring's documented behaviour and **has
  not been watched binding on this image.** If a `[derived]` key appears to do
  nothing, that is the first thing to suspect.

### Arming — there are three switches, not two

| key | env | effect |
|---|---|---|
| `liquidation.mode` | `AQUARIUM_LIQUIDATION_MODE` | `disabled` skips the cycle · `shadow` scans, builds, prices and records but never submits · **`live` submits real transactions that spend real funds**, burns a loan NFT and moves someone else's collateral |
| `liquidation.enabled` | `AQUARIUM_LIQUIDATION_ENABLED` | the second switch; `live` alone does nothing and `true` alone does nothing |
| `liquidation.ignoreProfitCheck` | `AQUARIUM_LIQUIDATION_IGNORE_PROFIT_CHECK` | **the third, and the one nobody expects.** The application's own source: *"disables both profitability gates"*. Every candidate becomes submittable whether or not the liquidation pays for its own transaction — **the node will spend to lose money.** The app refuses to start with this true on mainnet, which is the measure of what it is |

**An operator who reviews `mode` and `enabled` and concludes the bot is bounded
has checked two of three.** This chart previously exposed only those two.

**No values file in this repository sets any of them, and none may.** The chart
is public and installable by anyone; a preset that arms a transaction-signing bot
arms it for everybody who runs `helm install` to see what it does. Arming is a
deliberate act in the deploying operator's own values, outside this repo.

### Economics — gates, not knobs

| key | env | effect |
|---|---|---|
| `liquidation.checkProfitability` | `…_CHECK_PROFITABILITY` | applies the absolute floor; `false` removes that gate and leaves only the margin |
| `liquidation.minExpectedProfitLovelace` | `…_MIN_EXPECTED_PROFIT_LOVELACE` | the margin-adjusted floor, and the second of two. Negative authorises the bot to spend its own ada, up to that amount per liquidation, to move a borrower's collateral. **Both floors must be negative for a loss to get through** — setting only one changes nothing, and the application logs which floor is still holding |
| `liquidation.minProfitAbsoluteLovelace` | `…_MIN_PROFIT_ABSOLUTE_LOVELACE` | the floor, tested **before and independently of** the margin — lowering the margin can never rescue a candidate this refuses. Negative is a deliberate acceptance of mark-to-oracle economics: a convert liquidation fronts principal in ADA and receives collateral in tokens |
| `liquidation.profitMarginLovelace` | `…_PROFIT_MARGIN_LOVELACE` | profit = fee value − tx fee − this. Covers the reference-script surcharge and refuses dust liquidations. Lowering it admits smaller candidates |
| `loans.enabled` | `LOANS_ENABLED` | master switch. **Off also disables the two startup verifiers**, so a node with wrong coordinates starts quietly instead of refusing — safe for the bot, and it removes a correctness check |
| `loans.verifyConfig.failOnUnreachable` | `LOANS_VERIFY_CONFIG_FAIL_ON_UNREACHABLE` `[derived]` | whether an **unreachable** backend fails the reference-script verifier. `false` (the default) starts anyway, so the node can run **without having verified its scripts**. A genuine hash *mismatch* is fatal either way — this governs only the can't-tell case. **See below for how to tell which happened** |

### · Timing and behaviour

| key | env | effect |
|---|---|---|
| `liquidation.delaySeconds` | `…_DELAY_SECONDS` | interval between cycles |
| `liquidation.validityWindowSeconds` | `…_VALIDITY_WINDOW_SECONDS` | transaction validity window |
| `liquidation.oracleWindowMarginSeconds` | `…_ORACLE_MARGIN_SECONDS` | required headroom inside the feed's window. Raising it shortens the usable stretch one second for one; near the feed window it disables the bot in practice while every candidate merely reports `ORACLE_WINDOW_MARGIN_TOO_SMALL` — **which reads as "no candidates" rather than as a misconfiguration** |
| `liquidation.quarantineMinutes` | `…_QUARANTINE_MINUTES` | how long a failed loan is skipped |
| `liquidation.decisionLogSize` | `…_DECISION_LOG_SIZE` | in-memory decision ring buffer |
| `loans.oracle.enabled` | `LOANS_ORACLE_ENABLED` | off ⇒ every collateral prices as unavailable, so nothing is liquidatable |
| `loans.oracle.url` | `LOANS_ORACLE_URL` | wrong network's registry ⇒ collaterals silently price as unavailable |
| `scheduling.transactionProcessorDelayMinutes` | `SCHEDULING_TRANSACTION_PROCESSOR_DELAY_MINUTES` | |
| `scheduling.taskPoolSize` | `SPRING_TASK_SCHEDULING_POOL_SIZE` | Spring's default of 1 lets the transaction processor starve the 30 s oracle refresh — observed as feeds ageing past expiry exactly while transactions were processing. The app corrects it to 4; lowering it reintroduces that |
| `config.network` | `NETWORK` `[derived]` | the app derives this from the Spring profile. Setting it **overrides** that, so profile and network can disagree. Leave empty unless you mean to break the link |
| `blockfrost.url` | `BLOCKFROST_URL` `[derived]` | base URL only — the **key** is a secret and is not settable here |

> **"The verifier did not object" and "the verifier ran" are different
> statements, and with `failOnUnreachable: false` you cannot tell them apart from
> a summary line.** The absence of a complaint is also what a skipped check looks
> like.
>
> **Look for positive evidence of a completed round trip instead**: log lines
> reading `Read ConfigDatum from <txHash>#0` and `Read LMConfigDatum from
> <txHash>#1`. **A verifier that skipped on an unreachable backend could not have
> read two datums off specific UTxOs.** The field tally that follows
> (`21 checked / 0 skipped / 0 mismatched`) is then meaningful; on its own it is
> not.

### Reference scripts — buildability, not safety

`liquidation.referenceScripts.{loan, loanSpend, lenderManager, lenderManagerSpend,
loanClaimAction, lmLiquidateAction, lmLiquidateAndPayInAdvanceAction, assetManager}`
→ `AQUARIUM_LIQUIDATION_REF_*`, each a `txHash#index`. `[documented]`

A validator with a coordinate travels **by reference**; one without travels
**inline** in the witness set. All-inline exceeds `maxTxSize` and cannot build, so
at least one must be published.

> **A coordinate whose on-chain script hash does not match the derived one is a
> hard startup failure, by design.** A stale coordinate is worse than an absent
> one, and the verifier says so loudly rather than running the wrong script.
> **Blank them on a redeploy rather than leaving them stale** — and see §4, which
> is the trap in the other direction.

### Contract identity — `[derived]`, and guarded by the verifiers

`loans.config.{policyId, refUtxoTxHash, assetName}` · `loans.lmConfig.policyId` ·
`loans.smartTokensSpendScriptHash` · `aquarium.genesis.{txHash, outputIndex}` ·
`aquarium.staking.token.{policy, name}` · `aquarium.tank.refInput.{txHash, outputIndex}`

Wrong values do not silently run the wrong contracts: `LoansConfigVerifier`
derives every script hash from them and **refuses to start on a mismatch.** That
refusal is the protection — do not disable it to get past a mismatch.

### `extraEnv` and the one thing it may no longer do

`extraEnv` stays available for anything the chart does **not** emit — the
thirty-ninth parameter arrives with the next application release and an operator
must not be stuck until the chart catches up.

**But a key that has a typed home is refused at render**, naming the key to use
instead. Kubernetes takes the last duplicate, so `extraEnv` would silently beat a
documented default and leave the reader with false confidence in the value they
can see. **Fail on collision, not on use.**

---

## Upgrading: 36 parameters moved out of `extraEnv`

**If you set any application parameter through `extraEnv`, read this before you
upgrade.** Until this version only `liquidation.mode` and `liquidation.enabled`
had typed keys; every other parameter was reachable *only* through `extraEnv`.
**All 38 now have typed keys, and `extraEnv` refuses the 36 that newly gained
one.**

The render fails with the key named:

```
Error: extraEnv sets AQUARIUM_LIQUIDATION_PROFIT_MARGIN_LOVELACE, which has a
typed values key in this chart. Set that key instead — extraEnv would silently
override it.
```

**Under GitOps this presents as a sync error, not as a configuration error** —
the tool will not sync a release that will not render, so a running deployment
stops on a message about templating. That is the shape nobody debugs quickly,
which is why it is written here rather than left to the error alone.

**The migration is mechanical**: every `AQUARIUM_LIQUIDATION_*`, `LOANS_*`,
`AQUARIUM_GENESIS/staking/TANK_*`, `BLOCKFROST_URL`, `NETWORK`,
`SCHEDULING_*` and `SPRING_TASK_SCHEDULING_POOL_SIZE` entry moves to the key
listed for it in the tables above. For example:

```yaml
# before
extraEnv:
  AQUARIUM_LIQUIDATION_PROFIT_MARGIN_LOVELACE: "1500000"
  AQUARIUM_LIQUIDATION_REF_LOAN_CLAIM_ACTION: "48c102c0…#0"
# after
liquidation:
  profitMarginLovelace: 1500000
  referenceScripts:
    loanClaimAction: "48c102c0…#0"
```

> **Move them in the same apply that adopts the new chart.** The typed keys do
> not exist in the older chart, so a values change first is a values change that
> does nothing; a chart change first is a render failure. **One atomic change,
> never two.**

### Why the refusal exists, so nobody routes around it

**The obvious reading of this is "the chart got stricter for no reason", and the
obvious workaround is to pin back to the previous version — which reinstates
exactly the silent shadowing the refusal exists to prevent.** So:

A value set in both places does not error in Kubernetes. **The last duplicate
wins, silently.** So a chart that documents `liquidation.profitMarginLovelace:
1500000` while an `extraEnv` entry quietly supplies something else gives the
reader a documented default they can see and a real value they cannot.
**A documented default that an override silently beats is worse than no
documentation, because the reader now has false confidence.**

**And this is not hypothetical — it is how the deployment that asked for this
guard was configured.** Recorded by the operator it happened to:

> *"I did not fail to notice the class. I noticed the hazard, named it, fixed the
> one instance in front of me, and never asked 'where else does this shape live?'
> — that is a different and more common failure than inattention, and it is the
> one the guard actually protects against."*

Three of five parameters were still on `extraEnv`, set by the person who
identified the hazard, cared about it, and had already acted on it once. **A
reader thinking "I would never do that" has just been shown someone who did.**

**The reason this shape is dangerous is that it looks like diligence.** Spotting a
hazard, naming it and fixing an instance is visibly good work — and that is
exactly what makes the remaining instances harder to find, because the item now
reads as closed. **A hazard nobody noticed stays open in everyone's mind; a hazard
someone fixed is filed.**


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
| `waitForPostgres.enabled` | `false` | optional tcp-wait init container |
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
