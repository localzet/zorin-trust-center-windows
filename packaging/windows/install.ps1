$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { throw 'Installer internal error: PSScriptRoot is empty.' }
$Here = Split-Path -Parent (Split-Path -Parent $ScriptDir)
if ([string]::IsNullOrWhiteSpace($Here)) { throw 'Installer internal error: bundle root could not be resolved.' }

$State = Join-Path $env:APPDATA 'ZorinTrust'
$Local = Join-Path $env:LOCALAPPDATA 'ZorinTrust'
$Bin = Join-Path $Local 'bin'
$Ui = Join-Path $Local 'ui'
$Artifacts = Join-Path $Local 'artifacts'
$Logs = Join-Path $Local 'logs'
New-Item -ItemType Directory -Force -Path $State,$Bin,$Ui,$Artifacts,$Logs | Out-Null

$adb = Get-Command adb.exe -ErrorAction SilentlyContinue
if (-not $adb) { $adb = Get-Command adb -ErrorAction SilentlyContinue }
if (-not $adb) { throw 'adb not found. Install Android Platform Tools and add adb to PATH.' }
$AdbPath = if ($adb.Source) { $adb.Source } else { $adb.Path }
if ([string]::IsNullOrWhiteSpace($AdbPath)) { throw 'adb executable path could not be resolved.' }

$arch = $env:PROCESSOR_ARCHITECTURE
$A = if ($arch -eq 'ARM64') { 'arm64' } else { 'amd64' }
$HostSource = Join-Path $Here "host\zorin-host-agent-windows-$A.exe"
$OpsSource = Join-Path $Here "services\zorin-ops-windows-$A.exe"
$AuthoritySource = Join-Path $Here "services\zorin-authority-windows-$A.exe"
$TraySource = Join-Path $Here "app\ZorinTrustTray-windows-$A.exe"
$BootstrapSource = Join-Path $Here "app\ZorinTrustBootstrap-windows-$A.exe"
$IconSource = Join-Path $Here 'app\zorin-trust.ico'
$PairSource = Join-Path $Here 'app\installer\pair-phone.ps1'
$SigningScript = Join-Path $Here 'host\runtime-signing.ps1'
$Unsigned = Join-Path $Here 'app\runtime\Zorin-Trust-Runtime-v8.1.0-unsigned.apk'
$Signed = Join-Path $Artifacts 'Zorin-Trust-Runtime-v8.1.0-owner-signed.apk'
$Required = @($HostSource,$OpsSource,$AuthoritySource,$TraySource,$BootstrapSource,$IconSource,$PairSource,$SigningScript,$Unsigned)
foreach($p in $Required){if(-not(Test-Path -LiteralPath $p)){throw "Release bundle is incomplete. Missing: $p"}}

# Preserve the existing owner-managed signer. Ordinary v0.7 upgrades never migrate/unpair.
. $SigningScript
Sign-ZorinRuntime $Unsigned $Signed | Out-Null
if(-not(Test-Path -LiteralPath $Signed)){throw 'Runtime signing reported success but no signed APK was produced.'}

$devices=@()
& $AdbPath devices | Select-Object -Skip 1 | ForEach-Object { $f=($_ -split '\s+')|Where-Object{$_}; if($f.Count-ge2 -and $f[1]-eq'device'){$devices+=$f[0]} }
if($devices.Count -eq 1){
  & $AdbPath -s $devices[0] install -r $Signed | Out-Host
  if($LASTEXITCODE-ne0){throw 'Android Runtime update failed.'}
  try{& $AdbPath -s $devices[0] shell appops set dev.zorin.trustruntime SYSTEM_ALERT_WINDOW allow | Out-Null}catch{}
  try{& $AdbPath -s $devices[0] shell am start-foreground-service -n dev.zorin.trustruntime/dev.zorin.trustruntime.TrustService --ez dev.zorin.trust.ensure true | Out-Null}catch{}
  Write-Host 'Android Runtime 8.1.0 updated with your existing local signer.' -ForegroundColor Green
}else{Write-Warning "Phone Runtime not updated now (authorized adb devices: $($devices.Count)). Run Install.bat again with exactly one phone connected."}

Import-Module ScheduledTasks -ErrorAction Stop

