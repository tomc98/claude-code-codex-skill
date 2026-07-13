#!/usr/bin/env bash
# codex.sh — Wrapper for non-interactive Codex CLI usage
# Runs codex exec, captures session ID and final message, detects and recovers
# return-path failures (model at-capacity, stream errors) by resuming the SAME
# session with the SAME model/effort/schema — never by re-running from scratch
# and never by switching model. No resumable session (--ephemeral, or failure
# before session creation) = no recovery: an honest non-zero exit instead.
#
# Usage:
#   codex.sh run "prompt" [--dir PATH] [--model MODEL] [--effort LEVEL] [--sandbox MODE] [--image FILE] [--ephemeral] [--schema FILE] [--add-dir PATH]
#   codex.sh think "prompt" [--dir PATH] [--model MODEL] [--effort LEVEL] [--image FILE] [--ephemeral] [--schema FILE]
#   codex.sh resume [--session ID | --last] "prompt" [--dir PATH]
#   codex.sh review [--base BRANCH | --commit SHA | --uncommitted] ["custom instructions"]
#   codex.sh transfer [--source <claude-jsonl> | --latest] [--dir PATH]
#       Imports a Claude Code transcript (must live under ~/.claude/projects)
#       into a persistent Codex thread via the app-server protocol; the SESSION
#       line carries the imported thread id — `codex resume <id>` continues it.
#       Live transcripts are handled: the bridge hashes before importing and,
#       if the session grew mid-transfer, resolves the newest imported thread
#       for the path. The imported thread keeps the cwd recorded IN the
#       transcript (--dir is advisory); failures exit 1 with
#       CODEX_STATUS: transfer_failed. Env: CODEX_TRANSFER_TIMEOUT (180s).
#
# Output contract (stdout):
#   CODEX_START: mode=… model=… effort=… dir=…
#   [codex Ns] …           progress lines (heartbeat every CODEX_HEARTBEAT_SECS)
#   [codex recover] …      progress lines (recovery attempts)
#   [stderr tail …]        diagnostics — printed on failure only, BEFORE the block
#   CODEX_EXIT: <codex process exit code; '-' if codex was never invoked;
#                for transfer: the bridge's exit code (app-server is terminated by design)>
#   CODEX_STATUS: ok|ok_recovered|no_output|usage_error|capacity_exhausted|session_not_found|wrong_session|interrupted|transfer_failed
#   SESSION: <uuid; 'unknown' if codex was never invoked or printed no header;
#            session_not_found echoes the requested id>
#   ---
#   <final message — everything after the '---' line that follows SESSION:.
#    Empty on failure; diagnostics never appear below the delimiter.>
#
# The block is emitted on EVERY path — usage errors, preflight failures, and
# signals (INT/TERM/HUP → CODEX_STATUS: interrupted, exit 130) included.
# Sole exception: 'codex.sh help' prints usage text only, exit 0.
#
# Wrapper exit codes:
#   0 ok / ok_recovered   1 no_output   2 usage_error
#   3 capacity_exhausted  4 session_not_found / wrong_session   130 interrupted
#
# resume --last is resolved BY THE WRAPPER to the newest rollout on this
# machine (global, not cwd-filtered) and passed as an explicit session id, so
# identity verification is exactly as strict as --session.
#
# Env knobs:
#   CODEX_BIN               codex binary (default: codex)
#   CODEX_HEARTBEAT_SECS    heartbeat interval (default: 30)
#   CODEX_RECOVER_ATTEMPTS  recovery attempts on empty output (default: 3)
#   CODEX_RECOVER_BACKOFF   first backoff in seconds, doubling each attempt —
#                           total worst-case wait = BACKOFF*(2^ATTEMPTS - 1) (default: 30)
#   CODEX_SESSIONS_DIR      rollout root (default: ~/.codex/sessions)

set -o pipefail

