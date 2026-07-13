#!/usr/bin/env bash
# Test matrix for codex.sh against stub-codex. PASS/FAIL per scenario.
set -u

WRAP="$(cd "$(dirname "$0")/../scripts" && pwd)/codex.sh"
STUB="$(cd "$(dirname "$0")" && pwd)/stub-codex.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-test.XXXXXX")" || { echo "FATAL: mktemp -d failed"; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FATAL: bad TMP"; exit 1; }
TMP="$(cd "$TMP" && pwd)"   # normalize (macOS TMPDIR ends in '/', yielding '//' paths)
SID="019f0000-0000-7000-8000-000000000001"
PASS=0; FAIL=0
LAST_OUT=""; LAST_STATE=""

run_case() { # name scenario expected_exit expected_status [ENV=val...] -- wrapper args...
    local name="$1" scenario="$2" want_exit="$3" want_status="$4"; shift 4
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    local state="$TMP/state-$name"; echo 0 > "$state"
    local outfile="$TMP/out-$name"
    # stdout and stderr are captured SEPARATELY: the result contract lives on
    # stdout — a regression that moves envelope lines to stderr must fail
    env CODEX_BIN="$STUB" STUB_STATE="$state" STUB_SCENARIO="$scenario" STUB_SID="$SID" \
        CODEX_RECOVER_BACKOFF=1 CODEX_RECOVER_ATTEMPTS=2 CODEX_HEARTBEAT_SECS=2 \
        CODEX_SESSIONS_DIR="$TMP/sessions-$name" \
        ${envs[@]+"${envs[@]}"} "$WRAP" "$@" > "$outfile" 2> "$outfile.err"
    local got_exit=$?
    local got_status
    got_status=$(grep -m1 '^CODEX_STATUS:' "$outfile" | awk '{print $2}')
    if [ "$got_exit" = "$want_exit" ] && [ "$got_status" = "$want_status" ]; then
        echo "PASS  $name (exit=$got_exit status=$got_status)"
        PASS=$((PASS+1))
    else
        echo "FAIL  $name — want exit=$want_exit status=$want_status, got exit=$got_exit status=${got_status:-none}"
        sed 's/^/      | /' "$outfile" | head -20
        FAIL=$((FAIL+1))
    fi
    check_envelope "$name" "$outfile"
    LAST_OUT="$outfile"
    LAST_STATE="$state"
}

expect() { # description condition-command...
    local desc="$1"; shift
    if "$@"; then PASS=$((PASS+1)); else echo "FAIL  $desc"; FAIL=$((FAIL+1)); fi
}

check_envelope() { # $1=name $2=outfile — full contract invariants for every result
    local name="$1" outfile="$2"
    if ! head -1 "$outfile" | grep -q '^CODEX_START:'; then
        echo "FAIL  $name-contract: first line is not CODEX_START"; FAIL=$((FAIL+1)); return
    fi
    local field
    for field in CODEX_START CODEX_EXIT CODEX_STATUS SESSION; do
        if [ "$(grep -c "^$field:" "$outfile")" != "1" ]; then
            echo "FAIL  $name-contract: expected exactly one $field: line"; FAIL=$((FAIL+1)); return
        fi
    done
    local l_start l_exit l_status l_session l_delim
    l_start=$(grep -n '^CODEX_START:' "$outfile" | head -1 | cut -d: -f1)
    l_exit=$(grep -n '^CODEX_EXIT:' "$outfile" | head -1 | cut -d: -f1)
    l_status=$(grep -n '^CODEX_STATUS:' "$outfile" | head -1 | cut -d: -f1)
    l_session=$(grep -n '^SESSION:' "$outfile" | head -1 | cut -d: -f1)
    l_delim=$(grep -n '^---$' "$outfile" | head -1 | cut -d: -f1)
    if [ -z "$l_delim" ]; then
        echo "FAIL  $name-contract: no --- delimiter"; FAIL=$((FAIL+1)); return
    fi
    if ! { [ "$l_start" -lt "$l_exit" ] && [ "$l_exit" -lt "$l_status" ] && [ "$l_status" -lt "$l_session" ] && [ "$l_session" -lt "$l_delim" ]; }; then
        echo "FAIL  $name-contract: block out of order (START=$l_start EXIT=$l_exit STATUS=$l_status SESSION=$l_session ---=$l_delim)"; FAIL=$((FAIL+1)); return
    fi
    PASS=$((PASS+1))
}

