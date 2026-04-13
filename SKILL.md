---
name: codex
description: Delegate tasks to OpenAI Codex (GPT-5.4) as background tasks for precision coding, code review, deliberation, and complex implementation. Always launch in background (run_in_background=true), continue working, then collect results with TaskOutput when needed.
allowed-tools: Bash, Read, Grep, Glob, TaskOutput, Edit, Write
---

# Codex

> Paths below use `{base}` as shorthand for this skill's base directory, provided automatically at the top of the prompt when the skill loads.

Codex is GPT-5.4 — a different model with a different reasoning manifold than Claude. It catches things you miss, thinks about problems differently, and arrives at solutions from a different angle. Use it as a genuine second brain, not just a subprocess. Its opinions, reviews, and implementations carry independent signal — when Codex disagrees with your approach, that disagreement is valuable.

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
{base}/scripts/codex.sh run "prompt" --allowed-files "src/auth.py,src/auth_test.py" --dir /project
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

**Flags:** `--dir`, `--model`, `--effort`, `--sandbox`, `--image`, `--ephemeral`, `--schema`, `--add-dir`, `--allowed-files`

## How to Invoke

1. **Always run in background.** Continue working or block on `TaskOutput`.
2. **Pass the user's intent as-is.** Don't over-engineer the prompt — Codex reads files and figures things out.
3. **Add context Codex can't see** — working directory, file paths, framework info, constraints from earlier in conversation.
4. **Always include a file allowlist** for `run` mode — see Scope Control below.
5. **Collect results** with `TaskOutput(task_id=..., block=True, timeout=300000)`.
6. **After run mode**, validate scope and review changes — see Scope Control below.

```python
Bash(command='{base}/scripts/codex.sh think "Is this auth design scalable?" --dir /project',
     run_in_background=True)
# → task_id

TaskOutput(task_id="...", block=True, timeout=300000)
# → SESSION: <uuid>\n---\n<response>
```

For complex tasks, add structure (see `references/prompt-engineering.md` for templates). For simple asks, just describe what you need.

## Scope Control (MANDATORY for run mode)

Codex will modify files outside its assigned scope. This is not a bug — it's how GPT-5.4 reasons about "completeness." You MUST constrain it.

### File Allowlist

Every `run` prompt MUST include an explicit file allowlist:

```
FILES YOU MAY MODIFY (and ONLY these files):
- path/to/file1.py
- path/to/file2.py

DO NOT modify any other files. DO NOT modify test expectations, test counts,
or assertion values to make tests pass — if tests fail, your changes are wrong.
DO NOT reformat, re-order, or normalize YAML/JSON files you read for context.
DO NOT move rules between files (e.g. promoting/demoting shared rules).
DO NOT run git commit, git add, git push, or any git write operations.
```

If you don't know the exact file list, derive it from the plan or use `think` first.

Also pass the allowlist to codex.sh for automated enforcement:
```bash
{base}/scripts/codex.sh run "prompt" --allowed-files "file1.py,file2.py" --dir /project
```

### Git Operations — CC Only

Codex `run` mode is for implementation ONLY. Codex must NEVER:
- `git commit` or `git add`
- `git push` or create PRs
- Run any git write operations

After collecting Codex output, CC handles the entire git lifecycle:
1. Review all changes (`git diff --stat`, `git diff`)
2. Validate against file allowlist (restore unauthorized changes)
3. Re-run tests
4. Commit, push, PR via normal CC workflow

If Codex created commits during `run`, codex.sh auto-resets to the pre-run HEAD.
If that failed, manually reset: `git reset HEAD~N` then review the working tree.

### Post-Run Validation (MANDATORY)

After collecting Codex `run` output, ALWAYS:

1. Run `git status --short` in the `--dir` directory
2. Compare changed files against the allowlist from the prompt
3. For ANY file not in the allowlist: restore it immediately
4. Re-run tests AFTER restoring unauthorized changes
5. If Codex changed test expectations (counts, assertion values): treat as unauthorized — restore from origin

If `--allowed-files` was passed, codex.sh validates automatically and reports violations in stderr.
For manual validation:

```bash
# Pattern: validate and restore after every Codex run
ALLOWED="file1.py file2.py"  # from your prompt
cd <dir>
while IFS= read -r f; do
  if ! echo "$ALLOWED" | grep -qwF "$f"; then
    echo "UNAUTHORIZED: $f — restoring"
    git checkout -- "$f" 2>/dev/null || rm -f "$f"
  fi
done < <(git diff --name-only && git ls-files --others --exclude-standard)
```

## Error Handling

- **Empty output with error text**: API key issue or auth failure. Check env vars.
- **Empty output, no errors**: Codex timed out or crashed. Retry once; if it persists, reduce task scope.
- **Exit code in header**: Codex encountered issues but produced partial output. Review critically.
- **"session id: unknown"**: Codex CLI output format may have changed. Resume will not work for this session.
- **SCOPE VIOLATION in stderr**: codex.sh detected and auto-restored unauthorized file changes. Review the list to understand what Codex tried to do.

When Codex fails, do NOT silently drop the result. Report the failure to the user with the error details.

## Model Selection

| Task Type | Recommended | Flag |
|-----------|-------------|------|
| Typo fix, simple edit | gpt-5.1-codex-mini | `--model gpt-5.1-codex-mini --effort low` |
| Standard implementation | gpt-5.4 (default) | (no flag needed) |
| Security review, architecture | gpt-5.4 | `--effort xhigh` |
| Long multi-file refactor | gpt-5.1-codex-max | `--model gpt-5.1-codex-max` |

Default to the default model. Only override when there is a clear cost/performance reason.

## When Codex Shines

- **Second opinion** — its different training means it spots different bugs, suggests different patterns, and flags things you'd overlook
- **Adversarial review** — use `think` to challenge your own implementation. A different model questioning your code is more valuable than self-review
- **Parallel expertise** — while you work on feature A, Codex implements feature B or researches approach C
- **Deep reasoning tasks** — xhigh effort on complex algorithms, security analysis, architecture decisions

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
