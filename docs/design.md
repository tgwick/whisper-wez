# WhisperWez — Design

**Date:** 2026-09-02
**Status:** Approved (design)

## Problem

Wispr Flow dictation does not insert text into WezTerm. Wispr inserts text by
probing the focused window through the Windows **UI Automation** text provider.
WezTerm is GPU-rendered and exposes **no UIA text control**, so Wispr's insert
silently no-ops — and Wispr treats the no-op as success, so it never falls back
to clipboard-paste and never fires its "paste failed" notification. The result:
nothing lands in WezTerm and the clipboard is untouched (stale).

This was confirmed empirically:

- WezTerm launches into `WSL:Ubuntu` (`config.default_domain = 'WSL:Ubuntu'`).
- Manual paste works in WezTerm via its default binding **`Ctrl+Shift+V`** (bracketed
  paste). Note: plain `Ctrl+V` is *not* paste in WezTerm — it passes through to the WSL
  shell (readline quoted-insert), which is why an early `Ctrl+V`-based injector produced
  empty/garbage output.
- After dictating into WezTerm, the clipboard still holds prior content — Wispr
  never copied the transcript.
- Neither WezTerm, Wispr Flow, nor Wispr Flow Helper runs elevated (verified via
  the token elevation flag, validated against an `explorer.exe` baseline). So
  there is no UIPI/integrity block.
- The **same dictation works in another WSL terminal that does expose UIA**,
  isolating the cause to WezTerm's missing accessibility provider.
- Wispr config has no per-app insertion-method override, and WezTerm is not in
  any block/category list.