arg_after() { # $1=flag $2=argsfile — print the arg following $1
    awk -v f="$1" 'prev==f{print; exit} {prev=$0}' "$2"
}

mk_rollout() { # name — create rollout file for $SID in that case's sessions dir
    mkdir -p "$TMP/sessions-$1/2026/07/13"
    : > "$TMP/sessions-$1/2026/07/13/rollout-2026-07-13T00-00-00-$SID.jsonl"
}

# 1. happy path — ANSI header, clean UUID, message after delimiter
run_case happy ok 0 ok -- think "test prompt" --effort low
expect "happy: clean SESSION line"  grep -q "^SESSION: $SID\$" "$LAST_OUT"
expect "happy: final message"       grep -q "^FINAL ANSWER\$" "$LAST_OUT"
expect "happy: exact CODEX_EXIT"    grep -q "^CODEX_EXIT: 0\$" "$LAST_OUT"
expect "happy: think ran read-only" test "$(arg_after -s "$LAST_STATE.args.1")" = "read-only"

# 2. capacity on first call → recovered by resuming the same session,
#    carrying the exact model/effort/schema of the original run
mk_rollout recover
echo '{}' > "$TMP/schema.json"
run_case recover capacity_then_resume_ok 0 ok_recovered -- think "test prompt" --model gpt-5.6-luna --schema "$TMP/schema.json"
expect "recover: recovered content"        grep -q "RECOVERED FINAL" "$LAST_OUT"
expect "recover: resume carried exact -m"     test "$(arg_after -m "$LAST_STATE.args.2")" = "gpt-5.6-luna"
expect "recover: resume carried exact effort" test "$(arg_after -c "$LAST_STATE.args.2")" = 'model_reasoning_effort="xhigh"'
expect "recover: resume carried exact schema" test "$(arg_after --output-schema "$LAST_STATE.args.2")" = "$TMP/schema.json"
expect "recover: resume targeted our sid"     grep -qx -- "$SID" "$LAST_STATE.args.2"
expect "recover: resume carried the SANDBOX"  grep -qx -- 'sandbox_mode="read-only"' "$LAST_STATE.args.2"

# 3. capacity forever WITH resumable session → N resume attempts (ALL resumes), exit 3
mk_rollout exhaust
run_case exhaust capacity_always 3 capacity_exhausted -- think "test prompt"
expect "exhaust: made 3 calls (primary+2 resumes)" test "$(cat "$LAST_STATE")" = "3"
expect "exhaust: attempt 1 was a resume" grep -qx resume "$LAST_STATE.args.2"
expect "exhaust: attempt 2 was a resume" grep -qx resume "$LAST_STATE.args.3"

# 4. capacity with NO resumable session → immediate honest exit 3, no re-run
run_case nosession capacity_always 3 capacity_exhausted -- think "test prompt"
expect "nosession: exactly 1 call (no silent re-run)" test "$(cat "$LAST_STATE")" = "1"
expect "nosession: says why" grep -q "no resumable session" "$LAST_OUT"

# 5. recovery identity mismatch burns the attempt and RETRIES (doesn't exit early)
mk_rollout wrongretry
run_case wrongretry recover_wrong_then_ok 0 ok_recovered -- think "test prompt"
expect "wrongretry: 3 calls (capacity, wrong-session, recovered)" test "$(cat "$LAST_STATE")" = "3"
expect "wrongretry: wrong-session answer never delivered" bash -c '! sed -n "/^---\$/,\$p" '"$LAST_OUT"' | grep -q "WRONG SESSION ANSWER"'
expect "wrongretry: recovered content delivered" grep -q "^RECOVERED FINAL\$" "$LAST_OUT"

