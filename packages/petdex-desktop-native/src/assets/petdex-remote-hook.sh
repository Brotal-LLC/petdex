#!/bin/sh
# petdex remote hook. Installed at ~/.petdex/bin/petdex-hook on REMOTE
# hosts, where the desktop binary does not exist; the hook configs the
# desktop merges (codex hooks.json, hermes config.yaml) point at this
# exact path, so they work unchanged on both sides of the tunnel.
#
# Contract mirrors hook_runner.zig: argv [phase] [agent], hook JSON on
# stdin, state + bubble POSTs to 127.0.0.1:7777 (the ssh -R tunnel back
# to the desktop), token-gated, and NEVER fails outward — an agent's
# hook chain must not break because a mascot is unreachable.

# Drain stdin first, always: the agent may still be writing after the
# useful prefix, and closing the pipe early propagates EPIPE to it.
payload=$(cat 2>/dev/null)

runtime="$HOME/.petdex/runtime"

# Killswitch, same file the desktop honors.
[ -f "$runtime/hooks-disabled" ] && exit 0

# No curl, no token, no work. Both are expected states (fresh remote,
# tunnel not yet pushed the token), not errors.
command -v curl >/dev/null 2>&1 || exit 0
[ -f "$runtime/update-token" ] || exit 0
token=$(tr -d ' \t\r\n' < "$runtime/update-token")
[ -n "$token" ] || exit 0

# Local and remote installers write the same hook command. The desktop
# executable receives `bubble <phase> <agent>`; accept that exact shape here
# so a remote config works without a remote-specific merge.
[ "${1:-}" = "bubble" ] || exit 0
phase=${2:-}
agent=$(printf '%s' "${3:-}" | tr -cd 'A-Za-z0-9._-')

# Extract a flat string field from the payload without jq: stop at the
# first quote, first match only, whitelist charset so the value can be
# embedded in a JSON body without escaping.
field() {
    printf '%s' "$payload" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 | tr -cd 'A-Za-z0-9._-'
}

# phase -> sprite state, a port of hook_runner.stateForEvent. Missing
# phases deliberately map to nothing: an event we do not understand
# must not move the pet.
state=
busy=false
text=
case "$phase" in
    pre)
        tool=$(field tool_name)
        case $(printf '%s' "$tool" | tr 'A-Z' 'a-z') in
            read|grep|glob) state=review ;;
            *) state=running ;;
        esac
        busy=true
        if [ -n "$tool" ]; then
            text="Calling $tool"
        else
            text="Working…"
        fi
        ;;
    post) state=idle ;;
    tool-failure) state=failed ;;
    stop|session-end)
        state=waving
        text="Done"
        ;;
    user-prompt|session-start)
        state=jumping
        busy=true
        text="On it…"
        ;;
    notification)
        # A generic notification is not evidence that the agent is waiting
        # for the user. Explicit integrations use approval/clarification
        # phases; unknown notifications stay neutral.
        ;;
    waiting) ;;
esac

session_id=$(field session_id)

post() {
    # -m 2: the tunnel adds latency the local 300ms budget never sees,
    # but a wedged tunnel still must not stall the agent.
    curl -sS -m 2 -o /dev/null \
        -X POST \
        -H "x-petdex-update-token: $token" \
        -H "content-type: application/json" \
        --data "$2" \
        "http://127.0.0.1:7777/$1" 2>/dev/null || true
}

if [ -n "$state" ]; then
    # failed carries its dwell so the animation survives a whole cycle,
    # same 1220ms as the desktop runner.
    if [ "$state" = "failed" ]; then
        post state "{\"state\":\"$state\",\"duration\":1220,\"agent_source\":\"$agent\"}"
    else
        post state "{\"state\":\"$state\",\"agent_source\":\"$agent\"}"
    fi
fi

if [ -n "$text" ]; then
    if [ -n "$session_id" ]; then
        post bubble "{\"text\":\"$text\",\"busy\":$busy,\"agent_source\":\"$agent\",\"session_id\":\"$session_id\"}"
    else
        post bubble "{\"text\":\"$text\",\"busy\":$busy,\"agent_source\":\"$agent\"}"
    fi
fi

exit 0
