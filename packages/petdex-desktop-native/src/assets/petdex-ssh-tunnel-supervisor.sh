#!/bin/sh
# Keep an ssh reverse tunnel bounded by the Petdex desktop process even
# when the GUI is terminated by a signal and cannot run effects teardown.
# The shell remains the effect-owned process and runs ssh as its one child.
# This avoids a detached watcher inheriting the effect's output pipes: when
# ssh exits, the shell reaps it and exits with the same status so Petdex can
# enter its normal reconnect backoff.

parent=$1
shift

"$@" </dev/null &
tunnel=$!

while kill -0 "$parent" 2>/dev/null && kill -0 "$tunnel" 2>/dev/null; do
    sleep 1
done

if ! kill -0 "$parent" 2>/dev/null; then
    kill "$tunnel" 2>/dev/null || true
fi

wait "$tunnel"
exit $?
