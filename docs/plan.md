# WhisperWez Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a non-elevated Windows background helper that pastes Wispr Flow dictations into WezTerm by watching Wispr's `flow.sqlite`, working around WezTerm's missing UI Automation text provider.

**Architecture:** A single PowerShell module (`WhisperWez.psm1`) holds all logic as small, dependency-injectable functions; a thin runner (`whisperwez.ps1`) wires config + main loop. The helper polls `flow.sqlite` read-only via a bundled `sqlite3.exe`, and on a new WezTerm-targeted transcript sets the clipboard and sends `Ctrl+V` — only when WezTerm is the foreground window. Pure logic and the DB query are unit/integration tested with Pester v5; OS-input pieces are tested with Pester mocks plus manual verification.

**Tech Stack:** Windows PowerShell 5.1, Pester v5 (tests), `sqlite3.exe` CLI (read-only DB access), Win32 P/Invoke (`user32.dll` for foreground window + `SendInput`), Windows Task Scheduler (logon autostart).

## Global Constraints

- **Target runtime:** Windows PowerShell **5.1** only (no `pwsh`). All code must be 5.1-compatible (no PS7-only syntax like `??`, ternary, `-Parallel`).
- **Never elevated:** all scripts and the scheduled task run at the user's normal (Medium) integrity — required so `SendInput` reaches WezTerm.
- **DB is read-only:** open `flow.sqlite` as `file:...?mode=ro`; never write to it.
- **Never auto-execute:** inject only via clipboard + `Ctrl+V` (bracketed paste). Never simulate per-character typing or send Enter.
- **Target app string:** `wezterm-gui` (exact value Wispr stores in `History.app`).
- **DB path:** `Join-Path $env:APPDATA 'Wispr Flow\flow.sqlite'`.
- **No backlog replay:** on first run, initialize the high-water mark to the DB's current `MAX(timestamp)` (NOT local `Get-Date`).
- **Timestamps are DB-native UTC strings** of the form `YYYY-MM-DD HH:MM:SS.fff +00:00` (fixed width → lexicographic string comparison is time-monotonic). Both sides of every comparison MUST be DB-native strings; never generate a comparison timestamp from local `Get-Date`.
- **Finalization status:** inject only rows with `status IN ('formatted','raw_transcript')` (excludes `processing`, `empty`, `no_audio`, `dismissed`).
- **Test command (run from WSL):** `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0 -Force; Invoke-Pester -Path 'D:\Git\Personal\WhisperWez\tests\WhisperWez.Tests.ps1' -Output Detailed"`
- Repo root (Windows): `D:\Git\Personal\WhisperWez`  (WSL: `/mnt/d/Git/Personal/WhisperWez`).

## File Structure

```
WhisperWez/
  WhisperWez.psm1      # all functions (config, db reader, state, focus, clipboard, inject, log, loop)
  whisperwez.ps1       # runner: import module, build config, Start-WhisperWez
  install.ps1          # register logon Scheduled Task "WhisperWez"
  uninstall.ps1        # unregister the task
  sqlite3.exe          # bundled official CLI (gitignored; fetched in Task 1)
  README.md            # setup + troubleshooting
  docs/
    design.md          # approved design (already committed)
    plan.md            # this document
  tests/
    WhisperWez.Tests.ps1   # Pester v5 tests
  state.json           # runtime high-water mark (gitignored, created at runtime)
  whisperwez.log       # runtime log (gitignored, created at runtime)
```

One module keeps functions dot-sourceable for tests; the runner and install scripts stay thin so the untestable OS calls are isolated.

---

### Task 1: Project bootstrap & test harness (walking skeleton)

Validates that Pester v5 runs on PS 5.1, `sqlite3.exe` is reachable, and module import + test invocation work — before any real logic.

**Files:**
- Create: `WhisperWez.psm1`
- Create: `tests/WhisperWez.Tests.ps1`

**Interfaces:**
- Produces: `Get-WhisperWezVersion` → `[string]` semantic version.

- [ ] **Step 1: Install Pester v5**

Run (from WSL):
```bash
powershell.exe -NoProfile -Command "Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck; (Get-Module -ListAvailable Pester | Select-Object -First 1 Version)"
```
Expected: prints a `5.x` version. (`-SkipPublisherCheck` is required because the built-in Pester 3.4 is signed by a different publisher.)

- [ ] **Step 2: Ensure `sqlite3.exe` is available**

Run:
```bash
powershell.exe -NoProfile -Command "if (Get-Command sqlite3 -ErrorAction SilentlyContinue) { 'on PATH' } else { winget install -e --id SQLite.SQLite --accept-source-agreements --accept-package-agreements }"
```
Then copy the CLI into the repo so it is bundled/deterministic:
```bash
powershell.exe -NoProfile -Command "\$src = (Get-Command sqlite3 -ErrorAction SilentlyContinue).Source; if (-not \$src) { \$src = (Get-ChildItem 'C:\Users\tomgw\AppData\Local\Microsoft\WinGet\Packages\SQLite.SQLite*' -Recurse -Filter sqlite3.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }; if (\$src) { Copy-Item \$src 'D:\Git\Personal\WhisperWez\sqlite3.exe' -Force; & 'D:\Git\Personal\WhisperWez\sqlite3.exe' -version } else { throw 'sqlite3.exe not found; download from https://sqlite.org/download.html (sqlite-tools-win-x64) and place in the repo root' }"
```
Expected: prints a SQLite version line, and `sqlite3.exe` now exists in the repo root.

- [ ] **Step 3: Write the failing test**

Create `tests/WhisperWez.Tests.ps1`:
```powershell
BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\WhisperWez.psm1'
    Import-Module $script:ModulePath -Force
}

Describe 'Get-WhisperWezVersion' {
    It 'returns a semantic version string' {
        Get-WhisperWezVersion | Should -Match '^\d+\.\d+\.\d+$'
    }
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0 -Force; Invoke-Pester -Path 'D:\Git\Personal\WhisperWez\tests\WhisperWez.Tests.ps1' -Output Detailed"
```
Expected: FAIL — `Get-WhisperWezVersion` is not recognized.

- [ ] **Step 5: Write the minimal module**

