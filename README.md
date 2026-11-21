# GraphClip

**Turn Microsoft Graph requests copied from browser DevTools into clean, ready-to-run PowerShell.**

GraphClip watches the clipboard and converts supported PowerShell requests into readable
`Invoke-RestMethod` commands. It runs from the Windows notification area, can be triggered manually
or with a hotkey, and lets you choose how the bearer token is handled.

[Download GraphClip](https://github.com/UniverseCitiz3n/Graph-Clip/releases) ·
[Report an issue](https://github.com/UniverseCitiz3n/Graph-Clip/issues) ·
[Apache-2.0 license](./LICENSE)

## Why GraphClip

- **Save time:** copy a request from DevTools and get a clean PowerShell command on your clipboard.
- **Keep control:** GraphClip parses the copied request; it does not execute it or send it to Microsoft Graph.
- **Choose token handling:** store the token as a machine or user environment variable, or keep it inline in the generated command.
- **Use it your way:** convert automatically, use the tray menu, or assign a keyboard shortcut with PowerToys Keyboard Manager.
- **Deploy across Windows devices:** install the signed-in-user tray watcher with a per-machine MSI, including through Intune.

## Get started

1. Download the latest `GraphClip-Setup-<version>.msi` from [GitHub Releases](https://github.com/UniverseCitiz3n/Graph-Clip/releases).
2. Install PowerShell 7 or later, for example with `winget install --id Microsoft.PowerShell`. The machine-wide
   MSI and the Microsoft Store (MSIX) versions are both supported.
3. Install the MSI. Installation requires administrator or SYSTEM deployment context.
4. Sign in to Windows. GraphClip starts in the notification area.
5. Copy a supported Microsoft Graph PowerShell request from browser DevTools. GraphClip converts it and places the result on the clipboard.

Use the tray menu to turn automatic conversion on or off, convert the current clipboard, restore the original
clipboard text, choose token storage, open the log, or exit.

### Optional hotkey

With PowerToys Keyboard Manager, add a **Remap a shortcut > Start App** action:

| Field | Value |
|---|---|
| Program | `C:\Program Files\GraphClip\GraphClip.exe` |
| Arguments | `--convert` |
| Visibility | Hidden |
| If running | Do nothing |

## Token storage

Choose a mode from the tray menu. The selection is saved per user in
`%LOCALAPPDATA%\GraphClip\settings.json`.

| Mode | Generated command | Storage | Admin rights |
|---|---|---|---|
| **Machine** (default) | Reads `MSGRAPH_TOKEN` from the machine environment | Machine environment variable | Required to set |
| **User** | Reads `MSGRAPH_TOKEN` from the user environment | User environment variable | Not required |
| **Inline** | Includes the bearer token directly in the command | Clipboard command only | Not required |

Machine environment variables can be read by every local account on the device. Inline mode puts the
token in the generated clipboard text. Windows Clipboard history may retain the original copied
request, including its bearer token. Choose the mode that matches your device and account security
requirements.

## Requirements

- Windows 10 version 1809 or later, or Windows 11 (x64).
- Microsoft PowerShell 7 or later. GraphClip uses `C:\Program Files\PowerShell\7\pwsh.exe` when present, otherwise
  `pwsh.exe` from `PATH`, including the Microsoft Store (MSIX) app execution alias.
- Network connectivity only when you run the generated command against Microsoft Graph.
- PowerToys Keyboard Manager is optional and only needed for a custom hotkey.

## Install, upgrade, and remove

The MSI installs GraphClip under `C:\Program Files\GraphClip` and adds Start Menu and Startup
shortcuts to `GraphClip.exe`, a small launcher that starts the GraphClip scripts with PowerShell 7
without a console window. The tray watcher runs after a user signs in; clipboard access is not run in Session 0.
The installer does not require network access or force a restart.

```powershell
# Install
msiexec.exe /i ".\GraphClip-Setup-<version>.msi"

# Upgrade by installing a newer release
msiexec.exe /i ".\GraphClip-Setup-<new-version>.msi" /qn /norestart

# Uninstall using the MSI ProductCode
msiexec.exe /x "{PRODUCT-CODE}"
```

For managed deployment, use `msiexec.exe /i "GraphClip-Setup-<version>.msi" /qn /norestart`
with install behavior set to **System**. Deploy PowerShell 7 as a separate prerequisite; for device-wide
deployments prefer the machine-wide PowerShell MSI, because the Microsoft Store version is installed per user.
Find the MSI ProductCode in Installed Apps or in the MSI metadata before uninstalling.

## Build and test

The application version is in [`VERSION`](./VERSION). To build locally, install WiX Toolset 5.0.2
and Pester 5 or later, then run the commands below. The `GraphClip.exe` launcher is compiled with the
.NET Framework C# compiler included in Windows.

```powershell
dotnet tool install --global wix --version 5.0.2
Install-Module Pester -Scope CurrentUser
.\Build-GraphClipMsi.ps1
```

Run the test suite separately with:

```powershell
Invoke-Pester .\GraphClip.Tests.ps1
```

To publish a release, push a `v<version>` tag matching `VERSION`. The GitHub Actions workflow
validates the tag, tests and builds the MSI, then publishes the installer and its SHA-256 checksum
to [GitHub Releases](https://github.com/UniverseCitiz3n/Graph-Clip/releases).

## License

GraphClip is available under the [Apache License 2.0](./LICENSE).
