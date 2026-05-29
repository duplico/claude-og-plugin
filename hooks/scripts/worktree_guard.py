#!/usr/bin/env python3
"""
Worktree enforcement hook (og plugin).
Blocks Edit/Write to a repo's MAIN checkout, forcing work into git worktrees.

OPT-IN: inactive unless OG_REQUIRE_WORKTREE is truthy. Set it in a project's
.claude/settings.json env block for repos where subagents must use worktrees.

Configuration via environment:
  OG_REQUIRE_WORKTREE        Truthy to activate this guard.
  OG_ALLOW_MAIN_CHECKOUT     Truthy to bypass (the human is editing directly).
  CLAUDE_ALLOW_MAIN_CHECKOUT Also honored as a bypass (legacy name).

A path is allowed when it is:
  - inside a git worktree (.git is a file pointing to /worktrees/), OR
  - an AI-tooling file (.claude/, CLAUDE.md, .github/copilot-instructions.md,
    .ai/), even in the main checkout, OR
  - not inside any git repo.

A path is blocked when it is in a repo's main checkout (.git is a directory)
or inside a git submodule (.git file pointing to /modules/).
"""

import json
import os
import sys

ALLOWED_SUBSTRINGS = [
    "/.claude/",
    "/.ai/",
    "/.github/copilot-instructions.md",
]
ALLOWED_BASENAMES = ["CLAUDE.md"]


def is_truthy(name: str) -> bool:
    return str(os.environ.get(name, "")).lower() in ("1", "true", "yes", "on")


def find_git_marker(start_dir: str) -> str | None:
    """Walk up from start_dir to find a .git entry. Return its path or None."""
    cur = start_dir
    while True:
        candidate = os.path.join(cur, ".git")
        if os.path.exists(candidate):
            return candidate
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


def classify(file_path: str) -> tuple[str, str | None]:
    """
    Return (verdict, detail).
    verdict in {"allow", "block-main", "block-submodule"}.
    """
    start = os.path.dirname(file_path) or "/"
    marker = find_git_marker(start)
    if marker is None:
        return "allow", None  # not in a repo

    repo_root = os.path.dirname(marker)
    if os.path.isdir(marker):
        return "block-main", repo_root

    # marker is a file: worktree or submodule
    try:
        with open(marker) as f:
            content = f.read()
        if "/worktrees/" in content:
            return "allow", repo_root
        if "/modules/" in content:
            return "block-submodule", repo_root
    except Exception:
        pass
    # Unknown .git file form: be cautious, treat as main
    return "block-main", repo_root


def main():
    if not is_truthy("OG_REQUIRE_WORKTREE"):
        sys.exit(0)
    if is_truthy("OG_ALLOW_MAIN_CHECKOUT") or is_truthy("CLAUDE_ALLOW_MAIN_CHECKOUT"):
        sys.exit(0)

    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    if input_data.get("tool_name", "") not in ("Edit", "Write"):
        sys.exit(0)

    file_path = input_data.get("tool_input", {}).get("file_path", "")
    if not file_path:
        sys.exit(0)

    file_path = os.path.abspath(os.path.expanduser(file_path))

    # AI-tooling allowlist (editable even in main checkout)
    if any(s in file_path for s in ALLOWED_SUBSTRINGS):
        sys.exit(0)
    if os.path.basename(file_path) in ALLOWED_BASENAMES:
        sys.exit(0)

    verdict, repo_root = classify(file_path)
    if verdict == "allow":
        sys.exit(0)

    if verdict == "block-submodule":
        print(
            f"""BLOCKED: Attempting to modify a file inside a git submodule.

File: {file_path}
Submodule under: {repo_root}

Submodules are checked out by their parent repo; edits here will be lost or
cause conflicts. Work in the submodule's own repository checkout instead.""",
            file=sys.stderr,
        )
        sys.exit(2)

    # block-main
    print(
        f"""BLOCKED: Attempting to modify a file in a repo's main checkout.

File: {file_path}
Repo: {repo_root} (main checkout)

This project requires git worktrees for modifications (OG_REQUIRE_WORKTREE is set).
Create a worktree first:
  cd {repo_root}
  git worktree add ../$(basename {repo_root})-worktrees/task-$(date +%s) -b task-name

Then make your changes in the worktree.

If you are the human and intend to edit the main checkout directly,
set OG_ALLOW_MAIN_CHECKOUT=1.""",
        file=sys.stderr,
    )
    sys.exit(2)


if __name__ == "__main__":
    main()
