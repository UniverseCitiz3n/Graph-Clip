#requires -Version 7.0
<#
.SYNOPSIS
    Performs real Windows Installer metadata, silent install, major-upgrade, and uninstall checks.
.PARAMETER MsiPath
    MSI to install and validate.
.PARAMETER Version
    Expected three-part MSI version.
.PARAMETER ChecksumPath
    Optional SHA256SUMS.txt file to verify against the MSI.
.PARAMETER WixPath
    Optional path to WiX when it is not on PATH.
.PARAMETER SkipAppLaunch
    Skips the interactive-session watcher startup check.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MsiPath,
    [Parameter(Mandatory)][string]$Version,
    [string]$ChecksumPath,
    [string]$WixPath,
    [switch]$SkipAppLaunch
)

$ErrorActionPreference = 'Stop'
$MsiPath = (Resolve-Path -LiteralPath $MsiPath).Path
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = [Security.Principal.WindowsPrincipal]$currentIdentity
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Real MSI installation checks require an elevated administrator session.'
}
$expectedInstallDir = Join-Path $env:ProgramFiles 'GraphClip'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "GraphClip-MsiValidation-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $tempRoot
$logPaths = @(
    (Join-Path $tempRoot 'Install.log'),
    (Join-Path $tempRoot 'Upgrade.log'),
    (Join-Path $tempRoot 'Downgrade.log'),
    (Join-Path $tempRoot 'Uninstall.log')
)
$sentinel = Join-Path (Join-Path $env:LOCALAPPDATA 'GraphClip') "MsiValidation-$([guid]::NewGuid().ToString('N')).txt"
$productCodes = [System.Collections.Generic.List[string]]::new()
$testSucceeded = $false

function Get-MsiValue {
    param([object]$Database, [string]$Property)
    $view = $Database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property`` = '$Property'")
    $record = $null
    try {
        [void]$view.Execute()
        $record = $view.Fetch()
        if (-not $record) {
            throw "MSI property '$Property' is missing."
        }
        $record.StringData(1)
    } finally {
        if ($record) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($record)
        }
        [void]$view.Close()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view)
    }
}

function Get-MsiMetadata {
    param([Parameter(Mandatory)][string]$Path)
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($Path, 0)
    try {
        $summary = $database.SummaryInformation(0)
        $metadata = [pscustomobject]@{
            ProductName   = Get-MsiValue $database 'ProductName'
            Manufacturer  = Get-MsiValue $database 'Manufacturer'
            ProductVersion = Get-MsiValue $database 'ProductVersion'
            ProductCode   = Get-MsiValue $database 'ProductCode'
            UpgradeCode   = Get-MsiValue $database 'UpgradeCode'
            Template      = $summary.Property(7)
        }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($summary)
        $metadata
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($database)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
    }
}

function Invoke-Msi {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int[]]$ExpectedExitCodes = @(0, 3010)
    )
    $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -notin $ExpectedExitCodes) {
        $logArgumentIndex = [Array]::IndexOf($Arguments, '/L*v')
        $logPath = if ($logArgumentIndex -ge 0) { $Arguments[$logArgumentIndex + 1].Trim('"') }
        $logTail = if ($logPath -and (Test-Path -LiteralPath $logPath)) {
            $failureDetails = Select-String -LiteralPath $logPath -Pattern 'Return value 3' -Context 5, 5
            if ($failureDetails) {
                ($failureDetails | Select-Object -Last 3 | ForEach-Object {
                    $_.Context.PreContext + $_.Line + $_.Context.PostContext
                }) -join [Environment]::NewLine
            } else {
                (Get-Content -LiteralPath $logPath -Tail 30) -join [Environment]::NewLine
            }
        }
        throw "msiexec failed with exit code $($process.ExitCode).`n$logTail"
    }
    $process.ExitCode
}

function Test-ProductRegistered {
    param([Parameter(Mandatory)][string]$ProductCode)
    Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode"
}

