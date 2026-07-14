---
name: pr-response-protocol
description: "Protocol for responding to PR review comments. Preloaded by developer agents."
user-invocable: false
---

# PR Review Comment Response Protocol

When you address a PR review comment, you MUST both **reply** and **resolve its thread** on GitHub, comment by comment. This is the completion gate: a comment is **not "addressed"** until it has a reply citing the fix **and** its thread is resolved. A "Fixed in {sha}" reply left on a still-open thread does **not** count as done -- that is the single most common failure of this protocol. The only comments you reply to *without* resolving are ones you are declining or questioning (see below).

## The one way to respond: reply + resolve together

Replying and resolving target two different id spaces (the comment `databaseId` vs. the thread's node id), so a bare `gh api ... /replies` call posts the reply but leaves the thread **open**. Do not do that. Use the coupled helper -- it posts the reply, finds the enclosing thread by comment id, and resolves it in one call:

```bash
og-pr-reply-resolve {owner}/{repo} {N} {comment_id} \
  "Fixed in {sha} - renamed to \`getCurrentUser()\` as suggested." \
  --disclose "{model}"
```

- `{comment_id}` is the review comment's `databaseId` -- the number in its URL (`#discussion_r<ID>`) or from the GraphQL `reviewThreads` response.
- `--disclose "{model}"` appends the AI-disclosure line for you.
- It resolves **only** the one thread containing that comment -- never a bulk sweep.
- Verify the result: the JSON should show `"resolved": true`. If it prints `resolved: false` or warns it found no thread, the comment is likely a PR-level (non-inline) comment -- see below -- or the resolve was denied; do not report the comment as addressed until it resolves.

### When NOT to resolve

- **Declining or asking, not fixing?** Reply but keep the thread open: add `--no-resolve`. Use this for "Won't fix" (Category D) and "Question".
- **PR-level (Conversation-tab) comment?** It has no review thread to resolve. Reply with the plain replies/issue-comment endpoint and end your reply with `(AI-generated via Claude Code w/ {model})`.
- **Closed-loop mode:** if a `closed-loop-runner` is driving this PR, it owns resolution as its Step 7 -- reply with `--no-resolve` and let the runner resolve. (This exception applies **only** under an active closed-loop runner; when you are the one addressing comments directly, you resolve.)

## Reply Requirements

1. **Reply to EVERY review comment you address** -- do not silently fix issues.
2. **Reply and resolve as you process each comment** -- not after all work is done.
3. **Be concise** -- state what you did, not lengthy explanations.
4. **Always disclose** -- `--disclose` handles it via the helper; on a raw reply, end with `(AI-generated via Claude Code w/ {model})`.

## Acceptable Reply Content

- "Fixed in {sha}" or "Fixed in {sha} - [brief description]" → **reply + resolve**
- "Addressed in {sha}" (for non-trivial changes) → **reply + resolve**
- "Won't fix - [brief reason]" (if declining, must explain) → reply, `--no-resolve`
- "Question: [clarification needed]" (if the comment is unclear) → reply, `--no-resolve`

## Resolution Rules

- A fixed comment is done only when **both** its reply and its resolution have posted. Confirm `resolved: true`.
- Every reply cites the specific commit SHA that fixed the issue (or, for a false positive, explains WHY with evidence; for a deferral, cites the follow-up issue number).
- Resolve **only** threads you have replied to, one specific thread at a time. Never bulk-resolve -- it can hide feedback opened since you last looked.

## Review Comment Categories

| Category | Meaning | Action |
|----------|---------|--------|
| A | Fix Now | Address in this PR → reply + resolve |
| B | Tech Debt | Create a follow-up issue, link it in the reply → reply + resolve |
| C | Design Decision | Escalate to human (stops any feedback loop) → reply, leave open |
| D | Disagree | Explain rationale in the reply → reply, `--no-resolve` |

## Follow-up Issues (Category B)

When deferring:
1. Actually create the issue with `gh issue create`.
2. Link the issue in your reply to the original comment.
3. Include context referencing the original PR and comment.

Never list a Category B item without creating the issue.
