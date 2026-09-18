<#
.SYNOPSIS
  Register a logon Scheduled Task that starts WhisperWez automatically.

.DESCRIPTION
  Creates a Task Scheduler task (default name "WhisperWez") that launches whisperwez.ps1
  hidden and NON-elevated in the interactive session at every logon. Non-elevated matters:
  SendInput can only reach WezTerm if WhisperWez runs at the same (non-elevated) integrity
  level. The single-instance guard in whisperwez.ps1 keeps duplicate launches from stacking.

  Registering the task may require an elevated PowerShell (the task itself still runs
  non-elevated via RunLevel=Limited). If you get "Access is denied", re-run this from an
  elevated prompt.

.EXAMPLE
  .\install.ps1
  .\install.ps1 -TaskName 'WhisperWez'
#>
[CmdletBinding()]
param([string]$TaskName = 'WhisperWez')

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$runner = Join-Path $scriptDir 'whisperwez.ps1'
if (-not (Test-Path $runner)) { throw "whisperwez.ps1 not found next to install.ps1 (looked in '$scriptDir')." }

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runner`""

$action    = New-ScheduledTaskAction -Execute $psExe -Argument $arguments -WorkingDirectory $scriptDir
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
# Interactive + Limited: run in the logged-on desktop session, non-elevated, so SendInput reaches WezTerm.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
# Keep it resilient: start on/keep running on battery, start if a logon was missed, never time out.
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
} catch {
    throw "Failed to register task '$TaskName': $($_.Exception.Message)`nIf this is 'Access is denied', re-run install.ps1 from an elevated PowerShell."
}

Write-Host "Registered scheduled task '$TaskName':"
Write-Host "  runs : $runner (hidden, non-elevated, at logon)"
Write-Host "  log  : $(Join-Path $scriptDir 'whisperwez.log')"
Write-Host ""
Write-Host "Start it now without logging off:  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Remove it:                         .\uninstall.ps1"