# Resolve through symlinks so companion scripts are found beside the real file
SELF="$0"
while [ -L "$SELF" ]; do
    SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
    SELF="$(readlink "$SELF")"
    case "$SELF" in /*) : ;; *) SELF="$SELF_DIR/$SELF" ;; esac
done
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_SESSIONS_DIR="${CODEX_SESSIONS_DIR:-${CODEX_HOME:-$HOME/.codex}/sessions}"
HEARTBEAT_SECS="${CODEX_HEARTBEAT_SECS:-30}"
RECOVER_ATTEMPTS="${CODEX_RECOVER_ATTEMPTS:-3}"
RECOVER_BACKOFF="${CODEX_RECOVER_BACKOFF:-30}"
RECOVERY_PROMPT="Continue. Your previous turn was interrupted before the final answer was delivered (model capacity or stream error). Emit your complete final answer now."

# Malformed numeric knobs fall back to defaults instead of breaking arithmetic;
# 10# strips leading zeros so values like "08" aren't parsed as invalid octal
case "$HEARTBEAT_SECS"   in ''|*[!0-9]*) HEARTBEAT_SECS=30 ;;  *) HEARTBEAT_SECS=$((10#$HEARTBEAT_SECS)) ;; esac
case "$RECOVER_ATTEMPTS" in ''|*[!0-9]*) RECOVER_ATTEMPTS=3 ;; *) RECOVER_ATTEMPTS=$((10#$RECOVER_ATTEMPTS)) ;; esac
case "$RECOVER_BACKOFF"  in ''|*[!0-9]*) RECOVER_BACKOFF=30 ;; *) RECOVER_BACKOFF=$((10#$RECOVER_BACKOFF)) ;; esac
[ "$HEARTBEAT_SECS" -ge 1 ] || HEARTBEAT_SECS=30

OUTPUT_FILE=""
STDERR_FILE=""

CODEX_PID=""
CODEX_EXIT_CODE=""
RUN_DIR=""          # cd here before exec (resume/review have no -C flag)
STDOUT_FILE=""      # capture codex stdout here instead of /dev/null (review)
REQUESTED_SID=""    # user-specified resume target; mismatch or unverifiable = hard fail
RESUME_MODE=false   # resume must always produce a verifiable session header
MODE_NAME=""        # for the guaranteed CODEX_START line
ANNOUNCED=false

cleanup() {
    [ -n "$OUTPUT_FILE" ] && rm -f "$OUTPUT_FILE"
    [ -n "$STDERR_FILE" ] && rm -f "$STDERR_FILE"
}
trap cleanup EXIT

# ── Helpers ──────────────────────────────────────────────────────────

usage() {
    # printf, not a heredoc: bash 3.2 heredocs materialize via TMPDIR temp
    # files, and help must work even when TMPDIR is unusable
    printf '%s\n' \
        'codex.sh — Non-interactive Codex CLI wrapper' \
        '' \
        'Commands:' \
        '  run "prompt"                      Start a coding task (full-access sandbox)' \
        '  think "prompt"                    Deliberation/analysis (read-only + web search)' \
        '  resume --session ID "prompt"      Resume a specific session' \
        '  resume --last "prompt"            Resume the most recent session' \
        '  review                            Review uncommitted changes (read-only, enforced)' \
        '  review --base main                Review against a base branch' \
        '  review --commit SHA               Review a specific commit' \
        '  transfer --source FILE.jsonl      Import a Claude transcript as a Codex thread' \
        '  transfer --latest                 Same, using the newest Claude transcript' \
        '' \
        'Options:' \
        '  --dir PATH         Working directory (default: current; resume defaults' \
        '                     to the session'"'"'s own recorded directory)' \
        '  --model MODEL      Override model (default: from config.toml)' \
        '  --effort LEVEL     Reasoning effort: low|medium|high|xhigh|max|ultra' \
        '                     (default xhigh for run/think; max/ultra are GPT-5.6+;' \
        '                     ultra needs Sol or Terra)' \
        '  --sandbox MODE     Sandbox: read-only|workspace-write|danger-full-access' \
        '  --image FILE       Attach an image (repeatable)' \
        '  --ephemeral        Do not persist session to disk. Disables capacity recovery' \
        '                     and resume — sessions persist by default, including think' \
        '  --schema FILE      Validate output against JSON Schema' \
        '  --add-dir PATH     Grant write access to an additional directory' \
        '  --source FILE      Claude transcript to transfer (transfer only)' \
        '  --latest           Transfer the newest Claude transcript (transfer only)' \
        '' \
        'Exit codes:' \
        '  0 ok / ok_recovered      1 no_output / transfer_failed   2 usage_error' \
        '  3 capacity_exhausted     4 session_not_found / wrong_session' \
        '  130 interrupted (INT/TERM/HUP — child killed, block still emitted)' \
        '' \
        'On a failed run (empty output or non-zero codex exit) classified as' \
        'recoverable (model at capacity / stream error / 429), the wrapper resumes the' \
        'SAME session with the SAME model/effort/schema/sandbox (never a fallback' \
        'model, never a from-scratch re-run) and asks it to emit the final answer it' \
        'already computed — up to CODEX_RECOVER_ATTEMPTS attempts, backoff doubling' \
        'from CODEX_RECOVER_BACKOFF (worst-case total wait = BACKOFF*(2^ATTEMPTS - 1)).' \
        'Without a persisted session there is no recovery — the wrapper fails honestly' \
        '(exit 3) instead.'
}

strip_ansi() {
    # CSI/SGR (incl. ':' subparams), OSC (BEL- or ST-terminated), stray ESC+byte, CRs
    LC_ALL=C sed -E $'s/\x1b\\[[0-9;:?]*[@-~]//g; s/\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)?//g; s/\x1b.//g' | tr -d '\r'
}

extract_session_id() {
    strip_ansi < "$1" 2>/dev/null \
        | sed -nE 's/.*session id:[[:space:]]*([0-9a-fA-F-]+).*/\1/p' \
        | head -1
}