Create `WhisperWez.psm1`:
```powershell
Set-StrictMode -Version Latest

function Get-WhisperWezVersion {
    [CmdletBinding()]
    param()
    '0.1.0'
}

Export-ModuleMember -Function *
```

- [ ] **Step 6: Run the test to verify it passes**

Run the Step 4 command. Expected: PASS (1 test).

- [ ] **Step 7: Commit**

```bash
cd /mnt/d/Git/Personal/WhisperWez && git add WhisperWez.psm1 tests/WhisperWez.Tests.ps1 && git commit -m "test harness + module skeleton (Pester v5, sqlite3 bundled)"
```

---

### Task 2: Configuration resolver

**Files:**
- Modify: `WhisperWez.psm1`
- Modify: `tests/WhisperWez.Tests.ps1`

**Interfaces:**
- Produces: `Get-WhisperWezConfig [-Overrides <hashtable>]` → `[hashtable]` with keys: `DbPath`, `TargetApp`, `PollMs`, `RestoreClipboard`, `StateFile`, `LogFile`, `Sqlite3Path`, `MaxRecentIds`, `ClipboardRestoreDelayMs`.
- Produces: `Resolve-Sqlite3Path [-RepoRoot <string>]` → `[string]` path to sqlite3 (bundled `sqlite3.exe` in repo root if present, else `sqlite3` from PATH).

- [ ] **Step 1: Write the failing tests**

Add to `tests/WhisperWez.Tests.ps1`:
```powershell
Describe 'Get-WhisperWezConfig' {
    It 'provides expected defaults' {
        $c = Get-WhisperWezConfig
        $c.TargetApp              | Should -Be 'wezterm-gui'
        $c.PollMs                 | Should -Be 400
        $c.RestoreClipboard       | Should -BeTrue
        $c.MaxRecentIds           | Should -Be 50
        $c.ClipboardRestoreDelayMs| Should -Be 300
        $c.DbPath                 | Should -Match 'flow\.sqlite$'
    }
    It 'applies overrides' {
        $c = Get-WhisperWezConfig -Overrides @{ PollMs = 100; TargetApp = 'x' }
        $c.PollMs    | Should -Be 100
        $c.TargetApp | Should -Be 'x'
    }
}

Describe 'Resolve-Sqlite3Path' {
    It 'prefers a bundled sqlite3.exe in the repo root' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        Set-Content -Path (Join-Path $tmp 'sqlite3.exe') -Value 'stub'
        Resolve-Sqlite3Path -RepoRoot $tmp | Should -Be (Join-Path $tmp 'sqlite3.exe')
        Remove-Item $tmp -Recurse -Force
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the Global Constraints test command. Expected: FAIL — functions not defined.

- [ ] **Step 3: Implement**

Add to `WhisperWez.psm1` (above `Export-ModuleMember`):
```powershell
function Resolve-Sqlite3Path {
    [CmdletBinding()]
    param([string]$RepoRoot = $PSScriptRoot)
    $bundled = Join-Path $RepoRoot 'sqlite3.exe'
    if (Test-Path $bundled) { return $bundled }
    $cmd = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "sqlite3.exe not found (bundled or on PATH). See README setup."
}

