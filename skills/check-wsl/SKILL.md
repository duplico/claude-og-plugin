---
name: check-wsl
description: "Run the og-check-wsl diagnostic: probe the WSL2/Windows interop surface (notify-send, WSLg, PowerShell, BurntToast, cmd.exe, clip.exe, sshd) and report which path the plugin's notify hook will use. Pass --test-notify to actually fire a desktop toast."
disable-model-invocation: true
argument-hint: "[--test-notify]"
allowed-tools: Bash
---

# /og:check-wsl — WSL2 / Windows interop diagnostic

Run the diagnostic script and present the output verbatim (it's already
formatted with green/yellow/red marks). The script ships in the plugin's
`bin/` directory and is on PATH.

```bash
og-check-wsl $ARGUMENTS
```

If the user passed `--test-notify`, the script will fire real desktop
notifications through each available path. Tell them to look for the toast
on the Windows side.

Common remediations to surface if marks come back yellow/red:

| Mark | Item | Fix |
|---|---|---|
| `✗` notify-send | install: `sudo apt install -y libnotify-bin` |
| `!` BurntToast | install: `powershell.exe -c "Install-Module BurntToast -Scope CurrentUser -Force"` |
| `!` WSLg | upgrade to WSL2 ≥ 2.0 (Windows 11) — `wsl --update` |
| `!` systemd | enable in `/etc/wsl.conf`: `[boot]\nsystemd=true`, then `wsl --shutdown` |
| `!` sshd on :22 | install/start: `sudo apt install -y openssh-server && sudo systemctl enable --now ssh` |
| `!` wslview | optional: `sudo apt install -y wslu` |

If everything is green, just confirm the user is good to go.
