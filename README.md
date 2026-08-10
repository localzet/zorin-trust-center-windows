# Zorin Trust Center for Windows — v0.4

Native Windows WPF dashboard for Zorin Trust. It visualizes four independent state axes: Device Trust, Owner Presence, Authority and Transport. It also shows the workstation/phone graph, identity provider, pair verification phrase, and a persistent event timeline produced by `zorin-host-agent` 0.4.

No third-party GUI runtime is required: Windows PowerShell 5.1 + WPF/WinForms are enough.

## Run

`14-OPEN-TRUST-CENTER.bat`

## Tray mode

`15-INSTALL-TRUST-CENTER-TRAY.bat` copies the UI into `%LOCALAPPDATA%\ZorinTrust\ui` and creates a logon task. The UI may be closed to tray; the host-agent service remains independent.

## v0.5.1 installer/tray hardening

The Windows release installer uses `$PSScriptRoot` for deterministic bundle-root resolution, preflights/signs the Android Runtime before stopping existing components, and installs a pairing launcher with paths appropriate to the installed UI directory. The native tray is single-instance and handles the Windows `TaskbarCreated` broadcast so it restores its notification-area icon after Explorer restarts.