function Get-WhisperWezConfig {
    [CmdletBinding()]
    param([hashtable]$Overrides = @{})
    $root = $PSScriptRoot
    $config = @{
        DbPath                  = Join-Path $env:APPDATA 'Wispr Flow\flow.sqlite'
        TargetApp               = 'wezterm-gui'
        PollMs                  = 400
        RestoreClipboard        = $true
        ClipboardRestoreDelayMs = 300
        MaxRecentIds            = 50
        StateFile               = Join-Path $root 'state.json'
        LogFile                 = Join-Path $root 'whisperwez.log'
        Sqlite3Path             = $null   # resolved lazily by the runner to keep this pure/testable
    }
    foreach ($k in $Overrides.Keys) { $config[$k] = $Overrides[$k] }
    $config
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /mnt/d/Git/Personal/WhisperWez && git add -A && git commit -m "add config resolver and sqlite3 path resolution"
```

---

### Task 3: DB reader — `Read-NewTranscripts` (integration test with real sqlite3)

Reads finalized, WezTerm-targeted rows newer-or-equal to a cutoff, using `sqlite3.exe` JSON output (safe for text with quotes/newlines).

**Files:**
- Modify: `WhisperWez.psm1`
- Modify: `tests/WhisperWez.Tests.ps1`

**Interfaces:**
- Consumes: `Resolve-Sqlite3Path`.
- Produces: `Read-NewTranscripts -DbPath <string> -Sqlite3Path <string> -TargetApp <string> -SinceTimestamp <string>` → array of `[pscustomobject]@{ Id; Timestamp; Text }`, ordered by `Timestamp` ascending. Rows with empty `formattedText` fall back to `asrText`; rows with neither, or with a non-final `status`, are excluded.
- Produces: `Get-DbMaxTimestamp -DbPath <string> -Sqlite3Path <string>` → `[string]` the current `MAX(timestamp)` across all rows (DB-native UTC string), or `''` if the table is empty. Used to seed the high-water mark on first run.

- [ ] **Step 1: Write the failing integration test**

Add to `tests/WhisperWez.Tests.ps1`:
```powershell
Describe 'Read-NewTranscripts' {
    BeforeAll {
        $script:sqlite = Resolve-Sqlite3Path -RepoRoot (Join-Path $PSScriptRoot '..')
        $script:db = Join-Path ([IO.Path]::GetTempPath()) ("ww_" + [guid]::NewGuid() + ".sqlite")
        # Timestamps mirror the real DB shape: UTC, milliseconds, "+00:00" suffix.
        $ddl = @'
CREATE TABLE History (transcriptEntityId TEXT PRIMARY KEY, timestamp TEXT, app TEXT, formattedText TEXT, asrText TEXT, status TEXT);
INSERT INTO History VALUES ('id1','2026-09-02 10:00:00.100 +00:00','wezterm-gui','hello world','hello raw','formatted');
INSERT INTO History VALUES ('id2','2026-09-02 10:00:01.100 +00:00','wezterm-gui','','fallback text','formatted');
INSERT INTO History VALUES ('id3','2026-09-02 10:00:02.100 +00:00','wezterm-gui','','','formatted');
INSERT INTO History VALUES ('id4','2026-09-02 10:00:03.100 +00:00','chrome','other app','other','formatted');
INSERT INTO History VALUES ('id5','2026-09-02 09:00:00.100 +00:00','wezterm-gui','too old','old','formatted');
INSERT INTO History VALUES ('id6','2026-09-02 10:00:04.100 +00:00','wezterm-gui','line1
line2','multi','formatted');
INSERT INTO History VALUES ('id7','2026-09-02 10:00:05.100 +00:00','wezterm-gui','half baked','partial','processing');
INSERT INTO History VALUES ('id8','2026-09-02 10:00:06.100 +00:00','wezterm-gui','raw only','raw asr','raw_transcript');
'@
        $ddl | & $script:sqlite $script:db
        $script:since = '2026-09-02 10:00:00.100 +00:00'
    }
    AfterAll { Remove-Item $script:db -Force -ErrorAction SilentlyContinue }

    It 'returns only new, finalized, wezterm rows in ascending order' {
        $rows = Read-NewTranscripts -DbPath $script:db -Sqlite3Path $script:sqlite -TargetApp 'wezterm-gui' -SinceTimestamp $script:since
        ($rows | ForEach-Object Id) | Should -Be @('id1','id2','id6','id8')
    }
    It 'applies asrText fallback when formattedText is empty' {
        $rows = Read-NewTranscripts -DbPath $script:db -Sqlite3Path $script:sqlite -TargetApp 'wezterm-gui' -SinceTimestamp $script:since
        ($rows | Where-Object Id -eq 'id2').Text | Should -Be 'fallback text'
    }
    It 'excludes rows where both text columns are empty' {
        $rows = Read-NewTranscripts -DbPath $script:db -Sqlite3Path $script:sqlite -TargetApp 'wezterm-gui' -SinceTimestamp $script:since
        ($rows | Where-Object Id -eq 'id3') | Should -BeNullOrEmpty
    }
    It 'excludes non-final (processing) rows' {
        $rows = Read-NewTranscripts -DbPath $script:db -Sqlite3Path $script:sqlite -TargetApp 'wezterm-gui' -SinceTimestamp $script:since
        ($rows | Where-Object Id -eq 'id7') | Should -BeNullOrEmpty
    }
    It 'includes raw_transcript rows' {
        $rows = Read-NewTranscripts -DbPath $script:db -Sqlite3Path $script:sqlite -TargetApp 'wezterm-gui' -SinceTimestamp $script:since
        ($rows | Where-Object Id -eq 'id8').Text | Should -Be 'raw only'
    }
    It 'preserves multi-line text' {
        $rows = Read-NewTranscripts -DbPath $script:db -Sqlite3Path $script:sqlite -TargetApp 'wezterm-gui' -SinceTimestamp $script:since
        ($rows | Where-Object Id -eq 'id6').Text | Should -Be "line1`nline2"
    }
}

Describe 'Get-DbMaxTimestamp' {
    BeforeAll {
        $script:sqlite2 = Resolve-Sqlite3Path -RepoRoot (Join-Path $PSScriptRoot '..')
        $script:db2 = Join-Path ([IO.Path]::GetTempPath()) ("ww_max_" + [guid]::NewGuid() + ".sqlite")
        @'
CREATE TABLE History (transcriptEntityId TEXT PRIMARY KEY, timestamp TEXT, app TEXT, formattedText TEXT, asrText TEXT, status TEXT);
INSERT INTO History VALUES ('a','2026-09-02 10:00:00.100 +00:00','chrome','x','x','formatted');
INSERT INTO History VALUES ('b','2026-09-02 10:00:06.100 +00:00','wezterm-gui','y','y','formatted');
'@ | & $script:sqlite2 $script:db2
    }
    AfterAll { Remove-Item $script:db2 -Force -ErrorAction SilentlyContinue }

    It 'returns the maximum timestamp across all rows' {
        Get-DbMaxTimestamp -DbPath $script:db2 -Sqlite3Path $script:sqlite2 | Should -Be '2026-09-02 10:00:06.100 +00:00'
    }
    It 'returns empty string for an empty table' {
        $empty = Join-Path ([IO.Path]::GetTempPath()) ("ww_empty_" + [guid]::NewGuid() + ".sqlite")
        'CREATE TABLE History (transcriptEntityId TEXT, timestamp TEXT);' | & $script:sqlite2 $empty
        Get-DbMaxTimestamp -DbPath $empty -Sqlite3Path $script:sqlite2 | Should -Be ''
        Remove-Item $empty -Force
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — `Read-NewTranscripts` not defined.

- [ ] **Step 3: Implement**

Add to `WhisperWez.psm1`:
```powershell
function ConvertTo-SqlLiteral {
    param([string]$Value)
    "'" + ($Value -replace "'", "''") + "'"
}

function Read-NewTranscripts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DbPath,
        [Parameter(Mandatory)][string]$Sqlite3Path,
        [Parameter(Mandatory)][string]$TargetApp,
        [Parameter(Mandatory)][string]$SinceTimestamp
    )
    if (-not (Test-Path $DbPath)) { throw "DB not found: $DbPath" }

    $app   = ConvertTo-SqlLiteral $TargetApp
    $since = ConvertTo-SqlLiteral $SinceTimestamp
    $sql = @"
SELECT transcriptEntityId AS Id, timestamp AS Timestamp,
       COALESCE(NULLIF(formattedText,''), NULLIF(asrText,'')) AS Text
FROM History
WHERE app = $app
  AND timestamp >= $since
  AND status IN ('formatted','raw_transcript')
  AND COALESCE(NULLIF(formattedText,''), NULLIF(asrText,'')) IS NOT NULL
ORDER BY timestamp ASC;
"@
    Invoke-Sqlite -Sqlite3Path $Sqlite3Path -DbPath $DbPath -Sql $sql | ForEach-Object {
        [pscustomobject]@{ Id = $_.Id; Timestamp = $_.Timestamp; Text = $_.Text }
    }
}

function Invoke-Sqlite {
    # Runs a query against a read-only connection so Wispr's live DB is never locked/modified.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Sqlite3Path,
        [Parameter(Mandatory)][string]$DbPath,
        [Parameter(Mandatory)][string]$Sql
    )
    $uri = 'file:' + ($DbPath -replace '\\','/') + '?mode=ro'
    $json = $Sql | & $Sqlite3Path -json -readonly $uri 2>$null
    if (-not $json) { return @() }
    @($json | ConvertFrom-Json)   # ConvertFrom-Json yields a single object for one row; normalize to array
}

function Get-DbMaxTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DbPath,
        [Parameter(Mandatory)][string]$Sqlite3Path
    )
    if (-not (Test-Path $DbPath)) { throw "DB not found: $DbPath" }
    $rows = Invoke-Sqlite -Sqlite3Path $Sqlite3Path -DbPath $DbPath `
                -Sql "SELECT COALESCE(MAX(timestamp),'') AS MaxTs FROM History;"
    if (-not $rows) { return '' }
    [string]$rows[0].MaxTs
}
```

> Note: `-readonly` plus the `?mode=ro` URI are belt-and-suspenders. If a future sqlite3 build rejects the `-readonly` flag with a URI, drop `-readonly` and keep the URI.

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: PASS (4 assertions in the Describe).

- [ ] **Step 5: Commit**

```bash
cd /mnt/d/Git/Personal/WhisperWez && git add -A && git commit -m "add Read-NewTranscripts DB reader with integration tests"
```

---

### Task 4: State management (high-water mark)

**Files:**
- Modify: `WhisperWez.psm1`
- Modify: `tests/WhisperWez.Tests.ps1`

**Interfaces:**
- Produces:
  - `New-WhisperWezState [-Now <string>]` → `[pscustomobject]@{ LastTimestamp; RecentIds = @() }`. `Now` defaults to `(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')`.
  - `Get-WhisperWezState -StateFile <string>` → state object, or `$null` if the file does not exist.
  - `Save-WhisperWezState -StateFile <string> -State <object>` → void (writes JSON).
  - `Test-TranscriptProcessed -State <object> -Row <object>` → `[bool]` (true if `Row.Id` is in `RecentIds`).
  - `Update-WhisperWezState -State <object> -Row <object> [-MaxRecentIds <int>]` → new state object (advances `LastTimestamp` to the max of current/row, appends `Row.Id`, trims `RecentIds` to the most recent `MaxRecentIds`).

- [ ] **Step 1: Write the failing tests**

Add to `tests/WhisperWez.Tests.ps1`:
```powershell
Describe 'WhisperWez state' {
    It 'New-WhisperWezState starts empty at the given time' {
        $s = New-WhisperWezState -Now '2026-09-02 12:00:00'
        $s.LastTimestamp | Should -Be '2026-09-02 12:00:00'
        @($s.RecentIds).Count | Should -Be 0
    }
    It 'Get-WhisperWezState returns null when file is absent' {
        Get-WhisperWezState -StateFile (Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())) | Should -BeNullOrEmpty
    }
    It 'Save/Get round-trips' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid() + '.json')
        $s = New-WhisperWezState -Now '2026-09-02 12:00:00'
        Save-WhisperWezState -StateFile $f -State $s
        (Get-WhisperWezState -StateFile $f).LastTimestamp | Should -Be '2026-09-02 12:00:00'
        Remove-Item $f -Force
    }
    It 'Update advances timestamp and records id' {
        $s = New-WhisperWezState -Now '2026-09-02 12:00:00'
        $row = [pscustomobject]@{ Id='a'; Timestamp='2026-09-02 12:00:05'; Text='x' }
        $s2 = Update-WhisperWezState -State $s -Row $row
        $s2.LastTimestamp | Should -Be '2026-09-02 12:00:05'
        $s2.RecentIds | Should -Contain 'a'
    }
    It 'Update keeps the larger timestamp when row is older' {
        $s = New-WhisperWezState -Now '2026-09-02 12:00:10'
        $row = [pscustomobject]@{ Id='b'; Timestamp='2026-09-02 12:00:05'; Text='x' }
        (Update-WhisperWezState -State $s -Row $row).LastTimestamp | Should -Be '2026-09-02 12:00:10'
    }
    It 'Update trims RecentIds to MaxRecentIds' {
        $s = New-WhisperWezState -Now '2026-09-02 12:00:00'
        1..5 | ForEach-Object {
            $s = Update-WhisperWezState -State $s -Row ([pscustomobject]@{ Id="id$_"; Timestamp='2026-09-02 12:00:00'; Text='x' }) -MaxRecentIds 3
        }
        @($s.RecentIds).Count | Should -Be 3
        $s.RecentIds | Should -Be @('id3','id4','id5')
    }
    It 'Test-TranscriptProcessed detects a known id' {
        $s = New-WhisperWezState -Now '2026-09-02 12:00:00'
        $s = Update-WhisperWezState -State $s -Row ([pscustomobject]@{ Id='seen'; Timestamp='2026-09-02 12:00:00'; Text='x' })
        Test-TranscriptProcessed -State $s -Row ([pscustomobject]@{ Id='seen' })  | Should -BeTrue
        Test-TranscriptProcessed -State $s -Row ([pscustomobject]@{ Id='new' })   | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — functions not defined.

- [ ] **Step 3: Implement**

Add to `WhisperWez.psm1`:
```powershell
function New-WhisperWezState {
    [CmdletBinding()]
    param([string]$Now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    [pscustomobject]@{ LastTimestamp = $Now; RecentIds = @() }
}

function Get-WhisperWezState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateFile)
    if (-not (Test-Path $StateFile)) { return $null }
    $o = Get-Content -Raw -Path $StateFile | ConvertFrom-Json
    [pscustomobject]@{ LastTimestamp = $o.LastTimestamp; RecentIds = @($o.RecentIds) }
}

function Save-WhisperWezState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateFile, [Parameter(Mandatory)]$State)
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
}

function Test-TranscriptProcessed {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Row)
    @($State.RecentIds) -contains $Row.Id
}

