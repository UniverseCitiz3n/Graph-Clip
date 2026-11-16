# GraphClip

GraphClip converts Microsoft Graph requests copied as PowerShell from browser DevTools into clean
`Invoke-RestMethod` commands. How the bearer token is handled is configurable per user (see
[Token storage](#token-storage)); by default it is stored in the machine `MSGRAPH_TOKEN` environment
variable and the generated command references that variable.

## Requirements

- Windows 10 version 1809 or later, or Windows 11 (x64).
- Microsoft PowerShell 7 or later installed machine-wide at
  `C:\Program Files\PowerShell\7\pwsh.exe`.
- GraphClip only needs network connectivity when the generated command accesses Microsoft Graph.

PowerToys Keyboard Manager is optional for assigning a hotkey. Browser DevTools are the request source.

## Use GraphClip

The watcher runs in the notification area after a user signs in. Its menu can enable/disable automatic
conversion, convert the current clipboard, restore the original clipboard text, select the token
storage mode, open the log, or exit. The Start Menu also includes a separate **Convert clipboard now** shortcut.

To bind a hotkey in PowerToys Keyboard Manager, add a **Remap a shortcut > Start App** action:

| Field | Value |
|---|---|
| Program | `C:\Program Files\PowerShell\7\pwsh.exe` |
| Arguments | `-NoProfile -STA -ExecutionPolicy Bypass -File "C:\Program Files\GraphClip\Invoke-GraphClip.ps1"` |
| Visibility | Hidden |
| If running | Do nothing |

GraphClip only parses clipboard PowerShell syntax; it never executes the copied request. It converts
requests for Microsoft Graph hosts, keeps tokens out of logs, and preserves the request method, URI,
body, content type, and supported headers. The original clipboard text contains the bearer token;
Windows clipboard history (Win+V) may retain it.

### Token storage

Select the mode in the tray menu under **Token storage**. The choice is saved per user in
`%LOCALAPPDATA%\GraphClip\settings.json` and is used by both the watcher and the hotkey script.
`Invoke-GraphClip.ps1 -TokenStorage <Machine|User|Inline>` overrides it for a single run (for example,
from a PowerToys shortcut).

| Mode | Snippet `Authorization` header | Token stored in | Admin rights |
|---|---|---|---|
| **Machine** (default) | `[Environment]::GetEnvironmentVariable('MSGRAPH_TOKEN', 'Machine')` | `HKLM` machine variable | Required |
| **User** | `[Environment]::GetEnvironmentVariable('MSGRAPH_TOKEN', 'User')` | `HKCU` user variable | Not required |
| **Inline** | `'Bearer eyJ...'` written into the hashtable | Nowhere; only in the clipboard snippet | Not required |

Machine mode stores the token in one of three ways. GraphClip uses the first that applies:

1. When GraphClip already runs elevated, it writes the variable directly.
2. When the `GraphClip-SetToken` scheduled task from the earlier script-based installer exists, it runs
   that task without a prompt.
3. Otherwise it starts an elevated PowerShell through a UAC prompt. Cancelling the prompt still produces
   the snippet but leaves the previous machine token in place, and a warning is shown.

Standard users can't write the machine variable. Windows only allows Administrators and SYSTEM to change
`HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`. The `GraphClip-SetToken` task also
runs as the user with *highest privileges*, so it only works for members of the local Administrators
group (it avoids the UAC prompt, not the admin requirement). For a user without permanent admin rights,
Machine mode works only through on-demand elevation: just-in-time admin, Endpoint Privilege Management,
or administrator credentials at the UAC prompt. Otherwise use **User** mode. Machine variables can be
read by every user on the device, so a token stored there is visible to all local accounts.

## Build the MSI locally

The authoritative application version is in [`VERSION`](./VERSION). Install WiX Toolset 5.0.2 and
Pester 5 or later, then run:

```powershell
dotnet tool install --global wix --version 5.0.2
Install-Module Pester -Scope CurrentUser
.\Build-GraphClipMsi.ps1
```

The build runs the Pester tests and PowerShell syntax checks, stages only runtime files, and writes
`dist\GraphClip-Setup-<VERSION>.msi`. To run tests separately:

```powershell
Invoke-Pester .\GraphClip.Tests.ps1
```

For real MSI metadata/install/upgrade/downgrade/uninstall checks, run the validator from an elevated
PowerShell session:

```powershell
.\Test-GraphClipMsi.ps1 -MsiPath .\dist\GraphClip-Setup-1.0.0.msi -Version 1.0.0
```

It installs and removes the package, so do not run it if another GraphClip MSI is already installed
or if `C:\Program Files\GraphClip` contains unrelated files.

## Install and uninstall

The MSI is a per-machine x64 package installed under `C:\Program Files\GraphClip`. It requires
machine-wide PowerShell 7 at `C:\Program Files\PowerShell\7` and fails the install if it is missing.
It creates all-users Start Menu shortcuts and a common Startup shortcut so the tray watcher starts
in each signed-in user's session. The MSI installs without network access and requires an
administrator or SYSTEM deployment context; it does not launch a UI or force a restart.

Interactive install and uninstall:

```powershell
msiexec.exe /i .\GraphClip-Setup-1.0.0.msi
msiexec.exe /x "{PRODUCT-CODE}"
```

Silent install and uninstall:

```powershell
msiexec.exe /i .\GraphClip-Setup-1.0.0.msi /qn /norestart
msiexec.exe /x "{PRODUCT-CODE}" /qn /norestart
```

Upgrade to a newer MSI using the same silent install command:

```powershell
msiexec.exe /i ".\GraphClip-Setup-<new-version>.msi" /qn /norestart
```

Replace `<new-version>` with the downloaded MSI's version. Windows Installer removes the older MSI
version as part of the major upgrade.

Use the MSI's actual ProductCode for uninstall. Find it in Programs and Features / Installed Apps or
in the `ProductCode` property of the MSI. To set a non-default directory:

```powershell
msiexec.exe /i .\GraphClip-Setup-1.0.0.msi /qn /norestart INSTALLDIR="D:\Apps\GraphClip"
```

Standard Windows Installer logging is supported:

```powershell
msiexec.exe /i .\GraphClip-Setup-1.0.0.msi /qn /norestart /L*v "$env:TEMP\GraphClip-Install.log"
msiexec.exe /x "{PRODUCT-CODE}" /qn /norestart /L*v "$env:TEMP\GraphClip-Uninstall.log"
```

Windows Installer exit codes are passed through unchanged. Deployment systems should treat `0` as
success, `3010` as success/restart required, and `1641` as success/restart initiated; `/norestart`
prevents GraphClip from requesting a restart. `1603` is a fatal error and `1618` means another
installation is in progress.

### Intune and SYSTEM deployment

Deploy the MSI as a **Windows app (Win32)** or line-of-business MSI with install command:

```text
msiexec.exe /i "GraphClip-Setup-1.0.0.msi" /qn /norestart
```

Uninstall command:

```text
msiexec.exe /x "{PRODUCT-CODE}" /qn /norestart
```

Set the install behavior to **System** for a machine-wide install. The MSI does not depend on a mapped
drive, a user profile, an interactive installer session, or a network download. The common Startup
shortcut launches the watcher only after a user signs in; clipboard access and tray UI are
intentionally not run in Session 0. Keep PowerShell 7 installed machine-wide as a separate
prerequisite.

The MSI doesn't create the elevated `GraphClip-SetToken` task, so on an MSI-only device Machine mode
asks for elevation through UAC. Users without admin rights should select **User** or **Inline** in the
tray menu (see [Token storage](#token-storage)). User settings, data, and logs remain under
`%LOCALAPPDATA%\GraphClip` and are not removed by MSI upgrades or uninstall. The `MSGRAPH_TOKEN`
environment variables are also left untouched.

### Upgrades and migration

Installing a newer MSI with the same UpgradeCode performs a Windows Installer major upgrade and
rejects downgrades. A first MSI installation does not automatically remove an older ZIP/script-based
installation. Before deploying the MSI to an existing ZIP installation, disable the old
`GraphClip-Watcher` scheduled task for each affected user so an obsolete watcher does not continue to
run. The old `GraphClip-SetToken` task can stay: the MSI version uses it in Machine mode so that
existing users avoid the UAC prompt. Preserve `%LOCALAPPDATA%\GraphClip\GraphClip.log` if it is needed.

## Verify the release checksum

Release assets include `SHA256SUMS.txt`. From the directory containing both files:

```powershell
$expected = ((Get-Content .\SHA256SUMS.txt) -split '\s+')[0]
(Get-FileHash .\GraphClip-Setup-1.0.0.msi -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expected
```

The checksum line uses the standard format:

```text
<sha256-hash>  GraphClip-Setup-1.0.0.msi
```

## GitHub Releases

Push a tag whose version matches `VERSION`, for example:

```powershell
git tag v1.0.0
git push origin v1.0.0
```

The Windows GitHub Actions workflow validates the tag, runs tests, builds and validates the x64 MSI,
installs/upgrades/uninstalls it silently, checks SHA-256, then creates a GitHub Release. It also
starts the tray watcher when the runner has an interactive user session. The hosted runner validates
installation as an elevated account, not as LocalSystem; System-context deployment is not directly
tested. It publishes
`GraphClip-Setup-1.0.0.msi` and `SHA256SUMS.txt` in the repository's Releases page. A duplicate
release is not overwritten; the workflow fails if the tag already has a release.
