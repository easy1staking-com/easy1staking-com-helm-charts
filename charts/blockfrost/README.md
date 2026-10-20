# blockfrost

Helm chart for a **Blockfrost API** backed by your own Cardano node, without
running a node in the chart.

The Blockfrost API here is two workloads:

- **blockfrost-platform** (a stateless Deployment, `:3000`) in **solitary** mode:
  it answers the Blockfrost API, reads chain data from Dolos and submits
  transactions to your node.
- **Dolos** (a single-writer StatefulSet, MiniBF on `:3010`, inside the cluster
  only): a light data node that Mithril-bootstraps once, then follows your node's
  chain.

**There is no Cardano node in this chart.** It attaches to one you already run,
over two coordinates (below), and refuses to render without them.

```bash
helm install blockfrost ./charts/blockfrost \
  --namespace blockfrost \
  --set network=preview \
  --set upstream.n2n.host=node.example.invalid \
  --set upstream.n2c.host=node.example.invalid
```

Release names whose full name starts with a digit are refused; see "Naming".

---

## Read these before you deploy

### 1. What it needs from your node: two coordinates

| Coordinate | Value | Used by | What must be true |
|---|---|---|---|
| node-to-node (chain-sync) | `upstream.n2n.host` / `upstream.n2n.port` | Dolos | a node reachable over TCP; rendered into `dolos.toml` as `peer_address` |
| node-to-client (local socket) | `upstream.n2c.host` / `upstream.n2c.port` | Platform | the node's **local socket exposed over TCP by a socat bridge**, on a node that serves **LocalTxSubmission** |

Both hosts are **required**: the render fails naming the missing key. A host must
be a DNS name, an IPv4 address or a bracketed IPv6 address.

**The n2c bridge is yours to run.** Next to your node, something like:

```bash
socat TCP-LISTEN:<port>,fork UNIX-CONNECT:<path-to-node.socket>
```

The Platform pod runs the reverse bridge itself, as a socat sidecar
(UNIX-LISTEN to TCP), so the Platform sees an ordinary node socket.

**Why a real node and not Dolos' own n2c:** the Platform submits transactions
over node-to-client, which needs LocalTxSubmission. Dolos' own n2c endpoint cannot
stand in for it, so point `upstream.n2c` at a real node, not at Dolos.

**The Platform auto-detects the network** by trying every magic, so pointing
`upstream.n2c` at a node on a *different* network is **not** refused at the
handshake, and this chart does not try to guard it (it cannot see the answer).
Keep `network` and your node on the same network yourself. With an unreachable
n2c the Platform exits with "Could not detect network".

### 2. The first start takes about two hours

Dolos Mithril-bootstraps in an init container before it serves anything.
Measured on **preview**: **2h01m** wall time. Until it finishes, the Dolos pod is
in `Init` and its Service has no endpoints. See "Bootstrap guard" for what every
volume state does, and "Monitoring" for what stays silent meanwhile.

During that window the Platform logs
`ERROR ... Data node root check failed` every 2 seconds (observed in the
2026-10-20 dev deploy). That is **expected noise, not a fault**: the Platform is
asking Dolos, which is not up yet. The chart deliberately has **no startup gate**
that makes the Platform wait for Dolos, because node-only routes, such as
transaction submit, work without Dolos.

### 3. Kubernetes 1.29 or newer

The socat bridge is a **native sidecar** (an init container with
`restartPolicy: Always`). Before Kubernetes 1.29 that would run as a blocking init
container that never exits, and the Platform pod would never start. `Chart.yaml`
sets `kubeVersion: ">=1.29.0-0"`, so Helm refuses an older cluster instead.

### 4. What the images are

| Role | Image | Notes |
|---|---|---|
| Platform | `ghcr.io/blockfrost/blockfrost-platform:1.0.0` | distroless, runs as **root** upstream |
| Dolos | `ghcr.io/txpipe/dolos:v1.6.1` | runs as **root** upstream |
| socat | `alpine/socat:1.8.1.1` | runs as **root** upstream |

