#!/usr/bin/env python3
"""
Git branch protection hook (og plugin).
Blocks dangerous git operations that could affect protected branches.

Configuration via environment (set in project or user settings.json):
  OG_PROTECTED_BRANCHES   Comma-separated branch names to protect.
                          Default: main,master,develop,default
  OG_BRANCH_GUARD_OFF     Set truthy to disable this guard entirely.
"""

import json
import os
import re
import subprocess
import sys

DEFAULT_PROTECTED = "main,master,develop,default"


def protected_branches() -> list[str]:
    raw = os.environ.get("OG_PROTECTED_BRANCHES", DEFAULT_PROTECTED)
    return [b.strip() for b in raw.split(",") if b.strip()]


def dangerous_patterns(branches: list[str]) -> list[tuple[str, str]]:
    alt = "|".join(re.escape(b) for b in branches)
    return [
        (rf"\bgit\b.*\bpush\b.*\s({alt})\b", "push to protected branch"),
        (rf"\bgit\b.*\bpush\b.*--force\b.*\s({alt})\b", "force push to protected branch"),
        (rf"\bgit\b.*\bpush\b.*\s-f\b.*\s({alt})\b", "force push to protected branch"),
        (rf"\bgit\b.*\bpush\b.*--force-with-lease\b.*\s({alt})\b", "force push to protected branch"),
        (rf"\bgit\b.*\bpush\b.*\s({alt})\b.*--force", "force push to protected branch"),
        (rf"\bgit\b.*\bpush\b.*\s({alt})\b.*\s-f\b", "force push to protected branch"),
        (rf"\bgit\b.*\bbranch\b.*\s-[dD]\s+({alt})\b", "delete protected branch"),
        (rf"\bgit\b.*\breset\b.*--hard.*origin/({alt})", "hard reset to protected branch"),
    ]


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


def extract_git_working_dir(command: str) -> str | None:
    match = re.search(r"\bgit\b.*-C\s+(\S+)", command)
    return match.group(1) if match else None


def is_push_on_protected_branch(command: str, branches: list[str]) -> bool:
    if not re.search(r"\bgit\b.*\bpush\b", command, re.IGNORECASE):
        return False
    # Explicit "push <remote> <branch>" is handled by the pattern check
    if re.search(r"\bpush\b\s+(?:-\S+\s+)*(\S+)\s+(\S+)", command):
        return False
    cwd = extract_git_working_dir(command)
    current = get_current_branch(cwd)
    return bool(current and current in branches)


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

    for pattern, reason in dangerous_patterns(branches):
        if re.search(pattern, command, re.IGNORECASE):
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

    if is_push_on_protected_branch(command, branches):
        current = get_current_branch()
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
