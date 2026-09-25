@echo off
rem Double-click to (re)start WhisperWez. Safe to run when it's already running: the
rem single-instance mutex in whisperwez.ps1 makes a second copy exit immediately.
rem Uses the WhisperWez scheduled task if installed, otherwise launches the script hidden.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "if (Get-ScheduledTask -TaskName WhisperWez -ErrorAction SilentlyContinue) { Start-ScheduledTask -TaskName WhisperWez } else { Start-Process powershell.exe -WindowStyle Hidden -WorkingDirectory '%~dp0.' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0whisperwez.ps1' };" ^
  "Start-Sleep 3; Write-Host ''; Get-Content '%~dp0whisperwez.log' -Tail 3"
echo.
echo WhisperWez started. This window closes in 5 seconds.
timeout /t 5 >nul
