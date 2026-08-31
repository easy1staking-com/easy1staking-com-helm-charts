# iagon

Container image for the **Iagon Storage Node** (`iagon-node`), published as
`easy1staking/iagon`. Iagon publishes no container image of their own, which is
why this build exists.

Consumed by `charts/iagon` — see that chart's README for how the node is
operated, and for what the two persistent volumes hold.

## v2

Iagon's v2 migration (deadline **2026-08-12**, now passed) retired the v1 CLI
`iag-cli-linux`, which was distributed through GitHub releases at
`Iagonorg/mainnet-node-CLI`. v2 ships a different binary, `iagon-node`,
distributed as a tarball from Iagon's artifact server:

```
https://skywalker.luke.iagon.com/iagon-node/linux/x86_64/<version>/stable
```

Note there is **no `v` prefix** on the version — `.../v2.0.13/stable` returns
404.

## Pinning

The Dockerfile bakes two sha256 checksums as build args: the tarball's and the
inner binary's. The artifact server does send an `x-checksum-sha256` header, and
the tarball carries a `manifest.json` with the binary's hash, but neither is
trusted at build time — using them would make the build follow whatever upstream
currently publishes under a given version. The baked hashes make the build
reproducible and turn an upstream re-cut of a version into a loud build failure
instead of a silent image change. The vendor manifest is still cross-checked
against the pinned hash, so the two disagreeing also stops the build.

## Two things worth knowing before changing this image

**The base image is load-bearing.** The 2.0.13 binary is dynamically linked and
requires `GLIBC_2.39`. The v1 image was built on `ubuntu:22.04`, which ships
2.35 — that base cannot run this binary at all. `ubuntu:24.04` ships 2.39.

**`iagon-node update` must never run in a container.** It self-updates the
binary in place, which would silently defeat the version pin this image exists
to enforce. That is not left to convention: the container runs as uid 1000 while
the binary stays root-owned at `/usr/local/bin/iagon-node`, so the runtime user
cannot overwrite it. (`ubuntu:24.04` ships a stock `ubuntu` account on uid 1000,
which the build removes to claim that uid.)

## Entrypoint

`entrypoint.sh` picks one of three paths on every start, driven by environment
variables the chart sets:

| Variable | Meaning |
|---|---|
| `IAGON_DATA_DIR` | Storage shard directory, passed to `register --data-dir` (default `/data`) |
| `IAGON_LOG_LEVEL` | `error`, `warn` or `info` (default `info`) |
| `IAGON_AUTH_KEY_FILE` | Path to a file holding an existing node's auth key |
| `IAGON_ALLOW_NEW_NODE` | `true` arms registration of a **brand new** node |

1. **Already registered** → `iagon-node start`.
2. **Not registered, auth key file present** → `register -y --data-dir … --auth-key …`, then start.
3. **Not registered, no key** → refuse and exit 1, unless `IAGON_ALLOW_NEW_NODE=true`.

### The registration check is deliberately biased

`iagon-node info` **exits 0 whether or not the node is registered** — when it is
not, it prints `Error: NotRegistered` and still exits 0. The exit code carries
no information, so the entrypoint matches on output instead.

That leaves an ambiguous case: if `info` fails for some third reason (no egress
yet, Iagon API down), the output does not contain `NotRegistered` and the
entrypoint assumes the node **is** registered. This is the safe direction. The
node then fails loudly and CrashLoopBackOffs, which is recoverable. The opposite
default would read a transient network error as "not registered" and cut a
**second real node** on Iagon's mainnet, orphaning the first identity and its
shards. That is not recoverable.

## Build

```bash
docker build -t easy1staking/iagon:2.0.13 -t easy1staking/iagon:latest docker/iagon
```

To move to a new upstream version, update `IAGON_NODE_VERSION` and **both**
checksums, then bump `appVersion` in `charts/iagon/Chart.yaml`:

```bash
curl -sSL -o t.tgz https://skywalker.luke.iagon.com/iagon-node/linux/x86_64/<version>/stable
sha256sum t.tgz && tar -xzf t.tgz && sha256sum files/iagon-node && cat manifest.json
```

## Testing without registering

Registration mints a real node on Iagon's live network, so it is not something
to do from a build. The entrypoint's branches can be exercised to the network
boundary with `--network none`, which makes registration impossible:

```bash
docker run --rm --network none easy1staking/iagon:2.0.13                            # refuses: not armed
docker run --rm --network none -e IAGON_ALLOW_NEW_NODE=true easy1staking/iagon:2.0.13 # new-node branch, stops at public-IP lookup
```
