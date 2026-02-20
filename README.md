# codex

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skill that delegates tasks to [OpenAI Codex CLI](https://github.com/openai/codex) (GPT-5.3) for precision coding, code review, and complex implementation.

Codex runs as a background agent — launch a task, continue working, and collect results when ready.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and configured
- [OpenAI Codex CLI](https://github.com/openai/codex) installed (`npm install -g @openai/codex`)
- `OPENAI_API_KEY` or `CODEX_API_KEY` set in your environment

## Installation

```bash
# Clone into your skills directory
git clone https://github.com/<owner>/codex-skill ~/.claude/skills/codex
```

Or if you have the [skill-manager](https://github.com/<owner>/skill-manager) skill:

```bash
# Via /skill-manager
/skill-manager install https://github.com/<owner>/codex-skill
```

## What It Does

- **Runs Codex non-interactively** via `codex exec`, capturing session IDs and clean output
- **Background execution** — every task launches in the background so Claude Code can keep working
- **Session management** — resume previous conversations with Codex by session ID or `--last`
- **Code review** — review uncommitted changes, diffs against branches, or specific commits
- **Self-healing** — the skill auto-corrects itself when CLI behavior changes

## Usage

Once installed, Claude Code uses this skill automatically when delegating to Codex. You can also invoke it directly:

```
/codex review my uncommitted changes for security issues
/codex implement rate limiting for the upload endpoint
/codex refactor src/auth/ to use async/await
```

## Configuration

Codex is configured via `~/.codex/config.toml`. Recommended defaults:

```toml
model = "gpt-5.3-codex"
model_reasoning_effort = "xhigh"
sandbox_mode = "danger-full-access"
```

Override per-invocation with `--model`, `--effort`, or `--sandbox` flags.

## File Structure

```
codex/
├── SKILL.md                         # Skill prompt (loaded by Claude Code)
├── scripts/
│   └── codex.sh                     # Wrapper script for non-interactive Codex
└── references/
    ├── cli-reference.md             # Codex CLI flag reference
    └── prompt-engineering.md        # Guide for crafting effective prompts
```

## License

MIT
