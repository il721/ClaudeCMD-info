# ClaudeCMD — Claude Code status line (Windows)

A single-line, color status bar for [Claude Code](https://claude.com/claude-code) on Windows. It shows your model, reasoning effort, **live plan usage**, and current context size:

![status bar](statusbar.png)

```
Opus 4.8  [high]  │  ████████░░░░░░ 59%  │ 4:30 │  █░░░░░░░░░░░░░ 6%  │  134k tokens
          └effort┘     └ 5h session ┘   └reset┘    └ 7-day plan ┘      └ context ┘
```

- **Bar 1 (blue) — 5-hour session usage.** The same number the `/usage` command shows.
- **`H:MM` (blue) — time until the 5-hour session resets**, shown between the two bars.
- **Bar 2 (amber) — 7-day plan usage.**
- Both bars turn **amber at ≥75%** and **red at ≥90%**.
- **`N tokens`** — current conversation context size.

## Why it's accurate

The two usage bars read directly from `widget_limits.json` — **Claude Code's own cache of the `/usage` API** (`five_hour.utilization` / `seven_day.utilization`). These are the authoritative server-side numbers covering *all* your usage (web + Code). No cost estimation, no calibration.

Claude Code *used* to write this file itself, but **as of CC 2.1.161 it stopped** (and `/usage` no longer refreshes it). So `widget_refresh.ps1` now keeps it current: when the file goes stale, the status line fires this background worker, which makes one minimal `max_tokens:1` Haiku call to `/v1/messages` and reads the 5h/7d utilization + reset time from the response's `anthropic-ratelimit-unified-*` headers. Cost is negligible (a handful of tokens), there's no Claude Code impersonation, and the OAuth token is read from `~/.claude/.credentials.json` (nothing hardcoded).

If `widget_limits.json` is missing **and** the header refresh fails, the status line falls back to an estimate from [`ccusage`](https://github.com/ryoppippi/ccusage) (`5-hour cost ÷ cap`). That path is approximate — see calibration below.

## Requirements

- **PowerShell 7** (`pwsh`) — `winget install Microsoft.PowerShell`
- **Node.js** (for the ccusage fallback) — `winget install OpenJS.NodeJS`

## Install

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File Install_New_CMD\install.ps1
```

The installer:
1. Locates `pwsh` / `node` / `npm` and installs `ccusage` globally if missing.
2. Writes `statusline_model.ps1`, `widget_refresh.ps1`, and `usage_refresh.ps1` into `%USERPROFILE%\.claude\`.
3. Merges your `settings.json` (adds the `statusLine` command; backs up to `settings.json.bak`).
4. Primes the fallback usage cache.

Then **restart Claude Code** and press **Shift+Tab** to refresh the bar.

## Uninstall

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File Install_New_CMD\uninstall.ps1
```

Removes the `statusLine` key from `settings.json` and deletes the three status-line scripts plus their caches and locks. Leaves `widget_limits.json` (Claude Code's own file) and `effortLevel` untouched.

## Customization

Edit `~/.claude/statusline_model.ps1` (read fresh on every render — **no restart needed**):

| Variable | Purpose |
| --- | --- |
| `$BAR_WIDTH` | Width of each bar (default 14). |
| `$WIDGET_REFRESH_SEC` | How stale `widget_limits.json` may get before `widget_refresh.ps1` fires (default 60). Lower = fresher %s, more tiny API calls; higher = fewer calls. |
| `$WIDGET_MAX_AGE` | Max age (s) of the 5h % before it's distrusted (default 600). |
| `$WIDGET_7D_MAX_AGE` | Longer leash (default 21600 = 6h) so the slow-moving 7-day bar and reset time stay visible during idle stretches. |
| `$REFRESH_SEC` | Max age of the ccusage fallback cache before a background refresh fires. |
| `$USAGE_CAP_USD` | **Fallback only.** The cost-equivalent 5-hour cap. Only matters if both the widget cache and header refresh are unavailable. Calibrate to `current_5h_cost / (usage_percent / 100)`. |

Colors are defined by the `Fg r g b` helpers near the top.

## How it fits together

- **`settings.json` → `statusLine.command`** runs `pwsh` directly on `statusline_model.ps1`.
- **`statusline_model.ps1`** renders the line: model + effort from stdin/`settings.json`, usage + reset time from `widget_limits.json` (fallback `_usage5h.json`), context size from the transcript. When `widget_limits.json` is stale it fires `widget_refresh.ps1` in the background.
- **`widget_refresh.ps1`** is a fire-and-forget worker that refreshes `widget_limits.json` from the `anthropic-ratelimit-unified-*` response headers (one tiny Haiku call). It never blocks rendering.
- **`usage_refresh.ps1`** is a fire-and-forget worker that runs `ccusage` and writes the deeper fallback cache. It never blocks rendering.

> **Windows / Git Bash note:** Claude Code launches the `statusLine` command via **bash**, not cmd.exe. The command must use a **full, quoted `pwsh` path with forward slashes** — a Windows `.bat` path is silently mangled by bash and the bar comes up blank. The installer writes the command in the correct form.

## Files

| Path | What it is |
| --- | --- |
| `Install_New_CMD/install.ps1` | Current installer (embeds the latest status-line scripts). |
| `Install_New_CMD/uninstall.ps1` | Uninstaller. |
| `Install_New_CMD/how.txt` | Quick setup notes for a new machine. |
| `install.ps1` | Root copy of the installer, kept identical to `Install_New_CMD/install.ps1`. |
| `uninstall.ps1` | Root copy of the uninstaller, kept identical to `Install_New_CMD/uninstall.ps1`. |
| `CLI_01.png`, `pwrshl.png` | Design references. |
