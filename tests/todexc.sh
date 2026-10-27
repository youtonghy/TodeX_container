#!/usr/bin/env bash
# Checks bin/todexc without Docker: a fake `docker` records calls and reports
# a healthy container, and the generated compose file is inspected.
#
#   tests/todexc.sh
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/todexc-test.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/bin" "$scratch/config" "$scratch/work/a b" "$scratch/work/c"
cat > "$scratch/bin/docker" <<'EOF'
#!/bin/sh
[ "$1 $2" = "compose version" ] && exit 0
echo "docker $*" >> "$TODEXC_TEST_CALLS"
case "$*" in *" ps "*) echo container-id ;; esac
[ "$1" = inspect ] && echo healthy
exit 0
EOF
chmod +x "$scratch/bin/docker"
# uname reports TODEXC_TEST_UNAME (default Linux) so both host kinds are covered.
cat > "$scratch/bin/uname" <<'EOF'
#!/bin/sh
echo "${TODEXC_TEST_UNAME:-Linux}"
EOF
chmod +x "$scratch/bin/uname"
export TODEXC_TEST_CALLS="$scratch/calls"

fail() { printf 'todexc test: FAIL: %s\n' "$*" >&2; exit 1; }
todexc() {
    PATH="$scratch/bin:$PATH" XDG_CONFIG_HOME="$scratch/config" bash "$repo/bin/todexc" "$@" < /dev/null 2> "$scratch/stderr"
}
expect_failure() {
    if todexc "$@"; then fail "todexc $* should fail"; fi
}

todexc up --mount "$scratch/work/a b" --mount "$scratch/work/c:/workspace/c" || fail "up: $(cat "$scratch/stderr")"
compose="$scratch/config/todex-container/todex/compose.yaml"
grep -q 'container_name: "todex"' "$compose" || fail "default container is not named todex"
grep -q '"127.0.0.1:7345:7345"' "$compose" || fail "not published on loopback"
grep -qF "TODEX_AGENTD_WORKSPACE_ROOTS: \"$scratch/work/a b:/workspace/c\"" "$compose" || fail "workspace roots"
grep -qF "{\\\"hostPath\\\":\\\"$scratch/work/a b\\\",\\\"backendPath\\\":\\\"$scratch/work/a b\\\"}" "$compose" \
    || fail "mirrored mount has no identity mapping"
grep -qF "{\\\"hostPath\\\":\\\"$scratch/work/c\\\",\\\"backendPath\\\":\\\"/workspace/c\\\"}" "$compose" \
    || fail "mapped mount has no mapping"
grep -q "TODEX_UID: \"$(id -u)\"" "$compose" || fail "host UID not passed"
grep -q 'io.todex.instance: "todex"' "$compose" || fail "instance label"
ipc="$scratch/config/todex-container/todex/ipc"
grep -A 1 -- '- type: bind' "$compose" | grep -qF "source: \"$ipc\"" || fail "ipc directory is not mounted"
grep -A 1 -F "source: \"$ipc\"" "$compose" | grep -qF 'target: "/run/todex-ipc"' || fail "ipc mount target"
[ -d "$ipc" ] || fail "ipc directory was not created"
[ "$(stat -c %a "$ipc")" = 700 ] || fail "ipc directory mode is $(stat -c %a "$ipc"), not 700"
grep -qF "Local socket: $ipc/agentd.sock" "$scratch/stderr" || fail "up does not print the local socket path"
expect_failure mount add "$scratch/work/c:/run/todex-ipc"

expect_failure mount add "$scratch/work/c:/etc"
expect_failure mount add "$scratch/work/c:/home/todex/x"
expect_failure mount add "$scratch/work/c:/workspace/with:colon"
expect_failure mount add "$scratch/work/a b:/workspace/c"
expect_failure --name Bad up --mount "$scratch/work/c"
expect_failure up --port abc

todexc mount rm /workspace/c || fail "mount rm"
[ "$(todexc mount list)" = "$scratch/work/a b -> $scratch/work/a b" ] || fail "mount list after rm"

todexc pair ABCDE-12345 || fail "pair"
tail -n 1 "$TODEXC_TEST_CALLS" | grep -q 'exec -u todex todex todex-agentd pair approve ABCDE-12345' \
    || fail "pair does not approve as the todex user"

todexc --name second up --port 7346 --mount "$scratch/work/c" || fail "second instance"
grep -q 'container_name: "todex-second"' "$scratch/config/todex-container/second/compose.yaml" || fail "named instance"
grep -q 'io.todex.instance: "second"' "$scratch/config/todex-container/second/compose.yaml" || fail "named instance label"

# An ipc directory with loose permissions is tightened.
chmod 0755 "$ipc"
todexc up || fail "up again: $(cat "$scratch/stderr")"
[ "$(stat -c %a "$ipc")" = 700 ] || fail "ipc directory mode was not reset to 700"

# --no-publish drops the host port and the advertised URL; --publish restores them.
todexc --name ipconly up --no-publish --mount "$scratch/work/c" || fail "no-publish: $(cat "$scratch/stderr")"
ipc_compose="$scratch/config/todex-container/ipconly/compose.yaml"
if grep -qE 'ports:|ADVERTISE_URL' "$ipc_compose"; then fail "no-publish still publishes"; fi
grep -q 'TODEX_PUBLISH=0' "$scratch/config/todex-container/ipconly/settings.env" || fail "no-publish not saved"
todexc --name ipconly upgrade || fail "upgrade no-publish"
if grep -q 'ports:' "$ipc_compose"; then fail "upgrade publishes a no-publish instance"; fi
todexc --name ipconly up --publish || fail "publish again"
grep -q '"127.0.0.1:7345:7345"' "$ipc_compose" || fail "--publish does not restore the port"
TODEXC_TEST_UNAME=Darwin expect_failure --name macipc up --no-publish --mount "$scratch/work/c"

# Docker Desktop cannot pass Unix sockets: no ipc mount on macOS.
TODEXC_TEST_UNAME=Darwin todexc --name mac up --mount "$scratch/work/c" || fail "macOS instance: $(cat "$scratch/stderr")"
mac_compose="$scratch/config/todex-container/mac/compose.yaml"
if grep -q 'todex-ipc' "$mac_compose"; then fail "ipc mounted on macOS"; fi
[ ! -e "$scratch/config/todex-container/mac/ipc" ] || fail "ipc directory created on macOS"
grep -q 'io.todex.instance: "mac"' "$mac_compose" || fail "macOS instance label"
if grep -qF 'Local socket' "$scratch/stderr"; then fail "macOS up prints a local socket"; fi

printf 'todexc test: all checks passed\n'
