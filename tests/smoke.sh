#!/usr/bin/env bash
# Smoke test for a built image: start, health, container API, preinstalled
# CLIs, pairing CLI permissions, mounted-file ownership, the local socket
# (when the image's backend has one), and state kept across a restart.
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
ipcdir=$(mktemp -d "${TMPDIR:-/tmp}/todex-smoke-ipc.XXXXXX")
ipcdir=$(cd "$ipcdir" && pwd -P)
ipc_socket=$ipcdir/agentd.sock

fail() { printf 'smoke: FAIL: %s\n' "$*" >&2; docker logs --tail 60 "$container" >&2 || true; exit 1; }
pass() { printf 'smoke: ok: %s\n' "$*"; }
cleanup() {
    docker rm -f "$container" > /dev/null 2>&1 || true
    docker volume rm "$volume" > /dev/null 2>&1 || true
    rm -rf "$workdir" "$ipcdir"
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
    -v "$ipcdir:/run/todex-ipc" \
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
# tini and the entrypoint (root) carry "todex-agentd serve" in their args too;
# the daemon is the process whose program is todex-agentd itself.
daemon_user=$(docker top "$container" -o pid,user,args \
    | awk '$3 ~ /(^|\/)todex-agentd$/ && $4 == "serve" { print $2; exit }')
[ -n "$daemon_user" ] || fail "no todex-agentd serve process found"
[ "$daemon_user" != root ] || fail "todex-agentd runs as root"
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

# The local socket: reachable from the host user (the daemon's UID), refused
# for everyone else, and the local-admin API exists only there.
ipc_get() { curl -fsS --max-time 10 --unix-socket "$ipc_socket" "http://localhost$1"; }
for _ in $(seq 1 10); do
    [ ! -S "$ipc_socket" ] || break
    sleep 1
done
if [ -S "$ipc_socket" ]; then
    ipc=1
    [ "$(stat -c %a "$ipc_socket")" = 600 ] || fail "socket mode is $(stat -c %a "$ipc_socket"), not 600"
    [ "$(stat -c %u "$ipcdir")" = "$(id -u)" ] || fail "socket directory is not owned by the host user"
    [ "$(ipc_get /v2/version | jq -r .name)" = todex-agentd ] || fail "/v2/version over the socket"
    admin=$(ipc_get /v2/local-admin/status) || fail "/v2/local-admin/status over the socket"
    jq -e '.deployment == "container" and .configEditable == false and .ipcPath == "/run/todex-ipc/agentd.sock"' \
        <<< "$admin" > /dev/null || fail "local-admin status: $admin"
    status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --unix-socket "$ipc_socket" \
        -X PUT -H 'Content-Type: application/json' -d '{"autoUpdate":true}' http://localhost/v2/local-admin/config)
    [ "$status" = 409 ] || fail "local-admin config should be managed by the image (409), got $status"
    status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$port/v2/local-admin/status")
    [ "$status" != 200 ] || fail "local-admin API answers on TCP"
    as_todex curl -fsS --max-time 10 --unix-socket /run/todex-ipc/agentd.sock http://localhost/v2/version > /dev/null \
        || fail "todex cannot use the socket inside the container"
    # Root passes the file permissions, so only the daemon's peer UID check
    # can refuse it; UID 12345 is stopped by the 0700 directory already.
    if docker exec -u 0 "$container" curl -fsS --max-time 10 --unix-socket /run/todex-ipc/agentd.sock \
        http://localhost/v2/version > /dev/null 2>&1; then
        fail "the socket accepted a connection from root"
    fi
    if docker exec -u 12345 "$container" curl -fsS --max-time 10 --unix-socket /run/todex-ipc/agentd.sock \
        http://localhost/v2/version > /dev/null 2>&1; then
        fail "the socket accepted a connection from UID 12345"
    fi
    pass "local socket serves the host user and the local-admin API, refuses other UIDs"
else
    ipc=0
    printf 'smoke: skip: backend %s does not create a local socket\n' "$(jq -r .version <<< "$version")"
fi

keys_before=$(as_todex sha256sum /home/todex/.todex-agent/pairing_keys.json)
docker restart "$container" > /dev/null
wait_healthy
keys_after=$(as_todex sha256sum /home/todex/.todex-agent/pairing_keys.json)
[ "$keys_before" = "$keys_after" ] || fail "pairing keys changed across a restart"
if [ "$ipc" = 1 ]; then
    for _ in $(seq 1 10); do
        ipc_get /v2/version > /dev/null 2>&1 && break
        sleep 1
    done
    ipc_get /v2/version > /dev/null || fail "local socket does not come back after a restart"
fi
pass "state survives a restart"

printf 'smoke: all checks passed for %s\n' "$image"