# 6. empty output, unrecognised stderr → no_output, diagnostics above block, empty message below
run_case unknown empty_unknown 1 no_output -- run "test prompt"
expect "unknown: stderr tail present" grep -q "something exploded" "$LAST_OUT"
expect "unknown: nothing after delimiter" test -z "$(sed -n '/^---$/,$p' "$LAST_OUT" | sed '1d')"

# 7. codex exits non-zero despite writing output → NOT reported ok
run_case partial partial_then_die 1 no_output -- run "test prompt"
expect "partial: partial output not delivered as ok" bash -c '! sed -n "/^---$/,\$p" '"$LAST_OUT"' | grep -q "PARTIAL ANSWER"'
expect "partial: exact CODEX_EXIT surfaced" grep -q "^CODEX_EXIT: 5\$" "$LAST_OUT"

# 8. codex rejects the invocation (bad flag value / conflicting args) → usage_error
run_case clireject cli_reject 2 usage_error -- think "test prompt" --sandbox wat
run_case cliconflict cli_conflict 2 usage_error -- review --uncommitted "x"

# 9. resume with junk session id → usage_error, codex never invoked
run_case badid ok 2 usage_error -- resume --session "not-a-uuid" "hi"
expect "badid: stub not called" test "$(cat "$LAST_STATE")" = "0"
expect "badid: SESSION sentinel is unknown" grep -q "^SESSION: unknown\$" "$LAST_OUT"

# 10. resume with valid UUID but no rollout → session_not_found, codex never invoked
run_case norollout ok 4 session_not_found -- resume --session "$SID" "hi"
expect "norollout: stub not called" test "$(cat "$LAST_STATE")" = "0"
expect "norollout: SESSION echoes the requested id" grep -q "^SESSION: $SID\$" "$LAST_OUT"

# 11. resume delivers a different session than requested → wrong_session, output refused
mk_rollout wrongsess
run_case wrongsess wrong_session 4 wrong_session -- resume --session "$SID" "hi"
expect "wrongsess: fresh-session answer NOT delivered" bash -c '! grep -q "FRESH SESSION ANSWER" '"$LAST_OUT"

# 12. resume --session with NO session header → fails closed
mk_rollout noheader
run_case noheader no_header 4 wrong_session -- resume --session "$SID" "hi"
expect "noheader: unverifiable answer NOT delivered" bash -c '! grep -q "UNVERIFIABLE ANSWER" '"$LAST_OUT"

# 13. resume --last: wrapper resolves it to the newest rollout's SID, then fails closed
mk_rollout lastnoheader
run_case lastnoheader no_header 4 wrong_session -- resume --last "hi"
expect "lastnoheader: unverifiable answer NOT delivered" bash -c '! grep -q "UNVERIFIABLE ANSWER" '"$LAST_OUT"
expect "lastnoheader: --last resolved to our sid" grep -q "resolved to session $SID" "$LAST_OUT"

# 13b. resume --last where codex answers from a DIFFERENT valid session → refused
mk_rollout lastwrong
run_case lastwrong wrong_session 4 wrong_session -- resume --last "hi"
expect "lastwrong: fresh-session answer NOT delivered" bash -c '! grep -q "FRESH SESSION ANSWER" '"$LAST_OUT"

# 13c. resume --last with no recorded sessions at all → session_not_found, codex not invoked
run_case lastnone ok 4 session_not_found -- resume --last "hi"
expect "lastnone: stub not called" test "$(cat "$LAST_STATE")" = "0"
expect "lastnone: SESSION sentinel is unknown" grep -q "^SESSION: unknown\$" "$LAST_OUT"

# 13d. uppercase UUID is normalized before matching
mk_rollout upperid
UPPER_SID=$(printf '%s' "$SID" | tr 'a-f' 'A-F')
run_case upperid ok 0 ok -- resume --session "$UPPER_SID" "hi"

