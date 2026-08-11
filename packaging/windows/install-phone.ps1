$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Unsigned = Join-Path $Root 'app\runtime\Zorin-Trust-Runtime-v8.2.0-unsigned.apk'
$Signing = Join-Path $Root 'host\runtime-signing.ps1'

if(-not(Test-Path -LiteralPath $Signing)) {
    throw "Missing signing helper: $Signing"
}

. $Signing

$Artifacts = Join-Path $env:LOCALAPPDATA 'ZorinTrust\artifacts'
New-Item -ItemType Directory -Force -Path $Artifacts | Out-Null

$Signed = Join-Path $Artifacts 'Zorin-Trust-Runtime-v8.2.0-owner-signed.apk'
$AdbCommand = Get-Command adb.exe -ErrorAction SilentlyContinue
if(-not $AdbCommand) {
    $AdbCommand = Get-Command adb -ErrorAction SilentlyContinue
}
if(-not $AdbCommand) {
    throw 'adb not found.'
}

$AdbPath = if($AdbCommand.Source) {
    $AdbCommand.Source
}
else {
    $AdbCommand.Path
}

$Devices = @()
& $AdbPath devices |
    Select-Object -Skip 1 |
    ForEach-Object {
        $Fields = @(
            ($_ -split '\s+') |
                Where-Object {
                    $_
                }
        )

        if($Fields.Count -ge 2 -and $Fields[1] -eq 'device') {
            $Devices += $Fields[0]
        }
    }

if($Devices.Count -ne 1) {
    throw "Exactly one authorized adb device is required; found $($Devices.Count)."
}

$Serial = $Devices[0]

# APK всегда переподписываем постоянным owner signer с этой рабочей станции.
Sign-ZorinRuntime $Unsigned $Signed | Out-Null

& $AdbPath -s $Serial install -r $Signed | Out-Host
if($LASTEXITCODE -ne 0) {
    throw 'Android Runtime update failed.'
}

try {
    & $AdbPath -s $Serial shell appops set `
        dev.zorin.trustruntime `
        SYSTEM_ALERT_WINDOW `
        allow | Out-Null
}
catch {
    # Overlay не является критичным для самой trust-сессии.
}

try {
    & $AdbPath -s $Serial shell am start-foreground-service `
        -n dev.zorin.trustruntime/dev.zorin.trustruntime.TrustService `
        --ez dev.zorin.trust.ensure true | Out-Null
}
catch {
    # Если OEM отложил FGS, Host Agent повторит bootstrap через обычный recovery path.
}

Write-Host 'Phone Runtime 8.2.0 installed with the persistent owner signer.' -ForegroundColor Green
