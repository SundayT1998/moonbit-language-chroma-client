#!/usr/bin/env sh
# Integration tests against a real Chroma server.
#
# Kept out of scripts/ci.sh on purpose: the default checks must run anywhere
# `moon` is on PATH, and a Chroma container needs Docker and a published
# image. CI jobs that can provide both call this script after ci.sh.
#
# The tests themselves skip when CHROMA_ENDPOINT is unset, so this script is
# what makes them run — it starts the server, waits for it, and exports the
# endpoint.
#
# Usage: sh scripts/integration.sh [image]
#   image   Docker image to run (default: $CHROMA_IMAGE, else chromadb/chroma:latest)
#
# Environment:
#   CHROMA_IMAGE      override the image
#   CHROMA_PORT       host port to publish (default 8000)
#   CHROMA_READY_MS   how long to wait for /api/v2/heartbeat (default 120000)
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "${ROOT_DIR}"

IMAGE="${1:-${CHROMA_IMAGE:-chromadb/chroma:latest}}"
PORT="${CHROMA_PORT:-8000}"
READY_MS="${CHROMA_READY_MS:-120000}"
CONTAINER="chroma-client-it-$$"

log() {
  echo ""
  echo "==> $1"
}

cleanup() {
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
}
# Even a failed `docker run` should not leave a container behind.
trap cleanup EXIT

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to run the integration tests" >&2
  exit 1
fi

log "starting ${IMAGE}"
# Chroma serves its v2 API on 8000 and needs no configuration for this use:
# the default tenant/database already exist, and the tests create their own
# collections.
docker run -d --name "${CONTAINER}" -p "${PORT}:8000" \
  -e CHROMA_SERVER_HOST=0.0.0.0 \
  "${IMAGE}" >/dev/null

ENDPOINT="http://127.0.0.1:${PORT}"

log "waiting for ${ENDPOINT}/api/v2/heartbeat"
elapsed=0
interval=2
while [ "${elapsed}" -lt "${READY_MS}" ]; do
  if curl -fsS -m 3 "${ENDPOINT}/api/v2/heartbeat" >/dev/null 2>&1; then
    echo "chroma is up after ${elapsed}ms"
    break
  fi
  # A container that has already exited will never become ready, so fail
  # fast with its logs instead of waiting out the whole timeout.
  if ! docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null | grep -q true; then
    echo "chroma container exited unexpectedly:" >&2
    docker logs "${CONTAINER}" >&2 || true
    exit 1
  fi
  sleep "${interval}"
  elapsed=$((elapsed + interval * 1000))
done

if [ "${elapsed}" -ge "${READY_MS}" ]; then
  echo "chroma did not become ready within ${READY_MS}ms:" >&2
  docker logs "${CONTAINER}" >&2 || true
  exit 1
fi

# The caller is expected to have run scripts/ci.sh first, whose `update` step
# is what makes `moonbitlang/async` resolvable. Syncing again here costs
# nothing when the registry is already current and keeps this script usable on
# its own — without it, a stale (or absent) registry fails the whole job with
# "module was not found in the registry" instead of with a test failure.
log "moon update"
# `set -e` would abort here, and `moon update` exits non-zero even in the
# (harmless) case where it only reports that the index is already current and
# then regenerates the symbol index. The integration tests below re-run it and
# surface a real failure, so treat this run as best-effort.
moon update || echo "moon update reported a problem; continuing, see above"

log "moon test --target native (integration)"
# A run id namespaces the collections each test creates, so two jobs sharing
# one server cannot collide, and leftovers from a failed job stay
# identifiable.
export CHROMA_ENDPOINT="${ENDPOINT}"
export CHROMA_TEST_RUN_ID="${CHROMA_TEST_RUN_ID:-${CNB_BUILD_ID:-$$}}"

if ! moon test --target native --deny-warn -p SundayT1998/chroma-client/integration; then
  echo "" >&2
  echo "integration tests failed." >&2
  echo "If the failure above is dependency resolution (not a test failure), the" >&2
  echo "registry index in this runner is too old: re-run the job on a runner whose" >&2
  echo "image was built after the dependency was published, or bake the index into" >&2
  echo "the image (.cnb/Dockerfile, right after the toolchain install):" >&2
  echo "    RUN moon update" >&2
  exit 1
fi

log "integration passed"