All three are pinned by multi-arch index digest in `values.yaml`. `appVersion`
tracks the Platform; Dolos is pinned independently, so a Dolos bump does not move
`appVersion`.

**Dolos is v1.6.1, not the v1.4.0 that Blockfrost's own compose file pins.**
v1.4.0 can no longer Mithril-bootstrap: the aggregators dropped the Cardano-DB v1
backend it uses. v1.5.0 moved to Cardano DB v2; v1.6.1 is the first with the
rustls fix. The config keys are the same as v1.4.0's; the storage format is
`v3`.

---

## Parameters

Per-network settings (network magic, Mithril aggregator and keys, token registry
URL, default volume size) are **derived from `network` in the templates**. Setting
`network` inline is enough. **There are deliberately no `values-<network>.yaml`
presets**: a per-network file is invisible to a deployer who passes values inline,
who would then inherit every default the preset existed to override.

### General

| Key | Default | Meaning |
|---|---|---|
| `nameOverride` | `""` | replaces the chart name in object names |
| `fullnameOverride` | `""` | replaces the whole full name; must be a valid Service name (see "Naming") |
| `network` | `preview` | `mainnet`, `preprod` or `preview`; anything else fails the render |

### Upstream node

| Key | Default | Meaning |
|---|---|---|
| `upstream.n2n.host` | `""` | **required**; Dolos chain-sync peer |
| `upstream.n2n.port` | `3001` | its port |
| `upstream.n2c.host` | `""` | **required**; socat bridge to the node's local socket |
| `upstream.n2c.port` | `3001` | its port |

### Platform

| Key | Default | Meaning |
|---|---|---|
| `platform.image.repository` | `ghcr.io/blockfrost/blockfrost-platform` | image repository |
| `platform.image.tag` | `1.0.0` | image tag |
| `platform.image.digest` | pinned index digest | pins the image; see the warning below |
| `platform.replicas` | `1` | stateless, scale freely; `0` is honoured and renders 0 |
| `platform.logLevel` | `info` | `debug`, `info`, `warn`, `error` or `trace` |
| `platform.metrics` | `true` | serve Prometheus metrics on `:3000/metrics`; `false` adds `--no-metrics` |
| `platform.dataNodeTimeoutSec` | `30` | how long the Platform waits for Dolos before failing a request |
| `platform.resources.requests.cpu` | `100m` | measured on preview: anon 4.5 MiB, peak 25 MiB |
| `platform.resources.requests.memory` | `64Mi` | |
| `platform.resources.limits.memory` | `256Mi` | no CPU limit, by design |
| `platform.service.type` | `ClusterIP` | `ClusterIP` or `NodePort` |
| `platform.service.port` | `3000` | Service port |
| `platform.service.nodePort` | `null` | rendered only when type is `NodePort` **and** this is set |
| `platform.ingress.enabled` | `false` | render an Ingress for the API paths |
| `platform.ingress.className` | `""` | `ingressClassName`; empty omits it |
| `platform.ingress.host` | `""` | **required when enabled**; the render fails otherwise |
| `platform.ingress.annotations` | `{}` | Ingress annotations |
| `platform.ingress.tls` | `[]` | standard Ingress `tls` list |

**A digest is not repository-independent.** If you point `platform.image.repository`
(or the Dolos or socat equivalent) at your own mirror, clear or replace the
`digest` with one resolved from *that* repository; the pinned values identify
manifests inside the upstream repositories only.

### socat sidecar

| Key | Default | Meaning |
|---|---|---|
| `socat.image.repository` | `alpine/socat` | image repository |
| `socat.image.tag` | `1.8.1.1` | image tag |
| `socat.image.digest` | pinned index digest | pins the image |
| `socat.resources.requests.cpu` | `10m` | measured on preview: anon 0.9 MiB, peak 5.4 MiB |
| `socat.resources.requests.memory` | `16Mi` | |
| `socat.resources.limits.memory` | `64Mi` | |

