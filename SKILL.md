---
name: codex
description: Delegate tasks to OpenAI Codex (GPT-6 Astra) as background tasks for precision coding, code review, deliberation, and complex implementation. Always launch in background (run_in_background=true), continue working, then collect results with TaskOutput when needed.
allowed-tools: Bash, Read, Grep, Glob, TaskOutput, Edit, Write
---

# Codex

> Paths below use `{base}` as shorthand for this skill's base directory, provided automatically at the top of the prompt when the skill loads.

Codex is GPT-6 Astra — a different model with a different reasoning manifold than Claude. It catches things you miss, thinks about problems differently, and arrives at solutions from a different angle. Use it as a genuine second brain, not just a subprocess. Its opinions, reviews, and implementations carry independent signal — when Codex disagrees with your approach, that disagreement is valuable.

`gpt-6-astra` is a single slug (no Sol/Terra/Luna tiers, no snapshots) and the wrapper's **pinned default** — `codex.sh` always passes `-m`, so `~/.codex/config.toml` no longer decides the model. Override per call with `--model`, or machine-wide with `CODEX_DEFAULT_MODEL`.

| Model | Slug | Use it for |
|-------|------|-----------|
| **GPT-6 Astra** | `gpt-6-astra` | The default. Frontier reasoning, review, hard implementation. 2.5× Sol per token ($10 in / $50 out per 1M), partly offset by fewer output tokens |
| **GPT-5.6 Sol** | `gpt-5.6-sol` | Previous flagship — the cheaper fallback when Astra depth isn't needed |
| **GPT-5.6 Terra** | `gpt-5.6-terra` | Balanced everyday work at lower cost |
| **GPT-5.6 Luna** | `gpt-5.6-luna` | Fast and cheap; the subagent tier on ultra runs |

Astra needs codex-cli ≥ 0.153.1 (`codex --version`). Its Codex-backend context window is 272K (`~/.codex/models_cache.json`), so the API's >272K long-context surcharge never applies through the CLI — it applies only to API-key use of the 1.05M window.

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

**Flags:** `--dir`, `--model`, `--effort`, `--sandbox`, `--image`, `--ephemeral`, `--schema`, `--add-dir`, `--fast` (explicit-permission only — see Fast mode) · transfer: `--source`, `--latest`
**Env knobs:** `CODEX_DEFAULT_MODEL` (gpt-6-astra), `CODEX_DEFAULT_EFFORT` (medium), `CODEX_HEARTBEAT_SECS` (30), `CODEX_RECOVER_ATTEMPTS` (3), `CODEX_RECOVER_BACKOFF` (30s, doubles), `CODEX_SESSIONS_DIR` (~/.codex/sessions), `CODEX_BIN` (codex), `CODEX_TRANSFER_TIMEOUT` (180s)

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
CODEX_START: mode=think model=gpt-6-astra effort=medium tier=default dir=/project
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
- **Deep reasoning tasks** — raise `--effort` (xhigh/max) on complex algorithms, security analysis, architecture decisions

## Reasoning Effort