function Update-WhisperWezState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Row, [int]$MaxRecentIds = 50)
    $last = $State.LastTimestamp
    if ([string]::Compare($Row.Timestamp, $last) -gt 0) { $last = $Row.Timestamp }
    $ids = @($State.RecentIds) + $Row.Id
    if ($ids.Count -gt $MaxRecentIds) { $ids = $ids[($ids.Count - $MaxRecentIds)..($ids.Count - 1)] }
    [pscustomobject]@{ LastTimestamp = $last; RecentIds = $ids }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /mnt/d/Git/Personal/WhisperWez && git add -A && git commit -m "add high-water-mark state management"
```

---

### Task 5: Foreground-window detection

**Files:**
- Modify: `WhisperWez.psm1`
- Modify: `tests/WhisperWez.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-ForegroundProcessName` → `[string]` process name of the foreground window (no `.exe`), or `$null`.
  - `Test-TargetFocused -TargetApp <string>` → `[bool]` (`$true` when the foreground process name equals `TargetApp`). Calls `Get-ForegroundProcessName` so it can be mocked in tests.

- [ ] **Step 1: Write the failing tests (mock the OS call)**

Add to `tests/WhisperWez.Tests.ps1`:
```powershell
Describe 'Test-TargetFocused' {
    It 'is true when foreground matches target' {
        Mock -ModuleName WhisperWez Get-ForegroundProcessName { 'wezterm-gui' }
        Test-TargetFocused -TargetApp 'wezterm-gui' | Should -BeTrue
    }
    It 'is false when foreground differs' {
        Mock -ModuleName WhisperWez Get-ForegroundProcessName { 'chrome' }
        Test-TargetFocused -TargetApp 'wezterm-gui' | Should -BeFalse
    }
    It 'is false when foreground is unknown' {
        Mock -ModuleName WhisperWez Get-ForegroundProcessName { $null }
        Test-TargetFocused -TargetApp 'wezterm-gui' | Should -BeFalse
    }
}