function Invoke-WatcherLaunchCheck {
    param([Parameter(Mandatory)][string]$InstallDirectory)
    if ($SkipAppLaunch -or -not [Environment]::UserInteractive) {
        Write-Warning 'Watcher startup check skipped because no interactive user session is available.'
        return
    }

    $watcherScript = Join-Path $InstallDirectory 'GraphClip-Watcher.ps1'
    $startedAfter = (Get-Date).AddSeconds(-1)
    # Process.Start instead of Start-Process -Wait, which would also wait for the long-running watcher child.
    $launcher = [Diagnostics.Process]::Start((Join-Path $InstallDirectory 'GraphClip.exe'))
    $watcher = $null
    try {
        if (-not $launcher.WaitForExit(15000)) {
            throw 'GraphClip.exe did not exit after starting the watcher.'
        }
        if ($launcher.ExitCode -ne 0) {
            throw "GraphClip.exe exited with code $($launcher.ExitCode)."
        }
        Start-Sleep -Seconds 3
        $watcher = Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" |
            Where-Object { $_.CreationDate -ge $startedAfter -and $_.CommandLine -like "*$watcherScript*" } |
            Select-Object -First 1
        if (-not $watcher) {
            throw 'GraphClip watcher was not running 3 seconds after GraphClip.exe started it.'
        }
        Write-Host "Watcher startup check: OK ($($watcher.ExecutablePath))"
    } finally {
        $launcher.Dispose()
        if ($watcher) {
            Stop-Process -Id $watcher.ProcessId -ErrorAction SilentlyContinue
        }
    }
}

