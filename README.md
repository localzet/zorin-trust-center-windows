# Zorin Trust Center — Windows 0.9

Native Windows integration for Zorin Trust.

## 0.9

- Adds `ZorinTrustCenter.exe`, a native Win32 control surface with no browser/WebView dependency.
- Shows live device trust, owner presence, host fingerprint, phone fingerprint and CNG/TPM identity provider.
- Adds a policy-bound **Fresh approval** action that requires explicit confirmation on the phone.
- Adds an opt-in **Lock Windows when the trusted phone disconnects** setting.
- The tray enforces lock-on-loss with a short debounce so a single USB/ADB hiccup does not immediately lock the workstation.
- Left-clicking the tray icon opens Trust Center; Zorin Ops remains available separately for infrastructure operations.
- Existing console-free bootstrap and startup supervision are retained.

The lock-on-loss feature is disabled by default. It uses the standard Windows workstation lock operation and never attempts to bypass the normal Windows unlock/sign-in path.

## 0.10 — Portable Owner Key foundation

- Ships Android Runtime 8.2.0 with the first transport-independent `ZTRUST/2` connection path.
- Adds a one-shot portable launcher that starts the Host Agent with a memory-only identity and no Task Scheduler/service installation.
- Keeps the normal owner workstation on the proven silent bootstrap + ADB/USB path.
- Preserves the complete Windows PowerShell parser pass before the installer changes the system.

The portable launcher intentionally uses a visible console because it shows private-LAN bootstrap URLs, the temporary host fingerprint and the pair-verification code. Closing that console ends the portable identity.
