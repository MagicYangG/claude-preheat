# Security

Plain words, no legalese.

Nothing in v0.3+ ever runs Claude unattended on your code — the v0.2
relay feature and its `--dangerously-skip-permissions` flag are gone.

## the panel binds localhost only

The status page (`claude-panel`) serves `http://localhost:7878` and does
not bind to any other network interface. It is not reachable from other
machines on your network by default. If you reverse-proxy or forward
this port yourself, that exposure is on you.

## nothing phones home

This repo makes no outbound network calls of its own. The only network
traffic it causes is:

- the scheduled preheat ping — `claude -p "hi" --model haiku`, run in
  `firepit/`, an empty scratch directory inside the repo, so the ping
  never sees your code — subject to whatever proxy/network config your
  `claude` CLI already uses (see `schedule.json`'s `proxy` field),
- the follow-up ping a scheduled preheat books for itself when it landed in
  a window that was already running (same command, at most one per window;
  `"chase": false` in `schedule.json` turns it off),
- the Codex preheat (beta, only when `schedule.json` has a `codex`
  section): quota reads and a tiny `codex exec` ping through the Codex
  CLI or desktop app you already have — see the next section,
- your browser loading `localhost:7878` for the panel.

Optional BurntToast notifications are local toasts on your own machine,
and the statusline tap writes rate-limit numbers to a local file only
(`state-ratelimits.json`). No telemetry, no analytics, no third-party
services.

## Codex child processes (beta)

Codex fires, `preheat status -Codex`, `preheat report -Codex` and the
panel's Refresh button start the `codex` binary you already have, as you,
with the `proxy` and `CODEX_HOME` from `schedule.json` (for status and
report, a `CODEX_HOME` set in your shell wins over `codex.home`). Each first runs
`codex --version` (report runs only that, no quota read). Fires, status
reads and Refresh share one lock and never overlap; each child is a fresh
process:

- **quota reads**: `codex app-server --stdio`, a private child per read
  (never the instance your desktop app shares). preheat sends only four
  JSON-RPC methods — `initialize`, `initialized`, `account/read`,
  `account/rateLimits/read` — and refuses anything else before it is
  written, so this channel cannot start a turn or spend reset credits.
- **the ping**: `codex exec --ephemeral --ignore-user-config
  --ignore-rules -s read-only`, with the hooks, memories, goals, apps and
  plugins features switched off, run in `firepit-codex/`, an empty
  directory inside the repo, with stdin at end-of-file. Read-only
  sandbox, nothing kept in session history, your own `config.toml` not
  loaded — only four sign-in keys (`cli_auth_credentials_store`,
  `forced_login_method`, `forced_chatgpt_workspace_id`,
  `chatgpt_base_url`) are copied onto the command line so the ping uses
  the same login.
- **`auth.json` is never read**: preheat only checks that it exists and
  its modification time, to log whether a token refresh happened
  (`auth_rot` in the journal). It never copies, prints or uploads
  credentials. The local quota cache keeps a masked email and a short
  hash of the account id, never the address, and `preheat report -Codex`
  masks email addresses, sign-in tokens and API keys, your home path,
  and your user name (names of 4+ characters; read the output before
  posting). The fire journal (`preheat-log.jsonl`) keeps codex error
  text unmasked, so share the report rather than the raw log.
- **token refresh caveat**: at fire time the sign-in token has usually
  expired, so the first read typically makes codex refresh it (codex
  itself rewrites `auth.json`; preheat does not). If the Codex desktop app
  refreshes in the very same second, it can get signed out — there are
  upstream reports of this race, and it cannot be fixed on our side. Sign
  in again if that happens; the journal shows which step moved
  `auth.json`.

## state stays local

Tool **data** (`schedule.json`, logs, `state.json`,
`state-ratelimits.json`, `state-ratelimits-codex.json`, `firepit-codex/`)
lives inside the repo directory, and nothing is
uploaded anywhere. Three things are written outside the repo, all by
design and all removed by the uninstall steps in the README:

- a function block in your PowerShell profile (`preheat` /
  `claude-panel`), added by `install.ps1` with a timestamped backup,
- per-user scheduled tasks (`ClaudePreheat-*`, Codex ones as
  `ClaudePreheat-Codex-*`), registered without
  elevation and running as you,
- on macOS, two one-line shims in `~/.local/bin` (`preheat`,
  `claude-panel`) added by `install.ps1`.

## single-user assumption

This tool is built for one person on their own machine. The panel's
POST protection blocks cross-site (browser) requests, but it has no auth
token, so any local process running as you can drive it — the same
privilege you already have to run the scripts directly. On a shared
machine, keep the repo directory writable only by your own account:
scheduled tasks execute the scripts from that directory as you.

## reporting a vulnerability

Please report security issues privately through GitHub's **Report a
vulnerability** button (repository → Security → Advisories), not as a
public issue.
