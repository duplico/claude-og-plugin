#!/usr/bin/env python3
"""
WSL2 / desktop notification hook (og plugin).

Forwards Claude Code Notification events (permission needed, idle waiting,
etc.) to a desktop toast so you notice them when the terminal is in the
background. Designed for WSL2 but degrades gracefully anywhere.

Notification path (first that works wins):
  1. notify-send            (Linux native; works under WSLg on Windows 11)
  2. powershell.exe BurntToast  (Windows toast from WSL2, if module installed)
  3. powershell.exe balloon (System.Windows.Forms fallback)
  4. no-op

Never blocks; always exits 0.

Configuration via environment:
  OG_NOTIFY_OFF   Set truthy to disable notifications.
"""

import json
import os
import shutil
import subprocess
import sys

TITLE = "Claude Code"


def is_truthy(name: str) -> bool:
    return str(os.environ.get(name, "")).lower() in ("1", "true", "yes", "on")


def get_message(data: dict) -> str:
    # Notification event carries a "message"; other events fall back to a generic line.
    msg = data.get("message") or data.get("hook_event_name") or "Needs your attention"
    cwd = data.get("cwd", "")
    if cwd:
        return f"{msg}\n{os.path.basename(cwd.rstrip('/'))}"
    return str(msg)


def try_notify_send(message: str) -> bool:
    if not shutil.which("notify-send"):
        return False
    try:
        subprocess.run(
            ["notify-send", "-a", TITLE, TITLE, message],
            timeout=5, check=False,
        )
        return True
    except Exception:
        return False


def try_powershell(message: str) -> bool:
    pwsh = shutil.which("powershell.exe") or shutil.which("pwsh.exe")
    if not pwsh:
        return False
    # Escape single quotes for PowerShell string literals.
    safe = message.replace("'", "''")
    burnt = (
        "if (Get-Module -ListAvailable -Name BurntToast) {"
        "Import-Module BurntToast;"
        f"New-BurntToastNotification -Text '{TITLE}', '{safe}'"
        "} else {"
        "Add-Type -AssemblyName System.Windows.Forms;"
        "$n = New-Object System.Windows.Forms.NotifyIcon;"
        "$n.Icon = [System.Drawing.SystemIcons]::Information;"
        "$n.Visible = $true;"
        f"$n.ShowBalloonTip(5000, '{TITLE}', '{safe}', "
        "[System.Windows.Forms.ToolTipIcon]::Info);"
        "Start-Sleep -Seconds 6; $n.Dispose()"
        "}"
    )
    try:
        subprocess.run(
            [pwsh, "-NoProfile", "-NonInteractive", "-Command", burnt],
            timeout=12, check=False,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return True
    except Exception:
        return False


def main():
    if is_truthy("OG_NOTIFY_OFF"):
        sys.exit(0)
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    message = get_message(data)

    if try_notify_send(message):
        sys.exit(0)
    try_powershell(message)
    sys.exit(0)


if __name__ == "__main__":
    main()
