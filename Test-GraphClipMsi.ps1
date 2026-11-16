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
        throw "msiexec failed with exit code $($process.ExitCode)."
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

    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    $watcher = Join-Path $InstallDirectory 'GraphClip-Watcher.ps1'
    if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) {
        throw "PowerShell 7 prerequisite not found at $pwsh."
    }
    $process = Start-Process -FilePath $pwsh -ArgumentList @(
        '-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$watcher`""
    ) -WindowStyle Hidden -PassThru
    try {
        Start-Sleep -Seconds 3
        $process.Refresh()
        if ($process.HasExited) {
            throw "GraphClip watcher exited during startup with code $($process.ExitCode)."
        }
        Write-Host 'Watcher startup check: OK'
    } finally {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id
        }
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
        -not (Test-ProductRegistered $metadata.ProductCode)) {
        throw 'Silent install did not register or place the GraphClip runtime.'
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
    $upgradeBuild = @(
        '-OutputDir', $upgradeDir,
        '-Version', $upgradeVersion,
        '-AllowVersionOverride',
        '-SkipTests'
    )
    if ($WixPath) {
        $upgradeBuild += @('-WixPath', $WixPath)
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
    ) -ExpectedExitCodes @(1638)
    if ($downgradeExitCode -ne 1638 -or -not (Test-ProductRegistered $upgradeMetadata.ProductCode)) {
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