`--effort` takes `low | medium | high | xhigh | max | ultra`. **Default is `medium`** (Tom, 2026-09-05 — Astra's per-token price makes depth-by-default a spend multiplier; `CODEX_DEFAULT_EFFORT` changes the machine-wide default). Escalate per task, never as a skill default: `high`/`xhigh` for real review and hard implementation, `max`/`ultra` only when the task earns it. There is no `none`/`minimal` — both 400.

`max` and `ultra` sit above `xhigh`:

- **`max`** — maximum depth within a single turn. Reach for it on genuinely hard problems where `xhigh` returned something shallow. Cost is higher but bounded.
- **`ultra`** — maximum depth *plus* automatic task delegation: Codex decomposes the problem and spawns internal sub-agents. Escalate to it only when the task genuinely warrants it — a large refactor, a subtle cross-cutting bug, an architecture decision with many interacting constraints. Token spend is substantially higher and harder to predict, so don't make it a default.

`ultra` runs on `gpt-6-astra`, `gpt-5.6-sol` and `gpt-5.6-terra` — `gpt-5.6-luna` caps at `max`. (Astra + ultra verified 2026-09-05 on codex-cli 0.153.3 via an ephemeral `think`: `CODEX_STATUS: ok`; the API docs list only up to `max` because `ultra` is a Codex-backend effort, not an API one.) `minimal` is not in the ladder and 400s with `unsupported_value` despite years of docs claiming otherwise.

**FOOTGUN — a bare `codex exec` rewrites `~/.codex/config.toml`.** Running `codex exec -m <model> -c model_reasoning_effort="<effort>"` **persists that model and effort as the GLOBAL defaults**. One probe with `--effort ultra` left `model_reasoning_effort = "ultra"` in the config and would have made ultra the default for every skill that doesn't pass `-m` explicitly. `codex.sh` run/think/review/resume are immune — they pin model, effort AND service tier on every invocation, so a drifted config.toml cannot change what they run — but after ANY direct-CLI probing: re-read `~/.codex/config.toml` and restore it (other tools still read it). The live half of the footgun: `codex exec resume` applies the CURRENT config.toml defaults, NOT the session's recorded effort (upstream openai/codex#32061 — model mismatches warn, effort swaps silently), so a drifted default silently downgrades every resumed round. (`~/.codex/models_cache.json` is the source of truth for which slugs the account can actually reach — delete it to force a refetch.)

### Subagent tiering on ultra runs

`codex.sh` enables `multi_agent_v2` on every `--effort ultra` invocation (run/think and
crash-recovery resumes), which adds optional `model` and `reasoning_effort` parameters to the
session's internal `spawn_agent` tool. The root model only uses them when the dispatch prompt
says so — include this directive (adapt the exceptions to the task) in every ultra dispatch:

> Subagent tiering: spawn subagents with `model: "gpt-5.6-luna"`, `reasoning_effort: "medium"`
> by default — recon, inventories, contract checks, focused reviews; raise a subagent to
> `high`/`xhigh` only when its subtask needs it. Constraint: per-spawn
> model/effort overrides require `fork_turns` of `"none"` or a bounded number (never
> `"all"`), so pass the context the subagent needs in its `message`. Keep a subagent on the
> root model (omit `model`) only when it genuinely needs a full-context fork or frontier
> judgment.

Why: luna is ~60× cheaper than Astra per token and benchmarks near GPT-5.5-xhigh on scoped
work, and ultra's internal fan-out is where most of an ultra run's spend goes. Astra also
tends to UNDER-delegate — say explicitly in the dispatch when and how much to parallelise.
Verified 2026-08-18 on codex-cli 0.147.0: `multi_agent_v2` is stable but default-off; with it
on, the spawn schema accepts models `gpt-5.6-sol|terra|luna` (+5.5/5.4) and efforts up to
`max` for luna, and rejects overrides on `fork_turns: "all"`. Re-verified 2026-09-05 on
0.153.3 that an Astra root accepts `--effort ultra`; the spawn schema's model list was not
re-probed (subagents stay on luna regardless).

### Subagent tiering on ultra runs

`codex.sh` enables `multi_agent_v2` on every `--effort ultra` invocation (run/think and
crash-recovery resumes), which adds optional `model` and `reasoning_effort` parameters to the
session's internal `spawn_agent` tool. The root model only uses them when the dispatch prompt
says so — include this directive (adapt the exceptions to the task) in every ultra dispatch:

> Subagent tiering: spawn subagents with `model: "gpt-5.6-luna"`, `reasoning_effort: "xhigh"`
> by default — recon, inventories, contract checks, focused reviews. Constraint: per-spawn
> model/effort overrides require `fork_turns` of `"none"` or a bounded number (never
> `"all"`), so pass the context the subagent needs in its `message`. Keep a subagent on the
> root model (omit `model`) only when it genuinely needs a full-context fork or frontier
> judgment.

Why: luna is ~25× cheaper than sol per token and benchmarks near GPT-5.5-xhigh on scoped
work, and ultra's internal fan-out is where most of an ultra run's spend goes. Verified
2026-08-18 on codex-cli 0.147.0: `multi_agent_v2` is stable but default-off; with it on, the
spawn schema accepts models `gpt-5.6-sol|terra|luna` (+5.5/5.4) and efforts up to `max` for
luna (`ultra` stays sol/terra-only), and rejects overrides on `fork_turns: "all"`.

```bash
{base}/scripts/codex.sh think "why does this deadlock under load?" --effort ultra --dir /project
```

### Fast mode — explicit permission only

`service_tier = "fast"` is 2× the price for ~2× the speed, no latency SLA, unavailable under EU data residency. **The wrapper pins `service_tier="default"` on every run/think/review/resume and on capacity recovery**, so a drifted config.toml can never make a run fast. The only way in is `--fast`, and `--fast` is used ONLY after Tom's explicit yes in the current session — same posture as `FABLE_OPT_IN` / `GIT_GUARD_ALLOW`: never a default, never inferred from "make it quick", quoted in the daily note like any spend opt-in. `CODEX_START` prints `tier=fast` when it fires, so the trace can't hide it.

### Astra dispatch notes

Astra behaves differently from Sol in ways that change how you write the prompt (OpenAI migration guide, 2026-09):

- **It asks clarifying questions instead of assuming.** `exec` has no user to answer them. Tell it: state assumptions and proceed; never stop to ask.
- **It over-tests small changes.** Calibrate verification scope in the prompt — "run `./verify.sh --fast` and the targeted test file, not the suite".
- **It under-delegates on `ultra`.** Say when and how much to parallelise, or it does the work serially on the root model.
- **It emits list-heavy, formatted output with recurring phrases.** Ask for prose when a human reads the result; a schema when a script does.
- **It weights AGENTS.md / CLAUDE.md / skill text heavily.** Sophiie worktrees load `CLAUDE.md` via `project_doc_fallback_filenames`, so a stale "do not start coding" banner in `CLAUDE.local.md` now bites harder — clear it before dispatch.
- **Standard access refuses advanced offensive-cyber tasks** (first "Critical"-rated model). A security-review prompt should ask for the defect and the fix, not a working exploit.

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
