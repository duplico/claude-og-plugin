---
name: orchestrate-init
description: "Bootstrap a repository's Claude Code setup: investigate the stack, then generate a project orchestrator overlay, CLAUDE.md, permissions, optional domain agents, and gitignore entries. Run once per repo to get from zero to a useful, familiar orchestration setup."
disable-model-invocation: true
argument-hint: "[--minimal | --full]"
allowed-tools: Read, Glob, Grep, Bash, Edit, Write, Task, WebFetch
---

# Orchestrate-Init: bootstrap this repo's Claude Code setup

Your job is to take this repository from "no AI tooling" to "a useful, familiar orchestration setup" — without clobbering anything already there. Work through the phases in order. Be interactive at the decision points; otherwise just do the work.

`--minimal` = CLAUDE.md + project overlay + settings only.
`--full` (default) = also offer domain-specialist agents and a format hook.

---

## Phase 1 — Detect what already exists (never clobber)

```bash
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd); echo "Root: $ROOT"
for f in CLAUDE.md AGENTS.md .github/copilot-instructions.md .ai/context CONTRIBUTING.md \
         .claude/settings.json .claude/settings.local.json .gitignore; do
  [ -e "$ROOT/$f" ] && echo "EXISTS: $f"
done
echo "--- existing project agents ---"; ls -1 "$ROOT"/.claude/agents/*.md 2>/dev/null || echo none
echo "--- existing project skills ---"; ls -d "$ROOT"/.claude/skills/*/ 2>/dev/null || echo none
```

For anything that EXISTS, you will *augment* (or leave alone), not overwrite. Tell the user what you found.

## Phase 2 — Investigate the repo

Detect the stack, build/test/lint commands, CI, and layout. For a large/unfamiliar repo, delegate this to an `Explore` agent; for a small one, inspect directly.

```bash
ls "$ROOT" | head -40
ls "$ROOT"/{Makefile,justfile,Taskfile.yml,package.json,pyproject.toml,Cargo.toml,go.mod,*.csproj,build.gradle,pom.xml} 2>/dev/null
ls "$ROOT"/.github/workflows/ 2>/dev/null
```

