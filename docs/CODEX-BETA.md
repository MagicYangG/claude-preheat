# Codex beta guide

> Codex support ships as a pre-release (`v0.7.0-beta.1`). The code paths are covered by the same self-test suite that gates Claude (with a stub `codex`, on Windows and on macOS runners), but one question can only be answered on real accounts: **does a tiny scheduled ping anchor the Codex 5-hour window at the chosen time, and does that window then stay put?** That is what this beta is for. Success reports are as useful as failures.

Everything else works the way it does for Claude: same commands (add `-Codex`), same `schedule.json` (a `codex` section), same web panel at `localhost:7878` (Claude | Codex switch at the top), same journal (records carry `provider:"codex"`).

## Who can help

- The [Codex CLI](https://learn.chatgpt.com/docs/codex/cli) or the Codex desktop app installed, signed in with a ChatGPT account. An API-key sign-in has no 5-hour window, so preheat never pings it (but it sends a notification at every scheduled fire, so remove the Codex schedule if you are on an API key).
- An account that has a 5-hour Codex window, such as Plus. preheat reads it live at every fire. Free, Go and Pro have no 5-hour Codex window (Pro per OpenAI's pricing page, Free and Go as read from real accounts; Go has only a 30-day window): when no 5-hour window can be read on those plans, the fire skips and spends nothing, so there is nothing to test yet. Plans on flexible or credit pricing (some Enterprise and Edu workspaces) have no fixed limits either; preheat still pings them at every fire (journaled `window_unknown`), so do not enable Codex preheat on such a workspace. Any other plan whose window cannot be read is also pinged and journaled `window_unknown` - if you see that, tell us.
- Windows 10/11 or macOS 13+ with PowerShell 7, as for Claude. Claude Code itself is not needed if you only preheat Codex: set the top-level `rules` in `schedule.json` to `[]`, or always use `preheat apply -Provider codex`. Otherwise plain `preheat apply` looks for the claude CLI and reports an error (the Codex half still registers).

Not sure about your account? `preheat status -Codex` tells you in a few seconds without spending quota: it shows the plan and either the 5-hour window or `no 5h window readable`.

## Cost

Every ping spends real Codex quota, counted against both the 5-hour and the weekly limit; only the quota reads are free. A fire that reads a running window sends no ping. A fire tries the ping up to 2 times (a usage error can make it try further codex install paths inside one attempt; usage errors do not spend quota).

Pause rule: if the last 2 Codex fires both pinged and the window still did not start (journal state `sliding`), later fires stop pinging, and the next one sends a single notification. Pinging resumes after `preheat apply` (or `preheat apply -Provider codex`). Any other fire result (anchored, running, moved, unknown, a failure) breaks the streak; paused fires are not counted. This only catches pings that clearly did not start a window: a plan whose window cannot be read (`window_unknown`) keeps pinging at every scheduled fire, so check `preheat status -Codex` after the first fire and run `preheat off -Codex` (and remove the `codex` section) if it shows `no 5h window readable`.

## Enable

Install as in the [README](../README.md#quick-start) (or `git pull` an existing install, then run `install.ps1` again — it prints whether it found Codex). After `git pull`, reload any panel page that is already open: otherwise its first save is refused once ("schedule.json changed since this page loaded"), the editor reloads from disk, and you apply again.

The simplest way: open the panel, switch to the Codex tab at the top, pick the times and apply. The tab runs `preheat apply -Provider codex`, so the Claude side is not touched. A fresh install opens on the Claude tab; switch first.

To edit by hand: `schedule.json` is in the repo directory (created by `install.ps1`). Add a `codex` key at the top level, next to `rules` and `proxy` (mind the comma after the previous entry). A complete Codex-only file looks like this:

```json
{
  "proxy": "",
  "chase": true,
  "rules": [],
  "codex": { "rules": [ { "days": ["Mon", "Tue", "Wed", "Thu", "Fri"], "reset": "15:00" } ], "chase": true }
}
```

`reset` is the target reset time, and the fire time is reset − 5h (here 10:00), exactly like the Claude `rules`. `"chase": false` inside the `codex` section turns off Codex follow-ups (the panel tab cannot set this, or `home`). The panel's Codex tab edits the same section. Then:

```powershell
preheat apply -Provider codex   # registers only the Codex tasks; plain `preheat apply` does both
preheat status -Codex           # live read + the Codex tasks that got registered
```

Prefer a quick first try? `preheat +2m -Codex` fires once two minutes from now; the result lands in `preheat-log.jsonl` and in `preheat status -Codex`. Do not run `preheat status -Codex` or press Refresh in the panel during the minute the fire starts: only one Codex process runs at a time, and a fire that finds another one running waits up to 90 seconds and then stands down (journaled as `another Codex fire (or status read) was running`).

If you use a non-default `CODEX_HOME`, run `preheat apply` in a terminal where it is set — it is saved as `codex.home` so the scheduled tasks use it too. The `proxy` in `schedule.json` is shared by both sides; Codex child processes get it as `HTTPS_PROXY` / `HTTP_PROXY`.

The `codex` executable is looked up again at every fire (npm, standalone, desktop app, Microsoft Store and others), so a desktop auto-update needs no re-apply. If preheat cannot find it (an unusual install location), set `PREHEAT_CODEX_EXE` to its full path: on Windows as a user-level environment variable; on macOS a variable in your shell profile does not reach launchd, so instead add codex's folder to PATH in the terminal where you run `preheat apply` (that PATH is stored in the scheduled job).

## What a fire does

1. Reads the quota once through a read-only `codex app-server` (free). A lost sign-in or an API-key sign-in stops here and never pings.
2. Window already running: no ping, one follow-up preheat booked about 2 minutes after it expires. Same rule as Claude's `chase`: at most one, skipped when the next scheduled preheat comes first, and a follow-up never wakes a sleeping PC. Turn off with `"chase": false` inside the `codex` section.
3. Window idle: one tiny `codex exec` ping ("Reply with exactly: hi") in a read-only sandbox. If the quota read itself failed (network, proxy, timeout, unexpected reply), the fire still sends the ping and lets the reads afterwards decide, so it can spend quota even while a window is running.
4. Reads again two or three times and journals the verdict as `state`: `anchored` (the window started at our time), `running` (already running, no ping), `moved` (someone else started it first), `sliding` (the ping did not start a window — the case we most want to hear about), `no5h`, or `unknown`.

## Run it for 3-5 days

Use Codex normally. Two checks make the evidence useful:

1. **On a preheated day, 2-3 hours into real work**, run `preheat status -Codex`. The rolling check line compares today's reset time with the one recorded at fire time: `same window, reset unchanged (anchored)` means the window is anchored; `reset moved later by N min (rolling?)` means it slid with your usage.
2. **At the end**, run:

```powershell
preheat report -Codex
```

and paste the output into an issue at <https://github.com/MagicYangG/claude-preheat/issues> (title it `Codex beta report`). Add your OS, whether you use the CLI or the desktop app, and anything odd (a sign-out, a missed morning).

## Privacy

`preheat report -Codex` never prints your email (only the plan and a short account hash), and masks email addresses, sign-in tokens and API keys, your home path, and your user name (names of 4 or more characters). Read the output before posting. `preheat status -Codex` does show a masked email (first letter and domain), so do not paste status output if that matters to you. Paste the report, not the raw `preheat-log.jsonl`: the journal keeps codex error text as it came, without masking. preheat never reads `auth.json` — only its modification time, to note when a token refresh happened.

What the report **does** show is the time of each fire and reset — which reveals your daily routine. Round or drop those times before posting if you prefer; the order of events and the `state` values are what matter most. You decide what to paste.

## Leaving the beta

```powershell
preheat off -Codex   # removes only the Codex tasks; Claude preheats keep running
```

`preheat off -Codex` removes the Codex tasks now, but the next plain `preheat apply` would register them again while the `codex` section is in `schedule.json`. To leave the beta for good, also delete the `codex` section (a later `preheat apply` then removes any Codex weekly tasks it finds). The panel tab keeps showing the cached quota and the fire history. preheat never touches your Codex sign-in.

## Known gaps

- **Sleep**: Windows wakes the PC for a scheduled fire (with Claude and Codex both scheduled, that can be two wakes a night). launchd cannot wake a sleeping Mac — a fire missed during sleep runs at the next wake, so the window anchors late (see the [macOS guide](MAC-BETA.md#known-gap-sleep)).
- **Token refresh**: the first read of a fire usually makes codex refresh an expired sign-in token. If the desktop app refreshes in the very same second it can get signed out (an upstream race, see [SECURITY.md](../SECURITY.md)). Sign in again; the journal's `auth_rot` field shows which step moved `auth.json`. Please mention it in your report if it happens.
- **IDE-extension-only installs** (VS Code / Cursor without the CLI or desktop app) are looked up but unverified.
- **Which bucket the ping meters**: preheat reads the `codex` quota bucket. If your fires journal `sliding` while `status -Codex` shows another bucket's 5-hour window moving (its `other 5h` line), say so — the report lists every other bucket's 5-hour window (`other5h`).
- **`learn -Codex`** is not available yet (planned for a later beta); the panel's Codex tab has no 7-day utilization line for the same reason.
