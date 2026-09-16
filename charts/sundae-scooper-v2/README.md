# sundae-scooper-v2

The SundaeSwap **scooper v2** — the program that produces the "scoops"
(transactions) executing v4 DEX swaps. A single Rust binary from
`ghcr.io/sundaeswap-finance/scooper-v2`.

> ⚠ **ALPHA — no scooper has yet been run from this chart.** Published as a
> pre-release, so `helm search`/`helm install` will not select it without
> `--devel` or an explicit version.

## Every network is equal here

There is **no mainnet guard** — no refusal, no warning flag, no confirmation
step. Giovanni's ruling, 2026-09-15, and a softer guard would be the same guard.
`network: mainnet` runs on mainnet.

What differs is the **default**, not what is possible: this chart is public and
installable by a stranger, so it defaults to `preview` and ships no key, and
every value that decides identity or funds is empty and **fails the render**.

## Config: you supply upstream's, the chart layers over it

⛔ **No network config ships in the image.** Upstream's Dockerfile says so
outright — *"No network config ships in the image; bind-mount one at
/app/config.json."* There is nothing to inherit.

The binary takes **one or more `--config` files, applied in order**, each
overriding the last. Upstream's v4 config is ~40 coordinates deep: nine module
scripts each with a hash and a reference UTxO, a 350-element Plutus V3 cost
model, slot config, script hashes, a starting point. All of it must match
on-chain state, and upstream changes it when the DEX redeploys.

⇒ **So this chart does not retype any of it.** You put upstream's files
verbatim in a ConfigMap you own; the chart passes each as `--config` and then
adds its own overlay **last**:

```yaml
config:
  existingConfigMap: sundae-scooper-v2-config   # you create it
  files: [preview.json, preview-v4.json]        # order matters
```

The overlay carries only what Kubernetes decides — the SQLite path, the listen
addresses, the secret key path, the mempool socket. Upstream's examples point
sqlite at a relative filename and the socket at `/home/ec2-user/…`, both correct
for their host and wrong here.

### ⛔ An unknown config key is silently ignored

Measured, not assumed: config loads through the `config` crate with serde, and
the repository contains **no `deny_unknown_fields`**. A misspelled key does not
fail — it is **never applied**, and the scooper runs a compiled default nobody
chose. `helm template`, `helm lint` and a rendered diff all look correct.

```bash
./charts/sundae-scooper-v2/verify-config-schema.py <your-values.yaml>
```

Asserts the overlay's exact key set against an allowlist taken from upstream's
own config files and structs. **Run it after any edit to
`templates/configmap-overlay.yaml`.**

## The signing key

⛔ **No key value exists in this chart and none must be added.** The chart
references a Secret you created out of band and never creates, templates or
echoes it. Upstream also accepts an *inline* key and its example config ships a
dummy one; this chart offers no path to that, and upstream agrees — *"prefer
this over the inline key"*.

```yaml
secret:
  name: sundae-scooper-v2-preview   # both overridable; the chart has no opinion
  key: scooper.skey
```

### ⛔ 0.7.0 is the floor for envelope keys