# 13e. CODEX_SESSIONS_DIR defaults to $CODEX_HOME/sessions when unset
mkdir -p "$TMP/ch-def/sessions/2026/07/13"
: > "$TMP/ch-def/sessions/2026/07/13/rollout-2026-07-13T00-00-00-$SID.jsonl"
run_case homedefault ok 0 ok CODEX_SESSIONS_DIR= CODEX_HOME="$TMP/ch-def" -- resume --session "$SID" "hi"

# 13f. resume cwd derivation: newest rollout wins; JSON-escaped paths survive
mkdir -p "$TMP/cwd old" "$TMP/cwd \"new\""
mk_rollout cwdnew
OLD_RO="$TMP/sessions-cwdnew/2026/07/13/rollout-2026-07-13T00-00-00-$SID.jsonl"
NEW_RO="$TMP/sessions-cwdnew/2026/07/13/rollout-2026-07-13T00-00-05-$SID.jsonl"
python3 -c "import json,sys; open(sys.argv[1],'w').write(json.dumps({'session_id':sys.argv[3],'cwd':sys.argv[2]})+'\n')" "$OLD_RO" "$TMP/cwd old" "$SID"
python3 -c "import json,sys; open(sys.argv[1],'w').write(json.dumps({'session_id':sys.argv[3],'cwd':sys.argv[2]})+'\n')" "$NEW_RO" "$TMP/cwd \"new\"" "$SID"
touch -t 202607130001 "$OLD_RO"; touch -t 202607130002 "$NEW_RO"
run_case cwdnew ok 0 ok -- resume --session "$SID" "hi"
expect "cwdnew: newest rollout's ESCAPED cwd derived" grep -qF "resuming in the session's own directory: $TMP/cwd \"new\"" "$LAST_OUT"
expect "cwdnew: CODEX_START reports the DERIVED dir" bash -c 'head -1 "'"$LAST_OUT"'" | grep -qF "dir='"$TMP"'/cwd \"new\""'

# 13g. rollout with cwd nested under payload (alternate rollout shape)
mk_rollout cwdpayload
python3 -c "import json,sys; open(sys.argv[1],'w').write(json.dumps({'payload':{'session_id':sys.argv[3],'cwd':sys.argv[2]}})+'\n')" \
    "$TMP/sessions-cwdpayload/2026/07/13/rollout-2026-07-13T00-00-00-$SID.jsonl" "$TMP/cwd old" "$SID"
run_case cwdpayload ok 0 ok -- resume --session "$SID" "hi"
expect "cwdpayload: payload.cwd derived" grep -qF "resuming in the session's own directory: $TMP/cwd old" "$LAST_OUT"

# 14. heartbeat — slow run emits [codex Ns] lines before the result block
run_case heartbeat slow_ok 0 ok -- think "test prompt"
expect "heartbeat: >=2 beats" test "$(grep -c '^\[codex [0-9]*s\]' "$LAST_OUT")" -ge 2

# 15. octal-looking env knob ("02") is normalized, not a bash arithmetic crash
run_case octalenv slow_ok 0 ok CODEX_HEARTBEAT_SECS=02 -- think "test prompt"
expect "octalenv: beats still fired" test "$(grep -c '^\[codex [0-9]*s\]' "$LAST_OUT")" -ge 2

# 16. review path — stdout findings captured, sandbox FORCED read-only
run_case review ok_review 0 ok -- review --uncommitted "focus on x"
expect "review: content" grep -q "REVIEW FINDINGS" "$LAST_OUT"
expect "review: read-only sandbox override" grep -qx -- 'sandbox_mode="read-only"' "$LAST_STATE.args.1"

# 17. review capacity → recovery via resume delivers ONCE (no stdout+-o double-write)
mk_rollout revrec
run_case revrec review_capacity_then_resume_ok 0 ok_recovered -- review --uncommitted
expect "revrec: recovered exactly once" test "$(grep -c "RECOVERED REVIEW" "$LAST_OUT")" = "1"
expect "revrec: recovery kept the read-only sandbox" grep -qx -- 'sandbox_mode="read-only"' "$LAST_STATE.args.2"