Determine and write down (you'll use these in the generated files):
- **Languages / frameworks**
- **Build / test / lint commands** (prefer the project's Makefile/justfile wrappers)
- **CI system** and what it runs
- **Default branch** (`git symbolic-ref --short refs/remotes/origin/HEAD`)
- **GitHub slug** (if the remote is GitHub)
- **Multi-repo?** (submodules, repos.txt, sibling repos) and any dependency ordering you can infer

## Phase 3 — Ask the user (use AskUserQuestion)

Confirm your findings and gather decisions in ONE AskUserQuestion call (batch the questions):

1. **Stack confirmation** — present what you detected; let them correct.
2. **Orchestrator mode default** — friendly (implement-when-sensible) or strict (delegate-only). Writes `OG_ORCHESTRATOR_MODE`.
3. **Worktree enforcement** — should subagents be forced to use worktrees? (Recommended for shared repos with PR workflow; off for solo/small.) Writes `OG_REQUIRE_WORKTREE`.
4. **Domain agents** (only if `--full`) — offer 1-3 stack-specific agents to generate (e.g., a `<lang>-developer` specializing the generic developer, a `terraform-expert`, a `frontend-developer`). Let them pick which, or none.

Don't ask about things you can detect. Don't ask permission to create the basics — that's why they ran init.

## Phase 4 — Generate the setup

Create only what's missing. Use the templates below.

### 4a. Project orchestrator overlay → `.claude/skills/<project>-orchestrator/SKILL.md`

`<project>` = the repo's basename. This becomes invocable as `/<project>-orchestrator` and is also auto-detected by `/og:orchestrate`.

```markdown
---
name: <project>-orchestrator
description: "Orchestrator for the <project> repository. Coordinates work and delegates to subagents with <project>-specific knowledge."
allowed-tools: Read, Glob, Grep, Bash, Task, TodoWrite, WebFetch, WebSearch
---

# <project> Orchestrator

Adopt the og orchestrator role (see the `orchestrate` skill from the og plugin and
its universal-orchestrator-rules), then apply this project's specifics below.

## Stack & Commands
- Languages: <...>
- Build:  <command>
- Test:   <command>
- Lint:   <command>
- CI:     <what runs, where>

## Default mode: <friendly|strict>

## Subagents for this repo
| Agent | Use for |
|---|---|
| orchestrator-developer (or <generated domain dev>) | implementation in worktrees |
| orchestrator-reviewer | code review / comment triage |
| orchestrator-tester   | tests |
<...any generated domain agents...>

## Repository layout
<key directories and what lives in them>

## Dependency order (if multi-repo)
<upstream -> downstream graph, or "single repo">

## Project Rules (11+)
11. <project-specific rule, if any — e.g., "Makefile-first: never call the tool directly">
12. <...>

## GitHub
- Slug: <owner/repo>
- Default branch: <branch>
```

### 4b. `CLAUDE.md` (root) — only if absent

If absent, run the built-in `/init` skill to generate a strong first draft, then trim it and add: the build/test/lint commands, the "changes go through PRs" workflow, and an AI-disclosure note. If `CLAUDE.md` already exists, leave it and instead add a short pointer to the orchestrator overlay if one isn't there.

### 4c. `.claude/settings.json` — merge, don't overwrite

```json
{
  "env": {
    "OG_ORCHESTRATOR_MODE": "<friendly|strict>",
    "OG_REQUIRE_WORKTREE": "<unset|1>"
  },
  "permissions": {
    "allow": [
      "Bash(<project build cmd>)",
      "Bash(<project test cmd>)",
      "Bash(<project lint cmd>)",
      "Bash(git status)", "Bash(git diff:*)", "Bash(git log:*)",
      "Bash(gh pr view:*)", "Bash(gh pr list:*)", "Bash(gh pr checks:*)"
    ]
  }
}
```

Only set `OG_REQUIRE_WORKTREE` if the user opted in. If a `.claude/settings.json` exists, merge these keys into it (preserve their existing content).

If `--full` and a formatter was detected, add a `PostToolUse` Edit|Write hook that runs the project formatter (e.g., `ruff format`, `prettier -w`, `gofmt -w`, `cargo fmt`). Reference a script in `.claude/hooks/` you create, or an inline command.

### 4d. `.claude/settings.local.json` — template, gitignored

Create a minimal stub (machine-specific overrides) only if absent:
```json
{ "permissions": { "allow": [] } }
```

### 4e. `.gitignore` — append if missing

Ensure these are ignored (append, don't duplicate):
```
.claude/settings.local.json
.ai/scratch/
*-worktrees/
```

### 4f. Domain agents (only if `--full` and the user chose some) → `.claude/agents/<name>.md`

Base each on the plugin's `orchestrator-developer` (or `-reviewer`/`-tester`) and add stack-specific knowledge: the exact build/test commands, framework idioms, where things live, common pitfalls. Keep the worktree workflow and the structured-output block. Set `skills: [pr-response-protocol]` on developer-type agents.

## Phase 5 — Verify & hand off

1. Validate YAML frontmatter on every file you wrote (a missing `tools:`/`name:` makes an agent fail silently).
2. Print a summary: created vs skipped (with reasons), and the new commands available (`/<project>-orchestrator`, `/og:orchestrate`).
3. Remind the user these files are committed to the repo (except `settings.local.json`), so the team gets them too.
4. Suggest: *"Run `/<project>-orchestrator` (or `/og:orchestrate`) to start coordinating. Re-run `/og:orchestrate-init --full` later to add domain agents."*

## Guardrails

- Never overwrite an existing file without showing the user the diff and getting an OK.
- Keep generated files lean — a tight overlay beats a 400-line prompt nobody reads.
- Everything you generate is committed to the repo (team-shared) except `settings.local.json`. Don't put machine-specific paths or secrets in the committed files.
