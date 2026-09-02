Set-StrictMode -Version Latest

function Get-WhisperWezVersion {
    [CmdletBinding()]
    param()
    '0.1.0'
}

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
    # Materialize rows into a variable before iterating: this makes the query execute
    # and get parsed exactly once, and keeps each row's shape explicit for the loop body.
    $dbRows = Invoke-Sqlite -Sqlite3Path $Sqlite3Path -DbPath $DbPath -Sql $sql
    $dbRows | ForEach-Object {
        [pscustomobject]@{ Id = $_.Id; Timestamp = $_.Timestamp; Text = $_.Text }
    }
}

function ConvertTo-SqliteReadOnlyUri {
    # Builds a read-only sqlite3 "file:" URI from a filesystem path. Percent-encodes
    # the characters that are significant in a URI and realistically show up in a
    # real Windows path (Wispr's default DB lives under "...\Wispr Flow\flow.sqlite",
    # which contains a space) -- '%' is encoded first so an already-escaped path isn't
    # double-escaped, then space, '#', and '?'.
    param([string]$DbPath)
    $path = ($DbPath -replace '\\', '/')
    $path = $path.Replace('%', '%25').Replace('#', '%23').Replace('?', '%3F').Replace(' ', '%20')
    'file:' + $path + '?mode=ro'
}

function Invoke-Sqlite {
    # Runs a query against a read-only connection so Wispr's live DB is never locked/modified.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Sqlite3Path,
        [Parameter(Mandatory)][string]$DbPath,
        [Parameter(Mandatory)][string]$Sql
    )
    $uri = ConvertTo-SqliteReadOnlyUri $DbPath

    # Merge stderr into the output (2>&1) instead of discarding it with 2>$null:
    # native stderr lines arrive as ErrorRecord objects mixed in with the plain-string
    # stdout lines, so they can be separated below. This lets a genuine sqlite3 failure
    # (missing table, malformed SQL, a corrupt/missing DB file) be told apart from a
    # legitimately empty result set and surfaced with the real error text instead of
    # being silently masked as "no rows".
    $raw = $Sql | & $Sqlite3Path -json -readonly $uri 2>&1
    $exitCode = $LASTEXITCODE
    $stdoutLines = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $stderrText  = (@($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
                        ForEach-Object { $_.ToString() })) -join "`n"

    if ($exitCode -ne 0) {
        throw "sqlite3 failed (exit code ${exitCode}) against '$DbPath': $stderrText"
    }

    # sqlite3 -json can split its JSON result array across multiple output lines (one
    # row fragment per line); join them back into a single string before parsing so
    # ConvertFrom-Json sees one complete document instead of per-line fragments that
    # don't individually parse.
    $joined = ($stdoutLines -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($joined)) { return @() }

    # Parse, then wrap the result in @() as a *separate* statement. Wrapping @()
    # directly around an expression that itself invokes ConvertFrom-Json (e.g.
    # `@($x | ConvertFrom-Json)` or `@(ConvertFrom-Json $x)`) was empirically observed,
    # on this PowerShell 5.1 / sqlite3 3.53.4 combination, to silently truncate a
    # multi-row JSON array down to just its first element. Splitting the parse and the
    # array-normalization into two statements avoids that.
    $parsed = ConvertFrom-Json $joined
    $rows = @($parsed)   # normalizes a single-row result (which ConvertFrom-Json
                          # yields as a lone object, not a 1-element array) to an array
    $rows
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

Export-ModuleMember -Function *
