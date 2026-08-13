#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
keeper=
supervisor=
cleanup() {
    [ -z "$supervisor" ] || kill "$supervisor" 2>/dev/null || true
    [ -z "$keeper" ] || kill "$keeper" 2>/dev/null || true
    rm -rf "$fixture"
}
trap cleanup 0 1 2 15

# Create an intentionally unreaped child. kill -0 reports this zombie as
# alive, so the supervisor must inspect process state rather than waiting for
# the keeper to reap it.
python3 - "$fixture/parent.pid" <<'PY' &
import os
import sys
import time

child = os.fork()
if child == 0:
    os._exit(0)
with open(sys.argv[1], "w", encoding="ascii") as handle:
    handle.write(str(child))
time.sleep(15)
PY
keeper=$!

for _ in 1 2 3 4 5; do
    [ -s "$fixture/parent.pid" ] && break
    sleep 1
done
test -s "$fixture/parent.pid"
zombie=$(cat "$fixture/parent.pid")

sh "$root/src/assets/petdex-ssh-tunnel-supervisor.sh" "$zombie" sleep 30 >/dev/null 2>&1 &
supervisor=$!
for _ in 1 2 3 4 5; do
    kill -0 "$supervisor" 2>/dev/null || break
    sleep 1
done
if kill -0 "$supervisor" 2>/dev/null; then
    echo "supervisor did not stop for an unreaped parent" >&2
    exit 1
fi
wait "$supervisor" 2>/dev/null || true
supervisor=
