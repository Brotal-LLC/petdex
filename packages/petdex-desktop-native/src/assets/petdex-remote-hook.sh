#!/bin/sh
# petdex remote hook. Installed at ~/.petdex/bin/petdex-hook on REMOTE
# hosts, where the desktop binary does not exist; the hook configs the
# desktop merges (codex hooks.json, hermes config.yaml) point at this
# exact path, so they work unchanged on both sides of the tunnel.
#
# Contract mirrors the desktop petdex-hook CLI: argv `bubble [phase]
# [agent]`, hook JSON on stdin, state + bubble POSTs to 127.0.0.1:7777
# (the ssh -R tunnel back to the desktop), token-gated, and NEVER fails
# outward — an agent's hook chain must not break because a mascot is
# unreachable.

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

# Hook configs are shared by local and remote agents, so this script
# accepts the same leading `bubble` operation as the desktop binary.
# Unknown operations are harmless no-ops, matching the hook's general
# never-fail-outward contract.
[ "${1:-}" = "bubble" ] || exit 0
phase=${2:-}
agent=$(printf '%s' "${3:-}" | tr -cd 'A-Za-z0-9._-')

# Extract an identifier from the payload without jq. Identifiers are
# deliberately restricted because they are interpolated into JSON below.
id_field() {
    printf '%s' "$payload" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 | tr -cd 'A-Za-z0-9._-'
}

# Extract user-facing text from either the top-level payload or nested
# tool_input. Python is present on supported Codex hosts and gives us real
# JSON decoding; the sed fallback keeps the hook useful on minimal boxes.
# Quotes, backslashes and control characters are removed so the result is
# safe to interpolate into the compact JSON request bodies below.
text_field() {
    key=$1
    limit=${2:-96}
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$payload" | python3 -c '
import json, sys

def find(value, key):
    if isinstance(value, dict):
        found = value.get(key)
        if isinstance(found, str):
            return found
        for child in value.values():
            found = find(child, key)
            if found:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find(child, key)
            if found:
                return found
    return ""

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
value = " ".join(find(data, sys.argv[1]).split())
value = value.replace("\\", " ").replace("\"", " ")
sys.stdout.write(value[:int(sys.argv[2])])
' "$key" "$limit" 2>/dev/null
        return
    fi
    printf '%s' "$payload" \
        | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n 1 \
        | tr '\r\n\t\\"' '      ' \
        | tr -cd '[:alnum:][:space:].,;:!?@#%_+=/()-' \
        | cut -c "1-$limit"
}

session_id=$(id_field session_id)
[ -n "$session_id" ] || session_id=$(id_field sessionId)
[ -n "$session_id" ] || session_id=$(id_field sessionID)
[ -n "$session_id" ] || session_id=$(id_field thread_id)
[ -n "$session_id" ] || session_id=$(id_field conversation_id)
# Hermes emits subagent lifecycle hooks on the parent stream and stores the
# worker id in child_session_id. Keep the parent as a canonical fallback, but
# make the child the raw session so its summary nests instead of overwriting
# the parent card.
parent_session_hint=$(id_field parent_session_id)
[ -n "$parent_session_hint" ] || parent_session_hint=$session_id
child_session_id=$(id_field child_session_id)
subagent_lifecycle=false
case "$phase" in
    subagent-start|subagent-stop)
        if [ -n "$child_session_id" ] && [ "$child_session_id" != "$parent_session_hint" ]; then
            session_id=$child_session_id
            subagent_lifecycle=true
        fi
        ;;
esac
child_role=$(text_field child_role 48)
sessions="$runtime/sessions"

