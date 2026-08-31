#!/bin/sh
#
# iagon-node container entrypoint.
#
# Decides, on every pod start, between three states: already registered (just
# start), not registered but holding an auth key (re-attach an existing node
# identity), and not registered with no key (create a brand new node — only when
# explicitly armed).
#
set -eu

DATA_DIR="${IAGON_DATA_DIR:-/data}"
LOG_LEVEL="${IAGON_LOG_LEVEL:-info}"
AUTH_KEY_FILE="${IAGON_AUTH_KEY_FILE:-}"
ALLOW_NEW_NODE="${IAGON_ALLOW_NEW_NODE:-false}"

log() { echo "[entrypoint] $*"; }

# ── Is this node already registered? ─────────────────────────────────────────
#
# `iagon-node info` EXITS 0 WHETHER OR NOT THE NODE IS REGISTERED — when it is
# not, it prints "Error: NotRegistered" and still exits 0. The exit code carries
# no information here, so this has to match on output.
#
# The ambiguous case is deliberate and it matters. If `info` fails for some
# third reason (no egress yet, Iagon API down), we do NOT see "NotRegistered",
# and we fall through to "assume registered" → `start` → the node fails loudly
# and CrashLoopBackOffs. That is the safe direction. The opposite default would
# read a transient network error as "not registered" and cut a SECOND real node
# on Iagon's mainnet, orphaning the first one's identity and its stored shards.
# A visible crashloop is recoverable; a duplicate registration is not.
is_registered() {
    info_out="$(iagon-node info 2>&1 || true)"
    case "${info_out}" in
        *NotRegistered*) return 1 ;;
        *)               return 0 ;;
    esac
}

if is_registered; then
    log "node is registered; starting"
    exec iagon-node -l "${LOG_LEVEL}" start
fi

log "node is not registered"

if [ -n "${AUTH_KEY_FILE}" ] && [ -s "${AUTH_KEY_FILE}" ]; then
    # Re-attach an existing node identity. The key is read from a file (a
    # projected Secret) rather than taken from an environment variable so it
    # never shows up in `kubectl describe pod`. It still reaches the binary as
    # an argv element, because `register` offers no other way to accept it —
    # inside this container that exposes it only to the container's own
    # /proc, which is the best the CLI's surface allows.
    log "auth key present; re-attaching existing node identity (data-dir=${DATA_DIR})"
    iagon-node -l "${LOG_LEVEL}" register -y \
        --data-dir "${DATA_DIR}" \
        --auth-key "$(tr -d ' \t\n\r' < "${AUTH_KEY_FILE}")"
else
    # Registering with no auth key creates a BRAND NEW node on Iagon's network.
    # That is an outward, irreversible act, so it is never the default: the
    # operator has to arm it. This chart ships in a PUBLIC repository, where an
    # accidental `helm install` must not be able to mint network identities.
    if [ "${ALLOW_NEW_NODE}" != "true" ]; then
        log "ERROR: no auth key supplied and creating a new node is not armed."
        log "       Either point auth.existingSecret at a Secret holding the auth"
        log "       key of an existing node, or set auth.createNewNode=true to"
        log "       deliberately register a NEW node with the Iagon network."
        exit 1
    fi
    log "no auth key; registering a NEW node (data-dir=${DATA_DIR})"
    iagon-node -l "${LOG_LEVEL}" register -y --data-dir "${DATA_DIR}"
fi

log "registration complete; starting"
exec iagon-node -l "${LOG_LEVEL}" start
