#!/usr/bin/env python3
"""
Git branch protection hook (og plugin).
Blocks dangerous git operations that could affect protected branches, and
blocks pull-request merges (OG-0: PRs are merged by a human).

Configuration via environment (set in project or user settings.json):
  OG_PROTECTED_BRANCHES   Comma-separated branch names to protect.
                          Default: main,master,develop,default
  OG_ALLOW_MERGE          Set truthy to disable only the PR-merge rules.
  OG_BRANCH_GUARD_OFF     Set truthy to disable this guard entirely.
"""

import json
import os
import re
import shlex
import subprocess
import sys

DEFAULT_PROTECTED = "main,master,develop,default"

# git subcommands that cannot push or change branch state, regardless of what
# path arguments they carry (e.g. `git show HEAD:bin/og-push` is not a push).
READ_ONLY_SUBCOMMANDS = {
    "show", "log", "diff", "cat-file", "ls-tree", "ls-files",
    "rev-parse", "status", "blame",
}

# Global git options that take their value as a separate following token
# (`-C <path>`, `-c key=val`). `--git-dir=<path>` and similar carry their
# value inline in one token and need no special handling.
_GLOBAL_OPTS_WITH_SEPARATE_VALUE = {"-C", "-c"}

_SHELL_OPERATORS = {"&&", "||", ";", "|"}

_FORCE_FLAGS = {"-f", "--force", "--force-with-lease"}


def protected_branches() -> list[str]:
    raw = os.environ.get("OG_PROTECTED_BRANCHES", DEFAULT_PROTECTED)
    return [b.strip() for b in raw.split(",") if b.strip()]


def _tokenize(command: str) -> list[str]:
    try:
        return shlex.split(command)
    except ValueError:
        # Unbalanced quotes -- fall back to a naive split rather than failing closed.
        return command.split()


def git_invocations(command: str):
    """Yield (subcommand, rest_tokens) for each top-level `git <subcommand> ...`
    invocation in the command, skipping git's global options to find the
    subcommand token itself. `rest_tokens` runs up to the next shell operator
    (&&, ||, ;, |) or end of command.
    """
    tokens = _tokenize(command)
    n = len(tokens)
    i = 0
    while i < n:
        if tokens[i] != "git":
            i += 1
            continue
        j = i + 1
        while j < n and tokens[j] not in _SHELL_OPERATORS and tokens[j].startswith("-"):
            if tokens[j] in _GLOBAL_OPTS_WITH_SEPARATE_VALUE and j + 1 < n:
                j += 2
            else:
                j += 1
        if j >= n or tokens[j] in _SHELL_OPERATORS:
            i = j
            continue
        subcommand = tokens[j]
        k = j + 1
        rest = []
        while k < n and tokens[k] not in _SHELL_OPERATORS:
            rest.append(tokens[k])
            k += 1
        yield subcommand, rest
        i = k


def _matches_protected(token: str, branches: list[str]) -> bool:
    """True if a positional argument names a protected branch: as a bare
    branch name, a `<remote>/<branch>` ref, or the destination side of a
    `src:dst` refspec."""
    candidate = token.split(":")[-1]
    if candidate in branches:
        return True
    if "/" in candidate and candidate.rsplit("/", 1)[-1] in branches:
        return True
    return False


def _positionals(tokens: list[str]) -> list[str]:
    return [t for t in tokens if not t.startswith("-")]


def _check_push(rest: list[str], branches: list[str]) -> str | None:
    if not any(_matches_protected(t, branches) for t in _positionals(rest)):
        return None
    force = any(t in _FORCE_FLAGS or t.startswith("--force-with-lease=") for t in rest)
    return "force push to protected branch" if force else "push to protected branch"


def _check_branch_delete(rest: list[str], branches: list[str]) -> str | None:
    if not any(t in ("-d", "-D", "--delete") for t in rest):
        return None
    if any(_matches_protected(t, branches) for t in _positionals(rest)):
        return "delete protected branch"
    return None


def _check_hard_reset(rest: list[str], branches: list[str]) -> str | None:
    if "--hard" not in rest:
        return None
    if any(_matches_protected(t, branches) for t in _positionals(rest)):
        return "hard reset to protected branch"
    return None


