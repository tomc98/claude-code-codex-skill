#!/usr/bin/env bash
# stub-codex — fake codex CLI for testing codex.sh failure paths.
# Scenario via STUB_SCENARIO; call counter in STUB_STATE; session id via STUB_SID.
# Records each invocation's argv to $STUB_STATE.args.<n> for assertion.
set -u

state="${STUB_STATE:?STUB_STATE required}"
n=$(cat "$state" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$state"
printf '%s\n' "$@" > "$state.args.$n"

sid="${STUB_SID:-019f0000-0000-7000-8000-000000000001}"

# ── app-server emulation (for the transfer bridge) ──────────────────
if [ "${1:-}" = "app-server" ]; then
    case "${STUB_SCENARIO:?}" in
        transfer_ok)
            # Real 0.144.1 behaviour: create the imported thread's ROLLOUT,
            # record the ledger, and return the thread in successes[].target
            while IFS= read -r line; do
                case "$line" in
                    *'"initialized"'*) : ;;
                    *'"initialize"'*)  printf '{"jsonrpc":"2.0","id":1,"result":{}}\n' ;;
                    *'"externalAgentConfig/import"'*)
                        printf '{"jsonrpc":"2.0","id":2,"result":{"importId":"imp-1"}}\n'
                        printf '%s\n' "$line" | python3 -c '
import json, sys, hashlib, os
req = json.load(sys.stdin)
p = req["params"]["migrationItems"][0]["details"]["sessions"][0]["path"]
sha = hashlib.sha256(open(p, "rb").read()).hexdigest()
sid = os.environ.get("STUB_SID")
os.makedirs(os.environ["CODEX_HOME"], exist_ok=True)
lp = os.path.join(os.environ["CODEX_HOME"], "external_agent_session_imports.json")
try:
    led = json.load(open(lp))
except Exception:
    led = {"records": []}
led.setdefault("records", []).append({
    "source_path": os.path.realpath(p),
    "content_sha256": sha,
    "imported_thread_id": sid,
})
json.dump(led, open(lp, "w"))
rd = os.path.join(os.environ["CODEX_SESSIONS_DIR"], "2026", "07", "13")
os.makedirs(rd, exist_ok=True)
with open(os.path.join(rd, "rollout-2026-07-13T00-00-01-%s.jsonl" % sid), "w") as f:
    f.write(json.dumps({"session_id": sid, "cwd": "/tmp"}) + "\n")
'
                        printf '{"jsonrpc":"2.0","method":"externalAgentConfig/import/completed","params":{"importId":"imp-1","itemTypeResults":[{"itemType":"SESSIONS","successes":[{"target":"'"${sid}"'"}],"failures":[]}]}}\n' ;;
                esac
            done
            exit 0 ;;
        transfer_bad_target)
            # Malformed targets (trailing newline, non-UUID) + a non-UUID
            # ledger record — nothing valid anywhere → the bridge must FAIL,
            # never deliver a malformed id as ok
            while IFS= read -r line; do
                case "$line" in
                    *'"initialized"'*) : ;;
                    *'"initialize"'*)  printf '{"jsonrpc":"2.0","id":1,"result":{}}\n' ;;
                    *'"externalAgentConfig/import"'*)
                        printf '{"jsonrpc":"2.0","id":2,"result":{"importId":"imp-b"}}\n'
                        printf '%s\n' "$line" | python3 -c '
import json, sys, hashlib, os
req = json.load(sys.stdin)
p = req["params"]["migrationItems"][0]["details"]["sessions"][0]["path"]
sha = hashlib.sha256(open(p, "rb").read()).hexdigest()
os.makedirs(os.environ["CODEX_HOME"], exist_ok=True)
lp = os.path.join(os.environ["CODEX_HOME"], "external_agent_session_imports.json")
json.dump({"records": [{"source_path": os.path.realpath(p), "content_sha256": sha,
                        "imported_thread_id": "not-a-uuid-at-all"}]}, open(lp, "w"))
