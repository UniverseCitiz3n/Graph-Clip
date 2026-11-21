#requires -Version 7.0
<#
.SYNOPSIS
    Runs GraphClip validation and builds its Windows Installer package.
.PARAMETER OutputDir
    Directory for the MSI. Defaults to .\dist.
.PARAMETER Version
    Version to package. Defaults to VERSION; release builds pass the validated tag version.
.PARAMETER AllowVersionOverride
    Allows a different package version for the automated major-upgrade test only.
.PARAMETER SkipTests
    Skips Pester tests when they have already been run by the caller.
.PARAMETER WixPath
    Optional path to the WiX executable when it is not on PATH.
#>
[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot 'dist'),
    [string]$Version,
    [switch]$AllowVersionOverride,
    [switch]$SkipTests,
    [string]$WixPath
)

$ErrorActionPreference = 'Stop'
$runtimeFiles = @('GraphClip.psm1', 'GraphClip-Watcher.ps1', 'Invoke-GraphClip.ps1')
$sourceVersion = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
$version = if ($Version) { $Version } else { $sourceVersion }

if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version '$version' is not in MAJOR.MINOR.PATCH form."
}
if (@($version.Split('.') | Where-Object { [int]$_ -gt 255 }).Count -gt 0) {
    throw "Version '$version' exceeds Windows Installer's three-field version limits."
}
if ($version -ne $sourceVersion -and -not $AllowVersionOverride) {
    throw "Build version '$version' does not match VERSION '$sourceVersion'."
}

$syntaxFiles = @($runtimeFiles + 'GraphClip.Tests.ps1' + 'Test-GraphClipMsi.ps1')
foreach ($file in $syntaxFiles) {
    $path = Join-Path $PSScriptRoot $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required source file is missing: $file"
    }
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) {
        throw "Syntax error in ${file}: $($parseErrors[0].Message) (line $($parseErrors[0].Extent.StartLineNumber))"
    }
}
Write-Host 'PowerShell syntax check: OK'

if (-not $SkipTests) {
    if (-not (Get-Command Invoke-Pester -ErrorAction SilentlyContinue)) {
        throw 'Pester is required. Install it with: Install-Module Pester -Scope CurrentUser'
    }
    $testResult = Invoke-Pester -Path (Join-Path $PSScriptRoot 'GraphClip.Tests.ps1') -PassThru -Output None
    if ($testResult.FailedCount -gt 0 -or $testResult.PassedCount -eq 0) {
        throw "Pester: $($testResult.FailedCount) failed, $($testResult.PassedCount) passed."
    }
    Write-Host "Pester: $($testResult.PassedCount) passed"
}

if (-not $WixPath) {
    $wixCommand = Get-Command wix -ErrorAction SilentlyContinue
    if (-not $wixCommand) {
        throw 'WiX Toolset 5.0.2 is required. Install it with: dotnet tool install --global wix --version 5.0.2'
    }
    $WixPath = $wixCommand.Source
}
if (-not (Test-Path -LiteralPath $WixPath -PathType Leaf)) {
    throw "WiX executable was not found: $WixPath"
}

$staging = Join-Path ([IO.Path]::GetTempPath()) "GraphClip-Msi-$PID"
$stagingRoot = Join-Path $staging 'payload'
$null = New-Item -ItemType Directory -Path $stagingRoot -Force

try {
    foreach ($file in $runtimeFiles) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $stagingRoot
    }
    Set-Content -LiteralPath (Join-Path $stagingRoot 'VERSION') -Value $version -Encoding ascii -NoNewline

    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::new(32, 32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(0, 120, 212))
        try {
            $graphics.FillEllipse($brush, 1, 1, 30, 30)
        } finally {
            $brush.Dispose()
        }
        $font = [System.Drawing.Font]::new('Segoe UI', 17, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        try {
            $format = [System.Drawing.StringFormat]::new()
            try {
                $format.Alignment = [System.Drawing.StringAlignment]::Center
                $format.LineAlignment = [System.Drawing.StringAlignment]::Center
                $graphics.DrawString('G', $font, [System.Drawing.Brushes]::White, [System.Drawing.RectangleF]::new(0, 1, 32, 32), $format)
            } finally {
                $format.Dispose()
            }
            $icon = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
            try {
                $iconStream = [IO.File]::Create((Join-Path $stagingRoot 'GraphClip.ico'))
                try {
                    $icon.Save($iconStream)
                } finally {
                    $iconStream.Dispose()
                }
            } finally {
                $icon.Dispose()
            }
        } finally {
            $font.Dispose()
        }
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }

    # The launcher is built with the .NET Framework compiler that ships with Windows, so no SDK is needed.
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
        throw "The .NET Framework C# compiler was not found: $csc"
    }
    $assemblyInfo = Join-Path $staging 'AssemblyInfo.cs'
    Set-Content -LiteralPath $assemblyInfo -Encoding utf8 -Value @(
        'using System.Reflection;'
        '[assembly: AssemblyTitle("GraphClip")]'
        '[assembly: AssemblyDescription("Starts GraphClip with PowerShell 7.")]'
        '[assembly: AssemblyCompany("UniverseCitiz3n")]'
        '[assembly: AssemblyProduct("GraphClip")]'
        "[assembly: AssemblyVersion(`"$version.0`")]"
        "[assembly: AssemblyFileVersion(`"$version.0`")]"
        "[assembly: AssemblyInformationalVersion(`"$version`")]"
    )
    $launcherPath = Join-Path $stagingRoot 'GraphClip.exe'
    $cscOutput = & $csc /nologo /target:winexe /platform:x64 /optimize+ /warnaserror+ "/out:$launcherPath" `
        "/win32icon:$(Join-Path $stagingRoot 'GraphClip.ico')" /reference:System.Windows.Forms.dll `
        (Join-Path $PSScriptRoot 'installer\GraphClipLauncher.cs') $assemblyInfo 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw "Launcher build failed with exit code $LASTEXITCODE.`n$($cscOutput -join [Environment]::NewLine)"
    }
    Write-Host 'Launcher build: OK'

    $outputPath = [IO.Path]::GetFullPath($OutputDir)
    $null = New-Item -ItemType Directory -Path $outputPath -Force
    $msiPath = Join-Path $outputPath "GraphClip-Setup-$version.msi"
    $wixArgs = @(
        'build',
        (Join-Path $PSScriptRoot 'installer\GraphClip.wxs'),
        '-arch', 'x64',
        '-d', "ProductVersion=$version",
        '-d', "SourceDir=$stagingRoot",
        '-o', $msiPath
    )
    & $WixPath @wixArgs
    if ($LASTEXITCODE -ne 0) {
        throw "WiX build failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $msiPath -PathType Leaf)) {
        throw 'WiX reported success but the MSI was not created.'
    }

    Write-Host "MSI: $msiPath ($([math]::Round((Get-Item -LiteralPath $msiPath).Length / 1KB, 1)) KB)"
} finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}