### Dolos

| Key | Default | Meaning |
|---|---|---|
| `dolos.image.repository` | `ghcr.io/txpipe/dolos` | image repository |
| `dolos.image.tag` | `v1.6.1` | image tag; see "What the images are" |
| `dolos.image.digest` | pinned index digest | pins the image |
| `dolos.resources.requests.cpu` | `500m` | daemon; preview: anon 777 MiB at tip, peak 1047 MiB in the first minutes |
| `dolos.resources.requests.memory` | `1Gi` | |
| `dolos.resources.limits.memory` | `3Gi` | the mainnet epoch-boundary peak is **unmeasured** |
| `dolos.bootstrap.resources.requests.cpu` | `1` | Mithril init container; preview: anon peak 3.11 GiB |
| `dolos.bootstrap.resources.requests.memory` | `3Gi` | |
| `dolos.bootstrap.resources.limits.memory` | `5Gi` | the 8.76 GiB `memory.peak` included reclaimable page cache |
| `dolos.bootstrap.downloadDir` | `snapshot` | where the Mithril snapshot lands, relative to the data volume; see below |
| `dolos.storage.size` | `""` | empty means the per-network default; see "Storage" |
| `dolos.storage.storageClassName` | `""` | empty means the cluster's default StorageClass |
| `dolos.storage.accessMode` | `ReadWriteOnce` | |
| `dolos.sync.maxRollback` | `25920` | WAL pruning depth, written as `[sync] max_rollback` |
| `dolos.sync.pullBatchSize` | `100` | `[sync] pull_batch_size` |
| `dolos.mithril.aggregator` | `""` | empty means the per-network default |
| `dolos.mithril.genesisKey` | `""` | empty means the per-network default |
| `dolos.mithril.ancillaryKey` | `""` | empty means the per-network default |
| `dolos.tokenRegistryUrl` | `""` | empty means the per-network default |
| `dolos.logLevel` | `INFO` | Dolos `[logging] max_level`: `ERROR`, `WARN`, `INFO`, `DEBUG` or `TRACE` |

The Mithril keys are **public verification keys, not secrets**. They are
overridable, but the defaults are the published values for each network.

**`dolos.bootstrap.downloadDir`** must be a plain relative path: not empty, with
no `.` or `..` components, not `archive`, `index`, `state` or `wal` (the store
directories Dolos writes beside it), and its first component must not start with
`.` (it could alias the bootstrap marker and crashloop every later start). Dolos
**deletes** this directory after a successful bootstrap, so it must never resolve
to the data volume itself. It sits on the data volume because it is on disk at the
peak.

### Monitoring

| Key | Default | Meaning |
|---|---|---|
| `serviceMonitor.enabled` | `false` | render the ServiceMonitors |
| `serviceMonitor.releaseName` | `kube-prometheus-stack` | the `release` label your Prometheus selects on |
| `serviceMonitor.interval` | `30s` | scrape interval |
| `serviceMonitor.scrapeTimeout` | `10s` | scrape timeout |
| `prometheusRule.enabled` | `false` | render the PrometheusRule |
| `prometheusRule.releaseName` | `kube-prometheus-stack` | the `release` label your Prometheus selects on |
| `prometheusRule.rules.platformDown.for` | `5m` | `BlockfrostPlatformDown` |
| `prometheusRule.rules.platformUnhealthy.for` | `10m` | `BlockfrostPlatformUnhealthy` |
| `prometheusRule.rules.nodeDisconnected.for` | `5m` | `BlockfrostNodeDisconnected` |
| `prometheusRule.rules.dolosDown.for` | `10m` | `BlockfrostDolosDown` |
| `prometheusRule.rules.dolosStalled.for` | `5m` | `BlockfrostDolosStalled` |

---

## Exposure

