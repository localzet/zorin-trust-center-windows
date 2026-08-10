Get-Process ZorinTrustTray -ErrorAction SilentlyContinue|Stop-Process -Force
& schtasks.exe /Delete /TN ZorinTrustTray /F 2>$null|Out-Null
Write-Host 'Zorin Trust tray autostart removed.'