# Remove every historical Zorin Trust task. Some older bundles created tasks
# via schtasks/PowerShell in ways that ScheduledTasks cmdlets did not reliably
# unregister during an in-place upgrade, so use both APIs and verify cleanup.
$oldTasks=@(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'ZorinTrust*' })
foreach($t in $oldTasks){
  $fullName = if($t.TaskPath -and $t.TaskPath -ne '\'){ "$($t.TaskPath)$($t.TaskName)" } else { "\$($t.TaskName)" }
  try { Stop-ScheduledTask -InputObject $t -ErrorAction SilentlyContinue } catch {}
  try { $t | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue } catch {}
  try { & schtasks.exe /End /TN $fullName 2>$null | Out-Null } catch {}
  try { & schtasks.exe /Delete /TN $fullName /F 2>$null | Out-Null } catch {}
}
# Explicit legacy names cover historical releases even if enumeration was stale.
foreach($legacyName in @('ZorinTrustCenterTray','ZorinTrustTray','ZorinTrustHostAgent','ZorinTrustOps','ZorinTrustAuthority')){
  try { & schtasks.exe /End /TN "\$legacyName" 2>$null | Out-Null } catch {}
  try { & schtasks.exe /Delete /TN "\$legacyName" /F 2>$null | Out-Null } catch {}
}

foreach($name in 'ZorinTrustBootstrap','ZorinTrustTray','zorin-ops','zorin-authority','zorin-host-agent'){
  Get-Process $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
foreach($port in 47472,47474,47475){
  try {
    Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $port -State Listen -ErrorAction Stop |
      Select-Object -ExpandProperty OwningProcess -Unique |
      ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
  } catch {}
}

$Agent=Join-Path $Bin 'zorin-host-agent.exe'
$Ops=Join-Path $Bin 'zorin-ops.exe'
$Authority=Join-Path $Bin 'zorin-authority.exe'
$Tray=Join-Path $Ui 'ZorinTrustTray.exe'
$Bootstrap=Join-Path $Ui 'ZorinTrustBootstrap.exe'
Copy-Item $HostSource $Agent -Force
Copy-Item $OpsSource $Ops -Force
Copy-Item $AuthoritySource $Authority -Force
Copy-Item $TraySource $Tray -Force
Copy-Item $BootstrapSource $Bootstrap -Force
Copy-Item $IconSource (Join-Path $Ui 'zorin-trust.ico') -Force
Copy-Item $PairSource (Join-Path $Ui 'Pair-Phone.ps1') -Force
$PairBat="@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Pair-Phone.ps1`"`r`npause`r`n"
[IO.File]::WriteAllText((Join-Path $Ui 'pair-phone.bat'),$PairBat,[Text.Encoding]::ASCII)

$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
$BootstrapArgs='--adb "{0}"' -f $AdbPath
$action=New-ScheduledTaskAction -Execute $Bootstrap -Argument $BootstrapArgs
Register-ScheduledTask -TaskName 'ZorinTrustBootstrap' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'ZorinTrustBootstrap'

function Test-LocalTcp([int]$Port){
  $client=New-Object System.Net.Sockets.TcpClient
  try {
    $iar=$client.BeginConnect('127.0.0.1',$Port,$null,$null)
    if(-not $iar.AsyncWaitHandle.WaitOne(350)){ return $false }
    $client.EndConnect($iar)
    return $client.Connected
  } catch { return $false }
  finally { try{$client.Close()}catch{} }
}
function Test-LocalHttp([string]$Url){
  try {
    $r=Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 2
    return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500)
  } catch { return $false }
}

# First launch can be delayed by Defender/SmartScreen scanning several new EXEs.
# Use one shared deadline for the complete stack rather than three sequential
# per-port waits, which could report early services as failed even though they
# became ready moments later.
$deadline=(Get-Date).AddSeconds(60)
$ready=$false
$lastMissing=@()
do {
  $missing=@()
  if(-not(Test-LocalTcp 47472)){ $missing += '47472/host-agent' }
  if(-not(Test-LocalTcp 47474)){ $missing += '47474/ops' }
  elseif(-not(Test-LocalHttp 'http://127.0.0.1:47474/api/state')){ $missing += '47474/ops-http' }
  if(-not(Test-LocalTcp 47475)){ $missing += '47475/authority' }
  elseif(-not(Test-LocalHttp 'http://127.0.0.1:47475/v1/public-key')){ $missing += '47475/authority-http' }
  $lastMissing=$missing
  if($missing.Count -eq 0){ $ready=$true; break }
  Start-Sleep -Milliseconds 350
} while((Get-Date) -lt $deadline)

if(-not $ready){
  throw "Background bootstrap did not become healthy within 60s: $($lastMissing -join ', '). Run 6-STARTUP-DOCTOR.bat and inspect $Logs."
}
# Catch a process that bound a port and immediately died.
Start-Sleep -Milliseconds 750
if(-not(Test-LocalTcp 47472) -or -not(Test-LocalHttp 'http://127.0.0.1:47474/api/state') -or -not(Test-LocalHttp 'http://127.0.0.1:47475/v1/public-key')){
  throw "Background stack became ready but did not remain healthy. Run 6-STARTUP-DOCTOR.bat and inspect $Logs."
}

# Verify that upgrade cleanup actually removed old tasks. Do not fail a working
# install solely because Windows retained an inert legacy task; report it loudly.
$leftovers=@(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'ZorinTrust*' -and $_.TaskName -ne 'ZorinTrustBootstrap' })
if($leftovers.Count -gt 0){
  Write-Warning "Legacy Zorin Trust task(s) still present: $($leftovers.TaskName -join ', '). They are not used by 0.7.2; run 6-STARTUP-DOCTOR.bat for details."
}

Write-Host "Zorin Trust 0.7.2 installed. Silent bootstrap is running." -ForegroundColor Green
Write-Host 'Background services now run through the console-free native bootstrap. The tray opens Ops only after its local HTTP endpoint is healthy.'
Write-Host 'Raw diagnostics are under tools\developer; they are not part of the normal UI.'