| Mode | How | Notes |
|---|---|---|
| in-cluster (default) | `platform.service.type: ClusterIP` | Service `<fullname>-platform` on `platform.service.port` |
| NodePort | `platform.service.type: NodePort` plus `platform.service.nodePort` | no default on purpose; pick a free port |
| Ingress | `platform.ingress.enabled: true` plus `platform.ingress.host` | allowlist of API paths only |

**Dolos is ClusterIP only, with no value to change that.** MiniBF is the
Platform's data backend, not a public API. Expose the Platform instead.

**Taken NodePorts.** `platform.service.nodePort` has no default because several
ports are already claimed by default elsewhere in this repo: `30000` (`amaru` and
`cardano-node`), `30080` (`ft-aquarium-node` preview preset) and
`31337`/`31347`/`31357` (`ogmios`). Pick one that is free in your cluster.

**The Ingress is an allowlist, not a catch-all.** It routes `/` as `Exact` (the
root answers with node info: slot and sync state) and these prefixes:
`/accounts`, `/addresses`, `/assets`, `/blocks`, `/epochs`, `/genesis`,
`/governance`, `/health`, `/metadata`, `/network`, `/pools`, `/scripts`, `/tx`,
`/txs`, `/utils`.

**`/metrics` is never routed.** The Platform serves both `/metrics` **and
`/metrics/`** (trailing slash), so excluding only `/metrics` would still leak the
other. An allowlist is the only shape that cannot leak a path nobody thought of;
there is no `Prefix /`. If you add a path to the Ingress by hand, check
`/metrics/` first.

**`/epochs/latest` is a 404 from Dolos MiniBF.** The Platform passes it through,
so a client hitting it through this chart gets the 404. That is Dolos' MiniBF
route coverage, not a chart or Ingress fault, so do not go looking for a missing
path in the allowlist.

---

## Monitoring

Both switches default **off**: `ServiceMonitor` and `PrometheusRule` are
prometheus-operator CRDs, and an unknown kind fails the whole install on a
cluster without them.

`serviceMonitor.enabled` renders one ServiceMonitor for Dolos MiniBF
(`:3010/metrics`, always) and one for the Platform (`:3000/metrics`, only while
`platform.metrics` is true). Dolos' metrics are a MiniBF route on the same
listener, not a separate port: `dolos_slot`, `dolos_block_number`. Platform
metrics include `cardano_node_connections`, `health_errors_total`,
`http_requests_total`, `tx_submit_success` and `tx_submit_failure`.

`prometheusRule.enabled` renders one PrometheusRule with five alerts, each scoped
to its Service's job and this release's namespace:

| Alert | Fires when | Default `for` |
|---|---|---|
| `BlockfrostPlatformDown` | the Platform scrape target is down | 5m |
| `BlockfrostPlatformUnhealthy` | `health_errors_total` is above 0 | 10m |
| `BlockfrostNodeDisconnected` | `cardano_node_connections` is 0 | 5m |
| `BlockfrostDolosDown` | the Dolos scrape target is down | 10m |
| `BlockfrostDolosStalled` | `dolos_slot` has not changed over 15 minutes | 5m |

**`BlockfrostDolosDown` is silent during the bootstrap, by design.** While Dolos
is in its init container the Service has no endpoints, so the target is *absent*
rather than *down*, and `up == 0` has nothing to match.

**The alert set has blind spots, and they share one cause: every "down" alert
needs the target to exist.** None of these raises anything:

- a bootstrap crash-looping in its init container (the target never appears);
- a Platform scaled to 0 (`platform.replicas: 0`);
- a deleted workload.

`BlockfrostPlatformUnhealthy` may also fire while Dolos is still bootstrapping,
since the Platform's health depends on its data node. That is **unmeasured**.

**Scraping:** a real Prometheus v3.5.0 scraped both targets with `health=up`.
`promtool check metrics` rejects Dolos' body (no trailing newline, no `# TYPE`),
which only a strict linter notices; the scrape path accepts it.

