---
name: codex
description: Delegate tasks to OpenAI Codex (GPT-5.6) as background tasks for precision coding, code review, deliberation, and complex implementation. Always launch in background (run_in_background=true), continue working, then collect results with TaskOutput when needed.
allowed-tools: Bash, Read, Grep, Glob, TaskOutput, Edit, Write
---

# Codex

> Paths below use `{base}` as shorthand for this skill's base directory, provided automatically at the top of the prompt when the skill loads.

Codex is GPT-5.6 — a different model with a different reasoning manifold than Claude. It catches things you miss, thinks about problems differently, and arrives at solutions from a different angle. Use it as a genuine second brain, not just a subprocess. Its opinions, reviews, and implementations carry independent signal — when Codex disagrees with your approach, that disagreement is valuable.

GPT-5.6 ships as three tiers. `gpt-5.6-sol` is the default and the one you want almost always.

| Tier | Slug | Use it for |
|------|------|-----------|
| **Sol** | `gpt-5.6-sol` | Flagship. The default — deep reasoning, review, hard implementation |
| **Terra** | `gpt-5.6-terra` | Balanced everyday work at lower cost |
| **Luna** | `gpt-5.6-luna` | Fast and cheap; simple, repeatable tasks |

Two modes of operation:

| Mode | Command | Sandbox | Web | Sessions | Purpose |
|------|---------|---------|-----|----------|---------|
| **think** | `think` | read-only | yes | ephemeral | Analysis, deliberation, research, review, second opinions |
| **run** | `run` | full-access | yes | persisted | Implementation, coding, refactoring, bug fixes |

**Choose think** when the user wants opinions, analysis, or research — no files will be modified.
**Choose run** when the user wants code changes.
When unclear, default to **run**.

## Usage

```bash
# Think (read-only + web search)
{base}/scripts/codex.sh think "prompt" --dir /path/to/project
{base}/scripts/codex.sh think "prompt" --image screenshot.png --dir /project

# Run (full-access + web search)
{base}/scripts/codex.sh run "prompt" --dir /path/to/project
{base}/scripts/codex.sh run "prompt" --image mockup.png --dir /project
{base}/scripts/codex.sh run "prompt" --schema schema.json --dir /project
{base}/scripts/codex.sh run "prompt" --add-dir /other/path --dir /project

# Review (read-only, specialized)
{base}/scripts/codex.sh review --base main "Focus on security"
{base}/scripts/codex.sh review --commit abc123
{base}/scripts/codex.sh review --uncommitted

# Resume a previous run session
{base}/scripts/codex.sh resume --last "follow-up instruction"
{base}/scripts/codex.sh resume --session <SESSION_ID> "follow-up"
```

**Flags:** `--dir`, `--model`, `--effort`, `--sandbox`, `--image`, `--ephemeral`, `--schema`, `--add-dir`

## How to Invoke

1. **Always run in background.** Continue working or block on `TaskOutput`.
2. **Pass the user's intent as-is.** Don't over-engineer the prompt — Codex reads files and figures things out.
3. **Add context Codex can't see** — working directory, file paths, framework info, constraints from earlier in conversation.
4. **Collect results** with `TaskOutput(task_id=..., block=True, timeout=300000)`.
5. **After run mode**, check `git status` — Codex may have modified files.

```python
Bash(command='{base}/scripts/codex.sh think "Is this auth design scalable?" --dir /project',
     run_in_background=True)
# → task_id

TaskOutput(task_id="...", block=True, timeout=300000)
# → SESSION: <uuid>\n---\n<response>
```

For complex tasks, add structure (see `references/prompt-engineering.md` for templates). For simple asks, just describe what you need.

## When Codex Shines

- **Second opinion** — its different training means it spots different bugs, suggests different patterns, and flags things you'd overlook
- **Adversarial review** — use `think` to challenge your own implementation. A different model questioning your code is more valuable than self-review
- **Parallel expertise** — while you work on feature A, Codex implements feature B or researches approach C
- **Deep reasoning tasks** — xhigh effort on complex algorithms, security analysis, architecture decisions

## Reasoning Effort

`--effort` takes `low | medium | high | xhigh | max | ultra`. Default is `xhigh` for deep work.

`max` and `ultra` are new in GPT-5.6 and sit above `xhigh`:

- **`max`** — maximum depth within a single turn. Reach for it on genuinely hard problems where `xhigh` returned something shallow. Cost is higher but bounded.
- **`ultra`** — maximum depth *plus* automatic task delegation: Codex decomposes the problem and spawns internal sub-agents. Escalate to it only when the task genuinely warrants it — a large refactor, a subtle cross-cutting bug, an architecture decision with many interacting constraints. Token spend is substantially higher and harder to predict, so don't make it a default.

`ultra` requires Sol or Terra — `gpt-5.6-luna` caps at `max`. There is no `minimal` effort.

```bash
{base}/scripts/codex.sh think "why does this deadlock under load?" --effort ultra --dir /project
```

## When NOT to Use Codex

- Simple edits, typos, trivial changes — do them yourself
- Multi-file orchestration — you coordinate better across many files
- Conversational responses or explanations
- Tasks requiring mid-execution user interaction

## Parallelism

Launch multiple Codex tasks at once. Peek without blocking: `TaskOutput(task_id=..., block=False, timeout=0)`.

## Self-Healing

If anything breaks, fix the skill files directly — you have authorization to edit anything under `{base}/`:
- `scripts/codex.sh` — wrapper script
- `SKILL.md` — this file
- `references/cli-reference.md` — CLI flags
- `references/prompt-engineering.md` — prompt templates