is_uuid() {
    printf '%s' "$1" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

rollout_exists() {
    # sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl
    # Imported (transferred) sessions also create real rollouts — codex writes
    # the rollout BEFORE recording the import in its ledger, so a ledger-only
    # record is stale by definition and must NOT count as resumable.
    ls "$CODEX_SESSIONS_DIR"/*/*/*/rollout-*"$1".jsonl >/dev/null 2>&1
}

# Best-effort: the session's own working directory, recorded on the rollout's
# first line — resuming from an unrelated cwd would override the thread's cwd
# (codex sends the caller cwd as an explicit resume override). JSON-aware
# (escaped quotes in paths survive) and reads the NEWEST rollout for the id;
# silently skipped when python3 is unavailable (falls back to caller cwd).
session_cwd_from_rollout() { # $1 = session id
    command -v python3 >/dev/null 2>&1 || return 0
    local f
    f=$(ls -t "$CODEX_SESSIONS_DIR"/*/*/*/rollout-*"$1".jsonl 2>/dev/null | head -1)
    [ -n "$f" ] || return 0
    python3 -c '
import json, sys
try:
    d = json.loads(open(sys.argv[1], encoding="utf-8").readline())
    cwd = d.get("cwd") if isinstance(d, dict) else None
    if cwd is None and isinstance(d, dict) and isinstance(d.get("payload"), dict):
        cwd = d["payload"].get("cwd")
    if isinstance(cwd, str) and cwd:
        sys.stdout.write(cwd)
except Exception:
    pass
' "$f" 2>/dev/null
}

classify_stderr() {
    # capacity/transient → recoverable via same-session resume
    # cli_reject          → codex refused the invocation (bad flag value etc.)
    # unknown             → unrecognised; fail fast
    if grep -qiE 'at capacity|try a different model' "$STDERR_FILE"; then
        echo capacity
    elif grep -qiE 'stream (error|disconnected)|429 Too Many Requests|HTTP[ /][0-9.]* ?429|status(:| ) ?429|rate.?limit(ed)? (exceeded|reached|hit)|ERROR.*rate.?limit' "$STDERR_FILE"; then
        echo transient
    elif grep -qiE "error: (invalid value|unexpected argument|unrecognized subcommand|a value is required|the argument .* cannot be used with|the following required arguments|unexpected value)|Failed to read output schema" "$STDERR_FILE"; then
        echo cli_reject
    else
        echo unknown
    fi
}

print_stderr_tail() {
    echo "[stderr tail — last 40 lines]"
    strip_ansi < "$STDERR_FILE" | tail -40
}

# CODEX_START is guaranteed to be the FIRST stdout line of every result,
# including usage/preflight failures that never reach announce().
ensure_announced() {
    if [ "$ANNOUNCED" != true ]; then
        echo "CODEX_START: mode=${MODE_NAME:-unknown} model=${MODEL:-default} effort=${EFFORT:-config} dir=${DIR:-$PWD}"
        ANNOUNCED=true
    fi
}

emit_result_block() { # $1=status $2=session-id
    ensure_announced
    echo "CODEX_EXIT: ${CODEX_EXIT_CODE:--}"
    echo "CODEX_STATUS: $1"
    echo "SESSION: ${2:-unknown}"
    echo "---"
}

finish_ok() { # $1 = ok|ok_recovered
    local sid
    sid=$(extract_session_id "$STDERR_FILE")
    emit_result_block "$1" "$sid"
    cat "$OUTPUT_FILE"
    exit 0
}

finish_fail() { # $1=status $2=wrapper-exit-code — diagnostics BEFORE the block, empty final message
    local sid
    sid=$(extract_session_id "$STDERR_FILE")
    print_stderr_tail
    emit_result_block "$1" "$sid"
    exit "$2"
}

fail_usage() { # $1=message — contract-shaped usage error
    ensure_announced
    echo "[codex] usage error: $1"
    echo "ERROR: $1" >&2
    emit_result_block usage_error unknown
    exit 2
}

# Hard guard for resumes. Codex silently starts a NEW session when the target
# cannot be resumed — never pass that off as a resume. FAILS CLOSED: no
# parseable session id = no proof = refuse to deliver. Applies to --last too.
check_requested_session() {
    local sid
    if [ -n "$REQUESTED_SID" ]; then
        sid=$(extract_session_id "$STDERR_FILE")
        if [ -z "$sid" ] || [ "$sid" != "$REQUESTED_SID" ]; then
            echo "[codex] refusing to deliver: requested session $REQUESTED_SID but codex reported '${sid:-none}'."
            echo "[codex] codex silently starts a NEW, context-empty session when the target cannot be resumed."
            finish_fail wrong_session 4
        fi
    elif [ "$RESUME_MODE" = true ]; then
        sid=$(extract_session_id "$STDERR_FILE")
        if [ -z "$sid" ]; then
            echo "[codex] refusing to deliver: resume produced no verifiable session header (cannot prove which session answered)."
            finish_fail wrong_session 4
        fi
    fi
    return 0
}

# ── Execution core ───────────────────────────────────────────────────

exec_with_heartbeat() {
    : > "$STDERR_FILE"
    (
        [ -n "$RUN_DIR" ] && { cd "$RUN_DIR" || exit 97; }
        exec "${CMD[@]}" </dev/null >>"${STDOUT_FILE:-/dev/null}" 2>>"$STDERR_FILE"
    ) &
    CODEX_PID=$!
    local elapsed=0 next_beat="$HEARTBEAT_SECS" last
    while kill -0 "$CODEX_PID" 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [ "$elapsed" -ge "$next_beat" ]; then
            last=$(strip_ansi < "$STDERR_FILE" | LC_ALL=C tr -c '[:print:]\n' ' ' | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-160)
            echo "[codex ${elapsed}s] ${last:-working}"
            next_beat=$((next_beat + HEARTBEAT_SECS))
        fi
    done
    wait "$CODEX_PID" 2>/dev/null
    CODEX_EXIT_CODE=$?
    CODEX_PID=""
}

codex_succeeded() {
    # Whitespace-only output is not a final message
    [ "${CODEX_EXIT_CODE:-1}" -eq 0 ] && grep -q '[^[:space:]]' "$OUTPUT_FILE" 2>/dev/null
}

build_recovery_cmd() { # $1 = session id — SAME model/effort/schema/SANDBOX as the primary run
    CMD=("$CODEX_BIN" exec resume --skip-git-repo-check)
    [ -n "$MODEL" ]   && CMD+=(-m "$MODEL")
    [ -n "$EFFORT" ]  && CMD+=(-c "model_reasoning_effort=\"$EFFORT\"")
    [ -n "$SCHEMA" ]  && CMD+=(--output-schema "$SCHEMA")
    # resume has no -s flag; the config override keeps a read-only think from
    # recovering as full-access (resume derives permissions from the CURRENT
    # invocation, not the persisted thread)
    [ -n "$SANDBOX" ] && CMD+=(-c "sandbox_mode=\"$SANDBOX\"")
    CMD+=(-o "$OUTPUT_FILE" -- "$1" "$RECOVERY_PROMPT")
}

# Empty-output recovery. RESUME-ONLY: same session, same model — never a model
# fallback and never a from-scratch re-run (Tom, 2026-07-13: continue from
# where it hit capacity). No resumable session = no recovery.
run_with_recovery() {
    exec_with_heartbeat
    codex_succeeded && { check_requested_session; finish_ok ok; }

    local kind sid attempt=1 backoff="$RECOVER_BACKOFF" nsid
    kind=$(classify_stderr)
    case "$kind" in
        cli_reject) finish_fail usage_error 2 ;;
        unknown)    finish_fail no_output 1 ;;
    esac

    if [ -n "$REQUESTED_SID" ]; then
        sid="$REQUESTED_SID"
    else
        sid=$(extract_session_id "$STDERR_FILE")
    fi
    if [ -z "$sid" ] || ! rollout_exists "$sid"; then
        echo "[codex recover] ${kind} failure but no resumable session (ephemeral, or codex failed before persisting one) — cannot recover without re-running; re-run manually."
        finish_fail capacity_exhausted 3
    fi

    STDOUT_FILE=""   # recovery delivers via -o only (review would double-write otherwise)
    while [ "$attempt" -le "$RECOVER_ATTEMPTS" ]; do
        echo "[codex recover] ${kind} failure — resuming session $sid (same model), attempt ${attempt}/${RECOVER_ATTEMPTS} after ${backoff}s"
        sleep "$backoff"
        : > "$OUTPUT_FILE"
        build_recovery_cmd "$sid"
        RUN_DIR="${DIR:-$RUN_DIR}"
        exec_with_heartbeat
        # FAIL CLOSED: only a run that verifiably resumed OUR session counts.
        # An identity miss burns the attempt and retries — it never delivers
        # and never terminates the ladder early.
        nsid=$(extract_session_id "$STDERR_FILE")
        if [ -z "$nsid" ] || [ "$nsid" != "$sid" ]; then
            echo "[codex recover] resume did not verifiably continue $sid (codex reported '${nsid:-none}') — discarding this attempt's output"
            : > "$OUTPUT_FILE"
        else
            codex_succeeded && finish_ok ok_recovered
            kind=$(classify_stderr)
            case "$kind" in
                cli_reject) finish_fail usage_error 2 ;;
                unknown)    finish_fail no_output 1 ;;
            esac
        fi
        attempt=$((attempt + 1))
        backoff=$((backoff * 2))
    done
    finish_fail capacity_exhausted 3
}

