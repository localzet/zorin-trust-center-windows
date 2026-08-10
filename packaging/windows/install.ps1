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
New-Item -ItemType Directory -Force -Path $State,$Bin,$Ui,$Artifacts | Out-Null

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
$IconSource = Join-Path $Here 'app\zorin-trust.ico'
$PairSource = Join-Path $Here 'app\installer\pair-phone.ps1'
$SigningScript = Join-Path $Here 'host\runtime-signing.ps1'
$Unsigned = Join-Path $Here 'app\runtime\Zorin-Trust-Runtime-v8.0.0-unsigned.apk'
$Signed = Join-Path $Artifacts 'Zorin-Trust-Runtime-v8.0.0-owner-signed.apk'
$Required = @($HostSource,$OpsSource,$AuthoritySource,$TraySource,$IconSource,$PairSource,$SigningScript,$Unsigned)
foreach($p in $Required){if(-not(Test-Path -LiteralPath $p)){throw "Release bundle is incomplete. Missing: $p"}}

# Preserve the existing owner-managed signer. Ordinary v0.6 upgrades never migrate/unpair.
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
  Write-Host 'Android Runtime 8.0.0 updated with your existing local signer.' -ForegroundColor Green
}else{Write-Warning "Phone Runtime not updated now (authorized adb devices: $($devices.Count)). Run Install.bat again with exactly one phone connected."}

Import-Module ScheduledTasks -ErrorAction Stop
$taskNames=@('ZorinTrustHostAgent','ZorinTrustOps','ZorinTrustAuthority','ZorinTrustTray')
foreach($t in $taskNames){try{Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue}catch{}}
foreach($name in 'ZorinTrustTray','zorin-ops','zorin-authority','zorin-host-agent'){Get-Process $name -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue}
foreach($port in 47472,47474,47475){try{Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $port -State Listen -ErrorAction Stop|Select-Object -ExpandProperty OwningProcess -Unique|ForEach-Object{Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue}}catch{}}

$Agent=Join-Path $Bin 'zorin-host-agent.exe';$Ops=Join-Path $Bin 'zorin-ops.exe';$Authority=Join-Path $Bin 'zorin-authority.exe';$Tray=Join-Path $Ui 'ZorinTrustTray.exe'
Copy-Item $HostSource $Agent -Force;Copy-Item $OpsSource $Ops -Force;Copy-Item $AuthoritySource $Authority -Force;Copy-Item $TraySource $Tray -Force;Copy-Item $IconSource (Join-Path $Ui 'zorin-trust.ico') -Force;Copy-Item $PairSource (Join-Path $Ui 'Pair-Phone.ps1') -Force
$PairBat="@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Pair-Phone.ps1`"`r`npause`r`n";[IO.File]::WriteAllText((Join-Path $Ui 'pair-phone.bat'),$PairBat,[Text.Encoding]::ASCII)

$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
function Install-UserTask([string]$Name,[string]$Exe,[string]$Args=''){
  $action=if([string]::IsNullOrWhiteSpace($Args)){New-ScheduledTaskAction -Execute $Exe}else{New-ScheduledTaskAction -Execute $Exe -Argument $Args}
  Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force|Out-Null
}
$AgentArgs='daemon --adb "{0}"' -f $AdbPath
Install-UserTask 'ZorinTrustHostAgent' $Agent $AgentArgs
Install-UserTask 'ZorinTrustOps' $Ops
Install-UserTask 'ZorinTrustAuthority' $Authority 'serve'
Install-UserTask 'ZorinTrustTray' $Tray
$pAgent=Start-Process -WindowStyle Hidden -FilePath $Agent -ArgumentList $AgentArgs -PassThru
Start-Process -WindowStyle Hidden -FilePath $Ops
Start-Process -WindowStyle Hidden -FilePath $Authority -ArgumentList 'serve'
Start-Process $Tray

Write-Host "Zorin Trust 0.6 installed. Host Agent PID $($pAgent.Id)." -ForegroundColor Green
Write-Host 'The tray opens Zorin Ops. When the trusted phone reconnects, Ops can open automatically.'
Write-Host 'Raw diagnostics are under tools\developer; they are not part of the normal UI.'
