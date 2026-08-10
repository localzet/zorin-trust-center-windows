$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    throw 'Installer internal error: PSScriptRoot is empty.'
}
$Here = Split-Path -Parent (Split-Path -Parent $ScriptDir)
if ([string]::IsNullOrWhiteSpace($Here)) {
    throw 'Installer internal error: bundle root could not be resolved.'
}

$State = Join-Path $env:APPDATA 'ZorinTrust'
$Local = Join-Path $env:LOCALAPPDATA 'ZorinTrust'
$Bin = Join-Path $Local 'bin'
$Ui = Join-Path $Local 'ui'
$Artifacts = Join-Path $Local 'artifacts'
New-Item -ItemType Directory -Force -Path $Bin, $Ui, $Artifacts | Out-Null

# Resolve adb once and pin the exact executable path in the scheduled task.
$adb = Get-Command adb.exe -ErrorAction SilentlyContinue
if (-not $adb) { $adb = Get-Command adb -ErrorAction SilentlyContinue }
if (-not $adb) {
    throw 'adb not found. Install Android Platform Tools and add adb to PATH.'
}
$AdbPath = $adb.Source
if (-not $AdbPath) { $AdbPath = $adb.Path }
if ([string]::IsNullOrWhiteSpace($AdbPath)) {
    throw 'adb was found, but its executable path could not be resolved.'
}

$arch = $env:PROCESSOR_ARCHITECTURE
$HostBinaryName = if ($arch -eq 'ARM64') { 'zorin-host-agent-windows-arm64.exe' } else { 'zorin-host-agent-windows-amd64.exe' }
$TrayBinaryName = if ($arch -eq 'ARM64') { 'ZorinTrustTray-windows-arm64.exe' } else { 'ZorinTrustTray-windows-amd64.exe' }

$HostSource = Join-Path $Here ('host\' + $HostBinaryName)
$TraySource = Join-Path $Here ('app\' + $TrayBinaryName)
$CenterSource = Join-Path $Here 'app\trust-center.ps1'
$IconSource = Join-Path $Here 'app\zorin-trust.ico'
$PairSource = Join-Path $Here 'app\installer\pair-phone.ps1'
$SigningScript = Join-Path $Here 'host\runtime-signing.ps1'
$Unsigned = Join-Path $Here 'app\runtime\Zorin-Trust-Runtime-v7.0.0-unsigned.apk'
$Signed = Join-Path $Artifacts 'Zorin-Trust-Runtime-v7.0.0-owner-signed.apk'

$Required = @($HostSource, $TraySource, $CenterSource, $IconSource, $PairSource, $SigningScript, $Unsigned)
foreach ($path in $Required) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Release bundle is incomplete. Missing: $path"
    }
}

# Prepare and verify the signed Runtime BEFORE stopping any currently working desktop component.
. $SigningScript
Sign-ZorinRuntime $Unsigned $Signed | Out-Null
if (-not (Test-Path -LiteralPath $Signed)) {
    throw 'Runtime signing reported success but no signed APK was produced.'
}

# Update Android while the existing desktop agent is still available. This keeps an installer failure non-disruptive.
$devices = @()
& $AdbPath devices | Select-Object -Skip 1 | ForEach-Object {
    $fields = ($_ -split '\s+') | Where-Object { $_ }
    if ($fields.Count -ge 2 -and $fields[1] -eq 'device') { $devices += $fields[0] }
}
if ($devices.Count -eq 1) {
    & $AdbPath -s $devices[0] install -r $Signed | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Android Runtime update failed.' }
    try { & $AdbPath -s $devices[0] shell appops set dev.zorin.trustruntime SYSTEM_ALERT_WINDOW allow | Out-Null } catch {}
    Write-Host 'Android Runtime 7.0.0 updated.' -ForegroundColor Green
} else {
    Write-Warning "Phone Runtime not updated now (authorized adb devices: $($devices.Count)). Run Install.bat again with exactly one phone connected."
}

Import-Module ScheduledTasks -ErrorAction Stop

# Stop old user components only after all preflight/signing work succeeded.
Get-Process ZorinTrustTray -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
foreach ($taskName in 'ZorinTrustHostAgent', 'ZorinTrustTray') {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    }
}
try {
    Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 47472 -State Listen -ErrorAction Stop |
        Select-Object -ExpandProperty OwningProcess -Unique |
        ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
} catch {}

$Agent = Join-Path $Bin 'zorin-host-agent.exe'
$TrayExe = Join-Path $Ui 'ZorinTrustTray.exe'
Copy-Item -LiteralPath $HostSource -Destination $Agent -Force
Copy-Item -LiteralPath $CenterSource -Destination (Join-Path $Ui 'trust-center.ps1') -Force
Copy-Item -LiteralPath $TraySource -Destination $TrayExe -Force
Copy-Item -LiteralPath $IconSource -Destination (Join-Path $Ui 'zorin-trust.ico') -Force
Copy-Item -LiteralPath $PairSource -Destination (Join-Path $Ui 'Pair-Phone.ps1') -Force

# The installed tray/UI pairing launcher has a different directory layout than the release bundle.
$InstalledPairBat = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Pair-Phone.ps1"
pause
'@
Set-Content -LiteralPath (Join-Path $Ui 'pair-phone.bat') -Value $InstalledPairBat -Encoding ASCII

$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

$AgentArgs = 'daemon --adb "{0}"' -f $AdbPath
$AgentAction = New-ScheduledTaskAction -Execute $Agent -Argument $AgentArgs
$AgentTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user
Register-ScheduledTask -TaskName 'ZorinTrustHostAgent' -Action $AgentAction -Trigger $AgentTrigger -Principal $principal -Settings $settings -Force | Out-Null
$proc = Start-Process -WindowStyle Hidden -FilePath $Agent -ArgumentList $AgentArgs -PassThru

# Native tray is its own long-lived process and survives Trust Center window closes.
$TrayAction = New-ScheduledTaskAction -Execute $TrayExe
$TrayTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user
Register-ScheduledTask -TaskName 'ZorinTrustTray' -Action $TrayAction -Trigger $TrayTrigger -Principal $principal -Settings $settings -Force | Out-Null
Start-Process $TrayExe

Write-Host "Zorin Trust 0.5.1 installed. Agent PID $($proc.Id)." -ForegroundColor Green
Write-Host 'Normal use: click the Zorin Trust tray icon. Developer tools are under tools\developer.'
