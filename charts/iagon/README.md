# iagon

Helm chart for an **Iagon Storage Node** (`iagon-node` 2.0.13).

Unlike every other chart in this repository, this one does not deploy Cardano
infrastructure. It runs a storage node that sells disk to the Iagon network, so
it diverges from its neighbours on several points. Each divergence is explained
where it occurs, both here and in the templates.

## The v2 migration

Iagon retired the v1 CLI (`iag-cli-linux`, distributed via GitHub releases) at
the migration deadline of **2026-08-12**. v2 replaces it with a new binary,
`iagon-node`, distributed as a tarball from Iagon's own artifact server. There
is no upstream container image, so `docker/iagon/Dockerfile` in this repository
builds one: it downloads the pinned tarball, verifies **both** the tarball's
sha256 and the inner binary's sha256 against the vendor's `manifest.json`, and
installs it on `ubuntu:24.04`.

The base image is load-bearing. The 2.0.13 binary is dynamically linked and
requires `GLIBC_2.39`; the old v1 image was built on `ubuntu:22.04`, which ships
2.35 and physically cannot run it.

## A node IS its identity

The single most important fact about operating this chart: **an Iagon node is
its auth key plus its volumes.** Lose either and the node is gone — not
restartable, not recoverable. Registration is what mints an identity on Iagon's
live network, and it is not undoable from here.

Everything below follows from that.

### Two persistent volumes, both load-bearing

| Claim | Mount | Holds |
|---|---|---|
| `config` | `/opt/iagon` | Node identity, configuration, logs |
| `data` | `/data` (configurable) | The storage shards the node is paid to hold |

`/opt/iagon` is **not configurable**. The binary resolves it from a fixed path,
not from `$HOME` and not from any XDG variable — verified by running it as uid
1000 without write access to `/opt`, where it fails with `PrivilegeRequired`.
The v1 chart mounted `/root` for this reason; on v2 that is simply the wrong
path and would persist nothing.

The data directory is passed explicitly to `register --data-dir`. The binary's
own default is `/opt/iagon/data` — *inside* the identity volume. This chart
keeps the two apart so they can be sized, backed up and reasoned about
separately.

Note that **`start` accepts no `--data-dir`**: the location is recorded in the
config at registration time and read back from there afterwards. Moving the
data directory of a registered node is therefore not a matter of changing a
value here.

> `volumeClaimTemplates` are immutable. Neither size can be changed on a running
> StatefulSet — resizing means deleting the StatefulSet with `--cascade=orphan`
> and re-applying. Size `persistence.data.size` generously up front.

## The two operator paths

The entrypoint decides what to do on every pod start, and it can tell the
difference between the three states.

### 1. Attach an existing node (the migration path)

Create the Secret out of band and reference it by name. Nothing secret ever
enters this repository, which is public.

```bash
kubectl create secret generic iagon-node-1 --from-literal=auth-key='<AUTH KEY>'

helm install iagon-node-1 easy1staking/iagon \
  --set fullnameOverride=iagon-node-1 \
  --set auth.existingSecret=iagon-node-1 \
  --set persistence.data.size=500Gi
```

The key is projected as a **file** and the entrypoint is given its path. It is
deliberately not an environment variable: an env var is readable in
`kubectl describe pod` and in Argo's UI, a mounted file is not.

### 2. Register a brand new node

```bash
helm install iagon-node-3 easy1staking/iagon \
  --set fullnameOverride=iagon-node-3 \
  --set auth.createNewNode=true
```

`auth.createNewNode` defaults to `false` and **no values file in this chart
presets it to true, in any form.** Registering without an auth key mints a new
node on Iagon's live network — an outward, irreversible act. This is a public
chart repository, so an accidental `helm install` must not be able to perform
it. The absence of a ready-made preset is the design; please do not "complete"
it later. Without a key and without arming, the pod exits 1 with an explanatory
message rather than registering anything.

After registering, retrieve the new node's auth key (`iagon-node key regenerate`
or the Iagon dashboard) and store it somewhere durable. It is the only way to
re-attach this identity to a fresh volume.

### Running two nodes

Two nodes means **two releases**, each with its own Secret and its own volumes:

```bash
helm install iagon-node-1 easy1staking/iagon --set fullnameOverride=iagon-node-1 --set auth.existingSecret=iagon-node-1
helm install iagon-node-2 easy1staking/iagon --set fullnameOverride=iagon-node-2 --set auth.existingSecret=iagon-node-2
```

`replicas` is hard-coded to `1` and there is no `replicaCount` value — the same
choice `ft-aquarium-node` makes, for the same reason. A second replica would
come up against the same auth key with its own empty volumes; nothing about this
workload shards.

## Deliberate absences

Three things this chart does not ship, each on purpose:

- **No Service and no Ingress.** The node holds an *outbound* connection to
  Iagon's relay; management happens at `dashboard.iagon.com`, which reaches the
  node back through that relay rather than through any inbound port. There is
  nothing to expose. (Unlike `kupo`/`ogmios`, which ship a disabled ingress.)
- **No probes.** There is no endpoint this chart can reach to ask a meaningful
  question. A probe here could only re-test process liveness, which the
  container runtime already does — a probe that looks meaningful and is not is
  worse than none.
- **No `update` path.** `iagon-node update` self-updates in place, which would
  silently break the version pin the image exists to enforce. The image runs as
  uid 1000 while the binary stays root-owned, so self-update *cannot* succeed.
  Upgrades happen by bumping `appVersion` and rebuilding the image.

## Egress requirements

Registration is not a local operation and fails closed without network:

- `api.ipify.org` — public IP discovery. Registration **hard-fails** without it
  (`Failed to determine public IP address`), so a node behind an egress proxy
  that blocks it will never register.
- `speed.cloudflare.com` — bandwidth benchmark, run during registration.
- Iagon's API and gRPC relay — registration and the ongoing node connection.

`dnsPolicy` defaults to `Default` (the host resolver) rather than cluster DNS
for this reason.

## Maintenance mode

```bash
helm upgrade iagon-node-1 easy1staking/iagon --reuse-values --set maintenance=true
```

Replaces the container `command`, which overrides the image ENTRYPOINT entirely
— so the node cannot start, register, or touch its identity. Use it to inspect
or repair the volumes.

## Values

| Key | Default | Description |
|---|---|---|
| `image.repository` | `easy1staking/iagon` | Image built from `docker/iagon` |
| `image.tag` | `""` | Defaults to chart `appVersion` |
| `auth.existingSecret` | `""` | Name of a Secret holding the node auth key |
| `auth.key` | `auth-key` | Key within that Secret |
| `auth.createNewNode` | `false` | Arm registration of a **new** node |
| `logLevel` | `info` | `error`, `warn` or `info` |
| `persistence.config.size` | `2Gi` | Identity/config/log volume |
| `persistence.config.storageClass` | `""` | Cluster default when empty |
| `persistence.data.size` | `100Gi` | Storage shard volume — immutable once created |
| `persistence.data.storageClass` | `""` | Cluster default when empty |
| `persistence.data.mountPath` | `/data` | Passed to `register --data-dir` |
| `resources` | 100m / 256Mi req, 1Gi limit | The cluster schedules by **requests** |
| `podSecurityContext` | uid/gid/fsGroup 1000 | `fsGroup` is what makes the PVs writable |
| `dnsPolicy` | `Default` | Host resolver, for public-IP and relay egress |
| `maintenance` | `false` | Start the pod with the node stopped |