function Assert-ShortcutTarget {
    param([Parameter(Mandatory)][string]$LauncherPath)
    $shell = New-Object -ComObject WScript.Shell
    try {
        $programs = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'GraphClip'
        $shortcuts = @(
            (Join-Path $programs 'GraphClip.lnk'),
            (Join-Path $programs 'Convert clipboard now.lnk'),
            (Join-Path ([Environment]::GetFolderPath('CommonStartup')) 'GraphClip.lnk')
        )
        foreach ($shortcut in $shortcuts) {
            if (-not (Test-Path -LiteralPath $shortcut -PathType Leaf) -or
                $shell.CreateShortcut($shortcut).TargetPath -ne $LauncherPath) {
                throw "Shortcut is missing or does not start ${LauncherPath}: $shortcut"
            }
        }
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

try {
    if ($Version -notmatch '^\d+\.\d+\.\d+$' -or
        @($Version.Split('.') | Where-Object { [int]$_ -gt 255 }).Count -gt 0) {
        throw "Version '$Version' is not a valid three-field Windows Installer version."
    }
    if (Test-Path -LiteralPath $expectedInstallDir) {
        throw "Refusing to overwrite an existing directory: $expectedInstallDir"
    }

    $metadata = Get-MsiMetadata $MsiPath
    if ($metadata.ProductName -ne 'GraphClip' -or
        $metadata.Manufacturer -ne 'UniverseCitiz3n' -or
        $metadata.ProductVersion -ne $Version -or
        $metadata.Template -notmatch '^x64;') {
        throw "Unexpected MSI metadata: $($metadata | ConvertTo-Json -Compress)"
    }
    $parsedProductCode = [guid]::Empty
    if (-not [guid]::TryParse($metadata.ProductCode, [ref]$parsedProductCode)) {
        throw "Invalid MSI ProductCode '$($metadata.ProductCode)'."
    }
    $null = [guid]::Parse($metadata.UpgradeCode)

    if ($ChecksumPath) {
        $checksum = Get-Content -LiteralPath $ChecksumPath -Raw
        $expectedHash = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedLine = "$expectedHash  $(Split-Path $MsiPath -Leaf)"
        if ($checksum.Trim() -cne $expectedLine) {
            throw 'SHA256SUMS.txt does not match the MSI.'
        }
    }

    if (Test-ProductRegistered $metadata.ProductCode) {
        throw "Product $($metadata.ProductCode) is already installed."
    }

    $null = New-Item -ItemType Directory -Path (Split-Path $sentinel) -Force
    Set-Content -LiteralPath $sentinel -Value 'preserve across MSI uninstall'
    $productCodes.Add($metadata.ProductCode)
    $installLog = $logPaths[0]
    $null = Invoke-Msi -Arguments @(
        '/i', "`"$MsiPath`"", '/qn', '/norestart', '/L*v', "`"$installLog`""
    )
    if (-not (Test-Path -LiteralPath (Join-Path $expectedInstallDir 'GraphClip-Watcher.ps1')) -or
        -not (Test-Path -LiteralPath (Join-Path $expectedInstallDir 'GraphClip.exe')) -or
        -not (Test-ProductRegistered $metadata.ProductCode)) {
        throw 'Silent install did not register or place the GraphClip runtime.'
    }
    Assert-ShortcutTarget -LauncherPath (Join-Path $expectedInstallDir 'GraphClip.exe')
    $arpLocation = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($metadata.ProductCode)").InstallLocation
    if ("$arpLocation".TrimEnd('\') -ne $expectedInstallDir) {
        throw "Installed Apps InstallLocation is '$arpLocation' instead of $expectedInstallDir."
    }
    Write-Host 'Silent install check: OK'
    Invoke-WatcherLaunchCheck -InstallDirectory $expectedInstallDir

    $parts = @($Version.Split('.') | ForEach-Object { [int]$_ })
    if ($parts[2] -lt 255) {
        $parts[2]++
    } elseif ($parts[1] -lt 255) {
        $parts[1]++
        $parts[2] = 0
    } elseif ($parts[0] -lt 255) {
        $parts[0]++
        $parts[1] = 0
        $parts[2] = 0
    } else {
        throw "Cannot create a test upgrade above version $Version."
    }
    $upgradeVersion = $parts -join '.'
    $upgradeDir = Join-Path $tempRoot 'upgrade'
    $upgradeBuild = @{
        OutputDir            = $upgradeDir
        Version              = $upgradeVersion
        AllowVersionOverride = $true
        SkipTests            = $true
    }
    if ($WixPath) {
        $upgradeBuild.WixPath = $WixPath
    }
    & (Join-Path $PSScriptRoot 'Build-GraphClipMsi.ps1') @upgradeBuild

    $upgradeMsi = Join-Path $upgradeDir "GraphClip-Setup-$upgradeVersion.msi"
    $upgradeMetadata = Get-MsiMetadata $upgradeMsi
    if ($upgradeMetadata.UpgradeCode -ne $metadata.UpgradeCode -or
        $upgradeMetadata.ProductCode -eq $metadata.ProductCode) {
        throw 'Upgrade MSI does not use a new ProductCode and the stable UpgradeCode.'
    }
    $productCodes.Add($upgradeMetadata.ProductCode)
    $null = Invoke-Msi -Arguments @(
        '/i', "`"$upgradeMsi`"", '/qn', '/norestart', '/L*v', "`"$($logPaths[1])`""
    )
    $oldProductRegistered = Test-ProductRegistered $metadata.ProductCode
    $upgradeProductRegistered = Test-ProductRegistered $upgradeMetadata.ProductCode
    $watcherInstalled = Test-Path -LiteralPath (Join-Path $expectedInstallDir 'GraphClip-Watcher.ps1')
    if ($oldProductRegistered -or -not $upgradeProductRegistered -or -not $watcherInstalled) {
        throw 'Major upgrade did not replace the previous product registration.'
    }
    Write-Host 'Major upgrade check: OK'

    $downgradeExitCode = Invoke-Msi -Arguments @(
        '/i', "`"$MsiPath`"", '/qn', '/norestart', '/L*v', "`"$($logPaths[2])`""
    ) -ExpectedExitCodes @(1603)
    if ($downgradeExitCode -ne 1603 -or -not (Test-ProductRegistered $upgradeMetadata.ProductCode)) {
        throw 'Downgrade was not rejected by Windows Installer.'
    }
    Write-Host 'Downgrade prevention check: OK'

    $null = Invoke-Msi -Arguments @(
        '/x', $upgradeMetadata.ProductCode, '/qn', '/norestart', '/L*v', "`"$($logPaths[3])`""
    )
    $productStillRegistered = Test-ProductRegistered $upgradeMetadata.ProductCode
    $installDirectoryRemains = Test-Path -LiteralPath $expectedInstallDir
    $userDataPreserved = Test-Path -LiteralPath $sentinel
    if ($productStillRegistered -or $installDirectoryRemains -or -not $userDataPreserved) {
        throw 'Silent uninstall failed or removed user data.'
    }
    Write-Host 'Silent uninstall and user-data preservation checks: OK'
    $testSucceeded = $true
} finally {
    foreach ($productCode in $productCodes | Select-Object -Unique) {
        if (Test-ProductRegistered $productCode) {
            $cleanupLog = Join-Path $tempRoot "CleanupUninstall-$($productCodes.IndexOf($productCode)).log"
            $cleanup = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" `
                -ArgumentList @('/x', $productCode, '/qn', '/norestart', '/L*v', "`"$cleanupLog`"") `
                -Wait -PassThru
            if ($cleanup.ExitCode -notin 0, 3010) {
                Write-Warning "Cleanup uninstall for $productCode failed with exit code $($cleanup.ExitCode); MSI logs remain in $tempRoot."
            }
        }
    }
    if (Test-Path -LiteralPath $sentinel) {
        Remove-Item -LiteralPath $sentinel -Force
    }
    if ($testSucceeded) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    } else {
        Write-Warning "Validation logs and temporary MSI files were retained in $tempRoot."
    }
}
