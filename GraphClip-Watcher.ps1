#requires -Version 7.0
<#
.SYNOPSIS
    Tray watcher: converts DevTools "Copy as PowerShell" Graph requests on the clipboard automatically.
.DESCRIPTION
    Listens for clipboard changes (WM_CLIPBOARDUPDATE, no polling). When the new text is a Microsoft Graph
    DevTools request it is replaced with a clean Invoke-RestMethod snippet. Depending on the token storage
    setting the bearer token is stored in the machine or user MSGRAPH_TOKEN environment variable, or written
    into the snippet. Anything else is left alone.
    Tray menu: enable/disable, convert now, restore the original clipboard text, token storage, open the log, exit.
    Run with: pwsh -NoProfile -STA -WindowStyle Hidden -File GraphClip-Watcher.ps1
.PARAMETER Cmdlet
    Cmdlet used in the generated snippet.
.PARAMETER StartDisabled
    Start with automatic conversion turned off.
#>
[CmdletBinding()]
param(
    [ValidateSet('Invoke-RestMethod', 'Invoke-RecurenceRestMethod')]
    [string]$Cmdlet = 'Invoke-RestMethod',
    [switch]$StartDisabled
)

$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'GraphClip-Watcher must run in an STA thread (pwsh -STA).'
}

$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, 'Local\GraphClip-Watcher', [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    return
}

Import-Module (Join-Path $PSScriptRoot 'GraphClip.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$listenerSource = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace GraphClip {
  public sealed class ClipboardListener : NativeWindow, IDisposable {
    const int WM_CLIPBOARDUPDATE = 0x031D;
    static readonly IntPtr HWND_MESSAGE = new IntPtr(-3);
    [DllImport("user32.dll", SetLastError = true)] static extern bool AddClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError = true)] static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
    public event EventHandler ClipboardUpdate;
    public ClipboardListener() {
      CreateHandle(new CreateParams { Parent = HWND_MESSAGE });
      if (!AddClipboardFormatListener(Handle))
        throw new InvalidOperationException("AddClipboardFormatListener failed: " + Marshal.GetLastWin32Error());
    }
    protected override void WndProc(ref Message m) {
      if (m.Msg == WM_CLIPBOARDUPDATE) { var h = ClipboardUpdate; if (h != null) h(this, EventArgs.Empty); }
      base.WndProc(ref m);
    }
    public void Dispose() {
      if (Handle != IntPtr.Zero) { RemoveClipboardFormatListener(Handle); DestroyHandle(); }
    }
  }
}
'@
if (-not ('GraphClip.ClipboardListener' -as [type])) {
    $frameworkDir = [System.IO.Path]::GetDirectoryName([System.Windows.Forms.Form].Assembly.Location)
    $references = 'System.Windows.Forms.dll', 'System.Windows.Forms.Primitives.dll', 'System.ComponentModel.Primitives.dll',
    'System.Drawing.Primitives.dll', 'System.Runtime.dll', 'System.Runtime.InteropServices.dll', 'System.Collections.dll' |
        ForEach-Object { Join-Path $frameworkDir $_ } | Where-Object { Test-Path -LiteralPath $_ }
    Add-Type -TypeDefinition $listenerSource -ReferencedAssemblies $references
}

$script:State = @{
    Enabled     = -not $StartDisabled
    Original    = $null
    LastHandled = $null
    Cmdlet      = $Cmdlet
}
$maxClipboardChars = 200000

