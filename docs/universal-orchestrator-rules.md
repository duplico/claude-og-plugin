# Universal Orchestrator Rules

These rules apply to ALL orchestrators using the `og` plugin. They are numbered consistently so "Rule 6" means the same thing everywhere. Rule 0 is the most critical.

Project-specific rules start at Rule 12 and are numbered per project.

---

## Universal Rules (0-11)

### 0. Never Merge PRs - Absolute Rule

**Orchestrators and subagents must NEVER merge pull requests.** This is non-negotiable.

Forbidden actions:
- `gh pr merge` (any flags)
- `--admin` to bypass protections
- GitHub API merge endpoints
- Enabling auto-merge
- Instructing subagents to merge

When a PR is ready (CI passes, comments addressed):
1. Report "ready for human merge"
2. Stop and wait
3. Do NOT offer to merge

**Why:** Agents have historically merged PRs using admin rights to bypass approvals. This defeats code review.

### 1. Isolated Worktrees - Always

Every implementation task gets its own worktree branched from the latest default branch. This prevents merge conflicts and ensures clean PRs. Subagents must NEVER work in the main repo directory.

The `worktree_cleanup_guard.py` hook (shipped with this plugin) automatically protects against deleting your own CWD when removing a worktree. If the shell is inside the worktree being removed, the hook silently prepends a `cd` out to the parent before the removal command runs.

### 2. CI Must Pass - No Exceptions

Work is not complete until all CI checks pass. If CI fails, launch a subagent to fix it. Do not mark work as complete until CI passes.

### 3. Never Read Full Subagent Output

Subagent output files can be 500KB+. Reading them will flood your context window. Trust the completion summary, or spin out a summarizer agent if you need details.

**DO NOT** run `Read` or `cat` on subagent output files (`/tmp/claude-*/tasks/*.output`).

**DO** use these alternatives:
- Trust the completion summary returned by `TaskOutput`
- Launch a summarizer subagent if you need more detail
- Use `tail -50` for quick status checks on log files
- Use `gh pr checks` to verify CI status

### 4. Reply Inline to PR Comments — and Resolve the Thread

When subagents address review comments, they must **reply and resolve the thread together** on GitHub, comment by comment. A comment is not addressed until its thread is resolved; a "Fixed in {SHA}" reply left on a still-open thread does not count. Use the coupled helper so the reply and the resolution happen in one call:

```bash
og-pr-reply-resolve {OWNER}/{REPO} {PR} {COMMENT_ID} \
  "Fixed in {SHA}. {explanation}" --disclose "{model}"
```

Only decline/question comments stay open (add `--no-resolve`); under a `closed-loop-runner`, the runner owns resolution (its Step 7) and developers reply with `--no-resolve`. See the `pr-response-protocol` skill (preloaded by developer agents) for the full rules.

### 5. Explicit Permission Error Reporting

When subagents hit permission errors, they must flag them with specifics:
- Which tool/command failed
- The exact path involved
- Likely cause and remedy

Example: "Permission denied running `docker compose up` - may need to be in docker group or run with sudo"

Never report vague "permission denied" without context.

### 6. Blocked Subagent Termination

**When a subagent cannot proceed, it MUST stop immediately and return a clear summary.**

Subagents must NOT:
- Keep retrying indefinitely
- Silently spin without progress
- Work around blockers without reporting them

Subagents MUST:
1. **Stop immediately** when blocked by permissions, missing dependencies, unclear requirements, or unresolvable errors
2. **Write a clear summary** explaining:
   - What they were trying to do
   - What blocked them (specific error message, missing permission, unclear requirement)
   - What's needed to unblock (the remedy)
3. **Terminate and return** to the orchestrator with that summary

This ensures the orchestrator (and user) can see what went wrong and take corrective action, rather than having subagents spin for hours with no visibility.

### 7. GitHub as Source of Truth

GitHub is the canonical state for project work. On session startup, always check:
- Open issues and their labels/assignees
- Open PRs and their CI status
- Recent review comments on active PRs

This ensures new sessions can pick up where previous work left off. When reporting status, always include full GitHub URLs.

### 8. Periodically Review Subagent Definitions

Subagent definition files in `.claude/agents/` (and plugin agents) contain specialized prompts and context. Before launching a subagent, verify its definition is still accurate:
- Does it reflect the current codebase structure?
- Are tool/path references accurate?
- Are there new patterns that should be documented?

If you notice outdated information during a session, surface it to the user or update the file.

### 9. Test Failure Accountability

**When a test or CI check fails after a code change, the default assumption is that the code change caused the failure.**

This is non-negotiable:
1. **Burden of proof is on the agent** - Must demonstrate with evidence that a failure is NOT caused by their change before blaming tests, CI, infrastructure, or network issues
2. **Valid evidence includes:**
   - Showing the same test fails on the base branch (pre-existing)
   - Showing network/infrastructure errors unrelated to code paths
   - Showing the test makes invalid assumptions that contradict documented behavior
3. **Invalid reasoning includes:**
   - "This looks like an infrastructure issue" (without proof)
   - "The test is probably flaky" (without history showing flakiness)
   - "My code is correct so the test must be wrong" (circular reasoning)
   - Immediately modifying tests to pass without understanding why they failed

When tests fail, subagents must:
1. **First**: Understand what the test is checking and why it failed
2. **Second**: Determine if the code change could have caused this
3. **Third**: If they believe it's not their change, gather evidence
4. **Fourth**: Present the evidence and conclusion

Never accept "infrastructure issue" or "pre-existing failure" as a conclusion without supporting evidence.

### 10. Issue Narration

Comment on issues with high-level progress updates:
- When PR created
- When blocked/escalated
- When complete
- **When a human makes a material clarification or judgment call** to the AI

Human judgment calls to document:
- Decisions between competing approaches
- Clarifications of ambiguous requirements
- Overrides of AI recommendations
- Scope adjustments during implementation

Format for judgment call documentation:

```markdown
## Human Decision Recorded

**Decision**: {what was decided}
**Context**: {why this was ambiguous or required judgment}
**Impact**: {what this changes about the approach}

(AI-generated via Claude Code w/ {model})
```

Read issue comments before starting work to incorporate human feedback.

### 11. Use the Project's Tooling for Standardized Tasks

Invoke standardized tasks through the project's front door -- `just test`, `make lint`, `npm run build` -- rather than hand-rolling the underlying command. The wrapper encodes flags, environment, and container boundaries, and it is what CI runs; bypassing it diverges from CI silently (Rule 2). Discover the project's recipes before your first command, not after a failure (`just --list`, `make help`, `npm run`, the `scripts/` dir -- whatever it uses).

**This is not a ban on the underlying tool.** Running it directly is correct when no recipe covers what you need: an ad-hoc query, a one-off container exec, a debug shell. But if a raw command starts recurring, that is a missing recipe -- add one (`og:just-expert`) instead of normalizing the invocation.

**Do not restate this as a list of forbidden binaries.** "Never invoke `pytest` or `docker compose`" collides with the legitimate uses above, and an agent that meets a contradiction stops trusting the rule.

---

## Project-Specific Rules (12+)

A project's `<repo>/.claude/skills/<project>-orchestrator/SKILL.md` (generated by `/og:orchestrate-init`) may define additional rules starting at Rule 12. These are numbered independently per project.

When project rules conflict with universal rules, **universal rules win**. Project rules can be stricter, never looser.

---

## See Also

- `claude-agent-rules.md` — rules that apply to all subagents (not just orchestrators)
- The `pr-response-protocol` skill — preloaded by developer agents
- The `closed-loop-helpers` skill — for review feedback iteration
