<#
.SYNOPSIS
  Remove the WhisperWez logon Scheduled Task created by install.ps1.

.EXAMPLE
  .\uninstall.ps1
  .\uninstall.ps1 -TaskName 'WhisperWez'
#>
[CmdletBinding()]
param([string]$TaskName = 'WhisperWez')

$ErrorActionPreference = 'Stop'

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $existing) {
    Write-Host "No scheduled task named '$TaskName' found; nothing to do."
    return
}

# Stop a running instance first, then remove the task. (This does not stop a WhisperWez
# already launched by hand -- close that window or Stop-Process it separately.)
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Unregistered scheduled task '$TaskName'."