# 17b. RELATIVE --schema survives recovery's cd (absolutized at parse time)
mk_rollout relschema
echo '{}' > "$TMP/relschema.json"
( cd "$TMP" && env CODEX_BIN="$STUB" STUB_STATE="$TMP/state-relschema" STUB_SCENARIO=capacity_then_resume_ok STUB_SID="$SID" \
      CODEX_RECOVER_BACKOFF=1 CODEX_RECOVER_ATTEMPTS=2 CODEX_HEARTBEAT_SECS=2 CODEX_SESSIONS_DIR="$TMP/sessions-relschema" \
      "$WRAP" think "test prompt" --schema relschema.json > "$TMP/out-relschema" 2> "$TMP/out-relschema.err" )
relexit=$?
if [ "$relexit" = "0" ] && grep -q '^CODEX_STATUS: ok_recovered$' "$TMP/out-relschema"; then
    echo "PASS  relschema (recovered with relative schema)"; PASS=$((PASS+1))
else
    echo "FAIL  relschema — exit=$relexit status=$(grep -m1 '^CODEX_STATUS:' "$TMP/out-relschema" | awk '{print $2}')"; FAIL=$((FAIL+1))
fi
expect "relschema: recovery got the ABSOLUTE schema path" test "$(arg_after --output-schema "$TMP/state-relschema.args.2")" = "$TMP/relschema.json"

# 18. old ANSI-mangled session id pasted into --session → cleaned then resumed
mk_rollout ansipaste
run_case ansipaste ok 0 ok -- resume --session "$(printf '\033[1msession id:\033[0m %s' "$SID")" "hi"

# 19. flag missing its value → usage_error, no infinite loop, stub not called
run_case dangling ok 2 usage_error -- think "test prompt" --model
expect "dangling: stub not called" test "$(cat "$LAST_STATE")" = "0"

# 20. unknown/typo'd flag → usage_error (not silently dropped)
run_case typoflag ok 2 usage_error -- think "test prompt" --modle luna
expect "typoflag: stub not called" test "$(cat "$LAST_STATE")" = "0"

# 21. missing prompt → usage_error with contract block
run_case noprompt ok 2 usage_error -- think

# 22. wrapper-side selector conflicts → usage_error, codex never invoked
run_case resumeconflict ok 2 usage_error -- resume --session "$SID" --last "hi"
expect "resumeconflict: stub not called" test "$(cat "$LAST_STATE")" = "0"
run_case reviewconflict ok 2 usage_error -- review --base main --commit abc123
expect "reviewconflict: stub not called" test "$(cat "$LAST_STATE")" = "0"

# 23. nonexistent --dir → usage_error before codex runs
run_case baddir ok 2 usage_error -- think "test prompt" --dir "$TMP/does-not-exist"
expect "baddir: stub not called" test "$(cat "$LAST_STATE")" = "0"

# 24. nonexistent --schema file → usage_error before codex runs
run_case badschema ok 2 usage_error -- think "test prompt" --schema "$TMP/no-such-schema.json"
expect "badschema: stub not called" test "$(cat "$LAST_STATE")" = "0"

# 25. prompt starting with '-' passed after -- reaches codex as a positional arg
run_case dashprompt ok 0 ok -- think -- "-weird prompt starting with dash"
expect "dashprompt: prompt delivered positionally" test "$(arg_after -- "$LAST_STATE.args.1")" = "-weird prompt starting with dash"

# 26. whitespace-only output file is NOT a final message
run_case blank blank_ok 1 no_output -- think "test prompt"

