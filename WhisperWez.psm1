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
    # Materialize into a variable before piping: Invoke-Sqlite has its own internal
    # pipeline ($Sql | & $Sqlite3Path ...), and calling it unparenthesized as the head
    # of this outer `| ForEach-Object` causes PowerShell 5.1 to bind the outer $_ to
    # the *entire* result array in one pass (so $_.Id / $_.Text become arrays of all
    # values) instead of streaming one row per iteration. Assigning to $dbRows first
    # avoids that nested-pipeline $_ scoping bug.
    $dbRows = Invoke-Sqlite -Sqlite3Path $Sqlite3Path -DbPath $DbPath -Sql $sql
    $dbRows | ForEach-Object {
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

Export-ModuleMember -Function *
