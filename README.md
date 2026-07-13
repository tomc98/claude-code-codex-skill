# codex

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skill that delegates tasks to [OpenAI Codex CLI](https://github.com/openai/codex) (GPT-5.6) for precision coding, code review, deliberation, and complex implementation.

Codex runs as a background agent — launch a task, continue working, and collect results when ready.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and configured
- [OpenAI Codex CLI](https://github.com/openai/codex) installed (`npm install -g @openai/codex`)
- `OPENAI_API_KEY` or `CODEX_API_KEY` set in your environment

## Installation

```bash
# Clone into your skills directory
git clone https://github.com/tomc98/claude-code-codex-skill ~/.claude/skills/codex
```

Or if you have the [skill-manager](https://github.com/tomc98/claude-code-skill-manager) skill:

```bash
# Via /skill-manager
/skill-manager install https://github.com/tomc98/claude-code-codex-skill
```

## What It Does

- **Two modes**: `think` (read-only deliberation + web search) and `run` (full-access coding agent) — both persist sessions and are resumable
- **Honest, machine-parseable results** — every invocation emits a contract block (`CODEX_STATUS`, real exit codes `0/1/2/3/4/130`, `SESSION:` id, `---` delimiter) on every path, including usage errors and signals. Failures are never masked as empty successes
- **Automatic failure recovery** — "model at capacity" / stream errors resume the **same session** carrying the same model, effort, schema, and sandbox (never a fallback model, never a silent re-run) and deliver the answer Codex already computed, flagged `ok_recovered`
- **Fail-closed session identity** — resume (by id or `--last`) refuses to deliver output from a session it can't verify, and runs in the session's own recorded working directory
- **Enforced sandboxes** — `think` and `review` are genuinely read-only even when your Codex config defaults to full access
- **Heartbeat** — long runs tick a `[codex Ns]` progress line every 30s, so background tasks are visibly alive
- **Claude → Codex session transfer** — `transfer` imports a Claude Code transcript into a persistent Codex thread via the app-server protocol; continue it with `codex resume <id>`
- **Canonical review schema** — a standard findings shape (severity, file, line range, confidence 0–1, recommendation) for review-type passes via `--schema`
- **Web search, images, extra write dirs** — search on by default; `--image` and `--add-dir` everywhere
- **Regression matrix** — `tests/run-tests.sh` exercises 40 scenarios / 167 assertions against a stubbed Codex (no tokens spent), covering every failure path above
- **Self-healing** — the skill auto-corrects itself when CLI behavior changes

## Usage

Once installed, Claude Code uses this skill automatically when delegating to Codex. You can also invoke it directly:

```
/codex think is this architecture scalable?
/codex review my uncommitted changes for security issues
/codex implement rate limiting for the upload endpoint
/codex refactor src/auth/ to use async/await
/codex --transfer      # hand the current Claude session to a Codex thread
```

## Configuration

Codex is configured via `~/.codex/config.toml`. Recommended defaults:

```toml
model = "gpt-5.6-sol"
model_reasoning_effort = "xhigh"
sandbox_mode = "danger-full-access"

[features]
fast_mode = true
```

Override per-invocation with `--model`, `--effort`, or `--sandbox` flags.

## File Structure

```
codex/
├── SKILL.md                         # Skill prompt (loaded by Claude Code)
├── README.md                        # This file
├── scripts/
│   ├── codex.sh                     # Wrapper: contract, recovery, sandbox enforcement
│   └── transfer-bridge.py           # Claude→Codex session transfer (app-server JSON-RPC)
├── schemas/
│   └── review-output.schema.json    # Canonical review findings schema
├── tests/
│   ├── run-tests.sh                 # Regression matrix (stubbed codex, no tokens)
│   └── stub-codex.sh                # Fake codex CLI + app-server for the matrix
└── references/
    ├── cli-reference.md             # Codex CLI flag reference
    └── prompt-engineering.md        # Guide for crafting effective prompts
```

After any change to `scripts/codex.sh`, keep the matrix green:

```bash
tests/run-tests.sh
```

## Credits

The canonical review schema and the session-transfer protocol usage are adapted
from OpenAI's [codex-plugin-cc](https://github.com/openai/codex-plugin-cc)
(Apache-2.0).

## License

MIT