The only true fixes are upstream (WezTerm adds a UIA text provider — tracked
loosely under the exploratory, unimplemented
[wezterm#913](https://github.com/wezterm/wezterm/issues/913); or Wispr adds a
keystroke/clipboard fallback mode). Neither is imminent. WhisperWez is a
pragmatic local workaround.

## Goal

Make Wispr dictation land in WezTerm seamlessly — no per-dictation shortcut —
while never inserting a transcript into the wrong application and never
auto-executing a dictated shell command.

## Non-goals

- Fixing Wispr or WezTerm themselves.
- Supporting terminals other than WezTerm (Wispr already works where UIA exists).
- Any interaction with Wispr's cloud/account or writing to Wispr's database.

## Key data source

Wispr stores every dictation in `flow.sqlite`:

```
%APPDATA%\Wispr Flow\flow.sqlite   (Windows)
/mnt/c/Users/tomgw/AppData/Roaming/Wispr Flow/flow.sqlite   (WSL view)
```

Relevant table: **`History`**. Columns used by WhisperWez:

| Column               | Use                                                        |
|----------------------|-----------------------------------------------------------|
| `transcriptEntityId` | UUID primary key — dedupe / processed-ID tracking         |
| `timestamp`          | DATETIME — ordering and high-water mark                    |
| `app`                | Target app; WhisperWez acts only when this is `wezterm-gui`|
| `formattedText`      | Final AI-formatted text — the text to inject              |
| `asrText`            | Fallback if `formattedText` is empty                      |
| `status`             | Used to confirm the row is finalized                      |

The DB is WAL-mode and actively written by Wispr; WhisperWez opens it
**read-only** (`file:...?mode=ro`, NOT `immutable=1`, so new commits are visible)
and never writes to it.

## Design decisions (resolved during brainstorming)

1. **Runtime:** Windows-native background app. Keystroke injection into a Windows
   GUI app must originate on the Windows side; keeping everything there avoids a
   WSL⇄Windows process boundary.
2. **Language:** PowerShell — ships with Windows, zero install. Bundles the
   official `sqlite3.exe` for DB reads.
3. **Injection:** clipboard + `Ctrl+Shift+V` (WezTerm's default paste binding),
   which triggers WezTerm's **bracketed paste**. Dictated text lands on the prompt
   as literal input and does **not** auto-run (user presses Enter). Simulated
   per-character typing is rejected because a newline in the text could execute a
   command.
4. **Focus guard:** paste only if WezTerm is the foreground window at inject
   time. Otherwise leave the transcript on the clipboard for a manual `Ctrl+Shift+V`
   and skip the paste. This makes wrong-target insertion impossible.
5. **Elevation:** run **non-elevated**, matching WezTerm's integrity level, or
   `SendInput` will not reach it.

## Architecture

A single script `whisperwez.ps1` runs as a hidden, non-elevated background
process, auto-started at logon via a Scheduled Task. It polls `flow.sqlite` every
~400 ms. State and logs live next to the script. WhisperWez is a standalone
project (its own git repo); it lives on the D: drive so it is reachable from both
Windows and WSL.

### Data flow

```
Wispr dictation
  → row in History (app='wezterm-gui'; formattedText populated when formatting done)
  → poll finds a NEW, FINALIZED, wezterm-targeted row (timestamp > high-water mark,
    id not already processed)
  → is WezTerm the foreground window?
       yes → save current clipboard → set clipboard = transcript → SendInput Ctrl+Shift+V
             → (after short delay) restore previous clipboard
       no  → leave transcript on clipboard, skip paste
  → advance high-water mark, record processed id
  → log outcome
```

## Components (one file, logically separated)

- **Config** — `DbPath`, `TargetApp = 'wezterm-gui'`, `PollMs = 400`,
  `RestoreClipboard = $true`, `StateFile`, `LogFile`, `Sqlite3Path`.
- **DB reader** — invokes bundled `sqlite3.exe` with a `mode=ro` connection and a
  parameterized-by-construction query; parses delimited output into rows.
- **New-row detector** — persists a high-water mark (last processed `timestamp`
  plus a small set of recently processed `transcriptEntityId`s to disambiguate
  equal timestamps) to a JSON state file. **On first launch, initializes the mark
  to "now"** so the existing ~5,153-row backlog is never replayed.
- **Finalization gate** — the primary readiness signal is non-empty text:
  `COALESCE(NULLIF(formattedText,''), NULLIF(asrText,''))` must be non-empty.
  This prevents grabbing a half-formatted transcript still being written. The
  concrete set of `status` values that mean "done" will be confirmed against the
  live DB during implementation and, if reliable, added as a secondary guard;
  WhisperWez must work correctly on text-readiness alone if `status` proves
  ambiguous.
- **Injector** — foreground-window check (`GetForegroundWindow` +
  `GetWindowThreadProcessId` → process name compared to `TargetApp`),
  `Set-Clipboard`, `Ctrl+Shift+V` via `SendInput` (P/Invoke: Ctrl down, Shift down,
  V down, V up, Shift up, Ctrl up), then optional clipboard restore.
- **Logger** — appends timestamped lines to a rolling log file.

## Error handling

- Each poll iteration is wrapped in try/catch; the loop never dies.
- DB locked or momentarily missing → log at debug level, retry next tick.
- `sqlite3.exe` missing → fatal at startup with a clear, actionable message.
- Clipboard set/restore failure → caught; injection skipped for that row; logged.
- `-DryRun` switch logs `would paste N chars into wezterm (focused=Y/N)` without
  touching the clipboard or sending keys.

## Testing

- **Unit-testable pieces** (run against a throwaway temp SQLite DB the test
  creates — never Wispr's real DB):
  - new-row selection query (returns only new, finalized, wezterm-targeted rows)
  - high-water-mark advancement and equal-timestamp dedupe
  - state-file persistence across restart (no replay)
  - finalization gate (skips empty/unfinalized rows; applies fallback)
- **Injector** — verified via `-DryRun` plus manual checks:
  - dictate into WezTerm → transcript pastes
  - dictate into WezTerm then click away → transcript left on clipboard, no paste
  - dictate into another app → WhisperWez does nothing (`app != 'wezterm-gui'`)

## Install / uninstall

- `install.ps1` — registers a logon Scheduled Task named **WhisperWez** (hidden,
  non-elevated) that launches `whisperwez.ps1`; prints the log location.
- `uninstall.ps1` — unregisters the task.

## Files

```
WhisperWez/
  whisperwez.ps1      # the watcher + injector
  install.ps1         # register logon scheduled task "WhisperWez"
  uninstall.ps1       # unregister
  sqlite3.exe         # bundled official CLI (read-only DB access)
  README.md           # setup + troubleshooting
  docs/
    design.md         # this document
  tests/              # Pester tests for the pure logic pieces
  state.json          # runtime high-water mark (created at runtime)
  whisperwez.log      # runtime log (created at runtime)
```

## Risks & mitigations

- **Wispr also touches the clipboard** (copies transcript, restores prior
  contents). WhisperWez reacts *after* the DB row is finalized, i.e. after
  Wispr's own attempt, so the two do not contend for the same instant; the
  save/restore is best-effort and logged on failure.
- **Poll latency** (~400 ms) means a brief delay between finishing dictation and
  the paste appearing. Tunable via `PollMs`.
- **DB schema changes** in a future Wispr version could break the reader; the
  reader fails safe (logs, no paste) and the query is isolated for easy update.
- **State/log files** are runtime artifacts and must be git-ignored.
