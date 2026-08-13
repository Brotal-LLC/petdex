#!/bin/sh
set -eu

# Opt-in end-to-end transport test. It exercises the built desktop binary
# against an isolated SSH host without consuming a hosted CI runner.
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
binary=${PETDEX_TEST_BINARY:-$root/zig-out/bin/petdex-desktop-native}
pet=${PETDEX_TEST_PET:-$HOME/.petdex/pets/boba}
fixture=$(mktemp -d)
container=petdex-ssh-test-$$
app_pid=

cleanup() {
    if [ -n "$app_pid" ]; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$fixture"
}
on_signal() {
    trap - 0 1 2 15
    cleanup
    exit 143
}
trap cleanup 0
trap on_signal 1 2 15

command -v docker >/dev/null
command -v ssh >/dev/null
command -v ssh-keygen >/dev/null
test -x "$binary"
test -r "$pet/pet.json"

pet_name=$(basename "$pet")
mkdir -p "$fixture/.petdex/pets" "$fixture/.ssh"
cp -R "$pet" "$fixture/.petdex/pets/$pet_name"
chmod 700 "$fixture/.ssh"
ssh-keygen -t ed25519 -N '' -f "$fixture/.ssh/ci_petdex" -q

docker run -d --name "$container" -p 127.0.0.1::22 ubuntu:24.04 sleep infinity >/dev/null
docker exec "$container" bash -lc \
    'apt-get update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server curl python3 procps >/dev/null && useradd -m -s /bin/bash petdex && mkdir -p /run/sshd /home/petdex/.ssh'
docker cp "$fixture/.ssh/ci_petdex.pub" "$container:/tmp/ci_petdex.pub" >/dev/null
docker exec "$container" bash -lc \
    'cat /tmp/ci_petdex.pub > /home/petdex/.ssh/authorized_keys && chown -R petdex:petdex /home/petdex/.ssh && chmod 700 /home/petdex/.ssh && chmod 600 /home/petdex/.ssh/authorized_keys && ssh-keygen -A >/dev/null'
docker exec -d "$container" /usr/sbin/sshd -D -e

mapping=$(docker port "$container" 22/tcp | head -n 1)
port=${mapping##*:}
identity=$fixture/.ssh/ci_petdex
known_hosts=$fixture/.ssh/known_hosts
remote="ssh -oBatchMode=yes -oStrictHostKeyChecking=accept-new -oUserKnownHostsFile=$known_hosts -oConnectTimeout=8 -p $port -i $identity -- petdex@127.0.0.1"

for _ in 1 2 3 4 5 6 7 8 9 10; do
    # shellcheck disable=SC2086
    $remote true >/dev/null 2>&1 && break
    sleep 1
done
# shellcheck disable=SC2086
$remote true

printf '%s\n' \
    "{\"remotes\":[{\"name\":\"loopback\",\"host\":\"petdex@127.0.0.1\",\"port\":$port,\"identity_file\":\"$identity\",\"agents\":{\"opencode\":{\"enabled\":true},\"codex\":{\"enabled\":true},\"hermes\":{\"enabled\":true,\"home\":\"~/.hermes-ci\"}}}]}" \
    > "$fixture/.petdex/remote-agents.json"

HOME=$fixture PETDEX_PET=$pet_name "$binary" > "$fixture/app.log" 2>&1 &
app_pid=$!

ready=false
for _ in $(seq 1 60); do
    # shellcheck disable=SC2086
    if $remote 'test -s ~/.petdex/runtime/update-token && test -s ~/.petdex/runtime/codex-watch.pid && test -s ~/.petdex/runtime/hermes-watch.pid'; then
        ready=true
        break
    fi
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 1
done
if [ "$ready" != true ]; then
    cat "$fixture/app.log" >&2
    echo "remote feed never became ready" >&2
    exit 1
fi

# shellcheck disable=SC2086
$remote 'grep -q petdex-hook ~/.codex/hooks.json && grep -q petdex-hook ~/.hermes-ci/config.yaml && grep -qx "$HOME/.hermes-ci" ~/.petdex/runtime/hermes-home'
# shellcheck disable=SC2086
$remote 'curl -fsS --max-time 2 http://127.0.0.1:7777/health' | grep -q '"ok":true'
printf '%s\n' '{"tool_name":"Bash","session_id":"docker-ci"}' | \
    $remote '~/.petdex/bin/petdex-hook bubble pre codex'

kill "$app_pid"
wait "$app_pid" 2>/dev/null || true
app_pid=

stopped=false
for _ in $(seq 1 20); do
    # shellcheck disable=SC2086
    if $remote 'test ! -e ~/.petdex/runtime/update-token && test ! -e ~/.petdex/runtime/tunnel-lease && test ! -e ~/.petdex/runtime/codex-watch.pid && test ! -e ~/.petdex/runtime/hermes-watch.pid && ! pgrep -f "petdex-(codex|hermes)-watch" >/dev/null'; then
        stopped=true
        break
    fi
    sleep 1
done
if [ "$stopped" != true ]; then
    cat "$fixture/app.log" >&2
    # shellcheck disable=SC2086
    $remote 'ls -la ~/.petdex/runtime; ps -ef | grep -E "petdex|sshd" | grep -v grep' >&2 || true
    echo "remote transport survived desktop shutdown" >&2
    exit 1
fi

echo "remote Docker transport: passed"
