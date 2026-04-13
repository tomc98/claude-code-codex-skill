#!/usr/bin/env bash
# codex.sh — Wrapper for non-interactive Codex CLI usage
# Runs codex exec, captures session ID and final message cleanly.
#
# Usage:
#   codex.sh run "prompt" [--dir PATH] [--model MODEL] [--effort LEVEL] [--sandbox MODE] [--image FILE] [--ephemeral] [--schema FILE] [--add-dir PATH]
#   codex.sh think "prompt" [--dir PATH] [--image FILE] [--ephemeral] [--schema FILE]
#   codex.sh resume [--session ID | --last] "prompt" [--dir PATH]
#   codex.sh review [--base BRANCH | --commit SHA | --uncommitted] ["custom instructions"]

set -eo pipefail

CODEX_BIN="${CODEX_BIN:-codex}"
OUTPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/codex-output.XXXXXX")
STDERR_FILE=$(mktemp "${TMPDIR:-/tmp}/codex-stderr.XXXXXX")

cleanup() {
    rm -f "$OUTPUT_FILE" "$STDERR_FILE"
}
trap cleanup EXIT

# ── Helpers ──────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
codex.sh — Non-interactive Codex CLI wrapper

Commands:
  run "prompt"                      Start a coding task (full-access sandbox)
  think "prompt"                    Deliberation/analysis (read-only + web search)
  resume --session ID "prompt"      Resume a specific session
  resume --last "prompt"            Resume the most recent session
  review                            Review uncommitted changes
  review --base main                Review against a base branch
  review --commit SHA               Review a specific commit

Options:
  --dir PATH         Working directory (default: current)
  --model MODEL      Override model (default: from config.toml)
  --effort LEVEL     Reasoning effort: minimal|low|medium|high|xhigh
  --sandbox MODE     Sandbox: read-only|workspace-write|danger-full-access
  --image FILE       Attach an image (repeatable)
  --ephemeral        Don't persist session to disk
  --schema FILE      Validate output against JSON Schema
  --add-dir PATH     Grant write access to an additional directory
  --all              Show sessions from all directories (resume only)
EOF
    exit 1
}

extract_session_id() {
    grep -m1 'session id:' "$1" 2>/dev/null | sed 's/.*session id: //' || echo "unknown"
}

emit_result() {
    local session_id
    session_id=$(extract_session_id "$STDERR_FILE")

    echo "SESSION: $session_id"
    echo "---"

    if [[ -s "$OUTPUT_FILE" ]]; then
        cat "$OUTPUT_FILE"
    else
        echo "(No output captured — check stderr for errors)"
        echo ""
        grep -E '(ERROR|error|Warning)' "$STDERR_FILE" 2>/dev/null || true
    fi
}

# ── Shared flag parser ───────────────────────────────────────────────

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
            --dir)       DIR="$2"; shift 2 ;;
            --model)     MODEL="$2"; shift 2 ;;
            --effort)    EFFORT="$2"; shift 2 ;;
            --sandbox)   SANDBOX="$2"; shift 2 ;;
            --image)     IMAGES+=("$2"); shift 2 ;;
            --ephemeral) EPHEMERAL=true; shift ;;
            --schema)    SCHEMA="$2"; shift 2 ;;
            --add-dir)   ADD_DIRS+=("$2"); shift 2 ;;
            --search)    SEARCH=true; shift ;;
            --*)         shift ;;
            *)
                if [[ -z "$PROMPT" ]]; then
                    PROMPT="$1"
                fi
                shift ;;
        esac
    done
}

build_cmd() {
    # Builds CMD array from parsed globals. Caller sets defaults before calling.
    CMD=("$CODEX_BIN" exec --skip-git-repo-check)
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
    CMD+=("$PROMPT")
}

# ── Run ──────────────────────────────────────────────────────────────