Describe 'Get-ForegroundProcessName (smoke)' {
    It 'returns a string or null without throwing' {
        { Get-ForegroundProcessName } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — functions not defined.

- [ ] **Step 3: Implement**

Add to `WhisperWez.psm1`:
```powershell
$script:User32 = @'
using System;
using System.Runtime.InteropServices;
public static class WWUser32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
'@
if (-not ('WWUser32' -as [type])) { Add-Type -TypeDefinition $script:User32 }

function Get-ForegroundProcessName {
    [CmdletBinding()]
    param()
    try {
        $h = [WWUser32]::GetForegroundWindow()
        if ($h -eq [IntPtr]::Zero) { return $null }
        [uint32]$procId = 0   # NOTE: do not name this $pid (read-only automatic var); type must match the out uint param
        [void][WWUser32]::GetWindowThreadProcessId($h, [ref]$procId)
        if ($procId -eq 0) { return $null }
        (Get-Process -Id $procId -ErrorAction Stop).ProcessName
    } catch { $null }
}

function Test-TargetFocused {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetApp)
    (Get-ForegroundProcessName) -eq $TargetApp
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /mnt/d/Git/Personal/WhisperWez && git add -A && git commit -m "add foreground-window detection"
```

---

### Task 6: Clipboard + paste primitives

**Files:**
- Modify: `WhisperWez.psm1`
- Modify: `tests/WhisperWez.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-ClipboardTextSafe` → `[string]` current clipboard text (`''` on failure/empty).
  - `Set-ClipboardTextSafe -Text <string>` → `[bool]` success.
  - `Send-CtrlV` → void (injects Ctrl down / V down / V up / Ctrl up via `SendInput`). **Not exercised in automated tests** (it would paste into whatever is focused); covered by manual verification in Task 9.

- [ ] **Step 1: Write the failing tests**

Add to `tests/WhisperWez.Tests.ps1`:
```powershell
Describe 'Clipboard primitives' {
    It 'round-trips clipboard text' {
        $marker = 'WW_TEST_' + [guid]::NewGuid()
        (Set-ClipboardTextSafe -Text $marker) | Should -BeTrue
        Get-ClipboardTextSafe | Should -Be $marker
    }
    It 'Set-ClipboardTextSafe handles empty string' {
        (Set-ClipboardTextSafe -Text '') | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — functions not defined.

- [ ] **Step 3: Implement**

Add to `WhisperWez.psm1`:
```powershell
function Get-ClipboardTextSafe {
    [CmdletBinding()]
    param()
    try {
        $t = Get-Clipboard -Raw -ErrorAction Stop
        if ($null -eq $t) { '' } else { [string]$t }
    } catch { '' }
}

function Set-ClipboardTextSafe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    try {
        if ([string]::IsNullOrEmpty($Text)) { Set-Clipboard -Value ' ' } # Set-Clipboard rejects empty
        else { Set-Clipboard -Value $Text }
        $true
    } catch { $false }
}

$script:SendInput = @'
using System;
using System.Runtime.InteropServices;
public static class WWInput {
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public InputUnion U; }
    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion { [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll", SetLastError=true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    const uint INPUT_KEYBOARD = 1; const uint KEYEVENTF_KEYUP = 2;
    const ushort VK_CONTROL = 0x11; const ushort VK_V = 0x56;
    static INPUT Key(ushort vk, bool up) {
        return new INPUT { type = INPUT_KEYBOARD, U = new InputUnion { ki = new KEYBDINPUT { wVk = vk, dwFlags = up ? KEYEVENTF_KEYUP : 0 } } };
    }
    public static void CtrlV() {
        INPUT[] seq = new INPUT[] { Key(VK_CONTROL,false), Key(VK_V,false), Key(VK_V,true), Key(VK_CONTROL,true) };
        SendInput((uint)seq.Length, seq, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@
if (-not ('WWInput' -as [type])) { Add-Type -TypeDefinition $script:SendInput }

function Send-CtrlV {
    [CmdletBinding()]
    param()
    [WWInput]::CtrlV()
}
```

> `Set-ClipboardTextSafe` substitutes a single space for an empty string because `Set-Clipboard` throws on empty input; WhisperWez never injects empty text (the DB reader excludes empties), so this only guards the restore path.

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /mnt/d/Git/Personal/WhisperWez && git add -A && git commit -m "add clipboard and SendInput Ctrl+V primitives"
```

---

### Task 7: Injection orchestrator

**Files:**
- Modify: `WhisperWez.psm1`
- Modify: `tests/WhisperWez.Tests.ps1`

**Interfaces:**
- Consumes: `Test-TargetFocused`, `Get-ClipboardTextSafe`, `Set-ClipboardTextSafe`, `Send-CtrlV`.
- Produces: `Invoke-Injection -Text <string> -Config <hashtable> [-DryRun]` → `[pscustomobject]@{ Action; Focused }` where `Action` is `'pasted'`, `'clipboard-only'`, or `'dryrun'`.

- [ ] **Step 1: Write the failing tests (mock all OS calls)**

Add to `tests/WhisperWez.Tests.ps1`:
```powershell
Describe 'Invoke-Injection' {
    BeforeEach {
        $script:cfg = Get-WhisperWezConfig -Overrides @{ RestoreClipboard = $true; ClipboardRestoreDelayMs = 0 }
        Mock -ModuleName WhisperWez Get-ClipboardTextSafe { 'PREV' }
        Mock -ModuleName WhisperWez Set-ClipboardTextSafe { $true }
        Mock -ModuleName WhisperWez Send-CtrlV {}
        Mock -ModuleName WhisperWez Start-Sleep {}
    }
    It 'pastes and restores when WezTerm is focused' {
        Mock -ModuleName WhisperWez Test-TargetFocused { $true }
        $r = Invoke-Injection -Text 'hello' -Config $script:cfg
        $r.Action  | Should -Be 'pasted'
        $r.Focused | Should -BeTrue
        Should -Invoke -ModuleName WhisperWez Send-CtrlV -Times 1 -Exactly
        Should -Invoke -ModuleName WhisperWez Set-ClipboardTextSafe -Times 2 -Exactly  # set text, then restore
    }
    It 'sets clipboard only when not focused' {
        Mock -ModuleName WhisperWez Test-TargetFocused { $false }
        $r = Invoke-Injection -Text 'hello' -Config $script:cfg
        $r.Action | Should -Be 'clipboard-only'
        Should -Invoke -ModuleName WhisperWez Send-CtrlV -Times 0 -Exactly
        Should -Invoke -ModuleName WhisperWez Set-ClipboardTextSafe -Times 1 -Exactly
    }
    It 'does nothing to the OS in DryRun' {
        Mock -ModuleName WhisperWez Test-TargetFocused { $true }
        $r = Invoke-Injection -Text 'hello' -Config $script:cfg -DryRun
        $r.Action | Should -Be 'dryrun'
        Should -Invoke -ModuleName WhisperWez Send-CtrlV -Times 0 -Exactly
        Should -Invoke -ModuleName WhisperWez Set-ClipboardTextSafe -Times 0 -Exactly
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — `Invoke-Injection` not defined.

- [ ] **Step 3: Implement**

Add to `WhisperWez.psm1`:
```powershell
function Invoke-Injection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][hashtable]$Config,
        [switch]$DryRun
    )
    $focused = Test-TargetFocused -TargetApp $Config.TargetApp

    if ($DryRun) {
        return [pscustomobject]@{ Action = 'dryrun'; Focused = $focused }
    }

    if (-not $focused) {
        [void](Set-ClipboardTextSafe -Text $Text)
        return [pscustomobject]@{ Action = 'clipboard-only'; Focused = $false }
    }

    $prev = if ($Config.RestoreClipboard) { Get-ClipboardTextSafe } else { $null }
    [void](Set-ClipboardTextSafe -Text $Text)
    Send-CtrlV
    if ($Config.RestoreClipboard) {
        Start-Sleep -Milliseconds $Config.ClipboardRestoreDelayMs
        [void](Set-ClipboardTextSafe -Text $prev)
    }
    [pscustomobject]@{ Action = 'pasted'; Focused = $true }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /mnt/d/Git/Personal/WhisperWez && git add -A && git commit -m "add injection orchestrator with focus guard and clipboard restore"
```

---

### Task 8: Logger

**Files:**
- Modify: `WhisperWez.psm1`
- Modify: `tests/WhisperWez.Tests.ps1`

**Interfaces:**
- Produces: `Write-WhisperWezLog -LogFile <string> -Message <string> [-Level <string>]` → void. Appends `yyyy-MM-dd HH:mm:ss [LEVEL] message`. Rolls the file to `<LogFile>.1` when it exceeds ~5 MB.

- [ ] **Step 1: Write the failing tests**

Add to `tests/WhisperWez.Tests.ps1`:
```powershell
Describe 'Write-WhisperWezLog' {
    It 'appends a timestamped, leveled line' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid() + '.log')
        Write-WhisperWezLog -LogFile $f -Message 'hello' -Level 'INFO'
        (Get-Content $f) | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[INFO\] hello$'
        Remove-Item $f -Force
    }
    It 'rolls the file when oversized' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid() + '.log')
        Set-Content -Path $f -Value ('x' * 10) 
        Write-WhisperWezLog -LogFile $f -Message 'after' -MaxBytes 5
        Test-Path "$f.1" | Should -BeTrue
        Remove-Item $f, "$f.1" -Force -ErrorAction SilentlyContinue
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — function not defined.

- [ ] **Step 3: Implement**

Add to `WhisperWez.psm1`:
```powershell
function Write-WhisperWezLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogFile,
        [Parameter(Mandatory)][string]$Message,
        [string]$Level = 'INFO',
        [int]$MaxBytes = 5MB
    )
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt $MaxBytes)) {
            Move-Item -Path $LogFile -Destination "$LogFile.1" -Force
        }
        $line = "{0} [{1}] {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { }  # logging must never crash the loop
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /mnt/d/Git/Personal/WhisperWez && git add -A && git commit -m "add rolling file logger"
```

---

### Task 9: Main loop + runner wiring

**Files:**
- Modify: `WhisperWez.psm1`
- Create: `whisperwez.ps1`
- Modify: `tests/WhisperWez.Tests.ps1`

**Interfaces:**
- Consumes: `Get-WhisperWezConfig`, `Resolve-Sqlite3Path`, `Get-DbMaxTimestamp`, state functions, `Read-NewTranscripts`, `Invoke-Injection`, `Write-WhisperWezLog`.
- Produces: `Start-WhisperWez -Config <hashtable> [-DryRun] [-Once]` → void. Loads-or-initializes state (seeding the high-water mark from `Get-DbMaxTimestamp` on first run), then each tick reads new transcripts, injects the unprocessed ones, updates+saves state, logs. `-Once` runs exactly one poll (for tests); without it, loops forever sleeping `PollMs` between ticks.

- [ ] **Step 1: Write the failing tests (mock DB + injection)**

Add to `tests/WhisperWez.Tests.ps1`:
```powershell
Describe 'Start-WhisperWez -Once' {
    BeforeEach {
        $script:stateFile = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid() + '.json')
        $script:cfg = Get-WhisperWezConfig -Overrides @{
            StateFile   = $script:stateFile
            LogFile     = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid() + '.log')
            Sqlite3Path = 'sqlite3'
            DbPath      = 'C:\nonexistent\flow.sqlite'
        }
        Mock -ModuleName WhisperWez Invoke-Injection { [pscustomobject]@{ Action='pasted'; Focused=$true } }
        Mock -ModuleName WhisperWez Write-WhisperWezLog {}
        Mock -ModuleName WhisperWez Get-DbMaxTimestamp { '2026-09-02 12:00:00.000 +00:00' }
    }
    AfterEach { Remove-Item $script:stateFile -Force -ErrorAction SilentlyContinue }

    It 'injects each new transcript once and advances state' {
        Mock -ModuleName WhisperWez Read-NewTranscripts {
            @(
                [pscustomobject]@{ Id='r1'; Timestamp='2026-09-02 13:00:00'; Text='one' },
                [pscustomobject]@{ Id='r2'; Timestamp='2026-09-02 13:00:01'; Text='two' }
            )
        }
        Start-WhisperWez -Config $script:cfg -Once
        Should -Invoke -ModuleName WhisperWez Invoke-Injection -Times 2 -Exactly
        (Get-WhisperWezState -StateFile $script:stateFile).RecentIds | Should -Contain 'r2'
    }

    It 'does not re-inject an already-processed transcript on the next poll' {
        Mock -ModuleName WhisperWez Read-NewTranscripts {
            @([pscustomobject]@{ Id='r1'; Timestamp='2026-09-02 13:00:00'; Text='one' })
        }
        Start-WhisperWez -Config $script:cfg -Once   # processes r1
        Start-WhisperWez -Config $script:cfg -Once   # r1 already in RecentIds
        Should -Invoke -ModuleName WhisperWez Invoke-Injection -Times 1 -Exactly
    }

    It 'survives a DB read error without throwing' {
        Mock -ModuleName WhisperWez Read-NewTranscripts { throw 'db locked' }
        { Start-WhisperWez -Config $script:cfg -Once } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — `Start-WhisperWez` not defined.

- [ ] **Step 3: Implement the loop**

Add to `WhisperWez.psm1`:
```powershell
function Start-WhisperWez {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [switch]$DryRun,
        [switch]$Once
    )
    $state = Get-WhisperWezState -StateFile $Config.StateFile
    if ($null -eq $state) {
        # Seed from the DB's own clock/format (UTC) so timestamp comparisons are apples-to-apples.
        $seed = Get-DbMaxTimestamp -DbPath $Config.DbPath -Sqlite3Path $Config.Sqlite3Path
        $state = New-WhisperWezState -Now $seed
        Save-WhisperWezState -StateFile $Config.StateFile -State $state
        Write-WhisperWezLog -LogFile $Config.LogFile -Message "Initialized high-water mark at '$seed'"
    }

    do {
        try {
            $rows = Read-NewTranscripts -DbPath $Config.DbPath -Sqlite3Path $Config.Sqlite3Path `
                        -TargetApp $Config.TargetApp -SinceTimestamp $state.LastTimestamp
            foreach ($row in @($rows)) {
                if (Test-TranscriptProcessed -State $state -Row $row) { continue }
                $result = Invoke-Injection -Text $row.Text -Config $Config -DryRun:$DryRun
                $state = Update-WhisperWezState -State $state -Row $row -MaxRecentIds $Config.MaxRecentIds
                Save-WhisperWezState -StateFile $Config.StateFile -State $state
                Write-WhisperWezLog -LogFile $Config.LogFile `
                    -Message ("{0} chars -> {1} (focused={2}) id={3}" -f $row.Text.Length, $result.Action, $result.Focused, $row.Id)
            }
        } catch {
            Write-WhisperWezLog -LogFile $Config.LogFile -Level 'ERROR' -Message $_.Exception.Message
        }
        if (-not $Once) { Start-Sleep -Milliseconds $Config.PollMs }
    } while (-not $Once)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: PASS.

