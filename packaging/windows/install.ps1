$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
if([string]::IsNullOrWhiteSpace($ScriptDir)) {
    throw 'Installer internal error: PSScriptRoot is empty.'
}
$Here = Split-Path -Parent(Split-Path -Parent $ScriptDir)
if([string]::IsNullOrWhiteSpace($Here)) {
    throw 'Installer internal error: bundle root could not be resolved.'
}

function Assert-ZorinPowerShellSyntax {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $syntaxErrors = New-Object System.Collections.Generic.List[string]
    $scripts = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.ps1')

    foreach($script in $scripts) {
        $tokens = $null
        $parseErrors = $null

        [System.Management.Automation.Language.Parser]::ParseFile(
            $script.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null

        foreach($parseError in @($parseErrors)) {
            $line = $parseError.Extent.StartLineNumber
            $syntaxErrors.Add("$($script.FullName):$($line): $($parseError.Message)")
        }
    }

    if($syntaxErrors.Count -gt 0) {
        throw "Release bundle contains invalid PowerShell source:`n$($syntaxErrors -join "`n")"
    }
}

# До dot-source и любых изменений системы прогоняем штатный PowerShell parser
# по всему bundle. Так форматирование не сможет незаметно сломать синтаксис релиза.
Assert-ZorinPowerShellSyntax -Root $Here
$State = Join-Path $env:APPDATA 'ZorinTrust'
$Local = Join-Path $env:LOCALAPPDATA 'ZorinTrust'
$Bin = Join-Path $Local 'bin'
$Ui = Join-Path $Local 'ui'
$Artifacts = Join-Path $Local 'artifacts'
$Logs = Join-Path $Local 'logs'
$NodeDir = Join-Path $Local 'node'
New-Item -ItemType Directory -Force -Path @(
$State,
$Bin,
$Ui,
$Artifacts,
$Logs,
$NodeDir
) | Out-Null
$adb = Get-Command adb.exe -ErrorAction SilentlyContinue
if(-not $adb) {
    $adb = Get-Command adb -ErrorAction SilentlyContinue
}
if(-not $adb) {
    throw 'adb not found. Install Android Platform Tools and add adb to PATH.'
}
$AdbPath = if($adb.Source) {
    $adb.Source
}
else {
    $adb.Path
}
if([string]::IsNullOrWhiteSpace($AdbPath)) {
    throw 'adb executable path could not be resolved.'
}
foreach($tool in @('ssh', 'ssh-keygen', 'scp')) {
    if(-not(Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "OpenSSH $tool was not found in PATH. Install the Windows OpenSSH Client optional feature before using Zorin Trust 0.9."
    }
}
$Architecture = if($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
    'arm64'
}
else {
    'amd64'
}
$HostSource = Join-Path $Here "host\zorin-host-agent-windows-$Architecture.exe"
$OpsSource = Join-Path $Here "services\zorin-ops-windows-$Architecture.exe"
$AuthoritySource = Join-Path $Here "services\zorin-authority-windows-$Architecture.exe"
$TraySource = Join-Path $Here "app\ZorinTrustTray-windows-$Architecture.exe"
$CenterSource = Join-Path $Here "app\ZorinTrustCenter-windows-$Architecture.exe"
$BootstrapSource = Join-Path $Here "app\ZorinTrustBootstrap-windows-$Architecture.exe"
$IconSource = Join-Path $Here 'app\zorin-trust.ico'
$PairSource = Join-Path $Here 'app\installer\pair-phone.ps1'
$SigningScript = Join-Path $Here 'host\runtime-signing.ps1'
$NodeAMD64Source = Join-Path $Here 'node\zorin-node-linux-amd64'
$NodeARM64Source = Join-Path $Here 'node\zorin-node-linux-arm64'
$UnsignedRuntime = Join-Path $Here 'app\runtime\Zorin-Trust-Runtime-v8.1.0-unsigned.apk'
$SignedRuntime = Join-Path $Artifacts 'Zorin-Trust-Runtime-v8.1.0-owner-signed.apk'
$Required = @(
$HostSource,
$OpsSource,
$AuthoritySource,
$TraySource,
$CenterSource,
$BootstrapSource,
$IconSource,
$PairSource,
$SigningScript,
$UnsignedRuntime,
$NodeAMD64Source,
$NodeARM64Source
)
foreach($Path in $Required) {
    if(-not(Test-Path -LiteralPath $Path)) {
        throw "Release bundle is incomplete. Missing: $Path"
    }
}
# Обычное обновление сохраняет owner-managed signer и Android identity.
. $SigningScript
Sign-ZorinRuntime $UnsignedRuntime $SignedRuntime | Out-Null
if(-not(Test-Path -LiteralPath $SignedRuntime)) {
    throw 'Runtime signing reported success but no signed APK was produced.'
}
$Devices = @()
& $AdbPath devices | Select-Object -Skip 1 | ForEach-Object {
    $Fields =($_ -split '\s+') | Where-Object {
        $_
    }
    if($Fields.Count -ge 2 -and $Fields[1] -eq 'device') {
        $Devices += $Fields[0]
    }
}
if($Devices.Count -eq 1) {
    & $AdbPath -s $Devices[0] install -r $SignedRuntime | Out-Host
    if($LASTEXITCODE -ne 0) {
        throw 'Android Runtime update failed.'
    }
    try {
        & $AdbPath -s $Devices[0] shell appops set dev.zorin.trustruntime SYSTEM_ALERT_WINDOW allow | Out-Null
    }
    catch {
    }
    try {
        & $AdbPath -s $Devices[0] shell am start-foreground-service `
        -n dev.zorin.trustruntime/dev.zorin.trustruntime.TrustService `
        --ez dev.zorin.trust.ensure true | Out-Null
    }
    catch {
    }
    Write-Host 'Android Runtime 8.1.0 updated with your existing local signer.' -ForegroundColor Green
}
else {
    Write-Warning "Phone Runtime not updated now (authorized adb devices: $($Devices.Count)). Run 0-INSTALL-OR-UPDATE.bat again with exactly one phone connected."
}
Import-Module ScheduledTasks -ErrorAction Stop
# Удаляем все задачи старых релизов. Часть ранних версий создавалась через
# schtasks.exe, поэтому чистим одновременно через ScheduledTasks и schtasks.
$OldTasks = @(
Get-ScheduledTask -ErrorAction SilentlyContinue |
Where-Object {
    $_.TaskName -like 'ZorinTrust*'
}
)
foreach($Task in $OldTasks) {
    $FullName = if($Task.TaskPath -and $Task.TaskPath -ne '\') {
        "$($Task.TaskPath)$($Task.TaskName)"
    }
    else {
        "\$($Task.TaskName)"
    }
    try {
        Stop-ScheduledTask -InputObject $Task -ErrorAction SilentlyContinue
    }
    catch {
    }
    try {
        $Task | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    }
    catch {
    }
    try {
        & schtasks.exe /End /TN $FullName 2>$null | Out-Null
    }
    catch {
    }
    try {
        & schtasks.exe /Delete /TN $FullName /F 2>$null | Out-Null
    }
    catch {
    }
}
foreach($LegacyName in @(
'ZorinTrustCenterTray',
'ZorinTrustTray',
'ZorinTrustHostAgent',
'ZorinTrustOps',
'ZorinTrustAuthority'
)) {
    try {
        & schtasks.exe /End /TN "\$LegacyName" 2>$null | Out-Null
    }
    catch {
    }
    try {
        & schtasks.exe /Delete /TN "\$LegacyName" /F 2>$null | Out-Null
    }
    catch {
    }
}
foreach($ProcessName in @(
'ZorinTrustBootstrap',
'ZorinTrustTray',
'ZorinTrustCenter',
'zorin-ops',
'zorin-authority',
'zorin-host-agent'
)) {
    Get-Process $ProcessName -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
}
foreach($Port in @(47472, 47474, 47475)) {
    try {
        Get-NetTCPConnection `
        -LocalAddress 127.0.0.1 `
        -LocalPort $Port `
        -State Listen `
        -ErrorAction Stop |
        Select-Object -ExpandProperty OwningProcess -Unique |
        ForEach-Object {
            Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
    }
}
$Agent = Join-Path $Bin 'zorin-host-agent.exe'
$Ops = Join-Path $Bin 'zorin-ops.exe'
$Authority = Join-Path $Bin 'zorin-authority.exe'
$Tray = Join-Path $Ui 'ZorinTrustTray.exe'
$Center = Join-Path $Ui 'ZorinTrustCenter.exe'
$Bootstrap = Join-Path $Ui 'ZorinTrustBootstrap.exe'
Copy-Item $HostSource $Agent -Force
Copy-Item $OpsSource $Ops -Force
Copy-Item $AuthoritySource $Authority -Force
Copy-Item $NodeAMD64Source(Join-Path $NodeDir 'zorin-node-linux-amd64') -Force
Copy-Item $NodeARM64Source(Join-Path $NodeDir 'zorin-node-linux-arm64') -Force
Copy-Item $TraySource $Tray -Force
Copy-Item $CenterSource $Center -Force
Copy-Item $BootstrapSource $Bootstrap -Force
Copy-Item $IconSource(Join-Path $Ui 'zorin-trust.ico') -Force
Copy-Item $PairSource(Join-Path $Ui 'Pair-Phone.ps1') -Force
$PairBat =
@"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Pair-Phone.ps1"
pause
"@
[IO.File]::WriteAllText(
(Join-Path $Ui 'pair-phone.bat'),
$PairBat,
[Text.Encoding]::ASCII
)
$User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Settings = New-ScheduledTaskSettingsSet `
-StartWhenAvailable `
-ExecutionTimeLimit([TimeSpan]::Zero) `
-Hidden `
-AllowStartIfOnBatteries `
-DontStopIfGoingOnBatteries `
-MultipleInstances IgnoreNew `
-RestartCount 3 `
-RestartInterval(New-TimeSpan -Minutes 1)
$Principal = New-ScheduledTaskPrincipal `
-UserId $User `
-LogonType Interactive `
-RunLevel Limited
$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
$BootstrapArgs = '--adb "{0}"' -f $AdbPath
$Action = New-ScheduledTaskAction -Execute $Bootstrap -Argument $BootstrapArgs
Register-ScheduledTask `
-TaskName 'ZorinTrustBootstrap' `
-Action $Action `
-Trigger $Trigger `
-Principal $Principal `
-Settings $Settings `
-Force | Out-Null
Start-ScheduledTask -TaskName 'ZorinTrustBootstrap'
function Test-LocalTcp {
    param([int]$Port)
    $Client = New-Object System.Net.Sockets.TcpClient
    try {
        $Async = $Client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if(-not $Async.AsyncWaitHandle.WaitOne(350)) {
            return $false
        }
        $Client.EndConnect($Async)
        return $Client.Connected
    }
    catch {
        return $false
    }
    finally {
        try {
            $Client.Close()
        }
        catch {
        }
    }
}
function Test-LocalHttp {
    param([string]$Url)
    try {
        $Response = Invoke-WebRequest `
        -UseBasicParsing `
        -Uri $Url `
        -TimeoutSec 2
        return $Response.StatusCode -ge 200 -and $Response.StatusCode -lt 500
    }
    catch {
        return $false
    }
}
# Первый запуск часто задерживается Defender/SmartScreen. Используем один общий
# deadline для всего стека, а не три независимых коротких ожидания.
$Deadline =(Get-Date).AddSeconds(60)
$Ready = $false
$LastMissing = @()
do {
    $Missing = @()
    if(-not(Test-LocalTcp 47472)) {
        $Missing += '47472/host-agent'
    }
    if(-not(Test-LocalTcp 47474)) {
        $Missing += '47474/ops'
    }
    elseif(-not(Test-LocalHttp 'http://127.0.0.1:47474/api/state')) {
        $Missing += '47474/ops-http'
    }
    if(-not(Test-LocalTcp 47475)) {
        $Missing += '47475/authority'
    }
    elseif(-not(Test-LocalHttp 'http://127.0.0.1:47475/v1/public-key')) {
        $Missing += '47475/authority-http'
    }
    $LastMissing = $Missing
    if($Missing.Count -eq 0) {
        $Ready = $true
        break
    }
    Start-Sleep -Milliseconds 350
}
while((Get-Date) -lt $Deadline)
if(-not $Ready) {
    throw "Background bootstrap did not become healthy within 60s: $($LastMissing -join ', '). Run 6-STARTUP-DOCTOR.bat and inspect $Logs."
}
# Проверяем, что процесс не успел bind'нуть порт и тут же умереть.
Start-Sleep -Milliseconds 750
if(
-not(Test-LocalTcp 47472) -or
-not(Test-LocalHttp 'http://127.0.0.1:47474/api/state') -or
-not(Test-LocalHttp 'http://127.0.0.1:47475/v1/public-key')
) {
    throw "Background stack became ready but did not remain healthy. Run 6-STARTUP-DOCTOR.bat and inspect $Logs."
}
$Leftovers = @(
Get-ScheduledTask -ErrorAction SilentlyContinue |
Where-Object {
    $_.TaskName -like 'ZorinTrust*' -and
    $_.TaskName -ne 'ZorinTrustBootstrap'
}
)
if($Leftovers.Count -gt 0) {
    Write-Warning "Legacy Zorin Trust task(s) still present: $($Leftovers.TaskName -join ', '). They are not used by 0.9.3; run 6-STARTUP-DOCTOR.bat for details."
}
Write-Host 'Zorin Trust 0.9.3 installed. Silent bootstrap is running.' -ForegroundColor Green
Write-Host 'Left-click the tray icon to open the native Trust Center; Zorin Ops remains the infrastructure control plane.'
Write-Host 'Lock-on-trust-loss is opt-in and disabled until you enable it in Trust Center.'
