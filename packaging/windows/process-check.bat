@echo off
setlocal

echo Zorin Trust Runtime process check
echo.

for /f "tokens=1" %%D in ('adb devices ^| findstr /R /C:"device$"') do (
    set "SERIAL=%%D"
)

if not defined SERIAL (
    echo No authorized adb device.
    pause
    exit /b 2
)

echo ADB target: %SERIAL%
adb -s %SERIAL% shell am start-foreground-service ^
    -n dev.zorin.trustruntime/dev.zorin.trustruntime.TrustService ^
    --ez dev.zorin.trust.ensure true

echo.
<nul set /p="main process PID : "
adb -s %SERIAL% shell pidof dev.zorin.trustruntime
<nul set /p="trust process PID: "
adb -s %SERIAL% shell pidof dev.zorin.trustruntime:trust

echo.
echo ActivityManager service excerpt:
adb -s %SERIAL% shell dumpsys activity services dev.zorin.trustruntime ^
    | findstr /I ^
        /C:"ServiceRecord" ^
        /C:"processName" ^
        /C:"isForeground" ^
        /C:"foregroundId" ^
        /C:"dev.zorin.trustruntime"

pause
