$ErrorActionPreference='Stop'
$UiDir=$PSScriptRoot
$Local=Split-Path -Parent $UiDir
$Agent=Join-Path $Local 'bin\zorin-host-agent.exe'
if(-not(Test-Path -LiteralPath $Agent)) {
    throw "Installed Zorin Host Agent not found: $Agent"
}
$adb=Get-Command adb.exe -ErrorAction SilentlyContinue
if(-not$adb) {
    $adb=Get-Command adb -ErrorAction SilentlyContinue
}
if(-not$adb) {
    throw 'adb not found. Install Android Platform Tools and add adb to PATH.'
}
$AdbPath=if($adb.Source) {
    $adb.Source
}
else {
    $adb.Path
}
$devices=@()
& $AdbPath devices | Select-Object -Skip 1 | ForEach-Object {
    $f=($_ -split '\s+')|Where-Object {
        $_
    }
    if($f.Count-ge2 -and $f[1]-eq'device') {
        $devices+=$f[0]
    }
}
if($devices.Count-ne1) {
    throw "Pairing expects exactly one authorized adb device; found $($devices.Count)."
}
$serial=$devices[0]
$TaskName='ZorinTrustHostAgent';
$HadTask=$false
try {
    Import-Module ScheduledTasks -ErrorAction Stop
    $Task=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if($Task) {
        $HadTask=$true;
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
}
catch {
}
$pids=@()
try {
    $pids=@(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort 47472 -State Listen -ErrorAction Stop|Select-Object -ExpandProperty OwningProcess -Unique)
}
catch {
}
if($pids.Count) {
    Write-Host "Temporarily stopping $($pids.Count) running agent process(es)..." -ForegroundColor Yellow
    $pids|ForEach-Object {
        Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 350
}
$StateDir=Join-Path $env:APPDATA 'ZorinTrust'
Remove-Item(Join-Path $StateDir 'session.json') -Force -ErrorAction SilentlyContinue
Remove-Item(Join-Path $StateDir 'owner-mode.json') -Force -ErrorAction SilentlyContinue
Write-Host "Starting one-time owner pairing window for $serial" -ForegroundColor Cyan
Write-Host 'The Android app will open. Compare PAIR VERIFICATION and approve this workstation.'
Write-Host 'Press Ctrl+C after TRUSTED session UP is confirmed.' -ForegroundColor DarkGray
try {
    & $Agent daemon --pair-once --serial $serial --adb $AdbPath
}
finally {
    Remove-Item(Join-Path $StateDir 'session.json') -Force -ErrorAction SilentlyContinue
    Remove-Item(Join-Path $StateDir 'owner-mode.json') -Force -ErrorAction SilentlyContinue
    if($HadTask) {
        try {
            Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop;
            Write-Host 'Restored Zorin Host Agent autostart.' -ForegroundColor Green
        }
        catch {
            Write-Warning $_.Exception.Message
        }
    }
}
