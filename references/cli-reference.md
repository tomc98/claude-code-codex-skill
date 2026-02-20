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
| `--full-auto` | workspace-write + relaxed approvals |
| `--skip-git-repo-check` | Run outside git repos |
| `--output-schema FILE` | Validate output against JSON Schema |
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
-c model="gpt-5.3-codex"
-c model_reasoning_effort="xhigh"      # minimal|low|medium|high|xhigh
-c model_reasoning_summary="detailed"   # auto|concise|detailed|none

# Sandbox
-c sandbox_mode="workspace-write"

# Behavior
-c approval_policy="never"              # untrusted|on-failure|on-request|never
```

## Models

| Model | Use Case |
|-------|----------|
| `gpt-5.3-codex` | Best coding model, 25% faster than 5.2 |
| `gpt-5.3-codex` | Previous best, still excellent |
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

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `CODEX_API_KEY` / `OPENAI_API_KEY` | Authentication |
| `CODEX_HOME` | Override config dir (default: `~/.codex`) |

## Session Storage

Sessions stored at `~/.codex/sessions/` as JSONL files, organized by date.

## Output Modes

- **Default**: Progress on stderr, final message on stdout
- **`--json`**: JSONL event stream on stdout
- **`-o FILE`**: Final message written to file
- **`--output-schema`**: Final message validated against JSON Schema
