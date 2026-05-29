#!/usr/bin/env python3
"""
Worktree cleanup safety hook (og plugin).

Detects when a command would remove the directory the shell is currently in
(e.g. `git worktree remove` or `rm -rf` of the CWD). Instead of blocking, it
auto-prepends `cd <safe-dir> &&` to move the shell to safety first.

Safe directory resolution:
  OG_WORKTREE_SAFE_DIR   Explicit safe dir. If unset, uses $HOME.

Always active; only acts on removal commands that endanger the CWD.
"""

import json
import os
import re
import sys


def safe_dir() -> str:
    return os.environ.get("OG_WORKTREE_SAFE_DIR") or os.path.expanduser("~")


def is_removal_command(command: str) -> bool:
    if re.search(r"\bgit\b.*\bworktree\b.*\bremove\b", command):
        return True
    if re.search(r"\brm\b\s+-\S*r", command):
        return True
    if re.search(r"\brmdir\b", command):
        return True
    return False


def extract_removal_targets(command: str) -> list[str]:
    targets: list[str] = []
    match = re.search(r"\bworktree\s+remove\s+(?:--force\s+)?(\S+)", command)
    if match:
        targets.append(match.group(1))
    # path-like tokens for rm/rmdir (skip flags)
    for token in command.split():
        if token.startswith("-"):
            continue
        if "/" in token and token not in targets:
            targets.append(token)
    return targets


def resolve_path(path: str, cwd: str) -> str:
    expanded = os.path.expanduser(path)
    if os.path.isabs(expanded):
        return os.path.normpath(expanded)
    return os.path.normpath(os.path.join(cwd, expanded))


def is_cwd_at_risk(cwd: str, command: str) -> bool:
    for target in extract_removal_targets(command):
        abs_target = resolve_path(target, cwd)
        if cwd == abs_target or cwd.startswith(abs_target + "/"):
            return True
    return False


def has_safe_cd_prefix(command: str) -> bool:
    match = re.match(r"cd\s+(\S+)\s*&&", command.strip())
    if not match:
        return False
    cd_target = match.group(1)
    return cd_target.startswith("/") or cd_target.startswith("~")


def emit_fix(command: str, cwd: str, dest: str):
    fixed = f"cd {dest} && {command}"
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": (
                    f"Auto-prefixed 'cd {dest}' to prevent CWD deletion "
                    f"(shell was in {cwd}, inside the removal target)"
                ),
                "updatedInput": {"command": fixed},
            }
        },
        sys.stdout,
    )


def main():
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    if input_data.get("tool_name", "") != "Bash":
        sys.exit(0)

    command = input_data.get("tool_input", {}).get("command", "")
    if not is_removal_command(command):
        sys.exit(0)
    if has_safe_cd_prefix(command):
        sys.exit(0)

    cwd = input_data.get("cwd", "")
    dest = safe_dir()

    if not cwd:
        print(
            f"BLOCKED: Cannot determine working directory for safety check.\n"
            f"Prepend: cd {dest} && ...",
            file=sys.stderr,
        )
        sys.exit(2)

    if is_cwd_at_risk(cwd, command):
        emit_fix(command, cwd, dest)
        sys.exit(0)

    sys.exit(0)


if __name__ == "__main__":
    main()