function New-TrayIcon {
    param([System.Drawing.Color]$Color)
    $bitmap = [System.Drawing.Bitmap]::new(32, 32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.SmoothingMode = 'AntiAlias'
        $graphics.TextRenderingHint = 'AntiAliasGridFit'
        $brush = [System.Drawing.SolidBrush]::new($Color)
        $graphics.FillEllipse($brush, 1, 1, 30, 30)
        $font = [System.Drawing.Font]::new('Segoe UI', 17, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $format = [System.Drawing.StringFormat]::new()
        $format.Alignment = 'Center'
        $format.LineAlignment = 'Center'
        $graphics.DrawString('G', $font, [System.Drawing.Brushes]::White, [System.Drawing.RectangleF]::new(0, 1, 32, 32), $format)
        [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Get-ClipboardTextSafe {
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        try {
            if ([System.Windows.Forms.Clipboard]::ContainsText()) {
                return [System.Windows.Forms.Clipboard]::GetText()
            }
            return $null
        } catch {
            Start-Sleep -Milliseconds 60
        }
    }
    $null
}

function Set-ClipboardTextSafe {
    param([string]$Text)
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($Text)
            return $true
        } catch {
            Start-Sleep -Milliseconds 60
        }
    }
    $false
}

function Update-TrayState {
    $enabled = $script:State.Enabled
    $notifyIcon.Icon = if ($enabled) {
        $iconOn
    } else {
        $iconOff
    }
    $notifyIcon.Text = if ($enabled) {
        'GraphClip: watching clipboard'
    } else {
        'GraphClip: paused'
    }
    $toggleItem.Checked = $enabled
    $restoreItem.Enabled = $null -ne $script:State.Original
    $storage = Get-GraphClipTokenStorage
    foreach ($mode in $storageItems.Keys) {
        $storageItems[$mode].Checked = $mode -eq $storage
    }
}

function Invoke-ClipboardConversion {
    param([string]$Text, [switch]$Manual)

    $script:State.LastHandled = $Text
    $conversion = Invoke-GraphClipConversion -Text $Text -Cmdlet $script:State.Cmdlet
    Write-GraphClipLog "Watcher: manual=$([bool]$Manual) status=$($conversion.Status) success=$($conversion.Success)"
    if ($conversion.Success) {
        $script:State.LastHandled = $conversion.Snippet
        if (Set-ClipboardTextSafe -Text $conversion.Snippet) {
            $script:State.Original = $Text
        } else {
            $conversion.Level = 'Error'
            $conversion.Message = 'Could not write to the clipboard (locked by another app).'
        }
    }
    if ($conversion.Success -or $Manual -or $conversion.Status -in 'Expired', 'InvalidToken', 'NoAuthorization') {
        Show-GraphClipBalloon -Text $conversion.Message -Level $conversion.Level -NotifyIcon $notifyIcon
    }
    Update-TrayState
}

function Invoke-ClipboardCheck {
    if (-not $script:State.Enabled) {
        return
    }
    $text = Get-ClipboardTextSafe
    if ([string]::IsNullOrEmpty($text) -or $text.Length -gt $maxClipboardChars -or $text -ceq $script:State.LastHandled) {
        return
    }
    if (Test-DevToolsRequestText -Text $text) {
        Invoke-ClipboardConversion -Text $text
    }
}

$iconOn = New-TrayIcon -Color ([System.Drawing.Color]::FromArgb(0, 120, 212))
$iconOff = New-TrayIcon -Color ([System.Drawing.Color]::FromArgb(128, 128, 128))

$menu = [System.Windows.Forms.ContextMenuStrip]::new()
$toggleItem = [System.Windows.Forms.ToolStripMenuItem]::new('Convert automatically')
$toggleItem.CheckOnClick = $true
$convertNowItem = [System.Windows.Forms.ToolStripMenuItem]::new('Convert clipboard now')
$restoreItem = [System.Windows.Forms.ToolStripMenuItem]::new('Restore original clipboard text')
$storageMenu = [System.Windows.Forms.ToolStripMenuItem]::new('Token storage')
$storageItems = [ordered]@{
    Machine = [System.Windows.Forms.ToolStripMenuItem]::new('Machine environment variable')
    User    = [System.Windows.Forms.ToolStripMenuItem]::new('User environment variable')
    Inline  = [System.Windows.Forms.ToolStripMenuItem]::new('Inline in snippet headers')
}
foreach ($mode in $storageItems.Keys) {
    $storageItems[$mode].Tag = $mode
    [void]$storageMenu.DropDownItems.Add($storageItems[$mode])
}
$logItem = [System.Windows.Forms.ToolStripMenuItem]::new('Open log')
$exitItem = [System.Windows.Forms.ToolStripMenuItem]::new('Exit')
$menu.Items.AddRange(@($toggleItem, $convertNowItem, $restoreItem, $storageMenu, [System.Windows.Forms.ToolStripSeparator]::new(), $logItem, $exitItem))

$notifyIcon = [System.Windows.Forms.NotifyIcon]::new()
$notifyIcon.ContextMenuStrip = $menu

$debounce = [System.Windows.Forms.Timer]::new()
$debounce.Interval = 150

$listener = [GraphClip.ClipboardListener]::new()

$guard = {
    param([scriptblock]$Action)
    try {
        & $Action
    } catch {
        Write-GraphClipLog "Watcher error: $($_.Exception.Message)"
        Show-GraphClipBalloon -Text $_.Exception.Message -Level Error -NotifyIcon $notifyIcon
    }
}

$listener.add_ClipboardUpdate({
        $debounce.Stop()
        $debounce.Start()
    })
$debounce.add_Tick({
        $debounce.Stop()
        & $guard { Invoke-ClipboardCheck }
    })
$toggleItem.add_Click({
        $script:State.Enabled = $toggleItem.Checked
        Write-GraphClipLog "Watcher: enabled=$($script:State.Enabled)"
        Update-TrayState
    })
$convertNowItem.add_Click({
        & $guard {
            $text = Get-ClipboardTextSafe
            if ([string]::IsNullOrEmpty($text) -or -not (Test-DevToolsRequestText -Text $text)) {
                Show-GraphClipBalloon -Text 'Clipboard does not contain a Microsoft Graph DevTools request.' -Level Warning -NotifyIcon $notifyIcon
                return
            }
            Invoke-ClipboardConversion -Text $text -Manual
        }
    })
$restoreItem.add_Click({
        & $guard {
            if ($null -ne $script:State.Original -and (Set-ClipboardTextSafe -Text $script:State.Original)) {
                $script:State.LastHandled = $script:State.Original
                $script:State.Original = $null
                Show-GraphClipBalloon -Text 'Original clipboard text restored.' -NotifyIcon $notifyIcon
            }
            Update-TrayState
        }
    })
$storageMenu.add_DropDownItemClicked({
        param($menuSource, $clickArgs)
        & $guard {
            $mode = [string]$clickArgs.ClickedItem.Tag
            Set-GraphClipTokenStorage -Mode $mode
            Write-GraphClipLog "Watcher: token storage=$mode"
            Update-TrayState
        }
    })
$logItem.add_Click({
        & $guard {
            $logPath = Join-Path $env:LOCALAPPDATA 'GraphClip\GraphClip.log'
            if (Test-Path -LiteralPath $logPath) {
                Start-Process -FilePath notepad.exe -ArgumentList ('"{0}"' -f $logPath)
            }
        }
    })
$exitItem.add_Click({
        [System.Windows.Forms.Application]::ExitThread()
    })

Update-TrayState
$notifyIcon.Visible = $true
Write-GraphClipLog "Watcher started (pid $PID, enabled=$($script:State.Enabled))"

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    Write-GraphClipLog 'Watcher stopped'
    $debounce.Stop()
    $debounce.Dispose()
    $listener.Dispose()
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $menu.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