# 27. transfer: happy path — bridge imports the live transcript via stub
#     app-server (which creates the rollout + ledger like real codex);
#     thread id resolved from itemTypeResults successes[].target
THREAD="019faaaa-bbbb-7ccc-8ddd-eeeeffff0001"
FAKE_HOME="$TMP/home-transfer"
mkdir -p "$FAKE_HOME/.claude/projects/proj" "$TMP/codexhome-transfer"
printf '{"type":"user","message":"hello"}\n' > "$FAKE_HOME/.claude/projects/proj/sess.jsonl"
FIXTURE_REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$FAKE_HOME/.claude/projects/proj/sess.jsonl")
run_case transfer transfer_ok 0 ok HOME="$FAKE_HOME" CODEX_HOME="$TMP/codexhome-transfer" STUB_SID="$THREAD" -- transfer --source "$FIXTURE_REAL"
expect "transfer: SESSION carries thread id" grep -q "^SESSION: $THREAD\$" "$LAST_OUT"
expect "transfer: resume instructions present" grep -q "codex resume $THREAD" "$LAST_OUT"
expect "transfer: imported the real transcript path" grep -q "$FIXTURE_REAL" "$TMP/codexhome-transfer/external_agent_session_imports.json"
# 27t. authority proof: a stale ledger record (with the exact hash!) holds a
#      WRONG id — the completion's successes[].target must win
run_case transfertarget transfer_target_wins 0 ok HOME="$FAKE_HOME" CODEX_HOME="$TMP/codexhome-target" STUB_SID="$THREAD" -- transfer --source "$FIXTURE_REAL"
expect "transfertarget: target beat the ledger" grep -q "^SESSION: $THREAD\$" "$LAST_OUT"
expect "transfertarget: wrong ledger id NOT delivered" bash -c '! grep -q "019fdead-beef" '"$LAST_OUT"

# 27a. transfer → resume chain: the imported thread's rollout (created by the
#      stub like real codex) satisfies resume preflight, and resume runs in
#      the session's OWN cwd derived from that rollout
run_case transferresume ok 0 ok STUB_SID="$THREAD" CODEX_SESSIONS_DIR="$TMP/sessions-transfer" -- resume --session "$THREAD" "hi"
expect "transferresume: resumed in the session's own cwd" grep -q "resuming in the session's own directory: /tmp" "$LAST_OUT"

# 27b. transfer: live session GREW during import (sha mismatch) → newest-record fallback
THREAD2="019faaaa-bbbb-7ccc-8ddd-eeeeffff0002"
run_case transferrace transfer_race 0 ok HOME="$FAKE_HOME" CODEX_HOME="$TMP/codexhome-race" STUB_SID="$THREAD2" -- transfer --source "$FIXTURE_REAL"
expect "transferrace: fell back to newest record" grep -q "transcript changed while codex imported it" "$LAST_OUT"
expect "transferrace: still delivered the thread id" grep -q "^SESSION: $THREAD2\$" "$LAST_OUT"

# 28. transfer: codex too old for the import method → transfer_failed + upgrade hint
run_case transferold transfer_unsupported 1 transfer_failed HOME="$FAKE_HOME" CODEX_HOME="$TMP/codexhome-transfer" -- transfer --source "$FIXTURE_REAL"
expect "transferold: upgrade hint surfaced" grep -q "does not support Claude session transfer" "$LAST_OUT"

# 28b. transfer: import completes but the item FAILED → transfer_failed with diagnostics
# (deliberately reuses the transfer_ok ledger: a stale record for the same path
#  must NOT mask an explicit per-item failure)
run_case transferitem transfer_item_failed 1 transfer_failed HOME="$FAKE_HOME" CODEX_HOME="$TMP/codexhome-transfer" -- transfer --source "$FIXTURE_REAL"
expect "transferitem: itemTypeResults surfaced" grep -q "itemTypeResults" "$LAST_OUT"

# 28c. transfer: silent app-server → bounded by CODEX_TRANSFER_TIMEOUT, no hang
run_case transfersilent transfer_silent 1 transfer_failed HOME="$FAKE_HOME" CODEX_HOME="$TMP/codexhome-transfer" CODEX_TRANSFER_TIMEOUT=2 -- transfer --source "$FIXTURE_REAL"
expect "transfersilent: timeout surfaced" grep -q "timed out waiting for codex app-server" "$LAST_OUT"
expect "transfersilent: SESSION sentinel is unknown" grep -q "^SESSION: unknown\$" "$LAST_OUT"

