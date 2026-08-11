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

## 0.9.3 maintenance

- Fixes Windows PowerShell 5.1 multiline pipeline syntax in the startup doctor.
- Adds a portable source check for formatter regressions that can be executed in non-Windows build environments.
- The installer still performs the authoritative `System.Management.Automation.Language.Parser` pass over the complete release bundle before changing the system.
