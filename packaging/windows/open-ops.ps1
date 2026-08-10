$ErrorActionPreference='Stop'
$Url='http://127.0.0.1:47474/'
function Ops-Ready {
  try {
    $r=Invoke-WebRequest -UseBasicParsing -Uri ($Url+'api/state') -TimeoutSec 1
    return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500)
  } catch { return $false }
}
if(-not(Ops-Ready)){
  try{Start-ScheduledTask -TaskName 'ZorinTrustBootstrap' -ErrorAction Stop}catch{}
  $deadline=(Get-Date).AddSeconds(8)
  do{Start-Sleep -Milliseconds 200}while((-not(Ops-Ready)) -and (Get-Date) -lt $deadline)
}
if(-not(Ops-Ready)){
  throw 'Zorin Ops did not become ready on 127.0.0.1:47474. Run 6-STARTUP-DOCTOR.bat.'
}
Start-Process $Url
