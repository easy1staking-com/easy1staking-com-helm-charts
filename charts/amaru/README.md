# Amaru

Helm chart for [Amaru](https://github.com/pragma-org/amaru), the Rust Cardano node
by PRAGMA. This chart deploys one or more **relays**.

Image: `ghcr.io/pragma-org/amaru` · verified against `v10.11.20260820`.

---

## Read this first: what Amaru is and is not, today

Amaru gained relay and peer-sharing capability in `v10.11.20260820`. Two limits
come straight from upstream's own release notes and shape what this chart can
promise:

- **Connections are not full-duplex yet.** Amaru can initiate outbound
  connections and accept inbound ones, but *over two separate TCP bearers* — a
  peer talking to Amaru does not get one bidirectional session the way it does
  with a Haskell relay. Amaru is relay-**capable**, not yet a drop-in
  cardano-node relay replacement.
- **The VRF key uniqueness rule is not yet enforced.**

Two further facts about the shape of the process, verified from the binary:

- **There is no node-to-client (n2c) interface.** No socket path, no socket
  option, anywhere in the CLI. Tools that expect `node.socket` (cardano-cli,
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

## Ports

| Port | Direction | Set by | Exposed on | Purpose |
|---|---|---|---|---|
| **3001** | **inbound** | `nodes[].port` | headless + ClusterIP, optionally NodePort | node-to-node p2p mini-protocol |
| 8090 | inbound | `config.submitApi.port` | ClusterIP, optionally NodePort | HTTP Submit API — only when `config.submitApi.enabled` |
| 9464 | inbound (scrape) | `otelCollector.prometheusPort` | ClusterIP | Prometheus scrape target on the sidecar |
| 4317 / 4318 | pod-local | `otelCollector.otlpGrpcPort` / `otlpHttpPort` | not exposed | Amaru → sidecar OTLP, over localhost |
| — | **outbound** | `nodes[].peerAddresses` | — | connections Amaru opens to upstream peers |

Notes on the p2p port:

- `nodes[].port` is the single source of truth. It drives `--listen-address`,
  the `containerPort`, and every Service port together, so the port Amaru
  actually listens on cannot drift from the port the cluster advertises.
- **3001** matches the `cardano-node` chart in this repo. Amaru's own built-in
  default is `3000`; this chart always passes the address explicitly, so the
  built-in default never applies.
- Amaru accepts up to `config.downstreamPeers` inbound connections (upstream
  default 10). That is the relay's serving capacity.

### Services

Each relay gets the same three services the `cardano-node` chart uses:

| Service | Type | Always? | Use |
|---|---|---|---|
| `amaru-<name>` | headless (`clusterIP: None`) | yes | stable per-pod DNS, e.g. `amaru-relay-1-0.amaru-relay-1` |
| `amaru-<name>-int` | ClusterIP | yes | ordinary in-cluster access; also carries the scrape and submit-api ports |
| `amaru-<name>-ext` | NodePort | only when `nodes[].nodePort` is set | external inbound |

A relay is therefore **always** reachable inside the cluster, and externally
only when you ask for it.

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

Amaru draws outbound peers from four sources, blended by `config.peerMix`:

| Source | Where it comes from | Configure with |
|---|---|---|
| `static` | peers you list explicitly | `nodes[].peerAddresses` |
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

Each entry renders one `--peer-address`. An **empty list emits no flag at all**,
which is deliberate: Amaru then falls back to its network bootstrap peer plus
the embedded peer snapshot (637 mainnet relays as of `v10.11.20260820`) and
ledger-derived peers. So a relay with zero configured peers still finds the
network — listing peers constrains it, it is not required to make it work.

Related knobs, all optional and omitted from the command line when unset:

| Value | Upstream default | Meaning |
|---|---|---|
| `config.upstreamPeers` | 3 | how many upstream peers to hold connections to |
| `config.downstreamPeers` | 10 | max inbound peers accepted — serving capacity |
| `config.peerMix` | `static!2@15m, shared~6, snapshot~3@1h, ledger~3@24h` | source blend: floors `!n`, weights `~n`, malus half-lives `@Nd` |
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
is the snapshots directory. **Consequence:** if PRAGMA ever rotates an aggregator
or key, you upgrade the image — the chart cannot override it.

### Known issue: Mithril ingest can fail on block validation

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
docker run --rm -v $PWD/data:/data ghcr.io/pragma-org/amaru:v10.11.20260820 \
  node bootstrap --network=preview --ledger-dir /data/ledger.db --chain-dir /data/chain.db
docker run --rm -v $PWD/data:/data ghcr.io/pragma-org/amaru:v10.11.20260820 \
  mithril sync --network preview --ledger-dir /data/ledger.db \
    --chain-dir /data/chain.db --snapshots-dir /data/mithril
```

This is why `config.mithrilSync.failOnError` defaults to **false**: an ingest
failure leaves a perfectly valid bootstrapped node that can still reach tip from
its peers, and treating it as fatal would turn an accelerator into a reason the
pod never starts. Not established: whether `node run` hits the same block when
syncing from peers.

## Config, storage and bootstrap

Amaru takes no topology file and no config directory — everything is CLI flags
and `AMARU_*` environment variables. This differs from `cardano-node`, which
mounts `<network>-config.json` and `<network>-topology.json`.

| Value | Default | Flag |
|---|---|---|
| `config.ledgerDir` | `/data/db/ledger.db` | `--ledger-dir` |
| `config.chainDir` | `/data/db/chain.db` | `--chain-dir` |
| `config.noTui` | `true` | `--no-tui` |
| `config.migrateChainDb` | `false` | `--migrate-chain-db` |

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

**The PVC size is DERIVED FROM `network`, not defaulted.** `volumeSizeByNetwork`
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
asymmetry sets the direction: a storage class with `ALLOWVOLUMEEXPANSION=false` —
k3s's default `local-path` included — cannot grow a PVC that turns out too small,
so **under-sizing is not "adjust later", it is destroy the volume, re-bootstrap
and re-sync**, while over-sizing costs only a nominal claim (`local-path` does not
preallocate — a 250Gi claim binds instantly and consumes nothing). Refine downward
once a preview relay has actually reached tip.

> **⚠ Resizing a RUNNING relay does not work.** A StatefulSet's
> `volumeClaimTemplates` are immutable, so an upgrade that changes the size is
> rejected by the API server. Resizing means deleting the StatefulSet
> (`--cascade=orphan` keeps the pods) and re-applying, or replacing the PVC.

**Chain database v6.** As of `v10.11.20260820` the chain database schema is
version 6. Version 5 databases migrate automatically **only** with
`config.migrateChainDb: true`. Anything older must be rebuilt: delete the PVC and
let the init container bootstrap again.

**Filesystem permissions.** The image runs as non-root uid/gid **10000**. The
chart sets `podSecurityContext.fsGroup: 10000` so the PersistentVolume is
writable. Removing it makes Amaru fail at startup with a RocksDB
`PermissionDenied`.

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
sidecar, set `otelCollector.enabled: false` and give the node
`otlpMetricUrl` / `otlpSpanUrl`.

## Logging, and why the sidecar must accept logs and traces

**Amaru exports metrics, logs AND traces over OTLP.** A collector wired only for
metrics answers `Unimplemented` to the other two, and Amaru's exporters retry
every ~5 seconds, forever, writing an ERROR line into **Amaru's own log** each
time:

```
ERROR opentelemetry_sdk: TonicLogsClient   export failed … gRPC code: Unimplemented
ERROR opentelemetry_sdk: TonicTracesClient export failed … gRPC code: Unimplemented
```

**This is not cosmetic noise, and the reason is worth stating plainly: it inverts
severity.** Amaru reports block-validation failures — the messages that explain
why a node has stopped advancing — at **WARN**. A continuous stream of routine
**ERROR**s therefore outranks the diagnostics and buries them. During a real
investigation on this chart, the one WARN that contained the entire answer was
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

**If you disable the sidecar entirely**, Amaru has nowhere to push and the same
ERROR stream returns. Amaru has no `/metrics` endpoint and no way to be told to
stop exporting, so the sidecar is the only place this can be handled.

## Health checks

The chart sets a **readiness** probe (TCP connect on the p2p port) and
deliberately **no liveness probe**. Amaru has no HTTP health endpoint, and a
liveness probe would restart-loop a node during a long bootstrap or replay.
Readiness reports "listening" without ever killing a syncing node.

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
| `otelCollector.acceptLogsAndTraces` | `true` | give Amaru's log/trace exporters a pipeline — see Logging |
| `otelCollector.debugVerbosity` | `basic` | verbosity of the exporter terminating those pipelines |
| `resources` | 1 CPU / 1Gi | chart-level default, overridable per node |
| `podSecurityContext.fsGroup` | `10000` | required for PVC write access |
| `nodes[].name` | `relay-1` | relay name; becomes the object name suffix |
| `nodes[].enabled` | `true` | render this relay |
| `nodes[].type` | `relay` | label only |
| `nodes[].replicas` | `1` | StatefulSet replicas |
| `nodes[].port` | `3001` | p2p port: listen address, containerPort and services |
| `nodes[].peerAddresses` | `[]` | explicit upstream peers |
| `nodes[].nodePort` | `30000` | external exposure; omit for internal-only |
| `nodes[].submitApiNodePort` | unset | NodePort for the submit API |
| `nodes[].storageClassName` | unset | PVC storage class |
| `nodes[].sleep` | unset | start idle for debugging |
| `otelCollector.enabled` | `true` | the only metrics path |
| `serviceMonitor.enabled` | `true` | needs the Prometheus Operator CRDs |
