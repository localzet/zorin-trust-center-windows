$ErrorActionPreference='Stop'
$Src=Split-Path -Parent $MyInvocation.MyCommand.Path
$Dst=Join-Path $env:LOCALAPPDATA 'ZorinTrust\ui'
New-Item -ItemType Directory -Force -Path $Dst|Out-Null
Copy-Item (Join-Path $Src 'trust-center.ps1') (Join-Path $Dst 'trust-center.ps1') -Force
$Task='ZorinTrustCenterTray'
$PowerShell=(Get-Command powershell.exe).Source
$Arg="-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Dst\trust-center.ps1`" -Tray"
$Action=New-ScheduledTaskAction -Execute $PowerShell -Argument $Arg
$Trigger=New-ScheduledTaskTrigger -AtLogOn
$Principal=New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $Task -Action $Action -Trigger $Trigger -Principal $Principal -Force|Out-Null
Start-ScheduledTask -TaskName $Task
Write-Host "Trust Center tray installed: $Task" -ForegroundColor Green
