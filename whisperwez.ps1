[CmdletBinding()]
param([switch]$DryRun, [switch]$Once)

Import-Module (Join-Path $PSScriptRoot 'WhisperWez.psm1') -Force
$config = Get-WhisperWezConfig
$config.Sqlite3Path = Resolve-Sqlite3Path -RepoRoot $PSScriptRoot
Write-WhisperWezLog -LogFile $config.LogFile -Message "WhisperWez $(Get-WhisperWezVersion) starting (DryRun=$DryRun)"
Start-WhisperWez -Config $config -DryRun:$DryRun -Once:$Once
