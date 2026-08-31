# Iagon Storage Node — https://iagon.com
#
# Iagon's v2 migration (deadline 2026-08-12, now passed) retired the old
# GitHub-released `iag-cli-linux` and replaced it with `iagon-node`, distributed
# as a tarball from Iagon's own artifact server. There is no upstream container
# image, which is why this one exists.
#
# The artifact URL has NO `v` prefix on the version — `.../v2.0.13/stable` 404s.
ARG IAGON_NODE_VERSION=2.0.13

# ── fetch ─────────────────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS fetch
ARG IAGON_NODE_VERSION

# Both checksums are BAKED rather than read from the server at build time. The
# artifact server does send `x-checksum-sha256`, and the tarball carries a
# manifest.json with the inner binary's hash — but trusting either at build time
# means the build silently follows whatever upstream publishes under this
# version. Pinning here makes the build reproducible and makes an upstream
# re-cut of 2.0.13 a loud build failure instead of a silent image change.
ARG IAGON_NODE_SHA256=6dab7005ff9dfb4324742d4a44a423981c1552561fdbae514ec5d566ab14b83a
ARG IAGON_NODE_BIN_SHA256=de85c560b05ca7cf8820b8651b73b756527c4d1a72be1836dde29ba521f5f61d

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /fetch
RUN curl -fsSL -o iagon-node.tar.gz \
      "https://skywalker.luke.iagon.com/iagon-node/linux/x86_64/${IAGON_NODE_VERSION}/stable" \
 && echo "${IAGON_NODE_SHA256}  iagon-node.tar.gz" | sha256sum -c - \
 && tar -xzf iagon-node.tar.gz \
 && echo "${IAGON_NODE_BIN_SHA256}  files/iagon-node" | sha256sum -c - \
 # Cross-check: the vendor's own manifest must agree with the hash we pinned.
 # If Iagon re-cuts this version the two disagree and the build stops here.
 && grep -q "${IAGON_NODE_BIN_SHA256}" manifest.json \
 && install -m 0755 files/iagon-node /iagon-node

# ── runtime ───────────────────────────────────────────────────────────────────
#
# ubuntu:24.04 is load-bearing, not inherited from the old v1 image (which was
# 22.04). The 2.0.13 binary is dynamically linked and needs GLIBC_2.39; 22.04
# ships 2.35, so the previous base physically cannot run this binary.
FROM ubuntu:24.04
ARG IAGON_NODE_VERSION

LABEL org.opencontainers.image.title="iagon-node" \
      org.opencontainers.image.description="Iagon Storage Node" \
      org.opencontainers.image.version="${IAGON_NODE_VERSION}" \
      org.opencontainers.image.vendor="Iagon LTD" \
      org.opencontainers.image.source="https://github.com/easy1staking-com/easy1staking-com-helm-charts"

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# The binary stays root-owned while the node runs as uid 1000. That is the
# structural defence against `iagon-node update`: self-update would overwrite
# the binary in place and silently break the version pin this image exists to
# enforce. A non-root runtime user simply cannot write /usr/local/bin.
COPY --from=fetch --chown=root:root --chmod=0755 /iagon-node /usr/local/bin/iagon-node
COPY --chown=root:root --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# /opt/iagon is NOT configurable — the binary resolves it from a fixed path, not
# from $HOME or any XDG variable (verified: running as uid 1000 without write
# access to /opt fails with `PrivilegeRequired`). Node identity, config and logs
# all land under /opt/iagon/iagon-node. It MUST be a persistent volume.
# /data is the storage shard directory, passed explicitly to `register
# --data-dir` by the entrypoint; the binary's own default would be
# /opt/iagon/data, i.e. nested inside the config volume, which we avoid so the
# two concerns can be sized and backed up separately.
# ubuntu:24.04 ships a stock `ubuntu` account already sitting on uid 1000, so it
# has to go before we can claim that uid for the node.
RUN userdel --remove ubuntu \
 && useradd --uid 1000 --user-group --home-dir /home/iagon --create-home --shell /usr/sbin/nologin iagon \
 && mkdir -p /opt/iagon /data \
 && chown -R 1000:1000 /opt/iagon /data

USER 1000:1000
ENV IAGON_DATA_DIR=/data \
    IAGON_LOG_LEVEL=info
VOLUME ["/opt/iagon", "/data"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
