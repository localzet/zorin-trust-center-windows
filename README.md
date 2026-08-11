# Zorin Trust Center for Windows — v0.8.0

Native Windows WPF dashboard for Zorin Trust. It visualizes four independent state axes: Device Trust, Owner Presence, Authority and Transport. It also shows the workstation/phone graph, identity provider, pair verification phrase, and a persistent event timeline produced by `zorin-host-agent` 0.4.

No third-party GUI runtime is required: Windows PowerShell 5.1 + WPF/WinForms are enough.

## Run

`14-OPEN-TRUST-CENTER.bat`

## Tray mode

`15-INSTALL-TRUST-CENTER-TRAY.bat` copies the UI into `%LOCALAPPDATA%\ZorinTrust\ui` and creates a logon task. The UI may be closed to tray; the host-agent service remains independent.

## v0.5.1 installer/tray hardening

The Windows release installer uses `$PSScriptRoot` for deterministic bundle-root resolution, preflights/signs the Android Runtime before stopping existing components, and installs a pairing launcher with paths appropriate to the installed UI directory. The native tray is single-instance and handles the Windows `TaskbarCreated` broadcast so it restores its notification-area icon after Explorer restarts.


## v0.7 infrastructure release

The desktop bundle now ships Zorin Ops 0.2 with editable/removable VPS entries, effective OpenSSH diagnostics and read-only Docker logs. Runtime upgrades continue to use the owner-managed local APK signer; there is no signer migration step.


## v0.7.1 silent-start hotfix

Windows logon now runs one native GUI-subsystem `ZorinTrustBootstrap.exe` task instead of scheduling console services directly. The bootstrap starts Host Agent, Ops and Authority with `CREATE_NO_WINDOW`, writes local component logs, monitors/restarts background services, and starts the tray without a console. The task is allowed to start on battery power and is not stopped when the laptop switches to battery.

The tray health-checks Ops before opening the browser and can self-start Ops if the service is temporarily missing. The release includes a startup doctor that reports tasks, processes, listeners, HTTP probes and local logs.


## v0.7.2 startup-readiness hotfix

Installer readiness now uses one shared 60-second deadline and direct TCP/HTTP probes rather than three sequential short `Get-NetTCPConnection` checks. Legacy `ZorinTrust*` scheduled tasks are removed through both the ScheduledTasks API and `schtasks.exe`. The native tray waits for Explorer's notification area to become available and is supervised/restarted by the bootstrap if it exits.


## v0.8 short-lived SSH infrastructure

The Windows bundle ships Host Agent 0.8, Ops 0.3, Authority 0.3 and Linux Node 0.3 bootstrap binaries for amd64/arm64. Ops can install/update Node through an explicitly approved bootstrap SSH session, enroll the Authority OpenSSH User CA, and then use one-to-five-minute phone-approved user certificates with ephemeral local client keys. Windows OpenSSH `ssh`, `ssh-keygen` and `scp` are preflighted by the installer.