---

## Bootstrap guard

The Dolos init container (`bootstrap.sh`, in the ConfigMap) decides what to do
from the state of the data volume. The completion marker is the file
`.blockfrost-bootstrap-complete` at the root of the data volume. It is written
**only after** `dolos bootstrap mithril` exits 0 (through a temporary file and a
rename), and its content records which store it describes:
`magic=<network magic> storage=v3`.

| Volume state | What happens |
|---|---|
| not a mounted volume (missing, or on the same device as `/`) | **refuse**, exit 1. A Mithril restore onto the container's root filesystem would fill the node's root disk. |
| fresh (empty, apart from `lost+found`) | bootstrap, then write the marker |
| marker present, content matches this release | nothing to do; never deletes |
| marker for **another network** or storage version | **refuse**, exit 1, nothing deleted. A volume reused across networks is refused instead of served. |
| marker present but `state/` missing or empty (marked but empty) | **refuse**, exit 1, nothing deleted |
| no marker, but contents present (an interrupted bootstrap) | **wipe** the contents, **except `lost+found`**, then bootstrap again. The mount root itself is never removed. |
| bootstrap fails | no marker is written, so the next start clears and retries |

**The wipe is deliberate, and it diverges from `charts/amaru`**, whose guard
*adopts* unmarked data. A half-finished Mithril restore is unusable, so it is
cleared rather than adopted. Two consequences to know about:

- **A leftover disk from an earlier install, with no marker, is wiped too.** If
  you reuse a volume, it must carry the marker or be disposable.
- **There is no retry bound.** A bootstrap that fails the same way every time
  wipes and retries forever.

`lost+found` is kept because filesystems such as ext4 create it at the volume
root, and it cannot be removed meaningfully.

---

## Storage

Dolos' data lives on a `volumeClaimTemplate`. `dolos.storage.size` empty selects
the per-network default:

| network | default | basis |
|---|---|---|
| preview | `60Gi` | **MEASURED**: bootstrap peak 37.11 GiB, settling at 20.01 GiB once the download directory is removed, plus headroom for growth |
| preprod | `80Gi` | **DERIVED**, not measured: preview scaled by Mithril snapshot size (20.13 GB / 16.04 GB) gives about 46.6 GiB peak, plus headroom |
| mainnet | `250Gi` | **UNMEASURED**: Giovanni's ruling on 2026-10-19, "250 for now, refine later" (T-408) |

**Mainnet: 250Gi is probably too small.** The mainnet Mithril cardano-db is
236.71 GB uncompressed (aggregator, epoch 662, read 2026-10-20). Scaling preview's
ratios gives about **550 GiB** at the bootstrap peak and about **295 GiB** settled.
That is a derived, low-confidence figure (mainnet ledger state and index do not
scale linearly with immutable size), but it points one way. **Set
`dolos.storage.size` explicitly for mainnet, and read T-408, before you install.**

Preview, measured after bootstrap: `archive` 17G, `index` 3.1G, `snapshot` 15G
(the download directory, removed afterwards), `state` 915M, `wal` 64K. The disk
peak happens *before* the snapshot is removed, so size for the peak, not the
settled figure.

- **Published defaults are frozen.** `volumeClaimTemplates` are immutable, so
  changing a default here would be a breaking chart-version bump for every
  install that relied on it. Set an explicit size rather than waiting for one.
- **Under-sizing is a destroy-and-restore**, not a resize: a size change on a
  running StatefulSet is rejected, and many provisioners cannot expand volumes.
  Err generous; most provisioners do not preallocate.
