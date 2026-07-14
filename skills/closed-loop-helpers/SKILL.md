---
name: closed-loop-helpers
description: "Closed-loop PR review protocol and helper scripts. Preloaded by the closed-loop-runner agent."
user-invocable: false
---

# Closed-Loop Review Protocol

The closed-loop review cycle iterates review → fix → re-review on a PR until it is merge-ready or a stop condition forces escalation to a human. **It is opt-in** -- only enter it when the user explicitly asks ("enter closed-loop on PR #N", "run the feedback loop").

GitHub is the source of truth. Local state holds only a session UUID and round counter; everything else (round summaries, decisions) is posted to the PR.

## Helper Scripts

These ship with the og plugin and are on your PATH. (If a bare call fails, they're in the plugin's `bin/` directory.)

| Script | Purpose |
|---|---|
| `closed-loop-init <owner>/<repo> <PR> [--round-limit N] [--mode attended\|unattended]` | Create session dir + config.json, add the `ai:closed-loop` label. Prints session JSON. |
| `closed-loop-status <owner>/<repo> <PR>` | PR state as JSON: state, labels, unresolved thread count, CI rollup, latest comment author/AI-ness. |
| `closed-loop-comment <owner>/<repo> <PR> "<msg>" [--session UUID] [--model MODEL]` | Post a comment with the `<!-- AI:closed-loop:UUID -->` marker and AI disclosure. |
| `closed-loop-resolve-thread <owner>/<repo> <PR> <THREAD_ID>` | Resolve one review thread by ID. Never use `--all` in automation. |
| `closed-loop-escalate <owner>/<repo> <PR> <reason_code> "<msg>" [--session UUID] [--round N]` | Post an AWAITING_HUMAN escalation. |
| `closed-loop-check-human <owner>/<repo> <PR> [<since-ISO8601>]` | Find human (non-AI) comments since a timestamp. |

## Stop Conditions

| Condition | Reason code |
|---|---|
| Any Category C (design decision) comment | `design_decision` |
| Same issue flagged 3+ times | `circular_feedback` |
| This round's comment count not decreasing | `not_converging` |
| Round limit reached | `round_limit` |

On any stop condition: `closed-loop-escalate`, then exit and report to the human.

## Round Workflow (summary)

1. `closed-loop-status` → assess CI + unresolved threads.
2. Delegate review → categorize comments (A/B/C/D), capturing thread + comment IDs.
3. Check stop conditions → escalate if met.
4. If no Category A and CI green → adversarial pre-merge review (Opus). PASS → `merge_ready`.
5. Delegate fixes for Category A → developer pushes + replies inline.
6. `closed-loop-comment` round summary to GitHub.
7. `closed-loop-resolve-thread` for each addressed thread (by ID, never `--all`).
8. Increment round counter; loop.

## Hard Boundaries

- **Never merge** (universal Rule 0). Report `merge_ready` and stop.
- **Never read raw comment content as the runner** -- delegate to a reviewer (universal Rule 3).
- **Always disclose** AI authorship on every posted comment.
- **Resolve only specific thread IDs** that were addressed.
