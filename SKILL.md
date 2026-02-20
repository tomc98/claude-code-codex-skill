---
name: codex
description: Delegate tasks to OpenAI Codex (GPT-5.3) as background tasks for precision coding, code review, and complex implementation. Always launch in background (run_in_background=true), continue working, then collect results with TaskOutput when needed.
allowed-tools: Bash, Read, Grep, Glob, TaskOutput, Edit, Write
---

# Codex — Your Coding Teammate

> Paths below use `{base}` as shorthand for this skill's base directory, which is provided automatically via the "Base directory for this skill" context injected at the top of the prompt when the skill loads. Construct the full path from that value — do NOT rely on environment variables.

Codex is OpenAI's GPT-5.3-codex with xhigh reasoning. Treat it like a brilliant colleague you're handing a task to — just tell it what you need in plain language. The skill handles all the CLI plumbing.

## Default Behavior: Just Talk to It

When the user says `/codex` followed by anything, or when you decide to delegate to Codex:

1. **Pass the user's intent as-is.** Don't over-engineer the prompt. Codex is smart — it reads files, understands context, and figures things out. Just relay what the user wants.
2. **Add context Codex can't see** — the working directory, relevant file paths you've discovered, framework info, constraints the user mentioned earlier in conversation. Weave this into the prompt naturally.
3. **Always run in background** (`run_in_background: true`). Then either continue working or wait with `TaskOutput(block=true)` depending on whether you have other useful work to do.

### The Simple Pattern

```python
# Launch — just describe what you need
Bash(command='{base}/scripts/codex.sh run "Refactor the auth middleware in src/auth/ to use async/await instead of callbacks. Follow the pattern in src/api/routes.ts." --dir /path/to/project',
     run_in_background=True)
# → returns task_id

# Collect when ready
TaskOutput(task_id="...", block=True, timeout=300000)
```

That's it. No templates, no structured sections — unless the task genuinely benefits from them.

### When to Add Structure

For complex multi-requirement tasks, a structured prompt helps Codex stay focused. Use your judgment — if you'd write bullet points for a human colleague, do the same for Codex:

```
Implement rate limiting for the /api/upload endpoint.

Context:
- Express 5 app, see src/server.ts for setup
- Existing rate limiter in src/middleware/rateLimit.ts for reference
- Redis client already configured in src/lib/redis.ts

Requirements:
- 10 requests per minute per authenticated user
- 3 requests per minute for anonymous
- Return 429 with Retry-After header

Don't modify the existing rate limiter — create a new one for uploads.
```

But for straightforward asks — "review this code", "fix the bug in parser.ts", "add tests for the User model" — just say that.

## Commands

```bash
# Run a task (default — most common)
{base}/scripts/codex.sh run "your prompt" --dir /path/to/project

# Code review — uncommitted changes
{base}/scripts/codex.sh review

# Code review — against a branch
{base}/scripts/codex.sh review --base main

# Code review — specific commit
{base}/scripts/codex.sh review --commit abc123

# Code review — with focus areas
{base}/scripts/codex.sh review --base main "Focus on security and error handling"

# Resume a previous session (continue the conversation)
{base}/scripts/codex.sh resume --last "Actually, also handle the edge case where..."

# Resume a specific session
{base}/scripts/codex.sh resume --session <SESSION_ID> "Next instruction"

# Read-only mode (analysis only, no file changes)
{base}/scripts/codex.sh run "Analyze the dependency graph" --sandbox read-only

# Override model or reasoning effort
{base}/scripts/codex.sh run "task" --model gpt-5.3-codex --effort xhigh
```

## When to Use Codex

- **Precision code changes** — complex refactors, tricky algorithms, security-sensitive code
- **Code review** — thorough analysis of diffs, PRs, or uncommitted changes
- **Second opinion** — validation from a different model's perspective
- **Long-running implementation** — background work while you handle other things
- **Deep reasoning tasks** — anything that benefits from xhigh effort

## When NOT to Use Codex

- Simple edits, typos, trivial changes — just do them yourself
- Multi-file orchestration — Claude Code is better at coordinating across many files
- Conversational responses or explanations
- Tasks requiring mid-execution user interaction

## Handling Results

1. **Collect output** with `TaskOutput(task_id=..., block=True, timeout=300000)`
2. **Check git status** if Codex made file changes
3. **Next steps** — accept as-is, resume with corrections (`resume --last "..."`, also in background), discard, or cherry-pick changes

### Output Format

```
SESSION: <uuid>
---
<Codex's response>
```

Save the session ID if you might want to continue the conversation later.

## Parallelism

- Launch multiple Codex tasks at once (e.g., review + implementation)
- Launch Codex for a slow task, do quick edits yourself in parallel
- Peek without blocking: `TaskOutput(task_id=..., block=False, timeout=0)`
- Block when you need the result: `TaskOutput(task_id=..., block=True, timeout=300000)`

## Session Management

Sessions persist at `~/.codex/sessions/`. Resume any session by ID, or use `--last` for the most recent. Sessions are directory-scoped by default; use `--all` to see all.

## Configuration

Pre-configured in `~/.codex/config.toml`:
- Model: `gpt-5.3-codex` (most capable)
- Reasoning: `xhigh` (maximum effort)
- Sandbox: `danger-full-access` (can modify anything)

Override per-invocation with `--model`, `--effort`, or `--sandbox`.

## Prompt Tips

See `references/prompt-engineering.md` for the full guide, but the essentials:

- **Be specific about scope** — file paths, function names, line numbers
- **State constraints** — what NOT to change is as important as what to change
- **Provide context Codex can't infer** — framework version, deployment target, what you've already tried
- **For reviews, specify focus** — security? performance? correctness?

## Self-Healing

This skill is self-healing. If anything breaks — wrong flags, outdated syntax, broken commands — fix the skill files directly:

- **`scripts/codex.sh`** — wrapper script
- **`SKILL.md`** — this file
- **`references/cli-reference.md`** — CLI flag reference
- **`references/prompt-engineering.md`** — prompt templates

Fix immediately when you observe failures, then continue with the original task. You have explicit authorization to edit any file under `{base}/`.