# Read the title owned by each agent's server/session store. This runs on every
# event so delayed auto-titles and manual renames replace the prompt fallback
# without waiting for a reinstall or a new conversation.
provider_context() {
    command -v python3 >/dev/null 2>&1 || return
    python3 -c '
import json, os, sqlite3, sys
from pathlib import Path

agent, sid, force_parent, force_subagent, explicit_label = sys.argv[1:6]
title = ""
conversation = sid
parent = ""
# Hermes child hooks can beat state.db persistence. Unknown Hermes context is
# suppressed until a later event proves it is primary; this intentionally
# favors one missed startup update over a standalone subagent ghost card.
kind = "subagent" if agent == "hermes" else "primary"
label = ""
subagent_sources = {
    "subagent", "sub_agent", "child", "worker", "delegate", "delegated",
    "delegation", "background", "tool",
}
def delegate_parent(row):
    raw = row.get("model_config", "")
    try:
        config = json.loads(raw) if raw else {}
    except (TypeError, ValueError):
        config = {}
    return str(config.get("_delegate_from") or "") if isinstance(config, dict) else ""
def is_subagent(row):
    source = str(row.get("source", "") or "").strip().lower().replace("-", "_")
    if source in subagent_sources or bool(delegate_parent(row)):
        return True
    return bool(row.get("parent_session_id")) and not bool(row.get("session_key"))
try:
    if agent == "codex":
        path = Path.home() / ".codex" / "session_index.jsonl"
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
        for line in reversed(lines[-2000:]):
            row = json.loads(line)
            if str(row.get("id") or "") == sid:
                title = str(row.get("thread_name") or "")
                break
    elif agent == "hermes":
        root = Path(os.environ.get("HERMES_HOME") or (Path.home() / ".hermes"))
        db_path = root / "state.db"
        with sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=0.05) as db:
            columns = {str(row[1]) for row in db.execute("PRAGMA table_info(sessions)").fetchall()}
            wanted = [name for name in ("id", "title", "display_name", "source", "model_config", "parent_session_id", "session_key") if name in columns]
            def load(identifier):
                if "id" not in wanted:
                    return None
                row = db.execute(f"SELECT {chr(44).join(wanted)} FROM sessions WHERE id = ? LIMIT 1", (identifier,)).fetchone()
                return dict(zip(wanted, [str(value or "") for value in row])) if row else None
            first = load(sid)
            if first:
                chain = [first]
                current = first
                seen = {sid}
                for _ in range(16):
                    next_id = current.get("parent_session_id", "")
                    if not next_id or next_id in seen:
                        break
                    seen.add(next_id)
                    current = load(next_id)
                    if not current:
                        break
                    chain.append(current)
                root_row = chain[-1]
                conversation = next((row.get("session_key", "") for row in reversed(chain) if row.get("session_key")), root_row.get("id", sid))
                title = next((row.get("title", "") for row in reversed(chain) if row.get("title")), "")
                parent = first.get("parent_session_id", "") or delegate_parent(first) or force_parent
                kind = "subagent" if force_subagent == "true" or is_subagent(first) else "primary"
                label = explicit_label or first.get("display_name", "") or (first.get("title", "") if kind == "subagent" else "")
            elif force_subagent == "true" and force_parent and force_parent != sid:
                parent_row = load(force_parent)
                if parent_row:
                    chain = [parent_row]
                    current = parent_row
                    seen = {force_parent}
                    for _ in range(16):
                        next_id = current.get("parent_session_id", "")
                        if not next_id or next_id in seen:
                            break
                        seen.add(next_id)
                        current = load(next_id)
                        if not current:
                            break
                        chain.append(current)
                    root_row = chain[-1]
                    conversation = next((row.get("session_key", "") for row in reversed(chain) if row.get("session_key")), root_row.get("id", force_parent))
                    title = next((row.get("title", "") for row in reversed(chain) if row.get("title")), "")
                else:
                    conversation = force_parent
                parent = force_parent
                kind = "subagent"
                label = explicit_label
except Exception:
    pass
def clean(value, limit):
    return " ".join(str(value or "").split()).replace("\\", " ").replace(chr(34), " ")[:limit]
for value, limit in ((title, 256), (conversation, 96), (parent, 96), (kind, 16), (label, 48)):
    print(clean(value, limit))
' "$agent" "$session_id" "$parent_session_hint" "$subagent_lifecycle" "$child_role" 2>/dev/null
}

# The first prompt is a cross-agent fallback for harnesses without a generated
# title API. It is written only once; an authoritative provider title below
# always wins and is refreshed on every lifecycle update.
if [ "$phase" = "user-prompt" ] && [ -n "$session_id" ]; then
    prompt_title=$(text_field prompt 60)
    [ -n "$prompt_title" ] || prompt_title=$(text_field user_message 60)
    [ -n "$prompt_title" ] || prompt_title=$(text_field userPrompt 60)
    if [ -n "$prompt_title" ]; then
        umask 077
        mkdir -p "$sessions" 2>/dev/null || true
        title_file="$sessions/$session_id.title"
        if [ ! -s "$title_file" ]; then
            title_tmp="$title_file.tmp.$$"
            if printf '%s' "$prompt_title" > "$title_tmp" 2>/dev/null; then
                mv -f "$title_tmp" "$title_file" 2>/dev/null || true
            fi
        fi
    fi
fi

context=$(provider_context)
provider_title=$(printf '%s\n' "$context" | sed -n '1p')
conversation_key=$(printf '%s\n' "$context" | sed -n '2p')
parent_session_id=$(printf '%s\n' "$context" | sed -n '3p')
session_kind=$(printf '%s\n' "$context" | sed -n '4p')
subagent_label=$(printf '%s\n' "$context" | sed -n '5p')
[ -n "$conversation_key" ] || conversation_key=$session_id
[ -n "$session_kind" ] || session_kind=primary
if [ "$subagent_lifecycle" = true ]; then
    # A just-spawned worker can race state.db creation. Its known parent still
    # gives us the correct aggregate identity until the durable marker lands.
    [ -n "$parent_session_id" ] || parent_session_id=$parent_session_hint
    [ "$conversation_key" = "$session_id" ] && [ -n "$parent_session_hint" ] && conversation_key=$parent_session_hint
    session_kind=subagent
    [ -n "$subagent_label" ] || subagent_label=$child_role
