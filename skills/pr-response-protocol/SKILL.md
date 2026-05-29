---
name: pr-response-protocol
description: "Protocol for responding to PR review comments. Preloaded by developer agents."
user-invocable: false
---

# PR Review Comment Response Protocol

When addressing PR review comments, you MUST post replies on GitHub as you process each comment. This is a completion gate — work is NOT complete until every addressed comment has a reply posted.

## Reply Requirements

1. **Reply to EVERY review comment you address** — do not silently fix issues.
2. **Use inline replies** (strongly preferred) — reply directly to the specific review comment thread.
3. **Reply BEFORE or AS you make the fix** — not after all work is done.
4. **Be concise** — state what you did, not lengthy explanations.
5. **Include AI disclosure** — every reply ends with `(AI-generated via Claude Code w/ {model})`.

## How to Reply Inline

```bash
gh api repos/{owner}/{repo}/pulls/{N}/comments/{comment_id}/replies \
  -f body="Fixed in {sha} - renamed to \`getCurrentUser()\` as suggested.

(AI-generated via Claude Code w/ {model})"
```

The `{comment_id}` comes from the `databaseId` field in the GraphQL `reviewThreads` response.

## Acceptable Reply Content

- "Fixed in {sha}" or "Fixed in {sha} - [brief description]"
- "Addressed in {sha}" (for non-trivial changes)
- "Won't fix - [brief reason]" (if declining, must explain)
- "Question: [clarification needed]" (if the comment is unclear)

## Never Resolve Without Replying

- Every reply should cite the specific commit SHA that fixed the issue.
- If the concern was a false positive, explain WHY with evidence.
- If tracked as follow-up, cite the issue number.
- Bulk-resolving threads without replies is unacceptable.

## Review Comment Categories

| Category | Meaning | Action |
|----------|---------|--------|
| A | Fix Now | Address in this PR |
| B | Tech Debt | Create a follow-up issue, link it in the reply |
| C | Design Decision | Escalate to human (stops any feedback loop) |
| D | Disagree | Explain rationale in the reply |

## Follow-up Issues (Category B)

When deferring:
1. Actually create the issue with `gh issue create`.
2. Link the issue in your reply to the original comment.
3. Include context referencing the original PR and comment.

Never list a Category B item without creating the issue.
