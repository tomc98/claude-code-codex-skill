# Prompt Engineering for Codex

GPT-5.3-codex at xhigh reasoning is an extraordinarily capable coding model. The quality of its output is directly proportional to the quality of the prompt. This guide covers how to craft prompts that get the most out of Codex.

## Core Principles

### 1. Be Precise About Scope

Codex works best with well-defined boundaries. Tell it exactly what to change, what files to touch, and what to leave alone.

**Bad**: "Fix the authentication"
**Good**: "Fix the race condition in `src/auth/session.ts` where concurrent refresh token requests can invalidate each other. The `refreshToken()` function on line 45 doesn't lock the refresh operation."

### 2. Provide Context It Can't Infer

Codex reads files from disk but doesn't know your intentions, constraints, or deployment environment.

- Framework versions and compatibility requirements
- Performance constraints (latency budgets, memory limits)
- Why you chose the current approach
- What you've already tried that didn't work

### 3. Specify the Output Format

Tell Codex exactly what you expect back — modified files, analysis, explanation, or test results.

### 4. Use Structured Prompts

Organize complex tasks into clear sections. Codex parses structure well.

## Prompt Templates

### Implementation Task

```
TASK: Implement <specific feature/change>

CONTEXT:
- Language/framework: <e.g., TypeScript, Next.js 15, React 19>
- Architecture: <e.g., monorepo, microservices, serverless>
- Key files involved:
  - `path/to/main-file.ts` — <what it does>
  - `path/to/related-file.ts` — <how it relates>
- Existing patterns: <describe conventions — naming, error handling, testing>

REQUIREMENTS:
1. <Specific, testable requirement>
2. <Specific, testable requirement>
3. <Specific, testable requirement>

CONSTRAINTS:
- Do NOT modify: <files or code to preserve>
- Must be backwards-compatible with: <API/interface>
- Follow the existing pattern in: <reference file>
- Tests must pass: <test command>

ACCEPTANCE CRITERIA:
- <How to verify this is correct>
```

### Code Review

```
Review the following changes for:

1. **Correctness**: Logic errors, edge cases, off-by-one errors, null/undefined handling
2. **Security**: Injection vulnerabilities, auth bypass, data exposure, SSRF
3. **Performance**: Unnecessary allocations, N+1 queries, blocking I/O, cache misses
4. **Concurrency**: Race conditions, deadlocks, missing locks, shared mutable state
5. **Style**: Consistency with existing codebase conventions

For each finding:
- Severity: critical / high / medium / low / nit
- File and line number
- What the issue is
- Why it matters
- Suggested fix (code snippet if applicable)

Prioritize findings by severity. Be thorough but avoid false positives.
```

### Bug Fix

```
BUG: <One-sentence description of the bug>

SYMPTOMS:
- <What happens — error messages, incorrect behavior, crash>
- <When it happens — specific inputs, timing, conditions>
- <How to reproduce>

EXPECTED BEHAVIOR:
- <What should happen instead>

INVESTIGATION SO FAR:
- <What you've already checked>
- <Hypotheses you've formed>
- <What you've ruled out>

RELEVANT CODE:
- `path/to/file.ts` — <the function/module involved>

Fix the root cause, not just the symptom. Explain your reasoning.
```

### Refactoring

```
REFACTOR: <What to refactor and why>

CURRENT STATE:
- <Describe the current structure>
- <What's wrong with it — tech debt, coupling, performance>

TARGET STATE:
- <Describe the desired structure>
- <What patterns to use>

CONSTRAINTS:
- All existing tests must continue to pass
- Public API must remain unchanged
- Do NOT change: <boundaries>

Refactor incrementally — each change should leave the code in a working state.
```

### Test Writing

```
Write tests for: `path/to/module.ts`

TESTING FRAMEWORK: <jest/vitest/pytest/etc>
EXISTING TEST PATTERNS: See `path/to/existing.test.ts` for conventions

Cover:
1. Happy path — normal inputs produce expected outputs
2. Edge cases — empty inputs, boundary values, unicode, large inputs
3. Error cases — invalid inputs, network failures, timeouts
4. Integration points — mock external dependencies at: <boundaries>

Follow the existing test naming convention: <describe-it pattern / given-when-then / etc>
Do NOT test implementation details — test behavior and contracts.
```

## Advanced Techniques

### Chain of Thought Prompting

For complex tasks, ask Codex to think through the problem before coding:

```
Before implementing, analyze:
1. What are the possible approaches?
2. What are the tradeoffs of each?
3. Which approach best fits the existing architecture?

Then implement your chosen approach.
```

### Constraint-First Prompting

Start with what Codex must NOT do — this prevents common over-engineering:

```
CONSTRAINTS (read these first):
- Do NOT add new dependencies
- Do NOT refactor existing code
- Do NOT add error handling beyond what's explicitly required
- Keep changes minimal — smallest diff that solves the problem

TASK: <your task>
```

### File-Focused Prompting

When Codex needs to work on specific files, be explicit:

```
Work only in these files:
- `src/api/routes.ts` — add the new endpoint
- `src/api/middleware.ts` — add rate limiting
- `src/api/routes.test.ts` — add tests

Do NOT create new files. Do NOT modify any other files.
```

### Review with Schema

For structured review output that's easy to parse:

```
Output your review as structured findings. For each issue:

FILE: <path>
LINE: <number>
SEVERITY: critical|high|medium|low
CATEGORY: correctness|security|performance|style
ISSUE: <one-line description>
DETAIL: <explanation of why this is a problem>
FIX: <suggested code change>
```

## Tips for Getting the Best Results

1. **One task per session**: Don't overload a single prompt with multiple unrelated tasks
2. **Include file paths**: Always reference specific files — Codex can read them from disk
3. **Show don't tell**: Instead of describing a pattern, point to an existing file that demonstrates it
4. **Set the bar explicitly**: "Production-quality" vs "quick prototype" changes what Codex produces
5. **Use follow-ups**: Start with a focused task, then resume the session for refinements
6. **For reviews, provide context**: "This is a security-critical auth module" changes the review depth
7. **Trust but verify**: Codex at xhigh is highly accurate but always review the diff before accepting
