#requires -Version 7.0
<#
.SYNOPSIS
    Hotkey entry point: clipboard (DevTools "Copy as PowerShell") -> clean Invoke-RestMethod snippet in the clipboard.
.DESCRIPTION
    Stores the bearer token according to the token storage setting (machine or user MSGRAPH_TOKEN environment
    variable, or inline in the snippet). The clipboard is left untouched
    when the text is not a Microsoft Graph DevTools request.
    Run with: pwsh -NoProfile -STA -File Invoke-GraphClip.ps1
.PARAMETER Cmdlet
    Cmdlet used in the generated snippet.
.PARAMETER TokenStorage
    Overrides the saved token storage setting for this run: Machine, User or Inline.
.PARAMETER Quiet
    Suppress the notification balloon.
#>
[CmdletBinding()]
param(
    [ValidateSet('Invoke-RestMethod', 'Invoke-RecurenceRestMethod')]
    [string]$Cmdlet = 'Invoke-RestMethod',
    [ValidateSet('Machine', 'User', 'Inline')]
    [string]$TokenStorage,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GraphClip.psm1') -Force

function Send-Notification {
    param([string]$Text, [string]$Level = 'Info')
    if (-not $Quiet) {
        Show-GraphClipBalloon -Text $Text -Level $Level
    }
}

try {
    $conversionArgs = @{ Text = [string](Get-Clipboard -Raw); Cmdlet = $Cmdlet }
    if ($TokenStorage) {
        $conversionArgs.TokenStorage = $TokenStorage
    }
    $conversion = Invoke-GraphClipConversion @conversionArgs
    Write-GraphClipLog "Hotkey: status=$($conversion.Status) success=$($conversion.Success)"
    if ($conversion.Success) {
        Set-Clipboard -Value $conversion.Snippet
    }
    Send-Notification -Text $conversion.Message -Level $conversion.Level
    exit ([int](-not $conversion.Success))
} catch {
    Write-GraphClipLog "Hotkey error: $($_.Exception.Message)"
    Send-Notification -Text $_.Exception.Message -Level 'Error'
    exit 2
}