# ── Shared flag parser ───────────────────────────────────────────────

need_value() { # $1=flag $2=remaining-argc
    [ "$2" -ge 2 ] || fail_usage "flag $1 requires a value"
}

parse_common_flags() {
    # Sets globals: PROMPT, DIR, MODEL, EFFORT, SANDBOX, IMAGES[], EPHEMERAL, SCHEMA, ADD_DIRS[], SEARCH
    PROMPT=""
    DIR=""
    MODEL=""
    EFFORT=""
    SANDBOX=""
    IMAGES=()
    EPHEMERAL=false
    SCHEMA=""
    ADD_DIRS=()
    SEARCH=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --)          shift
                         if [[ $# -gt 0 && -z "$PROMPT" ]]; then PROMPT="$1"; shift; fi
                         [[ $# -gt 0 ]] && fail_usage "unexpected extra argument '$1' (prompt already set)"
                         break ;;
            --dir)       need_value "$1" $#; DIR="$2"; shift 2 ;;
            --model)     need_value "$1" $#; MODEL="$2"; shift 2 ;;
            --effort)    need_value "$1" $#; EFFORT="$2"; shift 2 ;;
            --sandbox)   need_value "$1" $#; SANDBOX="$2"; shift 2 ;;
            --image)     need_value "$1" $#; IMAGES+=("$2"); shift 2 ;;
            --ephemeral) EPHEMERAL=true; shift ;;
            --schema)    need_value "$1" $#; SCHEMA="$2"; shift 2 ;;
            --add-dir)   need_value "$1" $#; ADD_DIRS+=("$2"); shift 2 ;;
            --search)    SEARCH=true; shift ;;
            --*)         fail_usage "unknown flag '$1' (a prompt starting with '-'? pass it after --)" ;;
            *)
                if [[ -z "$PROMPT" ]]; then
                    PROMPT="$1"
                else
                    fail_usage "unexpected extra argument '$1' (prompt already set)"
                fi
                shift ;;
        esac
    done
}

