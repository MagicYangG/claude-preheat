# macOS support (beta)

> Status: **beta** since `v0.4.0-beta.1`. The full mechanism — schedule → launchd fire → journal → clean removal — is verified end-to-end on GitHub Actions macOS runners (real launchd, real `pwsh`), plus the same 55-case self-test suite that gates Windows. What it has **not** had yet is long-lived use on a physical Mac: sleep/wake edge cases and weeks-long recurring agents. That is exactly what this beta is for — feedback checklist at the bottom.

Everything user-facing is identical to Windows: same commands, same `schedule.json`, same web panel at `localhost:7878`, same journal. Only the scheduling backend differs — per-user launchd agents instead of Windows Task Scheduler.

## Requirements

- macOS 13+ (Apple silicon or Intel)
- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-macos): `brew install --cask powershell`
- [Claude Code CLI](https://code.claude.com/docs) installed and logged in, with a Claude subscription
- No sudo, no admin rights — everything lives in your user account

## Install

```bash
git clone https://github.com/MagicYangG/claude-preheat.git
cd claude-preheat
pwsh -NoProfile -File ./install.ps1
```

`install.ps1` drops two thin shims into `~/.local/bin` so the commands work from zsh/bash without entering pwsh:

- `preheat` → `preheat.ps1`
- `claude-panel` → `panel.ps1`

If `~/.local/bin` is not on your PATH the installer prints the one-liner to add to `~/.zshrc`.

Then, in a new terminal:

```bash
./test.ps1        # optional but recommended: 55 cases, all should pass
preheat apply     # register the weekly preheats from schedule.json
preheat status    # confirm what got registered
claude-panel      # web panel at http://localhost:7878
```

## How it schedules

Each preheat becomes a per-user LaunchAgent:

```
~/Library/LaunchAgents/com.claude-preheat.*.plist
```

- `preheat apply` rewrites the weekly agents; `preheat off` removes every agent and plist — `ls ~/Library/LaunchAgents | grep claude-preheat` should then come back empty.
- One-shot preheats (`preheat at`, `preheat +2h`, `preheat reset`) register a one-time agent that removes itself after firing; stale ones are also swept on the next `apply`/fire.
- The fire itself is the same tiny headless `claude` prompt as on Windows; results land in `preheat-log.jsonl` in the repo directory (`launchd-err.log` next to it captures anything launchd sees on stderr).

## Known gap: sleep

This is the one real platform difference. Windows Task Scheduler can wake the PC from sleep via RTC wake timers; **launchd cannot wake a sleeping Mac**. If your Mac is asleep at fire time, launchd runs the job at the next wake — the preheat happens late, which is never worse than not having it installed, but the window anchors at wake time rather than your chosen time.

Mitigations, in order of preference:

1. Schedule preheats for times the Mac is normally awake.
2. Keep it on AC power with sleep disabled (`System Settings → Displays → Advanced → Prevent automatic sleeping on power adapter`, or `sudo pmset -c sleep 0`).
3. `preheat status` warns when system sleep is enabled so you at least know the gap applies to you.

Notifications about fires use standard macOS notifications (osascript) — no extra install.

## Feedback checklist

If you run the beta, an issue with the following (success reports are just as useful as failures) makes the difference for v0.4.0 final:

1. macOS version + chip (e.g. `14.5 / M2`), `pwsh -v`
2. `preheat status -Json` output
3. Last few lines of `preheat-log.jsonl` — did the fire happen at the scheduled minute (`"ok":true` and a timely `ts`)?
4. `launchd-err.log` if it exists and is non-empty
5. Anything around sleep: was the Mac asleep at fire time, and when did the fire actually land?

Open issues at <https://github.com/MagicYangG/claude-preheat/issues>.
