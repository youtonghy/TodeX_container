#!/usr/bin/env bash
# Starts IMAGE with one mirrored and one mapped work directory, then pairs
# with it headlessly (see pairing-e2e.mjs). Needs TodeX_protocol checked out
# next to this repository, or TODEX_PROTOCOL_DIR.
#
#   tests/pairing-e2e/run.sh IMAGE
set -euo pipefail

image=${1:?usage: tests/pairing-e2e/run.sh IMAGE}
here=$(cd "$(dirname "$0")" && pwd -P)
suffix=$$-$RANDOM
container=todex-pairing-$suffix
volume=todex-pairing-home-$suffix
mirrored=$(mktemp -d "${TMPDIR:-/tmp}/todex-pairing.XXXXXX")
mirrored=$(cd "$mirrored" && pwd -P)
mapped=$(mktemp -d "${TMPDIR:-/tmp}/todex-pairing-mapped.XXXXXX")
mapped=$(cd "$mapped" && pwd -P)
cleanup() {
    docker rm -f "$container" > /dev/null 2>&1 || true
    docker volume rm "$volume" > /dev/null 2>&1 || true
    rm -rf "$mirrored" "$mapped"
}
trap cleanup EXIT

(cd "$here" && npm ci --no-audit --no-fund > /dev/null && npm run --silent build)

docker run -d --name "$container" \
    -p 127.0.0.1::7345 \
    -e TODEX_UID="$(id -u)" -e TODEX_GID="$(id -g)" \
    -e TODEX_AGENTD_WORKSPACE_ROOTS="$mirrored:/workspace/e2e" \
    -e TODEX_AGENTD_PATH_MAPPINGS="[{\"hostPath\":\"$mapped\",\"backendPath\":\"/workspace/e2e\"}]" \
    -e TODEX_EXTRA_AGENTS= \
    -v "$volume:/home/todex" \
    -v "$mirrored:$mirrored" \
    -v "$mapped:/workspace/e2e" \
    "$image" > /dev/null

for _ in $(seq 1 90); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$container")" = healthy ] && break
    sleep 2
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$container")" = healthy ] || {
    docker logs --tail 60 "$container" >&2
    echo "pairing-e2e: FAIL: container did not become healthy" >&2
    exit 1
}
port=$(docker port "$container" 7345/tcp | head -n 1 | sed 's/.*://')

if ! docker exec -u todex "$container" todex-agentd pair --help > /dev/null 2>&1; then
    echo "pairing-e2e: skip: the image's todex-agentd has no container support yet"
    exit 0
fi

node "$here/pairing-e2e.mjs" --server "http://127.0.0.1:$port" --container "$container" \
    --expect-mapping "$mapped=/workspace/e2e"