run_codex() {
    parse_common_flags "$@"

    if [[ -z "$PROMPT" ]]; then
        echo "ERROR: No prompt provided" >&2
        exit 1
    fi

    # Defaults for run: full-access sandbox, web search on
    [[ -z "$SANDBOX" ]] && SANDBOX="danger-full-access"
    SEARCH=true

    build_cmd

    "${CMD[@]}" </dev/null >/dev/null 2>"$STDERR_FILE" || true
    emit_result
}

# ── Think ────────────────────────────────────────────────────────────

think_codex() {
    parse_common_flags "$@"

    if [[ -z "$PROMPT" ]]; then
        echo "ERROR: No prompt provided" >&2
        exit 1
    fi

    # Defaults for think: read-only sandbox, web search on, ephemeral
    [[ -z "$SANDBOX" ]] && SANDBOX="read-only"
    SEARCH=true
    EPHEMERAL=true

    build_cmd

    "${CMD[@]}" </dev/null >/dev/null 2>"$STDERR_FILE" || true
    emit_result
}

# ── Resume ───────────────────────────────────────────────────────────

resume_codex() {
    local prompt=""
    local session_id=""
    local use_last=false
    local dir=""
    local show_all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session)  session_id="$2"; shift 2 ;;
            --last)     use_last=true; shift ;;
            --dir)      dir="$2"; shift 2 ;;
            --all)      show_all=true; shift ;;
            --*)        shift ;;
            *)
                if [[ -z "$prompt" ]]; then
                    prompt="$1"
                fi
                shift ;;
        esac
    done

    # cd into target dir if specified (resume doesn't support -C)
    [[ -n "$dir" ]] && cd "$dir"

    local -a cmd=("$CODEX_BIN" exec resume --skip-git-repo-check)
    $show_all && cmd+=(--all)

    if [[ -n "$session_id" ]]; then
        cmd+=("$session_id")
    elif $use_last; then
        cmd+=(--last)
    else
        echo "ERROR: Specify --session ID or --last" >&2
        exit 1
    fi

    [[ -n "$prompt" ]] && cmd+=("$prompt")

    cmd+=(-o "$OUTPUT_FILE")
    "${cmd[@]}" </dev/null >/dev/null 2>"$STDERR_FILE" || true
    emit_result
}

# ── Review ───────────────────────────────────────────────────────────

review_codex() {
    local prompt=""
    local base=""
    local commit=""
    local uncommitted=false
    local dir=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base)        base="$2"; shift 2 ;;
            --commit)      commit="$2"; shift 2 ;;
            --uncommitted) uncommitted=true; shift ;;
            --dir)         dir="$2"; shift 2 ;;
            --*)           shift ;;
            *)
                if [[ -z "$prompt" ]]; then
                    prompt="$1"
                fi
                shift ;;
        esac
    done

    [[ -n "$dir" ]] && cd "$dir"

    local -a cmd=("$CODEX_BIN" exec review --skip-git-repo-check)
    # Enable web search for reviews too
    cmd+=(-c 'features.search_tool=true')
    [[ -n "$base" ]]   && cmd+=(--base "$base")
    [[ -n "$commit" ]] && cmd+=(--commit "$commit")
    $uncommitted       && cmd+=(--uncommitted)
    [[ -n "$prompt" ]] && cmd+=("$prompt")

    "${cmd[@]}" </dev/null >"$OUTPUT_FILE" 2>&1 || true

    if [[ -s "$OUTPUT_FILE" ]]; then
        local session_id
        session_id=$(extract_session_id "$OUTPUT_FILE")
        echo "SESSION: $session_id"
        echo "---"
        cat "$OUTPUT_FILE"
    else
        echo "(No review output captured)"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && usage

case "$1" in
    run)      shift; run_codex "$@" ;;
    think)    shift; think_codex "$@" ;;
    resume)   shift; resume_codex "$@" ;;
    review)   shift; review_codex "$@" ;;
    help|--help|-h) usage ;;
    *) echo "ERROR: Unknown command '$1'. Use: run, think, resume, review" >&2; exit 1 ;;
esac
