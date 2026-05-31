---
name: sync
description: "Apply plugin updates down into this project's .claude/ overlay and agents. Fixes bare references to plugin agents/skills that should be og:-prefixed, and inserts shared-utility rows missing from the overlay's agent table. Run after a plugin update or whenever the project files have drifted from the current plugin API."
disable-model-invocation: true
argument-hint: "[--fix]"
allowed-tools: Bash
---

# /og:sync — apply plugin updates to this project

Run the sync script and present the output verbatim (already formatted).
Default mode is **report-only**. Append `--fix` to apply changes in place.

```bash
og-sync $ARGUMENTS
```

## What it checks

In `.claude/skills/*-orchestrator/SKILL.md` and `.claude/agents/*.md`:

1. **Bare references to plugin-shipped agents/skills** that should be `og:`-prefixed.
   Looks only in three structured contexts to avoid false positives on common words:
   - `skills:` preload list entries (YAML)
   - Markdown table cells (`| name |`)
   - Inline backticks (`` `name` ``)

2. **Missing shared-utility rows** in the overlay's agent table — `og:editor`,
   `og:web-doc-searcher`, `og:just-expert`, `og:closed-loop-runner`. So when the
   plugin gains a new shared agent, sync makes sure every project's overlay
   surfaces it.

## When to run

- After `claude plugin update og` reports a new version, before re-using the orchestrator.
- When dispatching a plugin agent fails with `Agent type '<name>' not found`.
- Whenever you suspect the project files have fallen behind the current plugin API.

## What it doesn't do

- Does NOT rewrite project-specific agent prompts (`gqc-developer`, etc.) — only
  fixes their plugin-name references.
- Does NOT renegotiate `.claude/settings.json` env keys.
- Does NOT remove rows for plugin agents you've intentionally hidden — manual.