'
                        printf '{"jsonrpc":"2.0","method":"externalAgentConfig/import/completed","params":{"importId":"imp-b","itemTypeResults":[{"itemType":"SESSIONS","successes":[{"target":"'"${sid}"'\\n"},{"target":"deadbeef"}],"failures":[]}]}}\n' ;;
                esac
            done
            exit 0 ;;
        transfer_target_wins)
            # Ledger holds a WRONG id; completion target has the right one —
            # the authoritative target must win over any ledger record
            while IFS= read -r line; do
                case "$line" in
                    *'"initialized"'*) : ;;
                    *'"initialize"'*)  printf '{"jsonrpc":"2.0","id":1,"result":{}}\n' ;;
                    *'"externalAgentConfig/import"'*)
                        printf '{"jsonrpc":"2.0","id":2,"result":{"importId":"imp-t"}}\n'
                        printf '%s\n' "$line" | python3 -c '
import json, sys, hashlib, os
req = json.load(sys.stdin)
p = req["params"]["migrationItems"][0]["details"]["sessions"][0]["path"]
sha = hashlib.sha256(open(p, "rb").read()).hexdigest()
lp = os.path.join(os.environ["CODEX_HOME"], "external_agent_session_imports.json")
os.makedirs(os.environ["CODEX_HOME"], exist_ok=True)
json.dump({"records": [{"source_path": os.path.realpath(p), "content_sha256": sha,
                        "imported_thread_id": "019fdead-beef-7000-8000-00000000dead"}]}, open(lp, "w"))
'
                        printf '{"jsonrpc":"2.0","method":"externalAgentConfig/import/completed","params":{"importId":"imp-t","itemTypeResults":[{"itemType":"SESSIONS","successes":[{"target":"'"${sid}"'"}],"failures":[]}]}}\n' ;;
                esac
            done
            exit 0 ;;
        transfer_race)
            # Old-protocol shape (no successes[].target) + the live-transcript
            # race: codex "read" a GROWN file, so the ledger sha differs from
            # what the bridge hashed pre-import → newest-record-for-path path
            while IFS= read -r line; do
                case "$line" in
                    *'"initialized"'*) : ;;
                    *'"initialize"'*)  printf '{"jsonrpc":"2.0","id":1,"result":{}}\n' ;;
                    *'"externalAgentConfig/import"'*)
                        printf '{"jsonrpc":"2.0","id":2,"result":{"importId":"imp-r"}}\n'
                        printf '%s\n' "$line" | python3 -c '
import json, sys, hashlib, os
req = json.load(sys.stdin)
p = req["params"]["migrationItems"][0]["details"]["sessions"][0]["path"]
sha = hashlib.sha256(open(p, "rb").read() + b"grown-after-hash\n").hexdigest()
lp = os.path.join(os.environ["CODEX_HOME"], "external_agent_session_imports.json")
os.makedirs(os.environ["CODEX_HOME"], exist_ok=True)
try:
    led = json.load(open(lp))
except Exception:
    led = {"records": []}
led.setdefault("records", []).append({
    "source_path": os.path.realpath(p),
    "content_sha256": sha,
    "imported_thread_id": os.environ.get("STUB_SID"),
})
json.dump(led, open(lp, "w"))
'
                        printf '{"jsonrpc":"2.0","method":"externalAgentConfig/import/completed","params":{"importId":"imp-r","itemTypeResults":[{"itemType":"SESSIONS"}]}}\n' ;;
                esac
            done
            exit 0 ;;
        transfer_item_failed)
            # Import "completes" but the item failed — nothing lands in the ledger
            while IFS= read -r line; do
                case "$line" in
                    *'"initialized"'*) : ;;
                    *'"initialize"'*)  printf '{"jsonrpc":"2.0","id":1,"result":{}}\n' ;;
                    *'"externalAgentConfig/import"'*)
                        printf '{"jsonrpc":"2.0","id":2,"result":{"importId":"imp-2"}}\n'
                        printf '{"jsonrpc":"2.0","method":"externalAgentConfig/import/completed","params":{"importId":"imp-2","itemTypeResults":[{"itemType":"SESSIONS","successes":[],"failures":[{"itemType":"SESSIONS","failureStage":"session_missing","message":"embedded cwd does not exist"}]}]}}\n' ;;
                esac
            done
            exit 0 ;;
        transfer_unsupported)
            while IFS= read -r line; do
                case "$line" in
                    *'"initialized"'*) : ;;
                    *'"initialize"'*)  printf '{"jsonrpc":"2.0","id":1,"result":{}}\n' ;;
                    *'"externalAgentConfig/import"'*)
                        printf '{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"method not found"}}\n' ;;
                esac
            done
            exit 0 ;;
        transfer_silent)
            # Never answers — the bridge's SIGALRM deadline must fire
            sleep 60
            exit 0 ;;
        *)
            echo "stub: app-server not scripted for scenario $STUB_SCENARIO" >&2
            exit 99 ;;
    esac
