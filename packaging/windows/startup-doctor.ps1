$ErrorActionPreference='Continue'
$Local=Join-Path $env:LOCALAPPDATA 'ZorinTrust'
$Logs=Join-Path $Local 'logs'
Write-Host 'Zorin Trust 0.9.2 startup doctor' -ForegroundColor Cyan
Write-Host "Local root: $Local"
Write-Host ''
Write-Host 'Scheduled tasks:' -ForegroundColor Yellow
$tasks=@(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskName -like 'ZorinTrust*'
}
| Sort-Object TaskName)
if($tasks.Count -eq 0) {
    Write-Host '  NONE' -ForegroundColor Red
}
foreach($t in $tasks) {
    $i=Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
    $a=$t.Actions | Select-Object -First 1
    Write-Host("  {0}  state={1}  lastResult=0x{2:X8}" -f $t.TaskName,$t.State,[uint32]$i.LastTaskResult)
    Write-Host("    execute: {0}" -f $a.Execute)
    if($a.Arguments) {
        Write-Host("    args:    {0}" -f $a.Arguments)
    }
}
$legacy=@($tasks | Where-Object {
    $_.TaskName -ne 'ZorinTrustBootstrap'
}
)
if($legacy.Count -gt 0) {
    Write-Host "  WARNING: legacy Zorin Trust task(s) still exist: $($legacy.TaskName -join ', ')" -ForegroundColor Red
}
Write-Host ''
Write-Host 'Processes:' -ForegroundColor Yellow
foreach($n in 'ZorinTrustBootstrap','ZorinTrustTray','zorin-host-agent','zorin-ops','zorin-authority') {
    $p=@(Get-Process $n -ErrorAction SilentlyContinue)
    if($p.Count) {
        foreach($x in $p) {
            Write-Host("  {0,-22} PID {1}" -f $n,$x.Id)
        }
    }
    else {
        Write-Host("  {0,-22} NOT RUNNING" -f $n) -ForegroundColor DarkYellow
    }
}
Write-Host ''
Write-Host 'Local listeners:' -ForegroundColor Yellow
foreach($port in 47472,47474,47475) {
    $x=@(Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    if($x.Count) {
        Write-Host("  127.0.0.1:{0} LISTENING pid={1}" -f $port,(($x|Select-Object -ExpandProperty OwningProcess -Unique)-join ',')) -ForegroundColor Green
    }
    else {
        Write-Host("  127.0.0.1:{0} NOT LISTENING" -f $port) -ForegroundColor Red
    }
}
Write-Host ''
Write-Host 'HTTP probes:' -ForegroundColor Yellow
foreach($u in 'http://127.0.0.1:47474/api/state','http://127.0.0.1:47475/v1/public-key') {
    try {
        $r=Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec 2;
        Write-Host "  $u -> $($r.StatusCode)" -ForegroundColor Green
    }
    catch {
        Write-Host "  $u -> FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}
Write-Host ''
foreach($name in 'bootstrap.log','host-agent.log','ops.log','authority.log','tray.log') {
    $p=Join-Path $Logs $name
    Write-Host "--- $name ---" -ForegroundColor Yellow
    if(Test-Path $p) {
        Get-Content $p -Tail 35
    }
    else {
        Write-Host '  not created yet'
    }
    Write-Host ''
}