fi

# This PR targets the base card model, which has no nested child hierarchy.
# Suppress every confidently classified Hermes worker at the source instead
# of opening standalone cards for delegated tool progress.
if [ "$agent" = "hermes" ] && [ "$session_kind" = "subagent" ]; then
    exit 0
fi

title=$(text_field petdex_session_title 256)
[ -n "$title" ] || title=$provider_title
title_source=server
if [ -z "$title" ] && [ -n "$session_id" ] && [ -f "$sessions/$session_id.title" ]; then
    title=$(head -c 240 "$sessions/$session_id.title" 2>/dev/null | tr -d '\r\n\\"')
    title_source=prompt
fi

# phase -> sprite state, a port of hook_runner.stateForEvent. Missing
# phases deliberately map to nothing: an event we do not understand
# must not move the pet.
state=
busy=false
text=
session_status=idle
message_kind=status
post_bubble=true
notification_kind=$(id_field notification_type)
[ -n "$notification_kind" ] || notification_kind=$(id_field notification_kind)
case "$phase" in
    pre|post)
        tool=$(id_field tool_name)
        lower_tool=$(printf '%s' "$tool" | tr 'A-Z' 'a-z')
        session_status=running
        message_kind=tool
        if [ "$lower_tool" = "clarify" ]; then
            if [ "$phase" = "pre" ]; then
                state=waiting
                session_status=needs_input
                message_kind=prompt
                text=$(text_field question 960)
                [ -n "$text" ] || text=$(text_field prompt 960)
                [ -n "$text" ] || text="Waiting for you…"
            else
                state=running
                text="Continuing…"
            fi
        else
            if [ "$phase" = "post" ]; then
                state=running
            else
                case "$lower_tool" in
                    read|read_file|grep|glob) state=review ;;
                    *) state=running ;;
                esac
            fi
            busy=true
            before=true
            [ "$phase" = "post" ] && before=false
            case "$lower_tool" in
                bash|shell|exec|exec_command)
                    description=$(text_field description 72)
                    command=$(text_field command 72)
                    command_name=$(printf '%s' "$command" | awk '{print $1}')
                    if [ -n "$description" ]; then
                        text=$description
                    elif [ -n "$command_name" ]; then
                        if $before; then text="Running $command_name"; else text="Ran $command_name"; fi
                    elif $before; then text="Running command"; else text="Ran command"; fi
                    ;;
                read|read_file)
                    path=$(text_field file_path 160)
                    [ -n "$path" ] || path=$(text_field path 160)
                    name=${path##*/}
                    if [ -n "$name" ]; then
                        if $before; then text="Reading $name"; else text="Read $name"; fi
                    elif $before; then text="Reading file"; else text="Read file"; fi
                    ;;
                grep|search|search_query|rg)
                    pattern=$(text_field pattern 48)
                    [ -n "$pattern" ] || pattern=$(text_field query 48)
                    if [ -n "$pattern" ]; then
                        if $before; then text="Searching $pattern"; else text="Searched $pattern"; fi
                    elif $before; then text="Searching code"; else text="Searched code"; fi
                    ;;
                glob|find)
                    if $before; then text="Finding files"; else text="Found files"; fi
                    ;;
                apply_patch|edit|edit_file|write|write_file)
                    if $before; then text="Editing files"; else text="Edited files"; fi
                    ;;
                *)
                    if [ -n "$tool" ]; then
                        if $before; then text="Calling $tool"; else text="Called $tool"; fi
                    elif $before; then text="Working…"; else text="Updated"; fi
                    ;;
            esac
        fi
        [ "$agent" = "codex" ] && post_bubble=false
        ;;
    tool-failure)
        state=failed
        session_status=failed
        message_kind=tool
        text="Tool failed"
        [ "$agent" = "codex" ] && post_bubble=false
        ;;
    stop|session-end)
        state=waving
        session_status=completed
        message_kind=lifecycle
        text=$(text_field last_assistant_message 960)
        [ -n "$text" ] || text="Done."
        ;;
    user-prompt)
        state=jumping
        busy=true
        session_status=running
        message_kind=prompt
        text="Thinking…"
        ;;
    session-start)
        state=jumping
        busy=true
        session_status=running
        message_kind=lifecycle
        text="Starting session…"
        ;;
    assistant)
        state=waving
        session_status=completed
        message_kind=assistant
        text=$(text_field assistant_response 960)
        [ -n "$text" ] || text=$(text_field last_assistant_message 960)
        [ -n "$text" ] || text=$(text_field message 960)
        [ -n "$text" ] || text="Done."
        ;;
    approval-request)
        state=waiting
        session_status=needs_input
        message_kind=prompt
        text=$(text_field question 960)
        [ -n "$text" ] || text=$(text_field prompt 960)
        [ -n "$text" ] || text=$(text_field message 960)
        [ -n "$text" ] || text="Waiting for you…"
        ;;
    notification)
        case "$notification_kind" in
            permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input)
                state=waiting
                session_status=needs_input
                message_kind=prompt
                text=$(text_field question 960)
                [ -n "$text" ] || text=$(text_field prompt 960)
                [ -n "$text" ] || text=$(text_field message 960)
                [ -n "$text" ] || text="Waiting for you…"
                ;;
            idle_prompt|agent_completed)
                state=waving
                session_status=completed
                message_kind=lifecycle
                text=$(text_field message 960)
                [ -n "$text" ] || text="Done."
                ;;
            *)
                # Authentication and unknown notifications are informational,
                # not correlated input requests.
                post_bubble=false
                ;;
        esac
        ;;
    waiting)
        # Legacy mascot phase only; no explicit request means no orange card.
        post_bubble=false
        ;;
    approval-response)
        state=running
        busy=true
        session_status=running
        message_kind=status
        text="Continuing…"
        ;;
    subagent-start|subagent-stop)
        state=running
        busy=true
        session_status=running
        message_kind=lifecycle
        # A spawn is only lifecycle noise. At stop Hermes provides a concise
        # child_summary; promote that one value to assistant prose so it folds
        # beneath the parent card instead of becoming another top-level bubble.
        if [ "$phase" = "subagent-stop" ]; then
            text=$(text_field child_summary 960)
            [ -n "$text" ] && message_kind=assistant
        fi
        ;;
