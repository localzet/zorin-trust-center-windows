$ErrorActionPreference='Stop'
$src=$PSScriptRoot
$dst=Join-Path $env:LOCALAPPDATA 'ZorinTrust\ui'
New-Item -ItemType Directory -Force -Path $dst|Out-Null
Copy-Item(Join-Path $src 'trust-center.ps1') $dst -Force
$arch=$env:PROCESSOR_ARCHITECTURE;
$tray=if($arch -eq 'ARM64') {
    'ZorinTrustTray-windows-arm64.exe'
}
else {
    'ZorinTrustTray-windows-amd64.exe'
}
Copy-Item(Join-Path $src('..\build\'+$tray))(Join-Path $dst 'ZorinTrustTray.exe') -Force
Copy-Item(Join-Path $src '..\assets\zorin-trust.ico') $dst -Force
if(Test-Path(Join-Path $src 'pair-phone.bat')) {
    Copy-Item(Join-Path $src 'pair-phone.bat') $dst -Force
}
$exe=Join-Path $dst 'ZorinTrustTray.exe'
$task='ZorinTrustTray'
& schtasks.exe /Delete /TN $task /F 2>$null|Out-Null
& schtasks.exe /Create /TN $task /SC ONLOGON /TR('"'+$exe+'"') /RL LIMITED /F|Out-Null
Start-Process $exe
Write-Host "Zorin Trust tray installed: $exe"
