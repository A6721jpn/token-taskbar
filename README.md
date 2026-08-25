# Codex Token Taskbar

Small Windows tray app that shows your current Codex 5-hour and weekly usage headroom in the Windows 11 notification area.

## Why tray icon instead of a custom taskbar widget?

Windows 11 no longer supports the old custom deskband/taskbar-toolbar model in a practical way for apps like this. The app therefore uses a pinned tray icon in the taskbar notification area, which is the most reliable always-on display surface on Windows 11.

## What it displays

- Tray icon number: weekly remaining percent
- Tray icon background color: 5-hour remaining percent
- Tooltip: compact summary
- Context menu: reset times and last sync time

Important: the app shows remaining percentages plus reset timestamps, not absolute token totals.

## Requirements

- Windows 11
- PowerShell 5 or newer
- Python 3 available on `PATH`
- Codex authentication state under `~/.codex/auth.json`
- Local Codex logs under `~/.codex/logs_1.sqlite` only if the official request path is unavailable

## Start the app

Run:

```bat
start-token-taskbar.cmd
```

This now routes startup through `wscript.exe`, so the resident tray process does not keep a console window attached.
Then pin the tray icon in Windows so it stays visible.

## Verify the data source

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\app\TokenTaskbar.ps1 -RunOnce
```

That prints the latest observed 5-hour and weekly values without starting the tray app.

## Start automatically at sign-in

Install the Task Scheduler entry:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-startup.ps1
```

If you already installed an older version, run the installer again once so the existing scheduled tasks switch to the hidden `wscript.exe` launcher.

Remove it later with:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-startup.ps1
```

The installer registers a task named `Codex Token Taskbar` that runs for the current user with:

- `AtLogOn`
- fixed delay `PT5M` (5 minutes after logon)
- `Interactive`
- restart on failure `3x / 1 minute`
- `IgnoreNew` for duplicate launches
- `wscript.exe` launcher so the tray host starts without a visible console window

The installer also registers `Codex Token Taskbar Recovery`, an event-driven recovery task that listens for Task Scheduler failure event `201` for the main task and starts it again. This avoids adding a periodic watchdog or another resident process.

This replaces the old Startup-folder shortcut approach.

## Verify crash recovery

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\verify-recovery.ps1
```

The verification script:

1. checks the scheduled task definition,
2. starts the task,
3. force-kills the tray process,
4. confirms that a new process comes back within 90 seconds.

Note: this intentionally kills the running tray instance once as part of the test.

## How the app works

1. `app/read_codex_rate_limits.py` first calls `https://chatgpt.com/backend-api/wham/usage` with the access token from `~/.codex/auth.json`.
2. If that official request fails, the reader falls back to the latest `codex.rate_limits` event from `~/.codex/logs_1.sqlite`.
3. `app/TokenTaskbar.ps1` polls that reader on a timer.
4. When the reader is on local-log fallback, unchanged `logs_1.sqlite` and `logs_1.sqlite-wal` signatures skip the Python reader call.
5. If the effective displayed state is unchanged, the tray app skips icon redraw and menu refresh.
6. The tray icon is redrawn with the current 5-hour and weekly remaining percentages.

## Resource forecast

Current local measurements for the PowerShell resident host are roughly:

- private memory: about `81 MB`
- working set: about `117 MB`
- steady-state CPU: effectively idle, around `0.03 CPU-seconds` over 20 seconds

Reader cost:

- warm `read_codex_rate_limits.py`: about `7-12 ms`
- cold first run: about `220 ms`

Implications:

- Task Scheduler startup does not materially change steady-state memory.
- Backend polling trades a small once-per-refresh network request for values that match the official usage dashboard.
- The DB/WAL gate still removes almost all unnecessary child-process launches when the app is operating on local-log fallback.
- Large memory reductions are unlikely without replacing the PowerShell resident host with a different runtime.

## Notes

- If the official request fails, the context menu `Last sync` line will show `local logs`.
- If the icon shows `--`, both the official request and the local-log fallback probably failed.
- If the Codex local log format changes in a future release, the reader script may need a small update.