build_cmd() {
    # Builds CMD array from parsed globals. Caller sets defaults before calling.
    CMD=("$CODEX_BIN" exec --skip-git-repo-check --color never)
    [[ -n "$DIR" ]]     && CMD+=(-C "$DIR")
    [[ -n "$MODEL" ]]   && CMD+=(-m "$MODEL")
    [[ -n "$EFFORT" ]]  && CMD+=(-c "model_reasoning_effort=\"$EFFORT\"")
    [[ -n "$SANDBOX" ]] && CMD+=(-s "$SANDBOX")
    [[ -n "$SCHEMA" ]]  && CMD+=(--output-schema "$SCHEMA")
    $EPHEMERAL           && CMD+=(--ephemeral)
    $SEARCH              && CMD+=(-c 'features.search_tool=true')

    for img in "${IMAGES[@]}"; do
        CMD+=(-i "$img")
    done
    for dir in "${ADD_DIRS[@]}"; do
        CMD+=(--add-dir "$dir")
    done

    CMD+=(-o "$OUTPUT_FILE")
    CMD+=(-- "$PROMPT")   # '--' so prompts starting with '-' are never parsed as flags
}

announce() { # $1=mode — idempotent; a preflight message may have announced already
    [ "$ANNOUNCED" = true ] && return 0
    echo "CODEX_START: mode=$1 model=${MODEL:-default} effort=${EFFORT:-config} dir=${DIR:-$PWD}"
    ANNOUNCED=true
}