esac

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

if [ -n "$text" ] && $post_bubble; then
    metadata=',"remote":true'
    [ -n "$session_id" ] && metadata="$metadata,\"session_id\":\"$session_id\""
    [ -n "$session_id" ] && metadata="$metadata,\"source_session_id\":\"$session_id\""
    [ -n "$conversation_key" ] && metadata="$metadata,\"conversation_key\":\"$conversation_key\""
    [ -n "$parent_session_id" ] && metadata="$metadata,\"parent_session_id\":\"$parent_session_id\""
    metadata="$metadata,\"session_kind\":\"$session_kind\""
    [ -n "$subagent_label" ] && metadata="$metadata,\"subagent_label\":\"$subagent_label\""
    [ -n "$title" ] && metadata="$metadata,\"title\":\"$title\""
    metadata="$metadata,\"title_source\":\"$title_source\",\"feed_source\":\"hook\",\"event_kind\":\"$phase\",\"message_kind\":\"$message_kind\",\"status\":\"$session_status\""
    [ -n "$notification_kind" ] && metadata="$metadata,\"notification_kind\":\"$notification_kind\""
    source_cwd=$(text_field cwd 240)
    [ -n "$source_cwd" ] && metadata="$metadata,\"source_cwd\":\"$source_cwd\""
    hostname=$(hostname 2>/dev/null | head -n 1 | tr -cd 'A-Za-z0-9._-')
    [ -n "$hostname" ] && metadata="$metadata,\"hostname\":\"$hostname\""
    turn_id=$(id_field turn_id)
    [ -n "$turn_id" ] && metadata="$metadata,\"turn_id\":\"$turn_id\""
    message_id=$(id_field message_id)
    [ -n "$message_id" ] || message_id=$(id_field event_id)
    [ -n "$message_id" ] || message_id=$(id_field call_id)
    [ -n "$message_id" ] && metadata="$metadata,\"message_id\":\"$message_id\""
    correlation_id=$(id_field request_id)
    [ -n "$correlation_id" ] || correlation_id=$(id_field tool_use_id)
    [ -n "$correlation_id" ] || correlation_id=$message_id
    if [ "$session_status" = "needs_input" ] && [ -n "$correlation_id" ]; then
        metadata="$metadata,\"request_id\":\"$correlation_id\""
    elif { [ "$phase" = "approval-response" ] || { [ "$phase" = "post" ] && [ "${lower_tool:-}" = "clarify" ]; }; } && [ -n "$correlation_id" ]; then
        metadata="$metadata,\"resolves_request_id\":\"$correlation_id\""
    fi
    [ "$agent" = "codex" ] && metadata="$metadata,\"source_app\":\"codex\""
    post bubble "{\"text\":\"$text\",\"busy\":$busy,\"agent_source\":\"$agent\"$metadata}"
fi

exit 0
