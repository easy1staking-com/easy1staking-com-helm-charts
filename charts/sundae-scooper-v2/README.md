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

⚠ **And the image tag has no `v`**: GHCR carries `0.7.1`; `v0.7.1` is the git
release tag and a 404 as an image tag. Upstream's own README example
(`scooper-v2:v0.6.0`) has the same mistake, so copying their docs gives
`ImagePullBackOff`. Verified newest, 2026-09-15: **`0.7.1`**, digest
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

## Sizing — read the provenance

```yaml
resources:
  requests: {cpu: 200m, memory: 512Mi}
  limits:   {memory: 2Gi}
```

```yaml
resources:
  requests: {cpu: 200m, memory: 512Mi}
  limits:   {memory: 4Gi}
```

⚠ **Unmeasured.** Upstream publishes no figures and this chart has never run.

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

## Single replica

`replicas: 1`, hardcoded, no `replicaCount`. A scooper signs from one key: two
replicas race the same SQLite index and build competing scoops from the same pool
state, and a losing scoop is a wasted fee rather than a no-op. ⚠ With one
replica and `OrderedReady`, no upgrade fails safely — the old pod is gone before
the new one starts.
