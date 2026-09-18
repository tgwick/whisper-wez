# WhisperWez

Make [Wispr Flow](https://wisprflow.ai) dictation land in **WezTerm** (and TUIs running
inside it, like **Claude Code** under WSL), which Wispr can't insert into on its own.

WhisperWez is a small, non-elevated PowerShell watcher. It polls Wispr's local database
for new dictations targeted at WezTerm and injects them into the focused WezTerm window as
a **bracketed paste** — no clipboard, so nothing races or goes stale. See
[`docs/design.md`](docs/design.md) for the full rationale and the history of what didn't work.

## Requirements

- Windows, with **WezTerm** and **Wispr Flow** installed.
- Run **non-elevated** (matching WezTerm), or synthetic keystrokes won't reach it.
- Bundled `sqlite3.exe` (in this repo) for read-only DB access.

## Setup

### 1. Suppress Wispr's `Ctrl+V` auto-paste in WezTerm — **required**

Wispr auto-pastes via `Ctrl+V`, which in a TUI like Claude Code inserts a **stale clipboard
value** on top of WhisperWez's correct text. Make WezTerm swallow `Ctrl+V` by adding this to
`~/.wezterm.lua` (Windows: `C:\Users\<you>\.wezterm.lua`) inside `config.keys`:

```lua
-- Swallow Ctrl+V so Wispr Flow's Ctrl+V auto-paste can't inject a stale clipboard value.
-- WhisperWez uses a bracketed paste, not Ctrl+V. Paste normally with Ctrl+Shift+V.
{ key = 'v', mods = 'CTRL', action = wezterm.action_callback(function() end) },
```

Reload WezTerm (`Ctrl+Shift+R`). `Ctrl+V` becomes inert everywhere in WezTerm; pasting is
`Ctrl+Shift+V` (in a terminal `Ctrl+V` was never paste anyway). Full explanation:
[`docs/design.md` → *Host requirement*](docs/design.md).

### 2. Run it

Launch manually (in a **non-elevated** PowerShell):

```powershell
cd D:\Git\Personal\WhisperWez
.\whisperwez.ps1
```

Then dictate into WezTerm/Claude Code — the transcript is injected when WezTerm is focused.
If it isn't focused, the text is left on the clipboard for a manual `Ctrl+Shift+V`.

### 3. Start automatically at logon (optional)

Register a hidden, non-elevated Scheduled Task that starts one instance at every logon:

```powershell
.\install.ps1                                # register the logon task
Start-ScheduledTask -TaskName WhisperWez     # start it now, without logging off
```

> If registration fails with "Access is denied", run `.\install.ps1` once from an **elevated**
> PowerShell. The task still *runs* non-elevated (required to reach WezTerm) — only creating it
> needs the rights.

**Turning it off** — three levels, depending on what you want:

```powershell
# a) Stop the currently running instance (leaves auto-start enabled):
Stop-ScheduledTask -TaskName WhisperWez

# b) Keep the task but stop it launching at logon (easy to re-enable later):
Disable-ScheduledTask -TaskName WhisperWez
Enable-ScheduledTask  -TaskName WhisperWez   # turn it back on

# c) Remove it entirely:
.\uninstall.ps1
```

Check whether it's installed / its state:

```powershell
Get-ScheduledTask -TaskName WhisperWez
```

Note: stopping or removing the task does **not** stop a WhisperWez you launched *by hand* —
close that PowerShell window (or `Stop-Process` it) separately.

## Options

Config lives in `Get-WhisperWezConfig` (`WhisperWez.psm1`); a couple are also runner flags:

- `-DryRun` — log what would be injected without touching the keyboard.
- `-Once` — run a single poll and exit.
- `-PasteDelayMs <n>` — per-byte pause during the paste (default 20). Raise it if a long
  transcript ever drops characters; lower it to paste faster.

## Troubleshooting

- **Nothing happens** — confirm exactly one watcher is running and WezTerm is focused; check
  `whisperwez.log` for `typed`/`pasted` vs `clipboard-only (focused=False)`.
- **A stale/old value appears before your text** — the WezTerm `Ctrl+V` step (above) is
  missing or not reloaded.
- **Dropped characters in a long paste** — raise `-PasteDelayMs` (e.g. 35).
- **Delay before text appears** — mostly Wispr's own formatting time; `PollMs` and
  `PasteDelayMs` are the parts you can tune.

## Tests

```powershell
Invoke-Pester .\tests\
```

Pure logic (DB query, state/high-water-mark, control-char stripping, injector dispatch) is
covered with Pester mocks; the actual key injection is verified manually.
