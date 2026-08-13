#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' 0 1 2 15
mkdir -p "$fixture/home/.petdex/runtime" "$fixture/bin"
printf 'test-token\n' > "$fixture/home/.petdex/runtime/update-token"

cat > "$fixture/bin/curl" <<'MOCK'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--data" ]; then
        shift
        printf '%s\n' "$1" >> "$PETDEX_CAPTURE"
    fi
    shift
done
exit 0
MOCK
chmod +x "$fixture/bin/curl"

payload='{"session_id":"raw-turn","session_key":"gateway/session key","petdex_session_title":"Canonical title","last_assistant_message":"Remote answer"}'
printf '%s' "$payload" | HOME="$fixture/home" PATH="$fixture/bin:/usr/bin:/bin" \
    PETDEX_CAPTURE="$fixture/capture" sh "$root/src/assets/petdex-remote-hook.sh" bubble assistant hermes

grep -Eq '"session_id":"[0-9a-f]{64}"' "$fixture/capture"
grep -q '"source_session_id":"raw-turn"' "$fixture/capture"
grep -q '"session_kind":"primary"' "$fixture/capture"

# The transport-published Hermes home must drive hook-side canonical lookup
# even when the hook process itself does not inherit HERMES_HOME.
mkdir -p "$fixture/custom-hermes/profiles/snoop"
printf 'snoop\n' > "$fixture/custom-hermes/active_profile"
printf '%s\n' "$fixture/custom-hermes" > "$fixture/home/.petdex/runtime/hermes-home"
python3 - "$fixture/custom-hermes/profiles/snoop/state.db" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as database:
    database.execute(
        "CREATE TABLE sessions (id TEXT, title TEXT, display_name TEXT, source TEXT, model_config TEXT, parent_session_id TEXT, session_key TEXT)"
    )
    database.execute(
        "INSERT INTO sessions VALUES (?,?,?,?,?,?,?)",
        ("custom-raw", "Custom server title", "", "primary", "{}", "", "custom-key"),
    )
PY
payload='{"session_id":"custom-raw","last_assistant_message":"Custom answer"}'
printf '%s' "$payload" | HOME="$fixture/home" PATH="$fixture/bin:/usr/bin:/bin" \
    PETDEX_CAPTURE="$fixture/capture" sh "$root/src/assets/petdex-remote-hook.sh" bubble assistant hermes
tail -n 1 "$fixture/capture" | grep -q '"session_id":"custom-key"'
tail -n 1 "$fixture/capture" | grep -q '"title":"Custom server title"'

# Explicit worker metadata must be suppressed even without state.db, while the
# primary fixture above proves missing provider state no longer suppresses all
# Hermes sessions.
before=$(wc -l < "$fixture/capture")
payload='{"session_id":"child","petdex_conversation_key":"parent","petdex_session_kind":"subagent","last_assistant_message":"noise"}'
printf '%s' "$payload" | HOME="$fixture/home" PATH="$fixture/bin:/usr/bin:/bin" \
    PETDEX_CAPTURE="$fixture/capture" sh "$root/src/assets/petdex-remote-hook.sh" bubble assistant hermes
after=$(wc -l < "$fixture/capture")
test "$before" -eq "$after"
