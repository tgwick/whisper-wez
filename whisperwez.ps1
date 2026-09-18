[CmdletBinding()]
param([switch]$DryRun, [switch]$Once, [int]$PasteDelayMs)

Import-Module (Join-Path $PSScriptRoot 'WhisperWez.psm1') -Force
$config = Get-WhisperWezConfig
$config.Sqlite3Path = Resolve-Sqlite3Path -RepoRoot $PSScriptRoot
# Tune the bracketed-paste per-byte pause from the command line (higher = safer against dropped
# characters in a TUI, at the cost of a slower paste).
if ($PSBoundParameters.ContainsKey('PasteDelayMs')) { $config.PasteDelayMs = $PasteDelayMs }

# Single-instance guard. Two overlapping watchers each poll flow.sqlite and each paste the
# same transcript, so the text lands twice. A named mutex lets only the first instance run;
# a second launch logs and exits immediately. The OS frees the mutex when the owning process
# exits (including a force-kill), so a crash never leaves a stale lock behind.
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'WhisperWez-SingleInstance', [ref]$createdNew)
if (-not $createdNew) {
    Write-WhisperWezLog -LogFile $config.LogFile -Level 'WARN' -Message "Another WhisperWez instance is already running; pid $PID exiting."
    Write-Warning 'WhisperWez is already running in another process. Exiting this one.'
    return
}

try {
    Write-WhisperWezLog -LogFile $config.LogFile -Message "WhisperWez $(Get-WhisperWezVersion) starting (pid $PID, DryRun=$DryRun)"
    Start-WhisperWez -Config $config -DryRun:$DryRun -Once:$Once
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