check_dir() {
    [ -n "$DIR" ] && [ ! -d "$DIR" ] && fail_usage "directory not found: $DIR"
    # Absolutize: recovery resumes cd into $DIR, which would re-resolve a
    # relative schema path against a different directory
    if [ -n "$SCHEMA" ]; then
        case "$SCHEMA" in /*) : ;; *) SCHEMA="$PWD/$SCHEMA" ;; esac
        [ -f "$SCHEMA" ] || fail_usage "schema file not found: $SCHEMA"
    fi
    return 0
}

# Newest recorded session on this machine (rollout filename carries the UUID).
resolve_last_session() {
    ls -t "$CODEX_SESSIONS_DIR"/*/*/*/rollout-*.jsonl 2>/dev/null | head -1 \
        | sed -nE 's/.*-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.jsonl$/\1/p'
}

# ── Run ──────────────────────────────────────────────────────────────

run_codex() {
    parse_common_flags "$@"

    [[ -z "$PROMPT" ]] && fail_usage "no prompt provided"
    check_dir

    # Defaults for run: full-access sandbox, web search on, explicit effort
    [[ -z "$SANDBOX" ]] && SANDBOX="danger-full-access"
    [[ -z "$EFFORT" ]]  && EFFORT="xhigh"
    SEARCH=true

    build_cmd
    announce run
    run_with_recovery
}

# ── Think ────────────────────────────────────────────────────────────

think_codex() {
    parse_common_flags "$@"

    [[ -z "$PROMPT" ]] && fail_usage "no prompt provided"
    check_dir

    # Defaults for think: read-only sandbox, web search on, explicit effort.
    # Sessions PERSIST (the old forced --ephemeral made every think session
    # unrecoverable and unresumable — pass --ephemeral explicitly to opt out).
    [[ -z "$SANDBOX" ]] && SANDBOX="read-only"
    [[ -z "$EFFORT" ]]  && EFFORT="xhigh"
    SEARCH=true

    build_cmd
    announce think
    run_with_recovery
}

# ── Resume ───────────────────────────────────────────────────────────

resume_codex() {
    PROMPT=""
    DIR=""
    MODEL=""
    EFFORT=""
    SCHEMA=""
    local session_id="" use_last=false show_all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --)         shift
                        if [[ $# -gt 0 && -z "$PROMPT" ]]; then PROMPT="$1"; shift; fi
                        [[ $# -gt 0 ]] && fail_usage "unexpected extra argument '$1' (prompt already set)"
                        break ;;
            --session)  need_value "$1" $#; session_id="$2"; shift 2 ;;
            --last)     use_last=true; shift ;;
            --dir)      need_value "$1" $#; DIR="$2"; shift 2 ;;
            --all)      show_all=true; shift ;;   # legacy no-op: --last is wrapper-resolved globally now
            --*)        fail_usage "unknown flag '$1' (a prompt starting with '-'? pass it after --)" ;;
            *)
                if [[ -z "$PROMPT" ]]; then
                    PROMPT="$1"
                else
                    fail_usage "unexpected extra argument '$1' (prompt already set)"
                fi
                shift ;;
        esac
    done

    if [[ -z "$session_id" ]] && ! $use_last; then
        fail_usage "specify --session ID or --last"
    fi
    if [[ -n "$session_id" ]] && $use_last; then
        fail_usage "--session and --last are mutually exclusive"
    fi
    check_dir
    RESUME_MODE=true

    # Resolve --last to a concrete session ID ourselves (newest rollout on this
    # machine) so identity verification is exactly as strict as --session —
    # otherwise codex's own fallback could silently answer from a fresh session.
    local last_note=""
    if $use_last; then
        session_id=$(resolve_last_session)
        if [[ -z "$session_id" ]]; then
            ensure_announced
            echo "[codex] --last: no recorded sessions found under $CODEX_SESSIONS_DIR — codex was not invoked."
            emit_result_block session_not_found unknown
            exit 4
        fi
        # announced AFTER cwd derivation so CODEX_START reports the real dir
        last_note="[codex] --last resolved to session $session_id (newest rollout)"
    fi

    if [[ -n "$session_id" ]]; then
        # Strip any ANSI garbage a consumer may have pasted from an old SESSION line
        session_id=$(printf '%s' "$session_id" | strip_ansi | sed -E 's/.*session id:[[:space:]]*//' | tr -d '[:space:]' | tr 'A-F' 'a-f')
        if ! is_uuid "$session_id"; then
            ensure_announced
            echo "[codex] invalid session id: '$session_id' is not a UUID — codex was not invoked (a bad id would silently start a NEW, context-empty session)."
            emit_result_block usage_error unknown
            exit 2
        fi
        if ! rollout_exists "$session_id"; then
            ensure_announced
            echo "[codex] no rollout found under $CODEX_SESSIONS_DIR for $session_id — codex was not invoked (ephemeral sessions are never resumable)."
            emit_result_block session_not_found "$session_id"
            exit 4
        fi
        REQUESTED_SID="$session_id"
    fi

    # Resume from the session's OWN directory unless --dir overrides: codex
    # sends the caller cwd as an explicit resume override, so resuming from an
    # unrelated checkout would silently re-root the thread there.
    local cwd_note=""
    if [[ -z "$DIR" ]]; then
        local sess_cwd
        sess_cwd=$(session_cwd_from_rollout "$session_id")
        if [[ -n "$sess_cwd" && -d "$sess_cwd" && "$sess_cwd" != "$PWD" ]]; then
            DIR="$sess_cwd"
            cwd_note="[codex] resuming in the session's own directory: $sess_cwd (pass --dir to override)"
        fi
    fi
    announce resume   # after derivation so CODEX_START reports the real dir
    [[ -n "$last_note" ]] && echo "$last_note"
    [[ -n "$cwd_note" ]] && echo "$cwd_note"
    RUN_DIR="$DIR"   # resume has no -C flag; cd instead
    CMD=("$CODEX_BIN" exec resume --skip-git-repo-check -o "$OUTPUT_FILE" -- "$session_id")
    [[ -n "$PROMPT" ]] && CMD+=("$PROMPT")

    run_with_recovery
}

