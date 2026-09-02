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

Export-ModuleMember -Function *