# 28d. transfer: MALFORMED targets (trailing-newline UUID, non-UUID) + non-UUID
#      ledger record → never delivered as ok
run_case transferbadtarget transfer_bad_target 1 transfer_failed HOME="$FAKE_HOME" CODEX_HOME="$TMP/codexhome-badtgt" -- transfer --source "$FIXTURE_REAL"
expect "transferbadtarget: malformed target logged+ignored" grep -q "ignoring malformed import target" "$LAST_OUT"
expect "transferbadtarget: non-uuid never delivered" bash -c '! grep -qE "^SESSION: (deadbeef|not-a-uuid)" '"$LAST_OUT"
expect "transferbadtarget: non-uuid ledger fixture actually exists" grep -q "not-a-uuid-at-all" "$TMP/codexhome-badtgt/external_agent_session_imports.json"

# 28e. TERM mid-transfer: wrapper interrupts, bridge cleanup reaps the
#      app-server — no orphan survives
tsigstate="$TMP/state-tsig"; echo 0 > "$tsigstate"
tsigout="$TMP/out-tsig"
env CODEX_BIN="$STUB" STUB_STATE="$tsigstate" STUB_SCENARIO=transfer_silent STUB_SID="$THREAD" \
    HOME="$FAKE_HOME" CODEX_HOME="$TMP/codexhome-transfer" CODEX_SESSIONS_DIR="$TMP/sessions-tsig" \
    "$WRAP" transfer --source "$FIXTURE_REAL" > "$tsigout" 2> "$tsigout.err" &
wpid=$!
sleep 2
kill -TERM "$wpid" 2>/dev/null
wait "$wpid"; tsigexit=$?
sleep 1
orphans=$(pgrep -f "stub-codex.sh app-server" | wc -l | tr -d ' ')
if [ "$tsigexit" = "130" ] && grep -q '^CODEX_STATUS: interrupted$' "$tsigout" && [ "$orphans" = "0" ]; then
    echo "PASS  transfer-signal (exit=130, no orphaned app-server)"; PASS=$((PASS+1))
else
    echo "FAIL  transfer-signal — exit=$tsigexit orphans=$orphans status=$(grep -m1 '^CODEX_STATUS:' "$tsigout" | awk '{print $2}')"
    pkill -f "stub-codex.sh app-server" 2>/dev/null
    FAIL=$((FAIL+1))
fi
check_envelope transfer-signal "$tsigout"

# 29. transfer: source outside ~/.claude/projects → usage_error, bridge never invoked
printf 'x\n' > "$TMP/outside.jsonl"
run_case transferout ok 2 usage_error HOME="$FAKE_HOME" -- transfer --source "$TMP/outside.jsonl"

# 30. transfer: missing source → session_not_found; no args / conflicting selectors → usage_error
run_case transfermissing ok 4 session_not_found HOME="$FAKE_HOME" -- transfer --source "$FAKE_HOME/.claude/projects/proj/nope.jsonl"
run_case transfernoargs ok 2 usage_error HOME="$FAKE_HOME" -- transfer
run_case transferconflict ok 2 usage_error HOME="$FAKE_HOME" -- transfer --latest --source "$FIXTURE_REAL"

# 30b. help works even with an unusable TMPDIR (the sole block-less path)
helpout=$(TMPDIR=/nonexistent-tmpdir-xyz "$WRAP" help 2>/dev/null); helpexit=$?
if [ "$helpexit" = "0" ] && printf '%s' "$helpout" | grep -q '^Commands:'; then
    echo "PASS  helptmpdir (help survives unusable TMPDIR)"; PASS=$((PASS+1))
else
    echo "FAIL  helptmpdir — exit=$helpexit, stdout $(printf '%s' "$helpout" | wc -c | tr -d ' ') bytes"; FAIL=$((FAIL+1))
fi