# ── Review ───────────────────────────────────────────────────────────

review_codex() {
    PROMPT=""
    DIR=""
    MODEL=""
    EFFORT=""
    SCHEMA=""
    local base="" commit="" uncommitted=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --)            shift
                           if [[ $# -gt 0 && -z "$PROMPT" ]]; then PROMPT="$1"; shift; fi
                           [[ $# -gt 0 ]] && fail_usage "unexpected extra argument '$1' (prompt already set)"
                           break ;;
            --base)        need_value "$1" $#; base="$2"; shift 2 ;;
            --commit)      need_value "$1" $#; commit="$2"; shift 2 ;;
            --uncommitted) uncommitted=true; shift ;;
            --dir)         need_value "$1" $#; DIR="$2"; shift 2 ;;
            --*)           fail_usage "unknown flag '$1' (a prompt starting with '-'? pass it after --)" ;;
            *)
                if [[ -z "$PROMPT" ]]; then
                    PROMPT="$1"
                else
                    fail_usage "unexpected extra argument '$1' (prompt already set)"
                fi
                shift ;;
        esac
    done

    local selectors=0
    [[ -n "$base" ]]   && selectors=$((selectors + 1))
    [[ -n "$commit" ]] && selectors=$((selectors + 1))
    $uncommitted       && selectors=$((selectors + 1))
    [ "$selectors" -gt 1 ] && fail_usage "--base, --commit, and --uncommitted are mutually exclusive"
    check_dir

    RUN_DIR="$DIR"             # review has no -C flag; cd instead
    STDOUT_FILE="$OUTPUT_FILE" # review prints findings to stdout (no -o)
    SANDBOX="read-only"        # also carried by capacity recovery
    CMD=("$CODEX_BIN" exec review --skip-git-repo-check)
    CMD+=(-c 'features.search_tool=true')
    # review has no -s flag and CLONES the current config's sandbox — without
    # this override a full-access user config makes "read-only review" a lie
    CMD+=(-c 'sandbox_mode="read-only"')
    [[ -n "$base" ]]   && CMD+=(--base "$base")
    [[ -n "$commit" ]] && CMD+=(--commit "$commit")
    $uncommitted       && CMD+=(--uncommitted)
    [[ -n "$PROMPT" ]] && CMD+=(-- "$PROMPT")

    announce review
    run_with_recovery
}

# ── Transfer (Claude transcript → persistent Codex thread) ──────────

