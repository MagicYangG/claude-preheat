# claude-preheat

**English** | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

https://github.com/user-attachments/assets/b0614c1a-fe78-4464-a11e-aaeb1794829e

For Claude subscribers who work in the Claude Code CLI on Windows or macOS. The 5-hour usage window is anchored by the first message sent while no window is active — a scheduled tiny ping anchors it at the time you choose, so your real session spans two 5-hour windows instead of being cut mid-flow. It offers:

1. Weekly recurring preheats
2. One-shot preheats
3. **Codex (beta)**: the same preheat for OpenAI Codex, see [Codex (beta)](#codex-beta)

## Web panel

Local address: `localhost:7878` (bilingual English/中文, one-click toggle in the header)

Modules: live quota strip (5-hour + weekly, with exact reset times — run `preheat statusline on` once to feed it) / weekly reset-time editor (writes `schedule.json` and applies it) / one-shot preheats / 7-day window-utilization line (`preheat learn` under the hood) / Claude | Codex switch at the top (Codex is a beta)

![panel](docs/panel.png)

## Quick start

**Requirements**: Windows 10/11 or macOS 13+ (macOS setup: [macOS guide](docs/MAC-BETA.md)); [Claude Code CLI](https://code.claude.com/docs) installed and logged in; a Claude subscription; PowerShell 7 (pwsh); no admin rights needed; Claude Code and a Claude subscription are not needed if you only preheat Codex (beta), see [Codex (beta)](#codex-beta)

**Recommended: paste this into Claude Code (or any AI coding tool) and let it install everything for you:**

```text
Clone https://github.com/MagicYangG/claude-preheat and set it up:
1. git clone, then run install.ps1 inside the repo directory
2. Ask me for the weekly times I want the window to reset, write them into schedule.json
   (reset = the target reset time; the fire time is automatically reset minus 5 hours)
3. Run ./test.ps1 and confirm every case passes
4. Run preheat apply, then show me the output of preheat status
Do not register or change anything beyond what install.ps1 and preheat apply create.
```

When it's done, open `http://localhost:7878` in your browser and drive everything from the panel.

**Manual install is three steps**: `git clone` → `./install.ps1` → run `preheat apply` in a new terminal. Full commands in the [command reference](#command-reference).

## Notes

1. **Claude Code CLI required** (not for Codex-only use): a preheat is a tiny headless prompt executed through the CLI
2. **What a ping costs**: one short `haiku` prompt — roughly 40k input tokens once Claude Code's own system prompt is counted (about $0.04 at API prices). It counts toward both the 5-hour window and the weekly window, so a preheat is cheap but not free. Pinging while a window is already active does not move the anchor. When a *scheduled* preheat lands in a window that is already running, it books one follow-up ping for the minute that window expires (so that day costs two pings) - at most one per window, and never when the next scheduled preheat comes first; `"chase": false` in `schedule.json` turns follow-ups off. A one-shot in the panel that you did not create is such a follow-up. The weekly window is not managed by this tool.
3. **Waking from sleep**: a scheduled fire can only wake the PC if wake timers are enabled in the active power plan — `preheat status` warns when they are off (Windows mechanism; launchd cannot wake a sleeping Mac — see the [macOS guide](docs/MAC-BETA.md)). A follow-up ping never wakes a sleeping PC: if the machine is asleep at that minute it is simply skipped.
4. **The window is account-level**: claude.ai, Claude Desktop, and Claude Code draw from one shared usage pool, so a preheat anchors the window for every surface — the CLI is just the ignition needle
5. **When the fire can and cannot run (Windows)**: the task runs only while you are signed in (a locked screen is fine; a signed-out PC skips that fire). It now also runs on battery. If you installed before this change, run `preheat apply` once more so the registered tasks pick up the new settings.
6. **Do not move or rename the repo directory after `preheat apply`**: the scheduled tasks, the launchd plists and the profile functions all carry absolute paths. If you do move it, run `install.ps1` and `preheat apply` again — `preheat status` flags tasks whose script path no longer exists.

## Codex (beta)

Codex support is a beta for now. The same `schedule.json`, panel and scheduled tasks can also preheat the OpenAI Codex 5-hour window; each side keeps its own schedule and neither affects the other. Beta testing and how to send back evidence: [Codex beta guide](docs/CODEX-BETA.md).

**Requirements**: the [Codex CLI](https://learn.chatgpt.com/docs/codex/cli) or the Codex desktop app, signed in with a ChatGPT account (an API-key sign-in has no 5-hour window, so nothing is pinged). Plus and other plans with a 5-hour window work; Free / Go / Pro skip and spend nothing when no 5-hour window can be read (Go, checked on a real account, has only a 30-day window); any other plan whose window cannot be read is still pinged and spends quota. Claude Code and a Claude subscription are not needed if you only preheat Codex.

**Enable**: just ask your AI coding tool to set it up (say "set Codex preheat to a 15:00 reset on weekdays"), or open the panel, switch to the Codex tab at the top, pick the times and apply (only the Codex side is touched). To edit by hand, add a `codex` key to `schedule.json` in the repo directory (created by install.ps1), at the same level as the existing `rules` and `proxy` (add a comma after the previous entry; fire time is again reset − 5h):

```json
"codex": { "rules": [ { "days": ["Mon", "Tue", "Wed", "Thu", "Fri"], "reset": "15:00" } ], "chase": true }
```
Then run `preheat apply -Provider codex`. If you only use Codex, set the top-level `rules` to `[]` or always pass `-Provider codex`; otherwise plain `preheat apply` looks for claude and reports an error when it is missing.

**Check**: run `preheat status -Codex` (read-only, spends nothing); you should see the plan, the 5-hour window and the registered `ClaudePreheat-Codex-*` tasks. For an immediate test, use `preheat +2m -Codex`.

**Each fire** (the scheduled moment a ping may be sent):
1. It first reads the quota for free; if a window is running, no ping, and one follow-up preheat is booked about 2 minutes after it expires (same `chase` rule)
2. Only an idle window gets one tiny ping; if the quota read itself fails (network, proxy, timeout), it pings anyway
3. If the window still did not start after 2 pinged fires in a row, later fires stop pinging and notify once, until you run `preheat apply` again

**Cost**: every Codex ping spends real quota, counted against both the 5-hour and the weekly limit; only the quota reads are free.

**Notes**:
1. Desktop-only installs work: the codex executable is looked up again at every fire. If it cannot be found, on Windows set the user-level environment variable `PREHEAT_CODEX_EXE` to its full path; on macOS add codex's folder to PATH in the terminal where you run `preheat apply`
2. If you changed `CODEX_HOME`, run `preheat apply` once in a terminal where it is set; it is saved as `codex.home`. The `proxy` is shared by both sides. With both sides scheduled, Windows may wake the PC twice a night
3. Leaving: `preheat off -Codex` removes only the Codex tasks, but while the `codex` section exists the next plain `preheat apply` registers them again; to turn Codex off for good, delete the `codex` section (no section = Codex off)

## Where did the relay go?

v0.2.0 shipped a cross-window auto-resume ("relay"). Claude Code v2.1.234 now auto-continues at a limit reset natively (on by default — `/config` → "Continue automatically at usage limit"), so v0.3.0 retired relay; the last relay release is preserved at tag [v0.2.0](https://github.com/MagicYangG/claude-preheat/releases/tag/v0.2.0). What the native feature does not do — start your window before you sit down — is exactly what preheat does.

## Command reference

The panel covers everyday use; the commands below are for terminal people and scripts.

```powershell
preheat apply           # register weekly preheat tasks from schedule.json (re-run after edits)
preheat status          # local activity + registered tasks + recent journal
preheat reset 20:00     # one-shot: make the window reset at 20:00 (fires at 15:00)
preheat at 15:00        # one-shot: fire at 15:00
preheat +2h             # one-shot: fire 2 hours from now
preheat learn           # schedule suggestions from your last 30 days + window-utilization report (learn auto applies)
                         # (natural rhythm from your own prompts; preheat pings are not counted)
preheat statusline on   # tap the statusline so exact reset times feed the panel quota strip (pure passthrough; off restores)
preheat off             # remove all preheat tasks
preheat status -Codex   # live Codex read: account, plan, 5-hour and weekly window, whether the reset moved later, recent fires
preheat report -Codex   # redacted Codex fire evidence, for pasting into an issue
preheat apply -Provider codex  # apply the Codex side only (no flag = both sides)
preheat at 10:00 -Codex # one-shot Codex preheat; reset / +2h take -Codex too
preheat off -Codex      # remove only the Codex preheat tasks (without -Codex = both sides)
claude-panel            # open the local web panel
```

In `schedule.json`, `reset` is the **target reset time**; the fire time is automatically reset − 5h. An empty `proxy` means no proxy.

## Uninstall

```powershell
preheat off             # remove all preheat tasks
preheat statusline off  # restore the original statusline (if you enabled the tap)
```

Then delete the lines between `# >>> claude-preheat functions >>>` and
`# <<< claude-preheat functions <<<` in your PowerShell profile (older installs
may have `claude-limit-relay` markers instead), and remove the repo directory.

Codex runtime files (`state-ratelimits-codex.json`, `firepit-codex/`, `.fire-codex.lock`) live inside the repo directory and go with it; if you set `PREHEAT_CODEX_EXE`, remove it too. preheat never touches Codex's own sign-in.
