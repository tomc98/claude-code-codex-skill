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
-c model="gpt-6-astra"
-c model_reasoning_effort="medium"     # low|medium|high|xhigh|max|ultra
-c service_tier="default"              # default|fast — codex.sh pins "default"; --fast is Tom's-explicit-yes only
-c model_reasoning_summary="detailed"   # auto|concise|detailed|none

# Web search (for exec mode — --search flag is interactive-only)
-c features.search_tool=true

# Sandbox
-c sandbox_mode="workspace-write"

# Behavior
-c approval_policy="never"              # untrusted|on-failure|on-request|never
```

## Models

GPT-6 Astra is a single slug; GPT-5.6 ships as three capability tiers — the generation number and the tier name advance independently.

| Model | Use Case |
|-------|----------|
| `gpt-6-astra` | Frontier (2026-09-03). **The default** — codex.sh pins it; needs codex-cli ≥ 0.153.1. 2.5× Sol pricing; 272K Codex-backend window |
| `gpt-5.6-sol` | Previous flagship agentic coding model; the cheaper fallback |
| `gpt-5.6-terra` | Balanced everyday work, lower cost |
| `gpt-5.6-luna` | Fast and affordable; caps at `max` effort; the ultra subagent tier |
| `gpt-5.5` | Previous frontier model |
| `gpt-5.4` | Strong everyday coding |
| `gpt-5.4-mini` | Small, fast, cost-efficient |
| `gpt-5.3-codex-spark` | Ultra-fast, text-only; not available via API |

There is no bare `gpt-5.6` slug — always name a tier. There is no `gpt-6` slug either — it is `gpt-6-astra`.

To see exactly what your account can reach, read `~/.codex/models_cache.json`; the CLI refreshes it from OpenAI and it is the source of truth. Slugs that have aged out (`gpt-5.3-codex`, `gpt-5.5-pro`, `gpt-5.1-codex-mini`, `gpt-5.1-codex-max`) now fail with a 400.

## Reasoning Effort

| Level | Use Case |
|-------|----------|
| `low` | Quick edits |
| `medium` | Daily driver — codex.sh's pinned default |
| `high` | Complex tasks |
| `xhigh` | Maximum accuracy, benchmarks |
| `max` | Maximum single-turn depth for the hardest problems |
| `ultra` | Maximum depth + automatic task delegation to internal sub-agents |

codex.sh's default is `medium` (`CODEX_DEFAULT_EFFORT`). `ultra` runs on Astra, Sol and Terra — Luna caps at `max` (Astra+ultra verified 2026-09-05 on 0.153.3). `none` and `minimal` are **not** valid efforts and will 400.

Escalate to `ultra` only when the task warrants it: it spawns sub-agents, so token spend is markedly higher and less predictable. Consider pairing it with `rollout_token_budget`.

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