transfer_codex() {
    PROMPT=""
    DIR=""
    MODEL=""
    EFFORT=""
    SCHEMA=""
    local source="" use_latest=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) need_value "$1" $#; source="$2"; shift 2 ;;
            --latest) use_latest=true; shift ;;
            --dir)    need_value "$1" $#; DIR="$2"; shift 2 ;;
            --*)      fail_usage "unknown flag '$1'" ;;
            *)        fail_usage "unexpected argument '$1' (transfer takes --source/--latest/--dir only)" ;;
        esac
    done
    check_dir
    if [[ -n "$source" ]] && $use_latest; then
        fail_usage "--source and --latest are mutually exclusive"
    fi
    command -v python3 >/dev/null 2>&1 || fail_usage "transfer requires python3 (used for the app-server JSON-RPC bridge)"

    if [[ -z "$source" ]] && $use_latest; then
        # Newest main-session transcript (subagent transcripts live one level deeper)
        source=$(ls -t "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null | head -1)
    fi
    [[ -z "$source" ]] && fail_usage "specify --source <claude-transcript.jsonl> or --latest"

    local real
    real=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$source" 2>/dev/null)
    if [[ -z "$real" || ! -f "$real" ]]; then
        ensure_announced
        echo "[codex] transcript not found: $source — codex was not invoked."
        emit_result_block session_not_found unknown
        exit 4
    fi
    case "$real" in
        *.jsonl) : ;;
        *) fail_usage "transfer source must be a .jsonl Claude transcript: $real" ;;
    esac
    local projects_real
    projects_real=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$HOME/.claude/projects" 2>/dev/null)
    case "$real" in
        "$projects_real/"*) : ;;
        *) fail_usage "codex imports Claude sessions only from $HOME/.claude/projects — got: $real" ;;
    esac

    CMD=(python3 "$SCRIPT_DIR/transfer-bridge.py" "$real" "${DIR:-$PWD}" "$OUTPUT_FILE")
    announce transfer
    exec_with_heartbeat
    # For transfer, CODEX_EXIT is the bridge's exit code: the app-server is a
    # long-lived process the bridge terminates by design.
    codex_succeeded && finish_ok ok
    finish_fail transfer_failed 1
}

# ── Main ─────────────────────────────────────────────────────────────

# help is the sole block-less path — handle it before temp allocation so an
# unusable TMPDIR can't turn it into a usage error
case "${1:-}" in help|--help|-h) usage; exit 0 ;; esac

# Temp allocation + signal wiring live down here so every failure path —
# including these — can use the contract-shaped emitters defined above.
OUTPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/codex-output.XXXXXX") || fail_usage "cannot create temp files (TMPDIR unusable?)"
STDERR_FILE=$(mktemp "${TMPDIR:-/tmp}/codex-stderr.XXXXXX") || fail_usage "cannot create temp files (TMPDIR unusable?)"

# Signals also honour the result contract: kill the child, then emit a block
# (CODEX_STATUS: interrupted, exit 130) so consumers never see a bare cut-off.
on_signal() {
    trap - INT TERM HUP
    if [ -n "$CODEX_PID" ]; then
        # Bounded escalation: a child that ignores TERM must not block exit 130
        kill "$CODEX_PID" 2>/dev/null
        local i=0
        while [ "$i" -lt 50 ] && kill -0 "$CODEX_PID" 2>/dev/null; do
            sleep 0.1
            i=$((i + 1))
        done
        kill -0 "$CODEX_PID" 2>/dev/null && kill -9 "$CODEX_PID" 2>/dev/null
        wait "$CODEX_PID" 2>/dev/null
    fi
    CODEX_EXIT_CODE="${CODEX_EXIT_CODE:-130}"
    local sid=""
    [ -n "$STDERR_FILE" ] && sid=$(extract_session_id "$STDERR_FILE")
    emit_result_block interrupted "$sid"
    exit 130
}
trap on_signal INT TERM HUP

[[ $# -lt 1 ]] && fail_usage "no command given (use: run, think, resume, review, transfer — see 'help')"

case "$1" in
    run)      MODE_NAME=run;      shift; run_codex "$@" ;;
    think)    MODE_NAME=think;    shift; think_codex "$@" ;;
    resume)   MODE_NAME=resume;   shift; resume_codex "$@" ;;
    review)   MODE_NAME=review;   shift; review_codex "$@" ;;
    transfer) MODE_NAME=transfer; shift; transfer_codex "$@" ;;
    help|--help|-h) usage; exit 0 ;;
    *) fail_usage "unknown command '$1' (use: run, think, resume, review, transfer — see 'help')" ;;
esac