- **The PVC survives `helm uninstall`.** StatefulSet claims are not garbage
  collected by Helm. A reinstall finds the old volume and its marker (see "Bootstrap
  guard"); delete the PVC yourself if you want a clean start.
- **A breaking Dolos upgrade needs a manual storage-format migration.** The
  marker records `storage=v3`; a Dolos release that changes the storage format
  will refuse the old volume. Migrate or re-bootstrap by hand (delete the PVC);
  the chart does not do it for you.

---

## Resources

All figures below are measured on **preview** unless marked. Memory is the
cgroup `anon` figure, the one a limit can OOM on.

| Container | Requests | Limits | Measured |
|---|---|---|---|
| Dolos bootstrap (init) | cpu `1`, memory `3Gi` | memory `5Gi` | anon peak 3.11 GiB; `memory.peak` 8.76 GiB including reclaimable page cache |
| Dolos daemon | cpu `500m`, memory `1Gi` | memory `3Gi` | anon 777 MiB at tip, peak 1047 MiB in the first minutes; mainnet epoch-boundary peak **unmeasured** |
| Platform | cpu `100m`, memory `64Mi` | memory `256Mi` | anon 4.5 MiB, peak 25 MiB |
| socat sidecar | cpu `10m`, memory `16Mi` | memory `64Mi` | anon 0.9 MiB, peak 5.4 MiB |

**No CPU limits**: sync and import are CPU-bursty, and a CPU limit only throttles
them. Kubernetes schedules by **requests**, so check `dolos.bootstrap.resources`
against your node's real headroom: the bootstrap request is the largest.

---

## Deliberate absences

Each of these reads like an omission. None is.

- **No Icebreakers registration, no secret and no reward address.** The Platform
  runs `--solitary`, which needs neither; the chart ships no value for either and
  never creates a Secret.
- **No `--mode`.** It only feeds the Icebreakers registration payload, which
  solitary mode never sends, so passing it would imply an effect it does not
  have.
- **No network-mismatch guard on n2c.** The Platform auto-detects the network
  from the node, so there is nothing for the chart to compare against (see
  "What it needs from your node").
- **`dolos.sync.maxRollback`, not `max_wal_history`.** Blockfrost's upstream
  template writes `[storage] max_wal_history = 25920`; no Dolos version reads
  that key, and Dolos silently ignores unknown keys, so it never had an effect.
  The chart writes the value upstream intended (`25920`) under the key Dolos
  reads, `[sync] max_rollback`. The dead key's name is not in the rendered config
  at all. Do not "restore" it.
- **No `[sync] max_history`.** Absent means a full archive, as upstream runs it.
- **No readiness probes yet.** Readiness is deferred until real data exists to
  base it on. The Platform's `/health` always answers 200, with
  `{"is_healthy": bool}` in the body, so a status code alone cannot say whether it
  is ready; and a probe tied to Dolos' sync state would restart a pod that is
  merely syncing. The Platform has a liveness probe; the Dolos daemon too.
- **No `--retain-snapshot`.** Dolos removes the Mithril download directory after a
  successful bootstrap.
- **No Mithril or network presets file.** Per-network values are derived from
  `network` (see "Parameters").
- **Both images run as root upstream.** The chart does not change the user.
- **`enableServiceLinks: false` on the Platform.** Every `BLOCKFROST_*` environment
  variable is read as configuration, and Kubernetes service links would inject
  look-alikes.

---

## Naming

All object names derive from the full name. Services must be DNS-1035 labels, so
the chart **refuses** any full name that is not one: lowercase letters, digits and
`-`, starting with a letter and ending with a letter or digit.

- **A release name that starts with a digit is refused** (for example `1node`):
  the render fails and tells you to set `fullnameOverride`.
- **A `fullnameOverride` that is not a valid Service name is refused**, with the
  same rule in the message.
- **Long release names are shortened** so the object names stay valid. The Dolos
  StatefulSet name is capped at **52** characters, not 63: the controller adds a
  suffix to the pod's `controller-revision-hash` label, and a longer name means the
  pods are never created. The base is truncated before `-dolos` is appended.

## Release

Bumping `Chart.yaml: version` in a commit to `main` publishes the chart
immediately via chart-releaser; that bump is the release gate.