def check_dangerous_git(command: str, branches: list[str]) -> str | None:
    """Return a reason string if any git invocation in `command` would push,
    delete, or hard-reset a protected branch; None otherwise."""
    for subcommand, rest in git_invocations(command):
        if subcommand in READ_ONLY_SUBCOMMANDS:
            continue
        if subcommand == "push":
            reason = _check_push(rest, branches)
        elif subcommand == "branch":
            reason = _check_branch_delete(rest, branches)
        elif subcommand == "reset":
            reason = _check_hard_reset(rest, branches)
        else:
            reason = None
        if reason:
            return reason
    return None


def has_bare_push(command: str) -> bool:
    """True if the command contains a `git push` invocation with no explicit
    remote/branch/refspec argument -- i.e. one whose target depends on the
    current branch."""
    for subcommand, rest in git_invocations(command):
        if subcommand == "push" and not _positionals(rest):
            return True
    return False


def get_current_branch(cwd: str | None = None) -> str | None:
    try:
        result = subprocess.run(
            ["git", "branch", "--show-current"],
            capture_output=True, text=True, timeout=5, cwd=cwd,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return None


def resolve_working_dir(command: str) -> str | None:
    """Best-effort working directory the command runs `git` from: a leading
    `cd <path> &&`/`;`, else a `-C <path>` global git option, else None
    (meaning: use the hook's own cwd). A `cd` with no path means $HOME.

    Callers pass the result straight to get_current_branch(), which already
    swallows any subprocess failure (bad path, not a git repo) and returns
    None -- so an unresolvable or non-repo directory fails open here rather
    than blocking on a guess.
    """
    tokens = _tokenize(command)
    if tokens and tokens[0] == "cd":
        if len(tokens) >= 2 and tokens[1] not in _SHELL_OPERATORS:
            return os.path.expanduser(tokens[1])
        return os.path.expanduser("~")
    match = re.search(r"\bgit\b.*?-C\s+(\S+)", command)
    if match:
        return os.path.expanduser(match.group(1).strip("'\""))
    return None


def merge_patterns() -> list[tuple[str, str]]:
    return [
        (r"\bgh\s+pr\s+merge\b", "gh pr merge"),
        (r"\bgh\b.*\bapi\b.*/pulls/\d+/merge\b", "gh api PR-merge endpoint"),
    ]


MERGE_BLOCK_MESSAGE = """BLOCKED: Pull request merge detected (OG-0: Never merge PRs).

Pull requests are merged by a human, not an agent -- this includes enabling
auto-merge, since that merges the PR without further human action.

When your changes are ready, tell the user the PR is ready for human merge.
Do not merge it yourself, in any form.

To disable this specific rule, set OG_ALLOW_MERGE=1.
To disable all git-branch-guard checks, set OG_BRANCH_GUARD_OFF=1."""


def main():
    if os.environ.get("OG_BRANCH_GUARD_OFF"):
        sys.exit(0)
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    if input_data.get("tool_name", "") != "Bash":
        sys.exit(0)

    command = input_data.get("tool_input", {}).get("command", "")
    branches = protected_branches()

    if not os.environ.get("OG_ALLOW_MERGE"):
        for pattern, _ in merge_patterns():
            if re.search(pattern, command, re.IGNORECASE):
                print(MERGE_BLOCK_MESSAGE, file=sys.stderr)
                sys.exit(2)

    reason = check_dangerous_git(command, branches)
    if reason:
        print(
            f"""BLOCKED: Dangerous git operation detected ({reason}).

Protected branches: {', '.join(branches)}

Changes should go through feature branches and PRs. Create a feature branch
first, then push to that branch.

To change which branches are protected, set OG_PROTECTED_BRANCHES.
To disable this guard, set OG_BRANCH_GUARD_OFF=1.
If you believe this is a false positive, ask the user for guidance.""",
            file=sys.stderr,
        )
        sys.exit(2)

    if has_bare_push(command):
        cwd = resolve_working_dir(command)
        current = get_current_branch(cwd)
        if current and current in branches:
            print(
                f"""BLOCKED: Attempting to push while on protected branch '{current}'.

Create a feature branch first:
  git checkout -b feature/your-feature-name
  git push -u origin feature/your-feature-name

Protected branches: {', '.join(branches)}""",
                file=sys.stderr,
            )
            sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()