`normalize_secret_key_hex` — the function that accepts a cardano-cli envelope at
all — **does not exist at 0.6.0 or 0.6.1.** It arrived in **0.7.0** ("mainnet
readiness: address network, staked pool addresses, bip32 key files"). So on 0.6.x
an envelope key is not undocumented, it is **unparsed**.

⚠ **And the image tag has no `v`**: GHCR carries `0.7.2`; `v0.7.2` is the git
release tag and a 404 as an image tag. Upstream's own README example
(`scooper-v2:v0.6.0`) has the same mistake, so copying their docs gives
`ImagePullBackOff`. Verified newest, 2026-09-16: **`0.7.2`**, digest
`sha256:c74b697f…484b18b4`.

### What to put in it

| form | accepted | validated at load |
|---|---|---|
| **raw hex**, 32 bytes (64 chars) or 64 bytes (128 chars), no `0x` | ✅ | ❌ **nothing** |
| cardano-cli **JSON envelope**, `cborHex` a CBOR bytestring of 32 (`5820`), 64 (`5840`) or 128 (`5880`) bytes | ✅ | ✅ |
| **bech32** `ed25519_sk…` | ❌ | — |

⛔ **The raw-hex path validates nothing.** Upstream's `normalize_secret_key_hex`
returns any non-`{` input verbatim — no length check, no hex check. A wrong
length, a `0x` prefix or a bech32 string all load cleanly and fail later and
deeper. **"The scooper started" is not evidence the key is well formed.**

The 128-byte envelope *is* checked: its embedded public key must match the one
derived from the secret, so a mislaid layout is rejected rather than signing with
the wrong key.

⇒ **Check a key without revealing it**: upstream ships
`cargo run --example keyhash -- <hex>`, which prints the blake2b-224 hash of the
**public** key and panics on a bad length.

### ⚠ If your key came from an HD wallet, set `stakeKeyhash`

Unset, the scooper derives an **enterprise** (payment-only) address. Upstream's
own warning: CIP-1852 wallets use base addresses, and *"funds sent to those
addresses are unreachable from an enterprise address."* Fresh testnet keys with
no staking are fine without it.

## ⛔ v3-only means OBSERVER. There is no v3 signing key.

`v4.enabled: false` does not mean "scoop v3 pools only". It means **index and do
not scoop**, and that is a property of the binary, not of this chart:

- `SundaeV3Protocol` has **no execution field** — only `order-script-hashes`,
  `pool-script-hash`, `settings-script-hash`, `settings-nft`, `starting-point`.
- `src/sundaev3/builder.rs` contains **no signing code at all**.
- every build-and-submit path runs through `v4_execution`
  (`match &self.v4_execution` in the scooper loop).

⇒ **So there is nowhere else to put a key.** A v3-only deploy syncs, serves
`/dashboard`, `/metrics` and the pool and order listings, and produces no scoops
and earns no fees. That makes it a genuine first deploy — it proves the image,
the config, the mount and the sync without touching funds — and it is not a
working scooper. `secret.name` is therefore optional with v4 off and **required**
with v4 on.

## ⛔ Why a partial `protocol.v4` is fatal and an absent one is fine

`protocol.v4` is an `Option`, so its **mere presence** switches v4 on. Once
present, `ScooperExecution` demands its required fields — and serde reports them
**one at a time**, so each deploy reveals exactly one more.

An absent block is handled: `src/main.rs` logs *"mempool.execute set but no v4
execution config; observing only"*.

⇒ **So the chart gates the whole object and never its members.** An earlier
version emitted an execution object containing only a key-file path — complete
enough to switch v4 on, empty enough to fail — and the first deploy died with
`missing configuration field "protocol.v4.execution.submit-url"` in under a
second, on a 70-byte log, before anything else ran.

### The complete required set, enumerated from source rather than discovered

`ScooperExecution` has **exactly six** fields with no default:

| | |
|---|---|
| `submit-url` | String |
| `fee` | (u64, u64) |
| `protocol-share` | (u64, u64) |
| `module-scripts` | nine modules, each a hash + ref-utxo |
| `plutus-v3-cost-model` | 350 integers |
| `slot-config` | zero-slot, zero-time, slot-length |

⇒ **All six are already present in upstream's `preview-v4.json`.** So enabling
v4 is not a matter of filling them in — it is a matter of *loading upstream's v4
file*, which the chart does via `config.files`. The chart's overlay contributes
only the key-file path on top.

⚠ **But upstream's `submit-url` is a Blockfrost URL carrying their project id in
the query string.** That is a credential, it is not ours, and it must not be
copied into this public repo. See the v4 plan below.

## Turning v4 on

```yaml
config:
  existingConfigMap: sundae-scooper-v2-config
  files: [preview.json, preview-v4.json]     # BOTH — see below
v4:
  enabled: true
secret:
  name: sundae-scooper-keys                  # required once v4 is on
  key: scooper.skey
submitUrl: "http://<your-ogmios-svc>.<namespace>.svc.cluster.local:1337"
```

**Both files, and the second supplements rather than replaces.** `preview.json`
carries `protocol.v3` and the acropolis block (the node address, the Mithril
aggregator); `preview-v4.json` carries `protocol.v4`, `persistence` and
`protocol.bootstrap` and **no acropolis section at all**. Load only the v4 file
and the scooper has no node to connect to.

```bash
kubectl -n <ns> create configmap sundae-scooper-v2-config \
  --from-file=scooper-v2/config/preview.json \
  --from-file=scooper-v2/config/preview-v4.json
```

⚠ **That second file contains upstream's own Blockfrost project id**, in
`protocol.v4.execution.submit-url`. It is public and theirs, so this is not a
leak — but once `submitUrl` overrides it, a credential-shaped string sits unused
in your ConfigMap, and it is better to know that than to find it.

### ⛔ Why `submitUrl` is required the moment v4 is on

Config files are applied **in order, later overriding earlier** — upstream
documents this. So `submitUrl` is what *displaces* their Blockfrost URL. Leave it
empty and the scooper submits through **SundaeSwap's Blockfrost account**. It
would probably work, which is exactly the problem: not your credential to spend,
and nothing looks wrong.

The chart therefore refuses to render without it, refuses a `blockfrost.io` URL
(its project id lives in the query string, and this repo is public), and refuses
`ws://`. `verify-config-schema.py` additionally asserts the overlay's
`submit-url` **equals** your `submitUrl` — because "v4 keys present" would pass
while upstream's URL remained in force.

### The Ogmios URL, exactly

The Ogmios branch does an **HTTP POST with a JSON-RPC body**
(`{"jsonrpc":"2.0","method":"submitTransaction",…}`), so: **`http://`, not
`ws://`, and no path** — Ogmios serves JSON-RPC at the root.

⛔ **And Ogmios is the fallback branch**: the scooper reaches it by the URL
matching *neither* `blockfrost.io` *nor* `/api/submit/tx`. **There is no
validation of the shape at all.** A malformed URL is not rejected — it is POSTed
to as though it were Ogmios, and the failure names neither Ogmios nor the real
cause. The only proof that submission works is a submitted transaction.

### ⚠ Check Ogmios has a node behind it first

An Ogmios that answers HTTP with no node attached will accept this config and
fail at submission — tonight's failure shape, one layer out.

```bash
curl -s http://<ogmios>:1337/health
```

Healthy looks like `"connectionStatus": "connected"` with
`"networkSynchronization"` at or near `1.0` and a plausible `currentEra` and
`lastKnownTip`. `"disconnected"` means the node wiring is wrong, not the scooper.

⚑ `charts/ogmios` in this repo already solves that wiring the same way this chart
does for the mempool: a `socat-socket-server` sidecar bridging
`socat.host`/`socat.port` (TCP) to a unix socket at `nodeSocketPath` in a shared
volume, because Ogmios wants `--node-socket` and a node in Kubernetes publishes
over TCP. **If `socat.host` was left empty there, Ogmios is running and connected
to nothing.**

## Inheritances we cannot yet write off

The overlay is applied **last**, so anything it writes wins. The hazard is the
opposite case: **a key the overlay does not mention keeps whatever upstream's
config file said.** Last-wins merges per key, not per file.

⚠ **Today, on mainnet, this is a non-problem for a reason that belongs to mainnet
and not to this chart:** upstream's `mainnet.json` carries no `server` block, no
`bootstrap`, no `protocol.v4` and no mempool. Rendered with real values it
produces `"server": {"address": "0.0.0.0:9999"}` and `"protocol": {}` — there is
nothing to inherit.

⇒ **That stops holding the day a `mainnet-v4.json` exists.** Upstream's other v4
files carry two things you would not choose:

| inherited | what it does |
|---|---|
| `server.public_address: 0.0.0.0:9998` | opens a **second, public** listener |
| `protocol.bootstrap` | a bootstrap block carrying **upstream's own Blockfrost project id** |

### What can write a value off, per key

`null` is the obvious tool and it is **type-dependent**, which is the whole
lesson: `null` on a plain Rust field is `invalid type: unit value` and refuses
the entire config at startup. On an `Option<T>` it is exactly the override you
want. Read from source at `v0.7.1`, and unchanged in `v0.7.2` — that release
touches only `src/main.rs` (one added `#[command(version)]` attribute):

| key | Rust type | `null` |
|---|---|---|
| `server.public_address` | `Option<SocketAddr>` | ✅ **works** |
| `protocol.bootstrap` | `Option<BootstrapConfig>` | ✅ **works** |
| `server.tls_cert` / `tls_key` | `Option<String>` | ✅ works |
| `protocol.v3` / `protocol.v4` | `Option<…>` | ✅ works |
| `server.address` | `SocketAddr` | ⛔ type error (moot — the overlay always writes it) |
| `protocol.v4.execution.scooper-secret-key` | `String` | ⛔ **type error — measured on a live pod** |
| `protocol.v4.execution.submit-url` | `String` | ⛔ type error (moot — required when v4 is on) |
| `protocol.v4.mempool.socket-path` / `network-magic` / `execute` | `String` / `u64` / `bool` | ⛔ type error (whole block is gated instead) |

⇒ **So both dangerous inheritances above ARE writable off, because both are
`Option`.** The chart does not currently write them, and that is the open gap.

⚠ **Why it is open:** 0.1.0-alpha.1 removed *every* explicit null after one of
them crashed a live pod. That was the right emergency fix and an over-correction
— the crash was on `scooper-secret-key`, a plain `String`, and the same commit
discarded the two type-safe nulls that addressed the real hazard.

### The other two mechanisms, for completeness

- **Emit a complete replacement block.** For a plain-typed field, the overlay
  must write *every* field of the object it is overriding, since a partial object
  merges rather than replaces — and a partial `protocol.v4` is
  [fatal](#-why-a-partial-protocolv4-is-fatal-and-an-absent-one-is-fine).
- **Environment variables win over every file.** `load_config` adds
  `Environment::with_prefix("SCOOPER_V2")` with `__` as the separator *after* all
  file sources, so `SCOOPER_V2_PERSISTENCE__SQLITE__FILENAME` overrides
  `persistence.sqlite.filename`. Useful for scalars; it cannot express `null`.

### What an operator must do until the chart closes this

Do not pass a `*-v4.json` you have not read. If it contains
`server.public_address` or a `bootstrap` block, either strip those keys from your
copy of the file — you supply it via `config.existingConfigMap`, so it is yours
to edit — or accept a public listener and upstream's Blockfrost id. **The chart
cannot currently protect you from either.**

## The v4 plan, recorded so it is not rediscovered

Nothing on the target cluster speaks HTTP transaction submission — the preview
node exposes 3000 (n2n), 3001 (a socat bridge to its IPC socket) and 12798
(Prometheus). No submit-api, no Ogmios. So `submit-url` does not need a config
key, **it needs an endpoint that does not exist yet.**

⇒ **And the two remaining v4 gaps are one problem.** Ogmios is the scooper's
**fallback dispatch branch**, so an Ogmios URL legally satisfies `submit-url` —
and Ogmios needs the node's IPC socket, which is exactly what the `socat` source
already solves for the mempool. **Solve the socket once and both gaps close**,
using `charts/ogmios` from this same repository. That is the argument for doing
v4 properly rather than reaching for Blockfrost to make `submit-url` go away —
Blockfrost would drag a credential into a public repo, which this chart already
refuses for config files.

## ⚑ The scooper will not scoop until it reaches tip — it self-gates

**You do not need to wait for a sync to finish before enabling v4.** `Scooper::run`
opens with a wait loop, not with batch processing:

```
scooper waiting for indexer to reach chain tip          ← on start, however far behind
…
scooper synced with chain tip, batch processing enabled  ← the moment it may scoop
```

It drains events meanwhile (so the broadcast channel does not overflow) and
breaks out only when `tip_slot + SYNC_TOLERANCE_SLOTS >= network_tip`, with the
tolerance compiled in at **10 slots**.

⇒ **So a scooper enabled 74 million slots behind tip does not attempt scoops on
orders consumed long ago.** It waits, and it says so on every pass. Those two log
lines are the transition, and the second one is the first moment submission can
be exercised at all.

⚠ **Two ways the wait never ends, both failing in the safe direction:** the check
reads v4 state, so with v4 off it returns "unknown" and the loop never releases
(there is nothing to release *to* — v3 has no execution path); and if the network
tip itself is unknown it also returns "unknown" and waits. Neither scoops.

⚠ **And `sync_lag` is an ALERT, not a gate.** Upstream's `alerts.yml` warns at
`scooper_v4_sync_lag_slots > 600` with the reasoning *"we'll lose races on new
orders"* — a competitiveness concern about a scooper that has fallen behind after
catching up, which is a different thing from the initial sync.

## ⛔ Scoopers are permissioned, and the allow-list is per network

`SettingsDatum.authorized_scoopers` is an **on-chain** list in the global
settings UTxO, and the transaction redeemer pins the scooper's **index** in that
list (`FairnessOrderRedeemer { settings_input_index, authorized_scooper_index }`).
A key hash that is not in the list has no index, so it cannot build the redeemer
— it cannot scoop.

⇒ **The list is per network, structurally.** Upstream's own configs name a
different `settings-script-hash` *and* `settings-nft` for preview
(`43f2ee25…`/`7b576da2…`) than for preprod (`726a1160…`/`ecd76a8c…`). Different
UTxO, different chain, different list. **A registration cannot span networks.**

⚠ The list is `Option`, so a settings datum carrying `None` would be
permissionless — that is a property of the deployment, not of the binary.

## What the old (v1) chart needed and v2 does not

| v1 | v2 |
|---|---|
| **MySQL** (bitnami subchart) | **SQLite** — `sqlx` is compiled with the sqlite feature only, and `src/persistence/` has exactly one backend |
| **Kupo** indexer | its own **Acropolis** indexer (`custom-indexer`, `block-unpacker`) — Kupo survives only as an *optional bootstrap source* |
| **Ogmios / GraphQL** env vars | Ogmios survives only as a **submit backend**, selected by URL shape |
| **socat** to a node socket, for everything | a node **address** (n2n, `:3001`) for indexing — preview's is public — plus an IPC **socket** only for reading the v4 mempool |
| `/wallet-keys/sundae.payment.{skey,vkey}` | one key file; **no vkey** — the public key is derived |
| `protocols.json` built by a ConfigMap + `init.sh` | upstream's own JSON config, layered |

⇒ **This chart ships no subchart dependencies**, and that is the argued
conclusion rather than an omission: v2 replaced both of v1's datastores with
things it carries itself.

### ⛔ The submit backend is chosen by the URL's shape

From upstream's dispatch: host contains `blockfrost.io` → Blockfrost; URL
contains `/api/submit/tx` → cardano-submit-api; **anything else → Ogmios**.
Ogmios is the *fallback branch*, so a typo'd Blockfrost hostname is attempted as
Ogmios and fails in a way that mentions neither.

⚠ A Blockfrost submit URL carries the project id **in the query string**, so it
is a credential. Keep it out of any values file in this public repo.

## Ports

| port | what | exposed |
|---|---|---|
| 9999 `private` | `/dashboard`, `/status`, `/health`, `/metrics`, `/failures`, `/events`, pool & order listings — **and `/pause`** | Service only |
| 9998 `public` | strategy-intent endpoints + `/health` | Service + optional Ingress |

⛔ The private port is **unauthenticated and includes `/pause`**. The ingress
template refuses to route it. The public listener only exists when
`config.overlay.publicAddress` is set — setting that value is what opens it.

## v4 needs a node IPC socket, and this chart does not provide one

`protocol.v4.mempool.socket-path` reads the mempool. ⚠ **This is the likeliest
reason a v4 scooper does not work in a cluster.** Three shapes, all yours to
choose: a `hostPath` to a node socket (ties the pod to that node — set
`nodeSelector`, or it schedules elsewhere and the socket is *silently* absent), a
shared volume with a node in the same pod, or a socat sidecar bridging a TCP
relay, which is what v1 did.

## v4 on a cluster where the node keeps its socket in a PVC

⛔ **`mempool.source: hostPath` has nothing to point at** when the node writes
its socket inside its own volume — which is the normal arrangement. And you must
**not** mount the node's own RWO database claim to reach it: that hands the
scooper write access to a live node's database directory, and a socket is not
worth that.

⇒ **Use the `socat` source.** The node side usually already runs
`socat TCP-LISTEN:<port>,fork UNIX-CONNECT:/data/db/node.socket`; the chart adds
the inverse as a sidecar, presenting a unix socket in an `emptyDir` shared with
the scooper. Nothing is written to the node's volume and the scooper needs no
access to it. This is the shape the v1 chart used, so it is a return rather than
an invention.

```yaml
mempool:
  enabled: true
  source: socat
  networkMagic: 2
  socat:
    host: cardano-node-preview-socat   # the node-side socat Service
    port: 3002
    image: {tag: "1.8.0.0"}            # pinned; no `latest` sidecars
```

`source` is a required enum when `mempool.enabled` — `socat`, `hostPath`,
`existingClaim` or `external` — so the guard cannot be satisfied by accident.
`external` steps aside for `extraContainers`/`extraVolumes` wiring of your own.

## What this cluster does not have

⚠ Reported from the target cluster so this documentation is honest rather than
optimistic:

- **No cardano-submit-api and no Ogmios on preview.** Combined with the
  URL-shape dispatch above, a `submitUrl` matching neither Blockfrost nor
  `/api/submit/tx` is attempted as **Ogmios** against something that is not
  Ogmios, and the error mentions neither.
- **No Kupo** — only an orphaned v1 volume with no pod.

⇒ **`charts/kupo` in this same repository is the cheaper bootstrap route**, and
it is worth considering before introducing a Blockfrost dependency:
`protocol.bootstrap.source: kupo` needs only a **url** and **no credential**,
where blockfrost needs a project id that is a credential this repo must never
carry. The trade is that Kupo is another workload to sync and store — v1's Kupo
volume was 20Gi — and it must be indexing the same network. Upstream's own
comment notes the Kupo provider relies on wildcard matching, which is standard
Kupo behaviour.

## What actually makes the initial sync fast

⚠ **Pointing the scooper at a local node is worth doing and is probably not the
thing you are hoping for.** Said plainly rather than agreed with:

`nodeAddresses` sets `acropolis.module.peer-network-interface.node-addresses` —
a **list of seed peers**. It removes per-block network latency, which is real,
and it keeps chain traffic inside the cluster. Across **~74 million slots** the
bottleneck is far more likely to be **block processing and SQLite index writes**
than peer bandwidth. Expect "faster", not "super fast".

⇒ **The intended fast path is the Mithril snapshot, and it is a different
module.** Acropolis's own docs say `sync-point: "dynamic"` — which upstream's
`default.json` sets — is *"for snapshot or Mithril modes"*. So
`acropolis.module.mithril-snapshot-fetcher` (`aggregator-url`, `genesis-key`)
matters far more to first-sync time than which peer you follow.

⛔ **And Mithril cannot shorten the scooper's own index build. Measured and read
from source, so nobody spends a wipe finding out.**

The Mithril fetcher and the peer interface **publish to the same bus topic** —
`cardano.block.proposed`, both set in upstream's `default.json`. Acropolis's own
description is *"fetches chain snapshots from the Mithril aggregator and replays
blocks"*. ⇒ **So Mithril changes where blocks come FROM; every block still flows
through the same pipeline and through the scooper's own indexers.** It is a
delivery optimisation, not an index handover.

⇒ **And delivery is already known not to be the bottleneck.** Pointing the
scooper at a node on the same cluster — which removes network latency
entirely — measured **1.09×** (279.0 → 303.7 KiB/s). That bounds the whole
delivery component at roughly 9%. The cost is block processing and SQLite index
writes, and Mithril does not touch either.

**And there is no snapshot-import path anywhere in the pipeline** — checked
rather than assumed, because a wrong "yes" here costs a wipe and a day:

- The scooper enables exactly five Acropolis modules:
  `genesis-bootstrapper`, `peer-network-interface`, `mithril-snapshot-fetcher`,
  `block-unpacker`, `custom-indexer`. ⇒ **That is a block pipeline**: a source
  (peer *or* Mithril) feeding an unpacker feeding an indexer.
- ⛔ **`snapshot-bootstrapper` — the one Acropolis module that "downloads and
  parses a new epoch state snapshot for fast bootstrap" — is NOT enabled.** The
  only import-shaped module in the framework is absent from the scooper's list.
- The scooper's own `Persistence` trait exposes `connect`, an `IndexerDao`, a
  `StrategyIntentDao` and a cursor DAO — and **no bulk-load, restore or import
  surface at all.** Data enters one block at a time through the indexer or not
  at all.

⇒ **So a first sync is a first sync.** At a measured ~1,532 slots/s, ~74 million
slots is about **13 hours**, and no configuration in this chart shortens it.

⚠ **One thing that is easy to misread as evidence about Mithril and is not:** a
log line saying `Block flow mode: Direct (auto-fetch)`. `BlockFlowMode` is
`Direct` vs `Consensus` — whether the peer interface manages chain selection
itself or delegates it to a consensus module. **It says nothing about whether
Mithril ran.** The Mithril fetcher's own lines are the ones to read:
`Using Mithril snapshot …`, `Using old Mithril snapshot …`, or
`SKIP DOWNLOAD: …`.

### `download-max-age: "never"` — what it actually does

Upstream's `default.json` sets it, and `default.json` is **compiled into the
binary** (`include_str!`, added as the first config source). It is not this
chart's doing, and this chart emits no Mithril key at all.

Acropolis parses it as `config.get::<u64>(…)`, so `"never"` fails to parse and
takes the error branch, which logs **`SKIP DOWNLOAD: Download max age is not set
or invalid`** and returns *skip*.

⚠ **But that check is only reached when a snapshot is ALREADY on disk** — the
caller does `if let Ok(old_snapshot) = load_snapshot_metadata(…)` first. ⇒ So
`"never"` is not an off switch: on a fresh volume Mithril downloads normally, and
thereafter reuses what it has forever. **It bites re-downloads, not first runs.**

### Peer discovery is not displaced

`node-addresses` are **seeds**, not the peer set. Peer sharing is on by default
(`peer-sharing-enabled` true, `target-peer-count` 15, `min-hot-peers` 3), so a
single local seed still fans out to a normal peer population — an observed
`hot_count 3, cold_count 40` is exactly those defaults at work.

⚠ The real risk of a lone local seed is **startup**: if that node is down when
the scooper starts, there is no other seed to bootstrap from. List a public relay
after yours.

## Sizing — read the provenance

```yaml
resources:
  requests: {cpu: 200m, memory: 512Mi}
  limits:   {memory: 2Gi}
```

```yaml
resources:
  requests: {cpu: 200m, memory: 512Mi}
  limits:   {memory: 1Gi}
```

⚑ **One measurement exists now: 82Mi RSS while indexing hard** — mid-sync,
pulling ~8.3 MB per 30s, on preview, on the v3 observer build (2026-09-15).

⚠ **That is one number, not a profile.** It is mid-sync, so the peak may still be
ahead, and a mainnet scooper or a larger index may look nothing like it. `1Gi` is
roughly 12× the observed figure — headroom for a single data point rather than a
tuned value.

⇒ **The default was 4Gi and dropping it was the right call, not a correction of a
mistake.** With nothing measured, the asymmetry favoured generosity: too low is a
silent restart loop, too high costs nothing until something else wants the
memory. Then something did — that 4Gi limit took one real cluster from 84% to
98% of allocatable memory limits by itself. **Once the cost is real, "costs
nothing" stops being an argument.**

⛔ **The risk is the LIMIT, not the request, and it fails as a loop.** A 512Mi
request is a small share of allocatable and will not sit `Pending`. What bites is
the limit during the **first cold sync**: exceed it and the container is
OOM-killed, restarted, and the index rebuilds from scratch — with a 30-minute
startup budget making each cycle slow. **It presents as a crash-loop and it is a
sizing problem**, and nothing in the logs says "limit".

⇒ The limit is therefore set generously on an asymmetry, not on a measurement:
too low costs a silent restart loop on first run, too high costs nothing until
something else on the node needs the memory. **4Gi is still a guess.** Watch the
first sync and set it from the observed peak — raise the **limit**, not the
request.

## ⛔ Symptom: "ServiceMonitor exists, `enabled: true`, no series"

If Prometheus shows **zero scooper series and an empty `up{}`** while the
ServiceMonitor is present and healthy, the object was **never selected**.

kube-prometheus-stack ships `serviceMonitorSelector: {release: <its release
name>}`. A ServiceMonitor without a matching `release` label is simply ignored,
and **nothing reports that** — the object exists, the flag is true, and zero
series looks exactly like a quiet scooper.

Read the real selector off the cluster instead of guessing:

```bash
kubectl get prometheus -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.spec.serviceMonitorSelector}{"\n"}{end}'
```

Then set it:

```yaml
metrics:
  serviceMonitor:
    releaseName: kube-prometheus-stack   # the default; match YOUR Prometheus
    labels: {}                           # anything else the selector wants
```

⚠ This chart's first deploy hit exactly this. `releaseName` now defaults to
`kube-prometheus-stack` — which is that chart's own default release name, so it
is the common case rather than a cluster-specific guess — matching the five other
monitoring charts in this repository. The earlier version emitted no `release`
label at all, which was an undocumented divergence from that precedent rather
than a decision.

## ⛔ Two failures that look identical from outside, with opposite remedies

**Both present as a pod restarting over and over.** An operator who reaches for
the wrong remedy makes it worse and learns nothing, so check the discriminant
before changing anything:

| | **config validation** | **memory limit** |
|---|---|---|
| `reason` | `Error` | `OOMKilled` |
| exit code | `1` | `137` |
| time to die | **under a second** | **minutes** — it indexes first |
| log size | **bytes.** One line, no banner, no version, no "loading config" | normal startup output, then nothing |
| remedy | a different **config file** | a bigger **limit** |

⇒ **The binary validates configuration before anything else runs**, which is why
a config failure produces no banner and no partial startup: nothing is permitted
to happen first. A 70-byte log is the signature — measured, on this chart's own
first deploy.

⛔ **So raising `resources.limits.memory` at a config error does nothing**, and
rewriting config at an OOM kill does nothing. The one that reads as "it crashed
instantly" is never the memory limit.

**The config failure you are most likely to hit** is a partial `protocol.v4` —
see above. It names one missing field at a time, so each restart reveals exactly
one more, and the fix is to omit the block rather than to fill it in.

## Single replica

`replicas: 1`, hardcoded, no `replicaCount`. A scooper signs from one key: two
replicas race the same SQLite index and build competing scoops from the same pool
state, and a losing scoop is a wasted fee rather than a no-op. ⚠ With one
replica and `OrderedReady`, no upgrade fails safely — the old pod is gone before
the new one starts.