# 31. canonical review schema: valid JSON AND its load-bearing constraints intact
SCHEMA_FILE="$(cd "$(dirname "$0")/.." && pwd)/schemas/review-output.schema.json"
expect "review schema: valid JSON" python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SCHEMA_FILE"
expect "review schema: constraints intact" python3 -c "
import json, sys
s = json.load(open(sys.argv[1]))
assert s['additionalProperties'] is False
assert set(s['required']) == {'verdict', 'summary', 'findings', 'next_steps'}
f = s['properties']['findings']['items']
assert f['additionalProperties'] is False
assert set(f['required']) >= {'severity', 'file', 'line_start', 'line_end', 'confidence', 'recommendation'}
c = f['properties']['confidence']
assert c['minimum'] == 0 and c['maximum'] == 1
assert set(f['properties']['severity']['enum']) == {'critical', 'high', 'medium', 'low'}
" "$SCHEMA_FILE"

# 32. TERM mid-run still emits the result contract (CODEX_STATUS: interrupted, exit 130)
sigstate="$TMP/state-signal"; echo 0 > "$sigstate"
sigout="$TMP/out-signal"
env CODEX_BIN="$STUB" STUB_STATE="$sigstate" STUB_SCENARIO=slow_ok STUB_SID="$SID" \
    CODEX_RECOVER_BACKOFF=1 CODEX_RECOVER_ATTEMPTS=2 CODEX_HEARTBEAT_SECS=2 \
    CODEX_SESSIONS_DIR="$TMP/sessions-signal" \
    "$WRAP" think "test prompt" > "$sigout" 2> "$sigout.err" &
wpid=$!
sleep 2
kill -TERM "$wpid" 2>/dev/null
wait "$wpid"; sigexit=$?
if [ "$sigexit" = "130" ] && grep -q '^CODEX_STATUS: interrupted$' "$sigout"; then
    echo "PASS  signal (exit=130 status=interrupted)"; PASS=$((PASS+1))
else
    echo "FAIL  signal — want exit=130 status=interrupted, got exit=$sigexit status=$(grep -m1 '^CODEX_STATUS:' "$sigout" | awk '{print $2}')"
    sed 's/^/      | /' "$sigout" | head -10
    FAIL=$((FAIL+1))
fi
check_envelope signal "$sigout"

# 33. TERM with a child that IGNORES it → wrapper escalates to KILL, still exits
#     130 with the contract (bounded — must not hang on an unbounded wait)
stubstate="$TMP/state-stubborn"; echo 0 > "$stubstate"
stubout="$TMP/out-stubborn"
env CODEX_BIN="$STUB" STUB_STATE="$stubstate" STUB_SCENARIO=slow_stubborn STUB_SID="$SID" \
    CODEX_RECOVER_BACKOFF=1 CODEX_RECOVER_ATTEMPTS=2 CODEX_HEARTBEAT_SECS=2 \
    CODEX_SESSIONS_DIR="$TMP/sessions-stubborn" \
    "$WRAP" think "test prompt" > "$stubout" 2> "$stubout.err" &
wpid=$!
sleep 2
T0=$SECONDS
kill -TERM "$wpid" 2>/dev/null
wait "$wpid"; stubexit=$?
ELAPSED=$((SECONDS - T0))
if [ "$stubexit" = "130" ] && grep -q '^CODEX_STATUS: interrupted$' "$stubout" && [ "$ELAPSED" -le 20 ]; then
    echo "PASS  stubborn-signal (exit=130 in ${ELAPSED}s despite TERM-ignoring child)"; PASS=$((PASS+1))
else
    echo "FAIL  stubborn-signal — want exit=130 within 20s, got exit=$stubexit in ${ELAPSED}s status=$(grep -m1 '^CODEX_STATUS:' "$stubout" | awk '{print $2}')"
    sed 's/^/      | /' "$stubout" | head -10
    FAIL=$((FAIL+1))
fi
check_envelope stubborn-signal "$stubout"

echo
echo "==== $PASS passed, $FAIL failed ===="
rm -rf "$TMP"
[ "$FAIL" = 0 ]