fi

out=""
prev=""
is_resume=false
is_review=false
for a in "$@"; do
    [ "$prev" = "-o" ] && out="$a"
    [ "$a" = "resume" ] && is_resume=true
    [ "$a" = "review" ] && is_review=true
    prev="$a"
done

# Enforce the real CLI 0.144.1 flag surface: resume/review have no --color/-C/-s;
# plain exec must carry --color (the never-colorize invariant).
if $is_resume || $is_review; then
    for a in "$@"; do
        case "$a" in
            --color|-C|-s) echo "stub: flag $a unsupported for resume/review" >&2; exit 64 ;;
        esac
    done
else
    case " $* " in
        *" --color "*) : ;;
        *) echo "stub: plain exec missing --color" >&2; exit 64 ;;
    esac
fi

emit_header() { # $1 = session id to report
    printf 'OpenAI Codex v0.144.1-stub\n' >&2
    printf '\033[1msession id:\033[0m %s\n' "$1" >&2
}

case "${STUB_SCENARIO:?STUB_SCENARIO required}" in
    ok)
        emit_header "$sid"
        echo "FINAL ANSWER" > "$out"
        ;;
    ok_review)
        emit_header "$sid"
        echo "REVIEW FINDINGS: none"   # review prints to stdout, no -o
        ;;
    slow_ok)
        emit_header "$sid"
        echo "working on step 1" >&2
        sleep 5
        echo "SLOW FINAL" > "$out"
        ;;
    slow_stubborn)
        # Ignores TERM — the wrapper's signal path must escalate to KILL
        trap '' TERM
        emit_header "$sid"
        sleep 60
        echo "NEVER" > "$out"
        ;;
    capacity_then_resume_ok)
        emit_header "$sid"
        if [ "$n" -ge 2 ] && $is_resume; then
            echo "RECOVERED FINAL" > "$out"
        else
            printf 'ERROR: Selected model is at capacity. Please try a different model.\n' >&2
        fi
        ;;
    capacity_always)
        emit_header "$sid"
        printf 'ERROR: Selected model is at capacity. Please try a different model.\n' >&2
        ;;
    recover_wrong_then_ok)
        # call 1: capacity; call 2 (resume): wrong session + output; call 3 (resume): right session + output
        if [ "$n" -eq 1 ]; then
            emit_header "$sid"
            printf 'ERROR: Selected model is at capacity. Please try a different model.\n' >&2
        elif [ "$n" -eq 2 ]; then
            emit_header "019fdead-beef-7000-8000-00000000dead"
            echo "WRONG SESSION ANSWER" > "$out"
        else
            emit_header "$sid"
            echo "RECOVERED FINAL" > "$out"
        fi
        ;;
    review_capacity_then_resume_ok)
        emit_header "$sid"
        if $is_resume; then
            echo "RECOVERED REVIEW" > "$out"
        else
            printf 'ERROR: Selected model is at capacity. Please try a different model.\n' >&2
        fi
        ;;
    empty_unknown)
        emit_header "$sid"
        echo "something exploded unrecognizably" >&2
        ;;
    partial_then_die)
        emit_header "$sid"
        echo "PARTIAL ANSWER" > "$out"
        echo "boom: internal fatal error" >&2
        exit 5
        ;;
    cli_reject)
        printf "error: invalid value 'wat' for '--sandbox <SANDBOX_MODE>'\n" >&2
        exit 2
        ;;
    cli_conflict)
        printf "error: the argument '--base <BRANCH>' cannot be used with '--commit <SHA>'\n" >&2
        exit 2
        ;;
    wrong_session)
        emit_header "019fdead-beef-7000-8000-00000000dead"
        echo "FRESH SESSION ANSWER" > "$out"
        ;;
    no_header)
        echo "no session line at all" >&2
        echo "UNVERIFIABLE ANSWER" > "$out"
        ;;
    blank_ok)
        emit_header "$sid"
        printf '\n   \n' > "$out"   # whitespace-only "final message"
        ;;
    *)
        echo "stub: unknown scenario" >&2
        exit 99
        ;;
esac
exit 0
