#!/usr/bin/env bash
# codex.sh — Wrapper for non-interactive Codex CLI usage
# Runs codex exec, captures session ID and final message cleanly.
#
# Usage:
#   codex.sh run "prompt" [--dir PATH] [--model MODEL] [--effort LEVEL] [--sandbox MODE]
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
  run "prompt"                      Start a new Codex task
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
  --all              Show sessions from all directories (resume only)
EOF
    exit 1
}

extract_session_id() {
    # Extract session ID from codex stderr header output
    grep -m1 'session id:' "$1" 2>/dev/null | sed 's/.*session id: //' || echo "unknown"
}

emit_result() {
    # Print session ID and final output
    local session_id
    session_id=$(extract_session_id "$STDERR_FILE")

    echo "SESSION: $session_id"
    echo "---"

    if [[ -s "$OUTPUT_FILE" ]]; then
        cat "$OUTPUT_FILE"
    else
        echo "(No output captured — check stderr for errors)"
        echo ""
        # Show relevant error lines from stderr
        grep -E '(ERROR|error|Warning)' "$STDERR_FILE" 2>/dev/null || true
    fi
}

# ── Run ──────────────────────────────────────────────────────────────

run_codex() {
    local prompt=""
    local dir=""
    local model=""
    local effort=""
    local sandbox=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir)      dir="$2"; shift 2 ;;
            --model)    model="$2"; shift 2 ;;
            --effort)   effort="$2"; shift 2 ;;
            --sandbox)  sandbox="$2"; shift 2 ;;
            --*)        shift ;;
            *)
                if [[ -z "$prompt" ]]; then
                    prompt="$1"
                fi
                shift ;;
        esac
    done

    if [[ -z "$prompt" ]]; then
        echo "ERROR: No prompt provided" >&2
        exit 1
    fi

    local -a cmd=("$CODEX_BIN" exec --skip-git-repo-check)
    [[ -n "$dir" ]]     && cmd+=(-C "$dir")
    [[ -n "$model" ]]   && cmd+=(-m "$model")
    [[ -n "$effort" ]]  && cmd+=(-c "model_reasoning_effort=\"$effort\"")
    [[ -n "$sandbox" ]] && cmd+=(-s "$sandbox")
    cmd+=(-o "$OUTPUT_FILE")
    cmd+=("$prompt")

    # Run: stdout suppressed (duplicated by -o), stderr captured for session ID
    "${cmd[@]}" >/dev/null 2>"$STDERR_FILE" || true

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

    local -a cmd=("$CODEX_BIN" exec resume --skip-git-repo-check)
    [[ -n "$dir" ]] && cmd+=(-C "$dir")
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

    # Resume doesn't support -o, capture stdout directly
    "${cmd[@]}" >"$OUTPUT_FILE" 2>"$STDERR_FILE" || true

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

    # cd into target dir if specified (review doesn't support -C)
    [[ -n "$dir" ]] && cd "$dir"

    local -a cmd=("$CODEX_BIN" exec review --skip-git-repo-check)
    [[ -n "$base" ]]   && cmd+=(--base "$base")
    [[ -n "$commit" ]] && cmd+=(--commit "$commit")
    $uncommitted       && cmd+=(--uncommitted)
    [[ -n "$prompt" ]] && cmd+=("$prompt")

    # Review streams everything to stderr; capture both and filter for the review output
    "${cmd[@]}" >"$OUTPUT_FILE" 2>&1 || true

    if [[ -s "$OUTPUT_FILE" ]]; then
        # Extract session ID
        local session_id
        session_id=$(extract_session_id "$OUTPUT_FILE")
        echo "SESSION: $session_id"
        echo "---"
        # Show the last codex message (after the last "codex" speaker label)
        # Fall back to showing everything after the header if no clear message
        local last_msg
        last_msg=$(awk '/^codex$/{found=NR} END{if(found) {c=0; for(i=found+1;i<=NR;i++) c++}}' "$OUTPUT_FILE")
        # Just show the full output — the agent can parse what it needs
        cat "$OUTPUT_FILE"
    else
        echo "(No review output captured)"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && usage

case "$1" in
    run)      shift; run_codex "$@" ;;
    resume)   shift; resume_codex "$@" ;;
    review)   shift; review_codex "$@" ;;
    help|--help|-h) usage ;;
    *) echo "ERROR: Unknown command '$1'. Use: run, resume, review" >&2; exit 1 ;;
esac
