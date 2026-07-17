# Install the restreamer as Windows services that start at boot and auto-restart.
# Uses Task Scheduler (built in — no extra downloads). Run in an ELEVATED PowerShell:
#   Set-ExecutionPolicy -Scope Process Bypass -Force
#   .\install-windows.ps1            # install + start
#   .\install-windows.ps1 -Uninstall
#
# Requires: Python 3 and ffmpeg on PATH (or set "ffmpeg" in config.json). Windows has no
# "Local Network Privacy", so a normal SYSTEM task reaches your cameras fine.
param([switch]$Uninstall)

$ErrorActionPreference = "Stop"
$Here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Python = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
if (-not $Python) { $Python = (Get-Command python3.exe -ErrorAction SilentlyContinue).Source }
if (-not $Python) { throw "Python not found on PATH. Install Python 3 and re-run." }

$tasks = @{
  "camtv-mosaic" = Join-Path $Here "camtv.py"
  "camtv-server" = Join-Path $Here "serve.py"
}

if ($Uninstall) {
  foreach ($n in $tasks.Keys) {
    Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
  }
  Write-Host "Uninstalled."
  return
}

if (-not (Test-Path (Join-Path $Here "config.json"))) {
  throw "Create config.json first (copy config.example.json)."
}
New-Item -ItemType Directory -Force -Path (Join-Path $Here "hls"), (Join-Path $Here "logs") | Out-Null

foreach ($n in $tasks.Keys) {
  $script = $tasks[$n]
  $action  = New-ScheduledTaskAction -Execute $Python -Argument "`"$script`"" -WorkingDirectory $Here
  $trigger = New-ScheduledTaskTrigger -AtStartup
  # restart on failure, keep running indefinitely
  $settings = New-ScheduledTaskSettingsSet -RestartCount 9999 -RestartInterval (New-TimeSpan -Minutes 1) `
                -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $n -Action $action -Trigger $trigger -Settings $settings `
      -Principal $principal -Force | Out-Null
  Start-ScheduledTask -TaskName $n
  Write-Host "Installed + started: $n"
}
Write-Host "Streams at http://<this-pc-ip>:8099/  (mosaic + cam0..N + config.json)"
Write-Host "Tip: for hardware encoding set config.json 'encoder' to h264_nvenc (NVIDIA), h264_qsv (Intel), or h264_amf (AMD)."
