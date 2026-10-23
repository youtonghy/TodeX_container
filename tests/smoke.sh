#!/usr/bin/env bash
# Smoke test for a built image: start, health, container API, preinstalled
# CLIs, pairing CLI permissions, mounted-file ownership, and state kept across
# a restart.
#
#   tests/smoke.sh IMAGE
#
# SMOKE_EXTRA_AGENTS (default empty) is passed as TODEX_EXTRA_AGENTS, so the
# first-start install is only exercised when asked for (it needs the network).
set -euo pipefail

image=${1:?usage: tests/smoke.sh IMAGE}
suffix=$$-$RANDOM
container=todex-smoke-$suffix
volume=todex-smoke-home-$suffix
workdir=$(mktemp -d "${TMPDIR:-/tmp}/todex-smoke.XXXXXX")
workdir=$(cd "$workdir" && pwd -P)

fail() { printf 'smoke: FAIL: %s\n' "$*" >&2; docker logs --tail 60 "$container" >&2 || true; exit 1; }
pass() { printf 'smoke: ok: %s\n' "$*"; }
cleanup() {
    docker rm -f "$container" > /dev/null 2>&1 || true
    docker volume rm "$volume" > /dev/null 2>&1 || true
    rm -rf "$workdir"
}
trap cleanup EXIT

wait_healthy() {
    local state
    for _ in $(seq 1 90); do
        state=$(docker inspect -f '{{.State.Health.Status}}' "$container" 2> /dev/null || echo missing)
        [ "$state" != healthy ] || return 0
        [ "$state" != unhealthy ] || break
        [ "$(docker inspect -f '{{.State.Running}}' "$container" 2> /dev/null)" = true ] || break
        sleep 2
    done
    fail "container did not become healthy (last state: $state)"
}

as_todex() { docker exec -u todex "$container" "$@"; }

docker run -d --name "$container" \
    -p 127.0.0.1::7345 \
    -e TODEX_UID="$(id -u)" -e TODEX_GID="$(id -g)" \
    -e TODEX_AGENTD_WORKSPACE_ROOTS="$workdir" \
    -e TODEX_AGENTD_ADVERTISE_URL=http://127.0.0.1:7345 \
    -e TODEX_EXTRA_AGENTS="${SMOKE_EXTRA_AGENTS:-}" \
    -v "$volume:/home/todex" \
    -v "$workdir:$workdir" \
    "$image" > /dev/null
wait_healthy
pass "container is healthy"

port=$(docker port "$container" 7345/tcp | head -n 1 | sed 's/.*://')
[ "$(curl -fsS "http://127.0.0.1:$port/health")" = ok ] || fail "/health from the host"
pass "/health reachable through the published port"

version=$(curl -fsS "http://127.0.0.1:$port/v2/version")
[ "$(jq -r .name <<< "$version")" = todex-agentd ] || fail "/v2/version name: $version"
# The container API arrived with the backend's container support.
if as_todex todex-agentd pair --help > /dev/null 2>&1; then
    container_api=1
    [ "$(jq -r .deployment <<< "$version")" = container ] || fail "/v2/version deployment: $version"
    pass "/v2/version reports deployment=container"
else
    container_api=0
    printf 'smoke: skip: backend %s has no container support yet\n' "$(jq -r .version <<< "$version")"
fi

for cli in codex opencode pi; do
    path=$(as_todex sh -c "command -v $cli") || fail "$cli is not on PATH"
    case "$path" in /opt/todex/agents/*) ;; *) fail "$cli resolved to $path, not the image's copy" ;; esac
    as_todex "$cli" --version > /dev/null || fail "$cli --version"
done
pass "codex, opencode and pi are preinstalled"

[ "$(docker exec "$container" id -u todex)" = "$(id -u)" ] || fail "todex UID was not aligned with the host"
[ "$(docker top "$container" -o user,args | awk '/todex-agentd serve/ { print $1 }' | head -n 1)" != root ] \
    || fail "todex-agentd runs as root"
as_todex touch "$workdir/created-in-container"
[ "$(stat -c %u "$workdir/created-in-container")" = "$(id -u)" ] || fail "file created in the container is not owned by the host user"
pass "daemon runs unprivileged and mounted files keep host ownership"

if [ "$container_api" = 1 ]; then
    [ "$(as_todex todex-agentd pair list --format json | jq length)" = 0 ] || fail "pair list is not empty"
    set +e
    docker exec "$container" todex-agentd pair list > /dev/null 2>&1
    status=$?
    set -e
    [ "$status" = 3 ] || fail "pair list as root should exit 3, got $status"
    status=0
    as_todex todex-agentd pair approve AAAAA-AAAAA > /dev/null 2>&1 || status=$?
    [ "$status" = 2 ] || fail "approving an unknown code should exit 2, got $status"
    pass "pair CLI works as todex and refuses other users"
fi

keys_before=$(as_todex sha256sum /home/todex/.todex-agent/pairing_keys.json)
docker restart "$container" > /dev/null
wait_healthy
keys_after=$(as_todex sha256sum /home/todex/.todex-agent/pairing_keys.json)
[ "$keys_before" = "$keys_after" ] || fail "pairing keys changed across a restart"
pass "state survives a restart"

printf 'smoke: all checks passed for %s\n' "$image"
