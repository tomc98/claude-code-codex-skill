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
| **think** | `think` | read-only | yes | persisted | Analysis, deliberation, research, review, second opinions |
| **run** | `run` | full-access | yes | persisted | Implementation, coding, refactoring, bug fixes |

All sessions persist (and are resumable) by default — pass `--ephemeral` to opt out, knowing that disables capacity recovery and resume.

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

# Resume a previous session (think and run both persist now)
{base}/scripts/codex.sh resume --last "follow-up instruction"
{base}/scripts/codex.sh resume --session <SESSION_ID> "follow-up"

# Transfer the CURRENT Claude session into a persistent Codex thread
# (source must be a transcript under ~/.claude/projects; SESSION: in the
#  output is the imported thread id — `codex resume <id>` continues the
#  conversation in the Codex TUI, or resume it via this wrapper)
{base}/scripts/codex.sh transfer --source <path-to-this-session.jsonl>
{base}/scripts/codex.sh transfer --latest   # newest transcript on this machine
```

**Flags:** `--dir`, `--model`, `--effort`, `--sandbox`, `--image`, `--ephemeral`, `--schema`, `--add-dir` · transfer: `--source`, `--latest`
**Env knobs:** `CODEX_HEARTBEAT_SECS` (30), `CODEX_RECOVER_ATTEMPTS` (3), `CODEX_RECOVER_BACKOFF` (30s, doubles), `CODEX_SESSIONS_DIR` (~/.codex/sessions), `CODEX_BIN` (codex), `CODEX_TRANSFER_TIMEOUT` (180s)

Transfer notes (requires `python3`): codex only imports real transcripts under `~/.claude/projects` (snapshot copies are rejected), so the live file is imported. The imported thread id comes from the import's own `itemTypeResults` target (authoritative — immune to stale ledger records and concurrent transfers), with a hash-keyed ledger lookup as the old-protocol fallback. The imported thread keeps the working directory recorded **in the transcript** (`--dir` is advisory), and `resume` honours it via the rollout. For transfer, `CODEX_EXIT` is the bridge's exit code since the app-server is a long-lived process the bridge terminates by design. `CODEX_SESSIONS_DIR` defaults to `$CODEX_HOME/sessions`.

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
```

For complex tasks, add structure (see `references/prompt-engineering.md` for templates). For simple asks, just describe what you need.

## Canonical review schema

For review-type `think` passes (adversarial reviews, omega A5-style bug hunts), prefer the canonical schema over ad-hoc ones so consumers can parse findings uniformly:

```bash
{base}/scripts/codex.sh think "<review prompt>" --schema {base}/schemas/review-output.schema.json --dir /project
```

Shape (adapted from openai/codex-plugin-cc, Apache-2.0): `verdict` (`approve`|`needs-attention`) · `summary` · `findings[]` with `severity` (critical/high/medium/low), `title`, `body`, `file`, `line_start`/`line_end`, `confidence` (0–1), `recommendation` · `next_steps[]`. Specialized passes with their own contract (e.g. omega's context-codex scope manifest) keep their dedicated schemas.

## Output contract & failure handling

Task output format (heartbeat lines appear while Codex runs, so a growing file = alive):

```
CODEX_START: mode=think model=default effort=xhigh dir=/project
[codex 30s] <last activity line>          # one line per 30s (CODEX_HEARTBEAT_SECS)
[codex recover] …                         # only when recovery kicks in
[stderr tail — last 40 lines]             # only on failure, always ABOVE the block
CODEX_EXIT: 0                             # codex process exit code
CODEX_STATUS: ok                          # see table below
SESSION: <uuid>
---
<final message — everything after the '---' line that follows SESSION:.
 Empty on failure; diagnostics never appear below the delimiter.>
```

| Wrapper exit | CODEX_STATUS | Meaning |
|---|---|---|
| 0 | `ok` / `ok_recovered` | Final message captured (possibly via same-session recovery) |
| 1 | `no_output` | Codex ran, no final message, cause unrecognised — stderr tail included |
| 2 | `usage_error` | Bad args, incl. a `--session` id that isn't a UUID |
| 3 | `capacity_exhausted` | A recoverable failure (at-capacity / stream error / 429) persisted through all recovery attempts — or no resumable session existed to recover from |
| 4 | `session_not_found` / `wrong_session` | Resume target missing on disk, or the session that answered couldn't be verified as the one requested |
| 1 | `transfer_failed` | `transfer` could not import (old CLI, timeout, per-item import failure) — diagnostics in the stderr tail |
| 130 | `interrupted` | Wrapper received INT/TERM/HUP — codex child killed, block still emitted |

When codex was never invoked (usage/preflight failures), the block carries sentinels: `CODEX_EXIT: -` and `SESSION: unknown` (`session_not_found` echoes the requested id when an explicit one was given; `--last` with no sessions and a missing transfer source report `unknown`). `resume --last` is resolved by the wrapper to the newest rollout on this machine (global, not cwd-filtered) and verified as strictly as `--session`. **Resume runs in the session's own recorded directory** (read from its rollout) unless `--dir` overrides — codex would otherwise re-root the thread at the caller's cwd. Prompts starting with `-` are safe: pass them after `--` and the wrapper forwards them positionally. The only block-less path is `codex.sh help` (usage text, exit 0).

**Sandbox guarantees:** `think` runs read-only (`-s read-only`); `review` is FORCED read-only via `-c sandbox_mode="read-only"` (codex's review clones the current config's sandbox — a full-access user config would otherwise make reviews write-capable); capacity recovery carries the primary invocation's sandbox, so a read-only `think` can never recover as full-access.

**Recovery is automatic, same-session, resume-only.** On a failed run (empty output or non-zero codex exit) classified as recoverable ("model at capacity" / stream error / 429), the wrapper resumes the SAME session carrying the same model/effort/schema (**never** a fallback model, never a from-scratch re-run) and asks it to emit the final answer it already computed: `CODEX_RECOVER_ATTEMPTS` (default 3) with doubling backoff from `CODEX_RECOVER_BACKOFF` (default 30s). A recovered result is flagged `ok_recovered`. Without a persisted session (`--ephemeral`, or codex died before creating one) there is no recovery — the wrapper exits 3 honestly. Resume identity fails closed for `--session` AND `--last`: output from an unverified or different session is refused (exit 4). `CODEX_START` is guaranteed to be the first line of every result, including usage/preflight failures.

**Collection rules:**
- **Never clip the output** (`| tail -N` has destroyed findings before) — Read the full task output file.
- The final message is everything after the `---` line that follows `SESSION:` (empty on failure).
- Check `CODEX_STATUS`/exit code before trusting the result; the wrapper no longer masks failures as success.
- If the harness wake signal doesn't fire (known bug): the task output file's heartbeat lines make liveness checkable — poll the file mtime or `ps aux | grep 'codex exec'`.

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
- `scripts/transfer-bridge.py` — Claude→Codex session transfer (app-server JSON-RPC)
- `schemas/review-output.schema.json` — canonical review schema
- `SKILL.md` — this file
- `references/cli-reference.md` — CLI flags
- `references/prompt-engineering.md` — prompt templates
- `tests/run-tests.sh` + `tests/stub-codex.sh` — regression matrix

After ANY change to `scripts/codex.sh`, run the regression matrix (stub codex — no tokens spent) and keep it green:

```bash
{base}/tests/run-tests.sh
```
