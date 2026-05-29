#!/usr/bin/env python3
"""
GitHub AI-disclosure hook (og plugin).
Blocks `gh` commands that post user-visible content without AI disclosure.

Configuration via environment:
  OG_DISCLOSURE_OFF   Set truthy to disable this guard.
"""

import json
import os
import re
import sys

DISCLOSURE_PATTERNS = [
    r"\bclaude\b",
    r"\banthro?pic\b",
    r"\bai[\s-]?(generated|assisted|written)\b",
    r"\bgenerated\s+(with|by)\s+\w*\s*(ai|claude|llm)\b",
    r"co-authored-by:.*claude",
    r"co-authored-by:.*anthropic",
    r"\bllm\b.*\b(generated|wrote|drafted)\b",
    r"<!--\s*ai:closed-loop",
]

POSTING_COMMANDS = [
    r"gh\s+pr\s+create\b",
    r"gh\s+pr\s+comment\b",
    r"gh\s+pr\s+review\b",
    r"gh\s+issue\s+create\b",
    r"gh\s+issue\s+comment\b",
    r"gh\s+api\s+.*-f\s+body=",
    r"gh\s+api\s+.*--field\s+body=",
    r'gh\s+api\s+.*-F\s+body=',
    r"gh\s+api\s+.*/replies\b",
    r"gh\s+api\s+.*/comments\b.*-[fFX]",
]


def has_disclosure(text: str) -> bool:
    text_lower = text.lower()
    return any(re.search(p, text_lower) for p in DISCLOSURE_PATTERNS)


def is_posting_command(command: str) -> bool:
    return any(re.search(p, command) for p in POSTING_COMMANDS)


def extract_body_files(command: str) -> list[str]:
    paths = []
    for match in re.finditer(r"--body-file[= ](\S+)", command):
        paths.append(match.group(1))
    for match in re.finditer(r"-F\s+body=@(\S+)", command):
        paths.append(match.group(1))
    return paths


def body_files_have_disclosure(command: str) -> bool:
    for path in extract_body_files(command):
        try:
            with open(path) as f:
                if has_disclosure(f.read()):
                    return True
        except (OSError, IOError):
            pass
    return False


def main():
    if os.environ.get("OG_DISCLOSURE_OFF"):
        sys.exit(0)
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    if input_data.get("tool_name", "") != "Bash":
        sys.exit(0)

    command = input_data.get("tool_input", {}).get("command", "")
    if not is_posting_command(command):
        sys.exit(0)
    if has_disclosure(command) or body_files_have_disclosure(command):
        sys.exit(0)

    print(
        """BLOCKED: GitHub posting command missing AI disclosure.

AI-generated content posted to GitHub should include disclosure. Add one of:
  - "(AI-generated via Claude Code w/ <Model>)"  (comments/replies)
  - "Co-Authored-By: Claude <Model> <noreply@anthropic.com>"  (commits)
  - Similar text naming the tool and specific model.

Include the specific model name when known (e.g., Opus 4.7, Sonnet 4.6, Haiku 4.5).
To disable this guard, set OG_DISCLOSURE_OFF=1. Then retry the command.""",
        file=sys.stderr,
    )
    sys.exit(2)


if __name__ == "__main__":
    main()
