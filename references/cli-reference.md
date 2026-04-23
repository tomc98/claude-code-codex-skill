# Codex CLI Quick Reference

## Commands

| Command | Description |
|---------|-------------|
| `codex exec "prompt"` | Run non-interactively (headless) |
| `codex exec review` | Run code review non-interactively |
| `codex exec resume` | Resume a previous session non-interactively |
| `codex resume` | Resume interactively (TUI) |
| `codex fork` | Fork/branch a previous session |

## Key Flags for `codex exec`

| Flag | Description |
|------|-------------|
| `-o FILE` | Write final message to file |
| `--json` | Output JSONL event stream |
| `-m MODEL` | Override model |
| `-C DIR` | Set working directory |
| `-s MODE` | Sandbox: `read-only`, `workspace-write`, `danger-full-access` |
| `-i FILE` | Attach image(s) to prompt (repeatable) |
| `--full-auto` | workspace-write + relaxed approvals |
| `--ephemeral` | Don't persist session to disk |
| `--output-schema FILE` | Validate output against JSON Schema |
| `--add-dir DIR` | Grant write access to additional directory |
| `--skip-git-repo-check` | Run outside git repos |
| `--color never` | Disable ANSI colors |

## Key Flags for `codex exec review`

| Flag | Description |
|------|-------------|
| `--uncommitted` | Review staged + unstaged + untracked |
| `--base BRANCH` | Review against base branch |
| `--commit SHA` | Review a specific commit |
| `--title TEXT` | Add commit title to summary |

## Key Flags for `codex exec resume`

| Flag | Description |
|------|-------------|
| `SESSION_ID` | Resume specific session |
| `--last` | Resume most recent session |
| `--all` | Show sessions from all directories |
| `PROMPT` | Send follow-up prompt after resume |

## Config Overrides (`-c`)

```bash
# Model and reasoning
-c model="gpt-5.5"
-c model_reasoning_effort="xhigh"      # minimal|low|medium|high|xhigh
-c model_reasoning_summary="detailed"   # auto|concise|detailed|none

# Web search (for exec mode — --search flag is interactive-only)
-c features.search_tool=true

# Sandbox
-c sandbox_mode="workspace-write"

# Behavior
-c approval_policy="never"              # untrusted|on-failure|on-request|never
```

## Models

| Model | Use Case |
|-------|----------|
| `gpt-5.5` | Best coding model, xhigh reasoning + fast mode |
| `gpt-5.5-pro` | Maximum performance, Pro/Enterprise only |
| `gpt-5.4` | Previous best, still excellent |
| `gpt-5.3-codex` | Older generation |
| `gpt-5.3-codex-spark` | Ultra-fast, ChatGPT Pro only |
| `gpt-5.1-codex-mini` | Cost-effective, fast |
| `gpt-5.1-codex-max` | Long-horizon agentic tasks |

## Reasoning Effort

| Level | Use Case |
|-------|----------|
| `minimal` | Fastest, simple tasks |
| `low` | Quick edits |
| `medium` | Daily driver |
| `high` | Complex tasks |
| `xhigh` | Maximum accuracy, benchmarks |

## Sandbox Modes

| Mode | Behavior |
|------|----------|
| `read-only` | Can read files, run read-only commands. Cannot write. Used by `think`. |
| `workspace-write` | Can read + write within the project directory only. Sandboxed. |
| `danger-full-access` | Full system access. No sandbox. Used by `run`. |

## Web Search in Exec Mode

The `--search` flag only works in interactive mode. For `codex exec`, enable web search via config override:

```bash
codex exec -c 'features.search_tool=true' "Search the web for..."
```

This is handled automatically by `codex.sh` — both `think` and `run` commands enable web search by default.

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `CODEX_API_KEY` / `OPENAI_API_KEY` | Authentication |
| `CODEX_HOME` | Override config dir (default: `~/.codex`) |

## Session Storage

Sessions stored at `~/.codex/sessions/` as JSONL files, organized by date. Use `--ephemeral` to skip persistence.

## Output Modes

- **Default**: Progress on stderr, final message on stdout
- **`--json`**: JSONL event stream on stdout
- **`-o FILE`**: Final message written to file
- **`--output-schema`**: Final message validated against JSON Schema
