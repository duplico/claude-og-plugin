# Claude Agent Rules

Rules that apply to **all** subagents (developers, reviewers, testers, researchers) using the `og` plugin. These complement the universal orchestrator rules.

---

## R1. Disclose AI Authorship

When you write content humans will read — PR descriptions, issue comments, review replies, documentation — include AI disclosure.

- **Commit trailer**: `Co-Authored-By: Claude {Model} <noreply@anthropic.com>`
- **Comments/replies/docs**: short closing line, e.g. `(AI-generated via Claude Code w/ Opus 4.7)`

**Exceptions:** trivial mechanical edits (typo fix, version bump in a single line), source code itself, content authored by the human.

## R2. Verify Before Asserting

Don't claim a file exists, a function is named X, or a config flag does Y without checking. Memory and prior context decay. Before:
- Recommending a change that depends on existing code → grep for the symbol.
- Citing a doc → re-read it (the API may have changed).
- Reporting a bug fix as complete → run the test or reproduce the original failure.

## R3. Stop When Blocked

See universal Rule 6. If you can't proceed (permission denied, missing dependency, unclear requirement, unresolvable error), stop immediately and return a structured summary:
- **What you were trying to do**
- **What blocked you** (exact error, missing thing)
- **What's needed to unblock**

Do not silently retry. Do not work around blockers without reporting them.

## R4. Stay In Your Worktree

If the orchestrator gave you a worktree path, work there and only there. Never edit files in the main repo checkout. Never edit files outside any worktree the orchestrator assigned.

The `worktree_guard.py` hook (shipped with this plugin) enforces this for `Edit`/`Write` operations when you are dispatched as a subagent.

## R5. Make Many Small Commits, Not One Big One

Commit at logical boundaries (one feature step, one refactor, one bug fix). Easier to review, easier to revert. Conventional Commits format:
```
type(scope): subject

body

Co-Authored-By: Claude {Model} <noreply@anthropic.com>
```

## R6. Never Bypass Safeguards

- Never `--no-verify` (skip hooks) unless explicitly authorized.
- Never `--no-gpg-sign` (bypass signing) unless explicitly authorized.
- Never `git push --force` to a protected branch.
- Never `git reset --hard` or `git checkout .` without confirming with the user when there are uncommitted changes.
- Never `gh pr merge` — see universal Rule 0.

## R7. Use the Tools You're Given

- `Read` for files (not `cat`).
- `Edit` for modifying files (not `sed`).
- `Write` only for new files or full rewrites.
- `Bash` for shell-only operations.
- `Glob`/`Grep` for searching, not for reading.

## R8. Report Structured Output

End every task with a summary block the orchestrator can parse without reading your full output:

```markdown
## Summary

**Task**: <what was requested>
**Branch**: <branch name, if applicable>
**Worktree**: <path, if applicable>
**Changes**: <files changed, commits made>
**Status**: <PR created/updated, CI status, blockers>
**Follow-up**: <any issues, next steps, recommendations>
```

## R9. Trust Project Conventions

When the project has a `CLAUDE.md`, `.github/copilot-instructions.md`, or `.ai/context/` directory, **read it first** and follow its conventions. Project-specific rules override generic patterns.

---

## See Also

- `universal-orchestrator-rules.md` — rules for orchestrators specifically
- The `pr-response-protocol` skill — preloaded by developer agents for review feedback
