# Amaru

Helm chart for [Amaru](https://github.com/pragma-org/amaru), the Rust Cardano node
by pragma. This chart deploys one or more **relays**, and optionally **block
producers** (see *Block producer*).

Image: `ghcr.io/pragma-org/amaru` · `v10.11.20261112`. Measured against that
image: it parses every `node run` argv this chart renders up to its database
check, and accepts the rendered bootstrap and Mithril flags. No node has been run
to tip on it by this chart.

---

## Read this first: what Amaru is and is not, today

Amaru gained relay and peer-sharing capability in `v10.11.20260820`. Upstream's
release notes for that version named two limits. They are kept here as history
of `v10.11.20260820`, because they explain earlier versions of this chart; each
says how far it is known to have changed since:

- **On `v10.11.20260820`, connections were not full-duplex.** Amaru could
  initiate outbound connections and accept inbound ones, but *over two separate
  tcp bearers* — a peer talking to Amaru did not get one bidirectional session
  the way it does with a Haskell relay. Since `v10.11.20260918`, the first
  release carrying it (Amaru's `CHANGELOG.md` at `v10.11.20261112` records the
  change under `v10.11.20260910 _[unreleased]_`), the outbound handshake offers
  duplex: when both sides agree, responders run on that bearer,
  and peer selection prefers promoting a duplex inbound connection over opening
  a second outbound one. Without `inbound` in `config.peerMix`, duplex inbound
  connections stay downstream-only.
- **On `v10.11.20260820`, the VRF key uniqueness rule was not yet enforced.**
  This chart has not checked whether that is still so on `v10.11.20261112`.

Two further facts about the shape of the process, verified from the binary:

- **There is no node-to-client (n2c) interface.** No socket path, no socket
  option, anywhere in the cli. Tools that expect `node.socket` (cardano-cli,
  db-sync, Ogmios, Kupo in node mode) cannot attach to Amaru. The nearest
  equivalent is the optional HTTP **Submit API** (`config.submitApi`), which
  serves `POST /api/submit/tx` and nothing else.
- **There is no Prometheus endpoint.** Amaru exports metrics over OTLP only.
  The scrape target this chart gives Prometheus is the **otel-collector
  sidecar**, which receives Amaru's OTLP stream and re-exposes it on port 9464.
  Disabling the sidecar means no metrics.

## Quick start

```bash
# Renders/installs a single mainnet relay with the built-in defaults
helm install amaru ./charts/amaru

# Or pick a network
helm install amaru ./charts/amaru -f ./charts/amaru/values-preview.yaml
helm install amaru ./charts/amaru -f ./charts/amaru/values-preprod.yaml
helm install amaru ./charts/amaru -f ./charts/amaru/values-mainnet.yaml
```

The chart renders a complete working relay out of the box. Switching network is
only the `network` value; the three presets contain nothing else.

## Upgrading to 0.0.1-alpha.24: one-time selector migration

**Why.** A StatefulSet's `spec.selector` is immutable. Before `0.0.1-alpha.24`
it included the node's `type`; from `0.0.1-alpha.24` it is `app`, `name` and
`network` only, so that a node can be flipped between `relay` and
`block-producer` in place. An existing StatefulSet still carries the old
selector, and the API server rejects the upgrade (*field is immutable*) until
that StatefulSet is gone. The Services' selectors are mutable and need nothing.

**What to run, once per existing StatefulSet:**

```bash
kubectl -n <namespace> delete statefulset amaru-<name> --cascade=orphan
```

then sync or `helm upgrade` as usual. **With Argo CD, point the app at the new
chart version first.** Its sync fails on the immutable selector until the old
StatefulSet is gone; delete it while the app still points at the old version
and selfHeal recreates it from the old chart, selector and all.

> **Do not delete the StatefulSet from the Argo CD UI.** Its delete defaults to
> foreground propagation, which deletes the pod along with it. Use `kubectl`
> with `--cascade=orphan` as above.

**What survives.** With `--cascade=orphan` the pod and its PersistentVolumeClaim
survive the delete. The new StatefulSet adopts the pod (its labels still match
the new selector) and the claim (same name, `amaru-<name>-amaru-<name>-0`), then
rolls the pod onto its own template only if that template differs between the
old and new chart; if it is identical, the adopted revision matches and nothing
restarts. Either way the pod stays on the same volume. The databases are kept,
and a rolled pod does not bootstrap again. This sequence follows from how
StatefulSets adopt orphans; this chart has not measured it on a live cluster.

**StatefulSets created on `0.0.1-alpha.24` or later need nothing.**

## Upgrading from v10.11.20260820

The chart now renders Amaru's current flag and environment variable names. The
old names are hidden aliases, deprecated in Amaru's CHANGELOG only, with no
runtime warning. Four behaviour changes arrive with the image itself:

- **An empty peer list no longer falls back to a network bootstrap peer.** With
  `nodes[].peerAddresses` empty, Amaru uses only its peer-mix sources. The
  image's own `--peer` help text still says it falls back; that is an upstream
  documentation bug.
- **Outbound connections bind to the listen port**, falling back to an ephemeral
  port if it cannot be reused. `--peers-ephemeral-outbound-port` opts out; this
  chart does not render it.
- **A new inbound handshake is refused** once `--peers-max-downstream` live
  inbound connections exist (default 10, `config.downstreamPeers` here).
- **The metrics export default became 1 s.** The chart overrides it with
  `config.otlpMetricExportIntervalMs`, default `30000` — see Monitoring.

The chain database schema is version 6 on both versions, so no chain-DB
migration is needed for this upgrade.

## Ports

| Port | Direction | Set by | Exposed on | Purpose |
|---|---|---|---|---|
| **3001** | **inbound** | `nodes[].port` | headless + ClusterIP, optionally NodePort | node-to-node p2p mini-protocol |
| 8090 | inbound | `config.submitApi.port` | ClusterIP, optionally NodePort | HTTP Submit API — only when `config.submitApi.enabled` |
| 9464 | inbound (scrape) | `otelCollector.prometheusPort` | ClusterIP | Prometheus scrape target on the sidecar |
| 4317 / 4318 | pod-local | `otelCollector.otlpGrpcPort` / `otlpHttpPort` | not exposed | Amaru → sidecar OTLP, over localhost |
| — | **outbound** | `nodes[].peerAddresses` | — | connections Amaru opens to upstream peers |

Notes on the p2p port:

- `nodes[].port` is the single source of truth. It drives `--peers-listen-on`,
  the `containerPort`, and every Service port together, so the port Amaru
  actually listens on cannot drift from the port the cluster advertises.
- **3001** matches the `cardano-node` chart in this repo. Amaru's own built-in
  default is `0.0.0.0:3001` as well; this chart always passes the address
  explicitly, so the built-in default never applies.
- Amaru refuses a new inbound handshake once `config.downstreamPeers` live
  inbound connections exist (upstream default 10). That is the relay's serving
  capacity.

### Services

Each relay gets the same three services the `cardano-node` chart uses:

| Service | Type | Always? | Use |
|---|---|---|---|
| `amaru-<name>` | headless (`clusterIP: None`) | yes | stable per-pod dns, e.g. `amaru-relay-1-0.amaru-relay-1` |
| `amaru-<name>-int` | ClusterIP | yes | ordinary in-cluster access; also carries the scrape and submit-api ports |
| `amaru-<name>-ext` | NodePort | only when `nodes[].nodePort` is set | external inbound |

A relay is therefore **always** reachable inside the cluster, and externally
only when you ask for it.

None of the three selects on the node's `type`, with one exception on purpose:
the `-ext` Service's selector carries the literal `type: relay`. If a relay with
a `nodePort` is flipped to `block-producer` and its `nodePort` removed, the `-ext`
Service stops rendering but can survive in the cluster (an Argo CD app with
`prune: false` never deletes it). Pinned to `relay`, that stale Service selects
nothing rather than exposing the block producer.

### Running several relays on one host

Give each entry in `nodes` its own `nodePort`. The in-pod `port` may stay 3001
for all of them — each relay is a separate pod with its own network namespace;
only the NodePorts share the host.

```yaml
nodes:
  - name: relay-1
    enabled: true
    type: relay
    replicas: 1
    port: 3001
    nodePort: 30000
  - name: relay-2
    enabled: true
    type: relay
    replicas: 1
    port: 3001
    nodePort: 30001
```

Note that a relay behind a NodePort advertises its **pod** address to the
peer-sharing protocol, not the node's external address. Inbound works because
peers dial the NodePort you gave them; automatic peer sharing of *this* relay's
address to strangers does not, in this topology.

## Upstream peers

Amaru fills its **upstream** slots from five sources, blended by
`config.peerMix`. They are not all pools it dials: `inbound` promotes
connections that peers opened to Amaru.

| Source | Where it comes from | Configure with |
|---|---|---|
| `static` | peers you list explicitly | `nodes[].peerAddresses` |
| `inbound` | duplex inbound connections, promoted into upstream slots | — |
| `shared` | discovered via the peer-sharing mini-protocol | — |
| `snapshot` | a `bigLedgerPools` JSON of stake-weighted big-ledger relays | `config.peerSnapshot`, else the snapshot embedded in the image |
| `ledger` | relays derived from ledger state | — |

To pin exactly who a relay talks to over the p2p mini-protocol, list them:

```yaml
nodes:
  - name: relay-1
    enabled: true
    type: relay
    replicas: 1
    port: 3001
    peerAddresses:
      - "cardano-node-relay-1-int:3001"     # your own Haskell relay, in-cluster
      - "relays.example.com:3001"           # anything reachable
```

Each entry renders one `--peer`. An **empty list emits no flag at all**, and
Amaru then uses only its other peer-mix sources (the table above).
It no longer falls back to a network bootstrap peer, as it did on `v10.11.20260820`;
the image's `--peer` help text still says it falls back, which is an upstream
documentation bug.

Related knobs, all optional and omitted from the command line when unset:

| Value | Upstream default | Meaning |
|---|---|---|
| `config.upstreamPeers` | 3 | how many upstream peers to hold connections to |
| `config.downstreamPeers` | 10 | max inbound peers accepted — serving capacity |
| `config.peerMix` | `static!2@15m, inbound~6, shared~6, snapshot~3@1h, ledger~3@24h` | source blend: floors `!n`, weights `~n`, malus half-lives `@Nd` |
| `config.peerSnapshot` | embedded | path to a `bigLedgerPools` JSON, cardano-node compatible |

Leaving a source out of the mix formula **disables** it.

> `config.downstreamPeers: 0` is honoured explicitly and means *accept no
> inbound peers* — the flag is still rendered. This needs saying because the
> obvious Helm idiom (`with`) treats `0` as falsy and would silently drop it,
> turning the most restrictive setting into Amaru's permissive default of 10.
> Keep the explicit nil check in the template if you refactor it.

> The legacy singular `nodes[].peerAddress` is still honoured as a fallback for
> existing deployment values, but `peerAddresses` is the supported form.

## Bootstrap and Mithril

Two distinct mechanisms, easy to conflate:

| | `amaru node bootstrap` | `amaru mithril sync` |
|---|---|---|
| what | imports a ledger snapshot, bootstrap headers and nonces | downloads verified Mithril immutable files and ingests the blocks |
| source | Amaru's own S3/R2 snapshot bucket | the Mithril aggregator for the network |
| required? | **yes** — the node cannot start without it | no, an accelerator |
| chart | always runs, in an init container | opt-in, `config.mithrilSync.enabled` |

**They are sequential, not alternative.** Run standalone against an empty volume,
`amaru mithril sync` fails immediately with *"Failed to create ledger. Did you
bootstrap your node?"*. The chart enforces the ordering: the Mithril init
container refuses to run unless the bootstrap marker is present.

### There is nothing to configure for Mithril

Unlike the `cardano-node` chart in this repo — which passes
`--aggregator-endpoint`, `--genesis-verification-key` and
`--ancillary-verification-key` to `mithril-client` — Amaru exposes **no Mithril
configuration at all**. The aggregator endpoints and genesis verification keys
are compiled into the binary per network:

```
mainnet  https://aggregator.release-mainnet.api.mithril.network/aggregator
preprod  https://aggregator.release-preprod.api.mithril.network/aggregator
preview  https://aggregator.testing-preview.api.mithril.network/aggregator
```

The embedded mainnet genesis verification key is byte-identical to the one the
`cardano-node` chart passes explicitly. The only Mithril knob in the whole binary
is the snapshots directory. **Consequence:** if pragma ever rotates an aggregator
or key, you upgrade the image — the chart cannot override it.

### Known issue: preview sync halts permanently at block 4,588,007

> **History, scoped to `v10.11.20260820`.** Everything in this section was
> observed on that version. The operator reports preview sync past 4,588,007 on
> later releases; this chart has not re-measured it on `v10.11.20261112`.

**On `v10.11.20260820` a preview relay reaches block 4,588,006 and then stops
forever**, rejecting 4,588,007 and every block after it as *"descends from an
invalid block"* while watching upstream tips advance in real time:

```
BlockValidationError … transaction failed phase one validation: invalid inputs:
inputs included in both reference inputs and spent inputs
parent=…(4588006)   failed_tip=120569440…(4588007)
```

**No chart configuration changes this.** All four combinations of upstream peers ×
Mithril sync were run on a live cluster and every one halted on the same block and
the same transaction. **Mithril changes where the node starts, not where it
stops** — a cell with both a healthy local relay peer and a Mithril snapshot
halted identically.

**It is not a peering problem, which is what it looks like.** Amaru ↔ cardano-node
11.0.1 node-to-node interop was verified working in the same run: handshake
completed, intersect found, upstream tip 4,602,448 visible. The node is connected;
the height is blocked by block *content*.

**The fix exists upstream, is verified to work, and is not merged.**
[`pragma-org/amaru` PR #1255, *"Fix Disjoint Inputs Check(s)"*](https://github.com/pragma-org/amaru/pull/1255)
says: *"In pv11+, the reference inputs and the inputs do not need to be disjoint
sets."* Preview is on `protocol_major` 11, so that conditional applies here.

**We tested it. observed, 2026-08-25:** built from the PR head `db5961c`, swapped
into the published `v10.11.20260820` image so that the binary was the only
difference, and run against a fresh volume with the two commands below. It
**stepped over the failing block without stopping** — `…4587545 → 4588321 →
4588731…` — and reached **block 4,602,721 with `max_block_height` equal to it**,
i.e. caught up to the upstream tip. Zero `BlockValidationError`, zero occurrences
of 4,588,007, nothing suppressed. **A preview node syncs normally on that branch.**

> **"Verified" is not "available".** The PR is **open and unmerged**, so no
> published image contains it. Both `v10.11.20260820` and `latest` (digest
> `b3f8594…`, a different build from a different commit) halt on the identical
> block — the halt is not a stale-image problem. **There is still nothing to
> upgrade to; the difference is that the wait now has a specific end**, namely
> #1255 merging and a release being cut, rather than being open-ended.

**Two facts a chart operator needs about the halted state itself:**

- **A halted Amaru is a *running* Amaru.** It does not exit. It stays up and
  refuses each successive block as *"descends from an invalid block"*, so the
  process is alive, the port is open and `/actuator`-style liveness has nothing
  to complain about. **This is the concrete reason the probes stay green** — see
  the retry warning under the probe section, which this is a second instance of.
- **Nothing in the chart's configuration changes it.** All four combinations of
  upstream peers × Mithril sync halt on the same block and the same transaction.

The three checks that establish where the defect is not: the overlap really is on
chain (transaction `97df1aec…` lists `fbe65e04…#0` in both its inputs and its
reference inputs); the transaction executes **no PlutusV3**, so #1255's own
carve-out — *"script executions in PlutusV3 must have disjoint sets regardless of
the protocol version"* — does not cover it; and the failure reproduces on bare
Docker with no chart and no Kubernetes involved at all.

> Provenance, since this chart is careful about it elsewhere: we reached
> "Conway removed the disjointness requirement" as a **derived** hypothesis and
> labelled it one, having no standing on ledger rules. Upstream's own PR
> description says the same thing, which makes **the rule** documented — by them,
> not by us. That the rule is documented would not by itself make **this block**
> an instance of it; the on-chain lookup is what does that, and it is `observed`.

Reproducing it takes about a minute on bare Docker, no Kubernetes and no chart —
bootstrap lands at 4,580,250 and the wall is 7,757 blocks later:

```bash
docker volume create amaru-repro
# the image runs as uid 10000; a fresh volume is root-owned
docker run --rm -u 0 -v amaru-repro:/data --entrypoint sh \
  ghcr.io/pragma-org/amaru:v10.11.20260820 -c 'chown -R 10000:10000 /data'

docker run --rm -v amaru-repro:/data ghcr.io/pragma-org/amaru:v10.11.20260820 \
  node bootstrap --network preview \
  --ledger-dir /data/ledger.db --chain-dir /data/chain.db  # old names, as run on v10.11.20260820

docker run --rm -v amaru-repro:/data ghcr.io/pragma-org/amaru:v10.11.20260820 \
  node run --network preview \
  --ledger-dir /data/ledger.db --chain-dir /data/chain.db --no-tui  # old names, as run on v10.11.20260820
```

The rejected transaction is `97df1aec…228dc4` at index 0, and the input Amaru
finds in both sets is `fbe65e04…30611e#0`.

If you deploy this chart on preview and the height stops at 4,588,006, **that is
this, and it is expected** — not a misconfiguration, and not worth investigating
again.

### Known issue: Mithril ingest can fail on block validation

> **History, scoped to `v10.11.20260820`.** This was observed on that version and
> has not been re-measured by this chart on `v10.11.20261112`.

Observed with `v10.11.20260820` on **preview**: after a successful bootstrap at
epoch 1392, Mithril ingest aborted validating a real on-chain block —

```
Error processing block at point
  Specific(120355272, d63078a9dccec5c0235ab3d00e4318d01005a93522206cc1e84d314afc6c7d86, 4580253)
  tx 4c8c5695ce079731b7843f45011943fe61e3c8964a1e48e7b23e92f3ef4d7dcb index 0
  phase two validation: PlutusV2 script evaluation failure, "Out of budget"
  consumed cpu 78,466,510 — remaining cpu -12,122
```

The block is on the real preview chain, so the Haskell node accepted it; Amaru's
cost accounting overshoots by ~0.015%. Reproduce with:

```bash
docker run --rm -v $pwd/data:/data ghcr.io/pragma-org/amaru:v10.11.20260820 \
  node bootstrap --network=preview --ledger-dir /data/ledger.db --chain-dir /data/chain.db  # old names, as run on v10.11.20260820
docker run --rm -v $pwd/data:/data ghcr.io/pragma-org/amaru:v10.11.20260820 \
  mithril sync --network preview --ledger-dir /data/ledger.db --chain-dir /data/chain.db --snapshots-dir /data/mithril  # old names, as run on v10.11.20260820
```

This is why `config.mithrilSync.failOnError` defaults to **false**: an ingest
failure leaves a perfectly valid bootstrapped node that can still reach tip from
its peers, and treating it as fatal would turn an accelerator into a reason the
pod never starts. Not established: whether `node run` hits the same block when
syncing from peers.

## Config, storage and bootstrap

Amaru takes no topology file and no config directory — everything is cli flags
and `AMARU_*` environment variables. This differs from `cardano-node`, which
mounts `<network>-config.json` and `<network>-topology.json`.

| Value | Default | Flag |
|---|---|---|
| `config.ledgerDir` | `/data/db/ledger.db` | `--db-ledger` |
| `config.chainDir` | `/data/db/chain.db` | `--db-chain` |
| `config.noTui` | `true` | `--tui-off` |
| `config.migrateChainDb` | `false` | `--db-chain-automatic-migration` |

Both databases live on the per-relay PersistentVolume mounted at `/data/db`,
sized by `volumeSize`.

**Bootstrap and restarts.** An init container runs `amaru node bootstrap`. It
needs outbound HTTPS. Completion is recorded with a marker file
(`<dataDir>/.bootstrap-complete`) written **only** after bootstrap exits 0 — not
by checking whether the database directories exist. That distinction is
load-bearing:

- Amaru **refuses** to bootstrap into an existing directory (*"use another
  location or remove it manually"*) and exits non-zero, so an unguarded re-run
  would fail every restart.
- A pod evicted mid-bootstrap leaves *one* database behind. A directory-existence
  check reads that as "already done" and starts the node on a half-built ledger.
  A completed bootstrap always produces both databases, so exactly one present
  and no marker means an aborted attempt: the chart clears it and starts over.
- Databases that predate the marker are **adopted**, never wiped — the chart does
  not destroy data it cannot prove is broken.

Preview needs roughly 1.6GB of ledger after bootstrap; mainnet is substantially
larger. Size `volumeSize` accordingly.

**The PVC size is derived from `network`, not defaulted.** `volumeSizeByNetwork`
maps mainnet and preprod to `250Gi` and preview to `50Gi`; an unknown network
falls back to the mainnet figure. Setting `volumeSize` overrides the derivation
entirely.

**It is derived rather than left to the preset files for a specific reason.**
GitOps tools commonly supply values *inline*, and an operator who writes
`network: preview` inline never opens `values-preview.yaml` — so a size that lived
only in that file handed them **mainnet sizing on preview**, silently, with
nothing to warn them. Deriving from the network makes that mistake unavailable
rather than merely documented. (This happened; it is not hypothetical.)

Preprod stays at the mainnet figure deliberately: it is far nearer mainnet than
preview is, and no measurement exists that would justify a specific smaller number.

**50Gi is an over-estimate on purpose, not a measurement.** The ledger is ~1.6GB
after bootstrap (observed); chain-db growth from the bootstrap epoch to tip is
**unmeasured**, and Mithril snapshots share the same volume when enabled. The
asymmetry sets the direction: a storage class with `allowvolumeexpansion=false` —
k3s's default `local-path` included — cannot grow a PVC that turns out too small,
so **under-sizing is not "adjust later", it is destroy the volume, re-bootstrap
and re-sync**, while over-sizing costs only a nominal claim (`local-path` does not
preallocate — a 250Gi claim binds instantly and consumes nothing).

**History, scoped to `v10.11.20260820`: why these figures were not refined.**
Sizing wants the usage of a relay that has reached tip, and on
`v10.11.20260820` **no preview relay could reach tip** — see *Known issue: preview
sync halts permanently* below. Both routes out were closed: the pinned image was
then the newest versioned tag `ghcr.io/pragma-org/amaru` published (observed), and
a newer Mithril snapshot cannot help because ingest **replays forward from the
ledger's current position** rather than relocating it — only `amaru node bootstrap`
sets the start point, and that snapshot is compiled into the image.

So `volumeSizeByNetwork` and `resources` were **not merely unmeasured but
unmeasurable on `v10.11.20260820`.** They are over-estimates justified by the
asymmetry above. The operator reports preview sync past 4,588,007 on later
releases; this chart has not re-measured either figure on `v10.11.20261112`, and
the first person who measures them should be someone running a build that gets
past block 4,588,007.

> **Resizing a running relay does not work.** A StatefulSet's
> `volumeClaimTemplates` are immutable, so an upgrade that changes the size is
> rejected by the API server. Resizing means deleting the StatefulSet
> (`--cascade=orphan` keeps the pods) and re-applying, or replacing the PVC.

**Chain database v6.** The chain database schema is version 6 at both
`v10.11.20260820` and `v10.11.20261112`, so upgrading between those two needs no
chain-DB migration. Version 5 databases migrate automatically **only** with
`config.migrateChainDb: true` (`--db-chain-automatic-migration`). Anything older
must be rebuilt: delete the PVC and let the init container bootstrap again.

**Filesystem permissions.** The image runs as non-root uid/gid **10000**. The
chart sets `podSecurityContext.fsGroup: 10000` so the PersistentVolume is
writable. Removing it makes Amaru fail at startup with a RocksDB
`PermissionDenied`. See *Security context* below for the rest of the pod's
security settings.

## Security context

Every pod meets the Pod Security Standards **restricted** profile, so the chart
installs into a namespace labelled `pod-security.kubernetes.io/enforce=restricted`.
Every container also runs with a **read-only root filesystem**.

**Pod** (`podSecurityContext`):

| Field | Value | Why |
|---|---|---|
| `runAsNonRoot` | `true` | the kubelet refuses any container whose user resolves to root |
| `runAsUser` / `runAsGroup` | `10000` | Amaru's image user. Its `USER` is the *name* `amaru`, which the kubelet cannot check against `runAsNonRoot`, so the number must be given explicitly |
| `fsGroup` | `10000` | makes the PersistentVolume writable (see *Filesystem permissions* above) |
| `fsGroupChangePolicy` | `OnRootMismatch` | re-own the volume only when its root does not already match, instead of walking every file on each mount |
| `seccompProfile.type` | `RuntimeDefault` | the container runtime's default seccomp filter |

**Every container** (`containerSecurityContext`), on init, mithril-sync, amaru
and the otel-collector sidecar:

| Field | Value |
|---|---|
| `allowPrivilegeEscalation` | `false` |
| `capabilities.drop` | `[ALL]` |
| `readOnlyRootFilesystem` | `true` |

Both are values-driven and Helm merges maps, so overriding one key (say
`podSecurityContext.fsGroup`) keeps all the others; set a key to `null` to
remove it.

**The sidecar runs as uid/gid 10001**, not 10000. That is the
`otel/opentelemetry-collector-contrib` image's own numeric user; the template
merges it over `containerSecurityContext` for that container only.

**Two `emptyDir` volumes stand in for the writable root**, mounted in init,
mithril-sync and amaru, including with `sleep: true`:

- `/var/lib/amaru`, the image WORKDIR. `amaru node bootstrap` writes its
  downloaded archives there, relative to its working directory. They are
  ephemeral, as they always were. This is the node's ephemeral storage, not the
  PersistentVolume, so on preview a bootstrap needs about 0.9 GiB of it
  (measured below).
- `/tmp`.

The databases still go to the PersistentVolume at `config.dataDir`.

**What has been measured.** On `v10.11.20261112`, a real preview
`amaru node bootstrap` run through the chart's init script under Docker with
`--read-only --user 10000:10000 --cap-drop ALL --security-opt no-new-privileges`,
tmpfs at `/var/lib/amaru` and `/tmp` and a writable data dir, completed with
exit code 0. It wrote about 914 MiB of archives under `/var/lib/amaru/snapshots`,
1.5 GiB to the data dir, and nothing to `/tmp`.

**What has not.** `amaru mithril sync` under the same constraints has **not**
been measured. The chart mounts the same two `emptyDir`s in the mithril-sync
container, but whether that is all it needs is unknown until a live run shows it.

Block-producer keys, when they are mounted, are read through the same `fsGroup`;
the block-producer section covers how.

## Block producer

A `nodes[]` entry with `type: block-producer` forges. It is the same StatefulSet
as a relay, with four differences: it mounts the pool's keys, passes the operator
flags, peers only with the list it is given, and is never exposed. **No values
file in this chart ships a block producer**; the default node is a relay.

```yaml
nodes:
  - name: <bp-name>
    enabled: true
    type: block-producer
    replicas: 1
    port: 3001
    peerAddresses:                       # your own relays, and nothing else
      - "<relay-a>:3001"
      - "<relay-b>:3001"
    # secretName: <bp-name>-secret       # the default
    # softwareTagOff: false              # the default: forged blocks carry the tag
```

### The keys Secret

Amaru forges only when it is given all three of `--operator-kes`,
`--operator-vrf` and `--operator-cert`; with none of them it is a follower. The
chart always passes all three, from a Secret named `<name>-secret`, or
`nodes[].secretName` when that is set. The Secret must hold exactly these keys:

| Key | What Amaru accepts |
|---|---|
| `kes.skey` | the period-zero KES key file, or a cardano-cli `kes.skey` envelope |
| `vrf.skey` | a raw 32-byte VRF seed, or an **unencrypted** cardano-cli `vrf.skey` |
| `node.cert` | the operational certificate |

**The cold key is not read and does not belong in the Secret**: the operational
certificate carries the cold verification key.

**Create the Secret out of band, never in values.** The chart has no inline-key
and no plaintext fallback on purpose: values end up in Git, in Argo CD and in
Helm's release history.

```bash
kubectl -n <namespace> create secret generic <bp-name>-secret \
  --from-file=kes.skey=<path-to>/kes.skey \
  --from-file=vrf.skey=<path-to>/vrf.skey \
  --from-file=node.cert=<path-to>/node.cert
```

How the chart mounts it:

- **In the `amaru` container only**, read-only at `/keys`. Not in `init` or
  `mithril-sync`, which run their scripts under `bash -x` and echo every command
  to the pod log, and not in the otel sidecar.
- **`items:` projects exactly the three keys above.** A Secret may hold more:
  the `cardano-node` chart in this repo also mounts `<name>-secret`, with the same
  three key names, and an operator may keep other material beside them. Only
  these three reach the pod. A key missing from the Secret fails the volume mount,
  so the pod does not start.
- **`defaultMode: 0440`**, readable by Amaru's uid 10000 through `fsGroup`. The
  `cardano-node` chart uses `0400`; this chart does not, because the files belong
  to root with group `fsGroup`. Not yet measured on a live cluster.
- **Not mounted with `sleep: true`**, which runs no Amaru and passes no operator
  flag.
- `secretName` is ignored on a relay, which mounts no Secret.

Amaru reads the keys **once, at startup**. It evolves the KES key in memory and
never writes it back. A rotation (a new KES key and an operational certificate
with its counter one higher) takes effect only on restart: update the Secret,
then restart the pod.

### What it renders

```
amaru node run --network <network> --db-ledger … --db-chain … \
  --peers-listen-on 0.0.0.0:<port> \
  --peer <relay-a>:3001 --peer <relay-b>:3001 \
  --tui-off [--db-chain-automatic-migration] \
  --peers-max-upstream 2 --peers-mix static!2 \
  --operator-kes /keys/kes.skey --operator-vrf /keys/vrf.skey --operator-cert /keys/node.cert \
  [--software-tag-off]
```

### Static-only peering

A block producer peers only with its own list: one `--peer` per entry of
`nodes[].peerAddresses` (the legacy `peerAddress` counts, empty strings do not),
then `--peers-max-upstream N --peers-mix static!N`, where `N` is the length of
that list. Both are `N` because the peer mix only splits the
`--peers-max-upstream` slots (default 3), and `!N` is a floor. The chart-wide
`config.upstreamPeers`, `config.downstreamPeers`, `config.peerMix`,
`config.peerSnapshot` and `config.submitApi` never reach a block producer: no
flag, no containerPort, and no port on `-int`.

**Every relay must list the block producer in its own peers.** Amaru's inbound
listener cannot be turned off, and its peer-sharing self-advertisement (pod IP
and listen port) is always on, but relays pull the block producer's blocks only
if they connect to it. An Amaru relay in the same release, for example:

```yaml
  - name: <relay-name>
    type: relay
    peerAddresses:
      - "amaru-<bp-name>-int:3001"
      - …
```

### Never exposed: what the render refuses

The render fails, naming the node, on any of these:

- `nodePort` or `submitApiNodePort` set on a block producer (any non-null value);
- any `submitApi` key on a block-producer entry;
- an empty effective peer list;
- two **enabled** block-producer entries resolving to the same Secret,
  `replicas: 0` included; that message names the Secret. A disabled entry and a
  relay do not count.

A block producer therefore gets the headless Service and `amaru-<name>-int`
only. The otel collector's metrics carry a `type` label (`relay` or
`block-producer`) beside `node` and `network`.

### Starting a block producer

Amaru checks the operational certificate at startup: its sequence number must
equal the chain's counter for the pool, or be exactly one ahead, **checked
against the ledger tip**. A KES key that does not match the certificate fails
startup too. Two ways to start:

- **Fresh, as a block producer from an empty volume.** A fresh bootstrap's
  ledger tip may be older than the current certificate. Startup then fails, and
  keeps failing, because the node never runs long enough to advance.
- **Sync as a relay first, then flip** (below). This is the remedy for the case
  above, and the path to prefer.

### KES expiry is silent

An **expired** KES period does **not** stop startup. The node keeps following,
and each slot it leads logs `WARN MISSED_SLOT reason=ocert_expired`. The
signal is the `remainingKESPeriods` gauge, which Amaru exports
over OTLP only on a node with credentials. The name it takes on the sidecar's
Prometheus endpoint has not been measured by this chart.

### Double forging: what the chart does and does not guarantee

Amaru does not detect two nodes forging with the same keys. RocksDB's lock
stops two processes only on the **same** volume.

What the chart guarantees, within **one release**: at most one pod per
block-producer entry, and no two enabled block-producer entries on one Secret.
The first holds because `replicas` is 0 or 1 and a StatefulSet's pod has a
fixed name, `amaru-<name>-0`: a pod name is unique in its namespace, so the
StatefulSet cannot create the replacement until the old pod is deleted from
the API. `podManagementPolicy` plays no part in this guarantee, though it does
govern the forced-rollback behaviour under "Health checks" below.

What it cannot see: other releases, other namespaces, other clusters, or a
Haskell block producer using the same keys. A force-deleted pod can also overlap
its replacement; on the same volume the second process fails at the RocksDB
lock. **Making sure nothing else forges with these keys is the operator's job**,
and the cutover below is where it matters.

### Cutover from a Haskell block producer

**Stop the Haskell block producer where it is declared, not by hand.** If its
release is managed by GitOps (an Argo CD or Flux app), its values in Git are the
source of truth, and a hand `kubectl scale` does not last: Argo CD's `selfHeal`
reverts it at once, and without `selfHeal` the next sync of that app reverts it,
possibly days after the NotFound check below passed. Either way both block
producers end up forging with the same keys.

1. **Stop the Haskell block producer at its source of truth.** In its values
   (its GitOps source, or the values file of its Helm release), set
   `replicas: 0`, or `enabled: false` if that is what its chart offers. Commit
   it, then sync that app.
2. **Do not hand-scale it instead.** A `kubectl scale` is reverted by `selfHeal`
   at once, and by any later sync of that app even without `selfHeal`.
3. **After that sync, prove it is gone.** `kubectl get pod` must print NotFound;
   a pod still Terminating is not gone.
4. **Only then enable the Amaru block producer** (`type: block-producer`,
   `replicas: 1`) and sync.
5. **After any flip, prove no NodePort Service survived.** Expect NotFound.

```yaml
# Step 1, in the Haskell block producer's values, in its source of truth:
replicas: 0          # or enabled: false, whichever its chart offers
```

```bash
# Step 3, after that sync. This must print NotFound.
kubectl -n <namespace> get pod <haskell-bp-pod>

# Step 5, after any flip. Expect NotFound.
kubectl -n <namespace> get svc amaru-<name>-ext
```

Repeat step 3 for anything else that may hold the same keys, in any release,
namespace or cluster: the chart cannot see it.

### Flipping relay ⇄ block producer in place

`type` is kept out of the StatefulSet selector, so changing it updates the
StatefulSet in place, keeping the node's name and volume (see *Upgrading to
0.0.1-alpha.24*).

- **Relay to block producer.** Create the Secret first. Remove the entry's
  `nodePort`, `submitApiNodePort` and any `submitApi` key (the render refuses
  them), give it `peerAddresses`, then set `type: block-producer`. Add it to every
  relay's peers.
- **Block producer to relay.** Set `type: relay`. The keys are no longer mounted,
  the operator flags go, and the chart-wide peering returns.

**After either flip, check the `-ext` Service.** A relay's `-ext` Service stops
rendering once its `nodePort` is gone but can survive in the cluster (an Argo CD
app with `prune: false` never deletes it). Its selector is pinned to
`type: relay`, so a stale one selects nothing, but delete it by hand and confirm
`kubectl -n <namespace> get svc amaru-<name>-ext` returns NotFound.

### Open files

Amaru fails at startup if the soft `RLIMIT_NOFILE` (open files) is below 1000.
The chart does not raise it; the container runtime's default applies. Check it
on the node, for example from a `sleep: true` pod:

```bash
kubectl -n <namespace> exec amaru-<name>-0 -c amaru -- bash -c 'ulimit -Sn'
```

### The CIP-0203 software tag

By default, forged blocks carry a CIP-0203 tag naming Amaru and its release
day. `softwareTagOff: true` renders `--software-tag-off`, which opts out. It is
off by default, so the tag is on.

## Monitoring

`otelCollector.enabled` is **true** by default, because it is the only path from
Amaru to Prometheus. Amaru pushes OTLP to the sidecar over localhost; the
sidecar exposes `/metrics` on 9464; the ServiceMonitor scrapes it.

```yaml
serviceMonitor:
  enabled: true                      # set false if kube-prometheus-stack is absent
  releaseName: kube-prometheus-stack # must match your Prometheus release label
```

The ServiceMonitor renders only when both `serviceMonitor.enabled` and at least
one collector are on — with no collector there is nothing to scrape.

The sidecar can also remote-write, or forward traces, via
`otelCollector.exporters`. To ship to a central collector instead of running a
sidecar, set `otelCollector.enabled: false` and give the node `otlpEndpoint`.

### How Amaru is pointed at the collector

`AMARU_LOG_OTLP=true` turns export on, for all signals (it replaces
`AMARU_WITH_OPEN_TELEMETRY`, the old name, which Amaru still remaps onto it).
Unset, Amaru exports nothing over OTLP. Instead of `true` it can name the signals
to export (metrics, traces, logs); this chart always sets `true`. **The endpoint
is not an `AMARU_` variable** — this binary contains no `AMARU_OTLP_*` string at
all and reads the **standard OpenTelemetry SDK environment**, so the chart sets
`OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_SERVICE_NAME`.

**Metrics export interval.** The chart also sets `OTEL_METRIC_EXPORT_INTERVAL`
from `config.otlpMetricExportIntervalMs`, in milliseconds, default `30000`.
Unset, Amaru exports metrics every 1000 ms (its own default; the OpenTelemetry
SDK's is 60 s), thirty times as often as Prometheus reads them at a 30 s scrape
interval. The ServiceMonitor this chart renders sets no interval, so the scrape
interval is the cluster's Prometheus default, not the chart's. The value must
be whole milliseconds in 1000..120000, as a YAML integer or a digit-only string;
anything else fails the render naming the key. That is checked at render time
because Amaru panics at startup on an empty or non-numeric value, and takes `0` as
a zero interval.

Until `0.0.1-alpha.22` the chart set `AMARU_OTLP_METRIC_URL`,
`AMARU_OTLP_SPAN_URL` and `AMARU_OTLP_SERVICE_NAME` instead. Those were
introduced in December 2025 against appVersion `0.0.1-alpha.1` and **silently
ignored ever since**; telemetry worked only because the SDK's default endpoint is
`localhost:4317`, which is where the sidecar listens. **`otelCollector.otlpGrpcPort`
was therefore a trap: moving it moved the collector's listener while the exporter
kept sending to 4317, and metrics stopped with every value in the chart looking
correctly applied.** It is a real knob now.

> **`otelCollector.otlpHttpPort` carries no traffic.** Measured from the
> collector's own internal telemetry, every signal — metrics, logs and spans —
> arrives over **gRPC on `otlpGrpcPort`**. The HTTP receiver is configured and
> unused. Two port values invite the reading that both are live paths; only one
> is, and only one needs changing if you move ports.

## Logging, and why the sidecar must accept logs and traces

**Amaru exports metrics, logs and traces over OTLP.** A collector wired only for
metrics answers `Unimplemented` to the other two, and Amaru's exporters retry
every ~5 seconds, forever, writing an error line into **Amaru's own log** each
time:

```
error opentelemetry_sdk: TonicLogsClient   export failed … gRPC code: Unimplemented
error opentelemetry_sdk: TonicTracesClient export failed … gRPC code: Unimplemented
```

**This is not cosmetic noise, and the reason is worth stating plainly: it inverts
severity.** Amaru reports block-validation failures — the messages that explain
why a node has stopped advancing — at **warn**. A continuous stream of routine
**error**s therefore outranks the diagnostics and buries them. During a real
investigation on this chart, the one warn that contained the entire answer was
very nearly missed in that stream. A log whose routine failures outrank its
findings is worse than a quiet one, and every future investigation pays the cost.

`otelCollector.acceptLogsAndTraces` (default `true`) gives both signals a pipeline
terminating in the collector's `debug` exporter, so Amaru receives success and
stops retrying. The summaries land in the **sidecar's** stdout, not Amaru's, so
severity stays where it belongs; `otelCollector.debugVerbosity` (default `basic`,
one line per batch) controls how much they say.

Traces additionally reach a real backend when `otelCollector.exporters.otlp` is
enabled. There is no such route for logs — the collector accepts and discards
them, which is what stops the retry loop.

**If you disable the sidecar**, the chart sets no `AMARU_LOG_OTLP` (unless the
node sets `withOpenTelemetry`), and with it unset Amaru exports nothing over OTLP
— no metrics, and no error stream either. A node pointed at a central collector
instead (`withOpenTelemetry` plus `otlpEndpoint`) still exports all three
signals, so that collector must accept logs and traces for the same reason.
Amaru can be told to export only some signals (`AMARU_LOG_OTLP` naming them), but
this chart always sets `true` and does not expose that selection.

## The `job` label is a contract with `amaru-monitoring`

The ServiceMonitor this chart renders deliberately relabels the scrape job to the
literal string `amaru`:

```yaml
relabelings:
  - sourceLabels: [__meta_kubernetes_service_label_app_kubernetes_io_name]
    targetLabel: job
    replacement: amaru
```

Without it the job would take the Service's own name (`amaru-relay-1-int`), which
varies per relay. **The `amaru-monitoring` chart's alert rules and dashboard
variables all query `job="amaru"`, so that relabel is load-bearing across the two
charts.**

**Remove or "simplify" it and every alert rule silently stops matching** — no
error, no failed rule, just alerts that never fire and dashboard dropdowns that
come back empty. That is the failure mode where a monitoring system reports
nothing and looks healthy doing it, which is worse than having no rules at all.

If you do change it, change `amaru-monitoring` in the same commit.


## Health checks

The chart sets a **readiness** probe (tcp connect on the p2p port) and
deliberately **no liveness probe**. Amaru has no HTTP health endpoint, and a
liveness probe would restart-loop a node during a long bootstrap or replay.
Readiness reports "listening" without ever killing a syncing node.

**A rollout that never becomes Ready needs the pod deleted by hand.** The
StatefulSet uses the Kubernetes default `podManagementPolicy: OrderedReady` with
rolling updates. If a change leaves the pod never Ready (a crash loop from a
bad image or flag, or block-producer keys that fail startup), reverting the
values is not enough: the StatefulSet keeps waiting for the broken pod before
it applies the reverted template. This is a known Kubernetes issue, described
under "Forced rollback" in the StatefulSet documentation. After reverting,
delete the pod with `kubectl delete pod amaru-<name>-0`; the StatefulSet
recreates it from the reverted template. On a block producer, delete it
normally and never with `--force`: see "Double forging" above.

## Debugging

Set `sleep: true` on a node to start the pod idle, with the databases mounted
but Amaru not running — the same convention as the `cardano-node` chart:

```yaml
nodes:
  - name: relay-1
    enabled: true
    sleep: true
```

Then `kubectl exec` in and run `amaru` by hand. `amaru node rollback` recovers
from a wrongly invalidated block; `amaru node rm --wipe-all-dbs` clears the
databases for a network.

## Values reference

| Key | Default | Description |
|---|---|---|
| `image.repository` | `ghcr.io/pragma-org/amaru` | upstream image |
| `image.tag` | `""` → chart `appVersion` | pin a release; `:latest` is a nightly |
| `network` | `mainnet` | `mainnet` \| `preprod` \| `preview` |
| `volumeSize` | `""` | explicit PVC size; overrides the derivation |
| `volumeSizeByNetwork` | mainnet/preprod `250Gi`, preview `50Gi` | PVC size derived from `network` — see Storage |
| `config.otlpMetricExportIntervalMs` | `30000` | `OTEL_METRIC_EXPORT_INTERVAL` in ms, 1000..120000; anything else fails the render — see Monitoring |
| `otelCollector.acceptLogsAndTraces` | `true` | give Amaru's log/trace exporters a pipeline — see Logging |
| `otelCollector.debugVerbosity` | `basic` | verbosity of the exporter terminating those pipelines |
| `resources` | 1 CPU / 1Gi | chart-level default, overridable per node |
| `podSecurityContext` | non-root uid/gid `10000`, `fsGroup: 10000` (`OnRootMismatch`), seccomp `RuntimeDefault` | pod side of the restricted profile; `fsGroup` is required for PVC write access — see Security context |
| `containerSecurityContext` | no privilege escalation, `drop: [ALL]`, `readOnlyRootFilesystem: true` | rendered on every container; the sidecar adds uid/gid `10001` — see Security context |
| `nodes[].name` | `relay-1` | relay name; becomes the object name suffix |
| `nodes[].enabled` | `true` | render this relay |
| `nodes[].type` | `relay` | `relay` \| `block-producer`; unset means `relay`, anything else fails the render. A pod label, kept out of the StatefulSet selector so a node can flip in place — see *Upgrading to 0.0.1-alpha.24* |
| `nodes[].replicas` | `1` | `0` or `1`; unset means `1`, anything else fails the render. `0` pauses the node and keeps its volume; scale out by adding `nodes` entries |
| `nodes[].port` | `3001` | p2p port: listen address, containerPort and services |
| `nodes[].peerAddresses` | `[]` | explicit upstream peers |
| `nodes[].nodePort` | `30000` | external exposure; omit for internal-only. Refused on a block producer |
| `nodes[].submitApiNodePort` | unset | NodePort for the submit API. Refused on a block producer |
| `nodes[].secretName` | `<name>-secret` | block producer only: the keys Secret (`kes.skey`, `vrf.skey`, `node.cert`) — see *Block producer* |
| `nodes[].softwareTagOff` | `false` | block producer only: `true` renders `--software-tag-off` |
| `nodes[].storageClassName` | unset | PVC storage class |
| `nodes[].sleep` | unset | start idle for debugging |
| `otelCollector.enabled` | `true` | the only metrics path |
| `serviceMonitor.enabled` | `true` | needs the Prometheus Operator CRDs |