- [ ] **Step 5: Create the runner**

Create `whisperwez.ps1`:
```powershell
[CmdletBinding()]
param([switch]$DryRun, [switch]$Once)

Import-Module (Join-Path $PSScriptRoot 'WhisperWez.psm1') -Force
$config = Get-WhisperWezConfig
$config.Sqlite3Path = Resolve-Sqlite3Path -RepoRoot $PSScriptRoot
Write-WhisperWezLog -LogFile $config.LogFile -Message "WhisperWez $(Get-WhisperWezVersion) starting (DryRun=$DryRun)"
Start-WhisperWez -Config $config -DryRun:$DryRun -Once:$Once
```

- [ ] **Step 6: Manual verification (record results in the commit message)**

Run each and confirm behavior via `whisperwez.log`:
1. Dry run, one poll:
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'D:\Git\Personal\WhisperWez\whisperwez.ps1' -DryRun -Once` → log shows startup + "Initialized state".
2. Focused paste: start `whisperwez.ps1` (no args) in one window, focus WezTerm, dictate a phrase → text appears at the prompt, not executed.
3. Focus-guard: dictate into WezTerm then immediately click another window → nothing pastes; `Ctrl+V` in WezTerm yields the transcript (clipboard-only path).
4. Non-target: dictate into another app → no WhisperWez log entry for it (row's `app` != `wezterm-gui`).

- [ ] **Step 7: Commit**

```bash
cd /mnt/d/Git/Personal/WhisperWez && git add -A && git commit -m "add main poll loop and runner; manual paste/focus-guard verification passed"
```

---

### Task 10: Install / uninstall (logon scheduled task)

**Files:**
- Modify: `WhisperWez.psm1`
- Create: `install.ps1`
- Create: `uninstall.ps1`
- Modify: `tests/WhisperWez.Tests.ps1`

**Interfaces:**
- Produces: `New-WhisperWezTaskAction -ScriptPath <string>` → a `ScheduledTaskAction` running `powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File <ScriptPath>`. Kept as a testable builder so the exact command line is asserted without registering anything.

- [ ] **Step 1: Write the failing test**

Add to `tests/WhisperWez.Tests.ps1`:
```powershell
Describe 'New-WhisperWezTaskAction' {
    It 'builds a hidden, non-profile powershell action for the runner' {
        $a = New-WhisperWezTaskAction -ScriptPath 'D:\Git\Personal\WhisperWez\whisperwez.ps1'
        $a.Execute   | Should -Match 'powershell\.exe$'
        $a.Arguments | Should -Match '-WindowStyle Hidden'
        $a.Arguments | Should -Match '-File "D:\\Git\\Personal\\WhisperWez\\whisperwez\.ps1"'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run the test command. Expected: FAIL — function not defined.

- [ ] **Step 3: Implement the builder**

Add to `WhisperWez.psm1`:
```powershell
function New-WhisperWezTaskAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScriptPath)
    $taskArgs = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath  # avoid $args (automatic var)
    New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the test command. Expected: PASS.

- [ ] **Step 5: Create install.ps1**

```powershell
[CmdletBinding()] param()
Import-Module (Join-Path $PSScriptRoot 'WhisperWez.psm1') -Force

$script  = Join-Path $PSScriptRoot 'whisperwez.ps1'
$action  = New-WhisperWezTaskAction -ScriptPath $script
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
# Limited run level = non-elevated, required so SendInput reaches WezTerm.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName 'WhisperWez' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "WhisperWez installed (logon task, non-elevated)."
Write-Host "Log: $(Join-Path $PSScriptRoot 'whisperwez.log')"
Write-Host "Start now without logging off:  Start-ScheduledTask -TaskName WhisperWez"
```

- [ ] **Step 6: Create uninstall.ps1**

```powershell
[CmdletBinding()] param()
Unregister-ScheduledTask -TaskName 'WhisperWez' -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "WhisperWez uninstalled."
```

- [ ] **Step 7: Manual verification**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'D:\Git\Personal\WhisperWez\install.ps1'
powershell.exe -NoProfile -Command "Get-ScheduledTask -TaskName WhisperWez | Select-Object TaskName,State; (Get-ScheduledTask WhisperWez).Principal.RunLevel"
powershell.exe -NoProfile -Command "Start-ScheduledTask -TaskName WhisperWez"
```
Expected: task exists, `RunLevel = Limited`; after Start, dictating into WezTerm pastes. Confirm uninstall removes it.

- [ ] **Step 8: Commit**

```bash
cd /mnt/d/Git/Personal/WhisperWez && git add -A && git commit -m "add logon scheduled-task install/uninstall"
```

---

### Task 11: README + repo finalization

**Files:**
- Create: `README.md`
- Modify: `.gitignore` (verify)

- [ ] **Step 1: Write README.md**

Include, in this order:
1. **What it is** — one paragraph: makes Wispr Flow dictation land in WezTerm; link `docs/design.md` for the why.
2. **Requirements** — Windows, Windows PowerShell 5.1, WezTerm, Wispr Flow; `sqlite3.exe` bundled.
3. **Setup** — `winget install -e --id SQLite.SQLite` (or place `sqlite3.exe` in the folder); `Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck` (dev only); run `install.ps1`.
4. **Usage** — starts at logon; `Start-ScheduledTask -TaskName WhisperWez` to start immediately; dictate into WezTerm and the text pastes on the prompt (press Enter yourself).
5. **Configuration** — table of `Get-WhisperWezConfig` keys and defaults (`PollMs`, `RestoreClipboard`, etc.); how to override by editing `whisperwez.ps1`.
6. **Troubleshooting** — check `whisperwez.log`; run `whisperwez.ps1 -DryRun -Once`; confirm the task is `RunLevel = Limited`; confirm Wispr stamps `app='wezterm-gui'`.
7. **Uninstall** — `uninstall.ps1`.
8. **How it works** — one paragraph: watches `flow.sqlite` `History`, pastes via clipboard + `Ctrl+V` only when WezTerm is focused; never auto-executes.

- [ ] **Step 2: Verify .gitignore**

Confirm `.gitignore` contains `state.json`, `*.log`, and `sqlite3.exe`. Confirm `git status` shows no runtime artifacts staged.

- [ ] **Step 3: Full test run (regression)**

Run the Global Constraints test command. Expected: all Describes PASS.

- [ ] **Step 4: Commit**

```bash
cd /mnt/d/Git/Personal/WhisperWez && git add -A && git commit -m "add README and finalize repo"
```

---

## Self-Review

**Spec coverage:**
- Problem/root cause → documented in `docs/design.md`; not code.
- Read-only DB watch of `History` → Task 3.
- Filter `app='wezterm-gui'`, finalized text with `asrText` fallback → Task 3.
- High-water mark, no backlog replay, equal-timestamp dedupe → Task 4 (+ init-to-now in Task 9 loop).
- Foreground guard → Task 5 + Task 7.
- Clipboard + `Ctrl+V` bracketed paste, never auto-execute → Task 6 + Task 7.
- Clipboard restore → Task 7.
- DryRun → Task 7 + Task 9.
- Error handling / loop never dies → Task 9 (+ safe logger Task 8).
- Logging → Task 8.
- Non-elevated logon autostart → Task 10.
- README/setup → Task 11.
- Config keys (`DbPath`, `TargetApp`, `PollMs`, `RestoreClipboard`, `StateFile`, `LogFile`, `Sqlite3Path`) → Task 2.

**Placeholder scan:** No TBD/TODO; every code and test step contains real content.

**Type consistency:** Row shape `@{ Id; Timestamp; Text }` is produced by `Read-NewTranscripts` (Task 3) and consumed identically by state functions (Task 4), `Invoke-Injection` (Task 7 uses `.Text`), and the loop (Task 9). Config keys defined in Task 2 are the exact keys read in Tasks 7 and 9. State shape `@{ LastTimestamp; RecentIds }` is consistent across Tasks 4 and 9. `Invoke-Injection` result `@{ Action; Focused }` is produced in Task 7 and logged in Task 9.
