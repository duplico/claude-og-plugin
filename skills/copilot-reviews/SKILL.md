---
name: copilot-reviews
description: "How to trigger and correctly find GitHub Copilot code reviews on a PR. Opt-in -- load only when the user brings Copilot into the review cycle."
user-invocable: false
---

# Working with GitHub Copilot reviews

This is an **opt-in capability**, not a mandatory step. Only use it when the user
explicitly brings Copilot into the loop -- e.g. "I triggered a Copilot review, go
look at its comments" or "start requesting Copilot reviews on this PR." Never
request a Copilot review or gate progress on one unless asked.

Two entry points:
- **Detect-only** -- the user already requested the review; find and act on its
  findings (`og-copilot-comments`).
- **Trigger-then-detect** -- you request the review, then poll for it
  (`og-copilot-review`, then `og-copilot-comments`).

## The three facts that make this non-obvious

1. **Copilot posts under two logins across two endpoints.** A naive exact-match
   on one login silently finds nothing.

   | Object | Endpoint | `user.login` |
   |---|---|---|
   | Review (summary) | `/repos/{slug}/pulls/{n}/reviews` | `copilot-pull-request-reviewer[bot]` |
   | Inline review comment | `/repos/{slug}/pulls/{n}/comments` | `Copilot` |

   Always check **both** endpoints and match case-insensitively by substring:
   `select(.user.login | ascii_downcase | contains("copilot"))`. A review can be
   summary-only (no inline comments) or "reviewed, generated N comments" -- polling
   only one endpoint misses cases.

2. **Copilot does not auto-review on push.** After fix commits, Copilot will not
   re-review until the review is **re-requested**. A wait-for-Copilot flow must
   **request first, then poll** -- polling alone hangs forever after round one.

3. **`requested_reviewers` is unreliable for Copilot.** It may be empty even while
   a review is pending or already posted. Never gate on it -- gate on findings
   (and, for freshness, on timestamps vs. the head commit).

## Helper scripts

Ship with the og plugin, on your PATH (else in the plugin's `bin/`).

| Script | Purpose |
|---|---|
| `og-copilot-review <slug> <PR>` | Request/re-request a Copilot review via the REST `requested_reviewers` endpoint (bot login `copilot-pull-request-reviewer[bot]`), then **verifies** a Copilot login actually appears in the response -- never trusts an exit code. Prints JSON; exits non-zero if the request didn't take. |
| `og-copilot-comments <slug> <PR> [--since ISO \| --since-head]` | List Copilot findings from **both** endpoints, case-insensitively, optionally timestamp-gated. Prints JSON `{review_count, comment_count, latest_at, has_findings, reviews[], comments[]}`. Each `comments[]` entry's `url` ends in `#discussion_r<ID>` -- that `<ID>` is the comment databaseId to reply to. |
| `og-pr-reply-resolve <slug> <PR> <comment_id> "<body>" [--disclose MODEL]` | Reply to a Copilot (or human) review comment **and** resolve its thread in one call. Use when a finding is fixed; pass `--no-resolve` for "won't fix"/questions. |

`--since-head` gates on the current head commit's **commit timestamp** (the
committer date) -- use it to focus on Copilot feedback on the latest revision,
ignoring stale findings from earlier rounds. Note this is the commit's timestamp,
not the moment it was pushed; the two usually coincide but can differ (e.g. a
rebase or an amended older commit), so treat it as a close approximation.

## Recipe A -- detect only

The user already requested the review. Find fresh findings and route them:

```bash
og-copilot-comments <slug> <PR> --since-head
```

If `has_findings` is true, hand the `reviews[]` + `comments[]` to a reviewer agent
to categorize (A: fix now / B: defer / C: design decision / D: disagree), then fix
as usual. Copilot findings are just another review source -- treat them like human
review comments once surfaced. When you fix one, close it with
`og-pr-reply-resolve` (reply citing the SHA **and** resolve the thread in one step);
for "won't fix"/questions, reply with `--no-resolve` and leave it open.

## Recipe B -- trigger, then poll

```bash
# 1. Request the review (does not auto-happen on push).
og-copilot-review <slug> <PR>

# 2. Poll both endpoints, gated to this head commit, until findings appear.
#    Copilot typically takes ~1-3 min. Bound your polling; don't loop forever.
og-copilot-comments <slug> <PR> --since-head    # repeat until has_findings, then act
```

Each subsequent round: push fixes, **re-request** (`og-copilot-review` again),
then poll with `--since-head` for the new review. Requesting on an unchanged head
is deduped by GitHub ("already up to date") -- a fresh review only lands after a new
head commit. If a stale prior review blocks a re-review, minimize (mark outdated)
Copilot's previous review in the UI/GraphQL first.

## Boundaries

- **Opt-in only** -- never trigger or wait on Copilot unless the user asked.
- **Bound your polling** -- Copilot is not guaranteed to review; cap wait time and
  report if nothing lands rather than looping indefinitely.
- Copilot findings carry the same disclosure/response norms as any PR review; reply
  to them via the normal PR response protocol.
