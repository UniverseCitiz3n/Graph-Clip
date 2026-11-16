#requires -Version 7.0
<#
.SYNOPSIS
    GraphClip core: turns DevTools "Copy as PowerShell" output into a clean Invoke-RestMethod snippet.
.DESCRIPTION
    Clipboard text is only parsed (AST) and never executed. The token storage mode (Machine, User or
    Inline) is a per-user setting: Machine/User store the bearer token in the MSGRAPH_TOKEN environment
    variable of that scope and reference it from the snippet; Inline writes the token into the snippet.
#>

Set-StrictMode -Version Latest

$script:TokenVariableName = 'MSGRAPH_TOKEN'
$script:TokenStorageModes = 'Machine', 'User', 'Inline'
$script:DefaultTokenStorage = 'Machine'
$script:TaskName = 'GraphClip-SetToken'
$script:AppDataDir = Join-Path $env:LOCALAPPDATA 'GraphClip'
$script:PendingTokenPath = Join-Path $script:AppDataDir 'pending.token'
$script:SettingsPath = Join-Path $script:AppDataDir 'settings.json'
$script:LogPath = Join-Path $script:AppDataDir 'GraphClip.log'
$script:GraphHostPattern = '^(graph\.microsoft\.com|graph\.microsoft\.us|dod-graph\.microsoft\.us|microsoftgraph\.chinacloudapi\.cn)$'
$script:BearerPattern = '^Bearer [A-Za-z0-9\-._~+/]+=*$'
$script:KeptHeaders = @{
    consistencylevel = 'ConsistencyLevel'
    prefer           = 'Prefer'
    'if-match'       = 'If-Match'
}
$script:SwitchParameters = @(
    'UseBasicParsing', 'AllowUnencryptedAuthentication', 'DisableKeepAlive', 'PassThru',
    'PreserveAuthorizationOnRedirect', 'SkipCertificateCheck', 'SkipHeaderValidation',
    'SkipHttpErrorCheck', 'AllowInsecureRedirect', 'Resume', 'UseDefaultCredentials', 'NoProxy'
)

#region Parsing

function Get-StaticAstValue {
    # Evaluates only literal constructs. Anything dynamic ($var, $(...), commands) is rejected, never executed.
    param([Parameter(Mandatory)]$Ast)

    if ($Ast -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return $Ast.Value
    }
    if ($Ast -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        if ($Ast.NestedExpressions.Count -eq 0) {
            return $Ast.Value
        }
        throw [System.NotSupportedException]::new('String with variable expansion.')
    }
    if ($Ast -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        return $Ast.Value
    }
    if ($Ast -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $inner = $Ast.Pipeline
        if ($inner -is [System.Management.Automation.Language.PipelineAst] -and $inner.PipelineElements.Count -eq 1 -and
            $inner.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
            return Get-StaticAstValue -Ast $inner.PipelineElements[0].Expression
        }
        throw [System.NotSupportedException]::new('Unsupported parenthesized expression.')
    }
    if ($Ast -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        # Edge wraps non-ASCII bodies as [System.Text.Encoding]::UTF8.GetBytes("...")
        $isGetBytes = -not $Ast.Static -and
        $Ast.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $Ast.Member.Value -eq 'GetBytes' -and
        $Ast.Arguments.Count -eq 1 -and
        $Ast.Expression -is [System.Management.Automation.Language.MemberExpressionAst] -and
        $Ast.Expression.Member.Value -eq 'UTF8' -and
        $Ast.Expression.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
        $Ast.Expression.Expression.TypeName.Name -match '^(System\.)?Text\.Encoding$'
        if ($isGetBytes) {
            return Get-StaticAstValue -Ast $Ast.Arguments[0]
        }
    }
    throw [System.NotSupportedException]::new("Unsupported expression: $($Ast.GetType().Name)")
}

function ConvertTo-DevToolsRequestObject {
    param([Parameter(Mandatory)][System.Management.Automation.Language.CommandAst]$Command)

    $namedParameters = @{}
    $positional = [System.Collections.Generic.List[object]]::new()
    $elements = $Command.CommandElements
    for ($i = 1; $i -lt $elements.Count; $i++) {
        $element = $elements[$i]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            $positional.Add($element)
            continue
        }
        if ($null -ne $element.Argument) {
            $namedParameters[$element.ParameterName] = $element.Argument
        } elseif ($element.ParameterName -in $script:SwitchParameters) {
            continue
        } elseif ($i + 1 -lt $elements.Count -and $elements[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            $namedParameters[$element.ParameterName] = $elements[$i + 1]
            $i++
        }
    }

    $uriAst = if ($namedParameters.ContainsKey('Uri')) {
        $namedParameters['Uri'] 
    } elseif ($positional.Count -gt 0) {
        $positional[0] 
    } else {
        return $null 
    }
    $uri = [string](Get-StaticAstValue -Ast $uriAst)

    $headers = [ordered]@{}
    if ($namedParameters.ContainsKey('Headers')) {
        $headersAst = $namedParameters['Headers']
        if ($headersAst -isnot [System.Management.Automation.Language.HashtableAst]) {
            throw [System.NotSupportedException]::new('Headers must be a hashtable literal.')
        }
        foreach ($pair in $headersAst.KeyValuePairs) {
            $name = [string](Get-StaticAstValue -Ast $pair.Item1)
            $valueStatement = $pair.Item2
            if ($valueStatement -isnot [System.Management.Automation.Language.PipelineAst] -or
                $valueStatement.PipelineElements.Count -ne 1 -or
                $valueStatement.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
                throw [System.NotSupportedException]::new('Unsupported header value.')
            }
            $headers[$name] = [string](Get-StaticAstValue -Ast $valueStatement.PipelineElements[0].Expression)
        }
    }

    $body = if ($namedParameters.ContainsKey('Body')) {
        [string](Get-StaticAstValue -Ast $namedParameters['Body']) 
    } else {
        $null 
    }
    $contentType = if ($namedParameters.ContainsKey('ContentType')) {
        [string](Get-StaticAstValue -Ast $namedParameters['ContentType']) 
    } else {
        $null 
    }

    $method = if ($namedParameters.ContainsKey('Method')) {
        [string](Get-StaticAstValue -Ast $namedParameters['Method']) 
    } elseif ($headers.Contains('method')) {
        $headers['method'] 
    } elseif ($null -ne $body) {
        'Post' 
    } else {
        'Get' 
    }
    if ($method -notmatch '^[A-Za-z]{3,10}$') {
        throw [System.NotSupportedException]::new("Unsupported HTTP method '$method'.")
    }
    $method = $method.Substring(0, 1).ToUpperInvariant() + $method.Substring(1).ToLowerInvariant()

    [pscustomobject]@{
        Method      = $method
        Uri         = $uri
        Headers     = $headers
        Body        = $body
        ContentType = $contentType
    }
}

function ConvertFrom-DevToolsRequest {
    <#
    .SYNOPSIS
        Parses DevTools "Copy as PowerShell" text into request objects without executing it.
    .OUTPUTS
        One object per Invoke-WebRequest/Invoke-RestMethod call: Method, Uri, Headers, Body, ContentType.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Text
    )

    process {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            return
        }
        $commands = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in 'Invoke-WebRequest', 'iwr', 'Invoke-RestMethod', 'irm'
            }, $true)
        foreach ($command in $commands) {
            try {
                $request = ConvertTo-DevToolsRequestObject -Command $command
            } catch [System.NotSupportedException] {
                Write-Verbose "Skipped request: $($_.Exception.Message)"
                continue
            }
            if ($request) {
                $request
            }
        }
    }
}

function Get-JwtInfo {
    <#
    .SYNOPSIS
        Decodes JWT claims for display/expiry checks only. Signature is not verified. Returns $null for opaque tokens.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Token)

    $parts = ($Token -replace '^\s*Bearer\s+', '').Split('.')
    if ($parts.Count -ne 3) {
        return $null
    }
    try {
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 {
                $payload += '==' 
            }
            3 {
                $payload += '=' 
            }
        }
        $claims = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    } catch {
        return $null
    }

    $claim = {
        param($name)
        $property = $claims.PSObject.Properties[$name]
        if ($property) {
            $property.Value 
        }
    }
    $expires = $null
    $exp = & $claim 'exp'
    if ($null -ne $exp) {
        $expires = [DateTimeOffset]::FromUnixTimeSeconds([long]$exp)
    }
    $user = (& $claim 'upn') ?? (& $claim 'unique_name') ?? (& $claim 'preferred_username') ?? (& $claim 'appid')

    [pscustomobject]@{
        Audience = & $claim 'aud'
        User     = $user
        TenantId = & $claim 'tid'
        Scopes   = & $claim 'scp'
        Expires  = $expires
    }
}

function Test-DevToolsRequestText {
    <#
    .SYNOPSIS
        Strict, cheap detection used by the clipboard watcher: DevTools PowerShell output that targets Microsoft Graph.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 200000) {
        return $false
    }
    $startsLikeDevTools = $Text -match '(?s)\A\s*(\$session\s*=\s*New-Object\s+Microsoft\.PowerShell\.Commands\.WebRequestSession|Invoke-WebRequest\s)'
    $startsLikeDevTools -and ($Text -match 'graph\.microsoft\.(com|us)|microsoftgraph\.chinacloudapi\.cn')
}

#endregion

#region Formatting

function ConvertTo-DoubleQuotedLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $escaped = $Value.Replace('`', '``').Replace('$', '`$')
    $escaped = [regex]::Replace($escaped, '["\u201C\u201D\u201E\u201F]', { param($m) '`' + $m.Value })
    $escaped = $escaped.Replace("`r", '`r').Replace("`n", '`n').Replace("`t", '`t')
    '"' + $escaped + '"'
}

function ConvertTo-SingleQuotedLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    "'" + [regex]::Replace($Value, "['\u2018\u2019\u201A\u201B]", { param($m) $m.Value + $m.Value }) + "'"
}

function Format-GraphSnippet {
    <#
    .SYNOPSIS
        Builds a clean snippet from a parsed request. Authorization references the MSGRAPH_TOKEN variable of
        the selected scope, or embeds the token itself for Inline. Only the method, URI, body, content type
        and a small functional allowlist of headers are kept.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Request,
        [ValidateSet('Invoke-RestMethod', 'Invoke-RecurenceRestMethod')]
        [string]$Cmdlet = 'Invoke-RestMethod',
        [ValidateSet('Machine', 'User', 'Inline')]
        [string]$TokenStorage = $script:DefaultTokenStorage,
        [string]$Token
    )

    $nl = [Environment]::NewLine
    $hasBody = -not [string]::IsNullOrEmpty($Request.Body)
    if ($hasBody -and $Cmdlet -eq 'Invoke-RecurenceRestMethod') {
        $Cmdlet = 'Invoke-RestMethod' # Invoke-RecurenceRestMethod has no -Body
    }

    $preamble = ''
    $bodyExpression = $null
    if ($hasBody) {
        $isMultiline = $Request.Body -match "[\r\n]"
        $hereStringSafe = $Request.Body -notmatch "(?m)^'@"
        if (-not $isMultiline) {
            $bodyExpression = ConvertTo-SingleQuotedLiteral -Value $Request.Body
        } elseif ($hereStringSafe) {
            $normalized = $Request.Body -replace "`r`n|`r|`n", $nl
            $preamble = "`$body = @'$nl$normalized$nl'@$nl$nl"
            $bodyExpression = '$body'
        } else {
            $bodyExpression = ConvertTo-DoubleQuotedLiteral -Value $Request.Body
        }
    }

    $headerLines = [System.Collections.Generic.List[string]]::new()
    $authorization = if ($TokenStorage -eq 'Inline') {
        if ([string]::IsNullOrEmpty($Token)) {
            throw 'Inline token storage requires the token.'
        }
        ConvertTo-SingleQuotedLiteral -Value $Token
    } else {
        "[Environment]::GetEnvironmentVariable('$script:TokenVariableName', '$TokenStorage')"
    }
    $headerLines.Add("    Authorization = $authorization")
    foreach ($name in $Request.Headers.Keys) {
        $canonical = $script:KeptHeaders[$name.ToLowerInvariant()]
        if ($canonical) {
            $headerLines.Add("    $canonical = $(ConvertTo-SingleQuotedLiteral -Value $Request.Headers[$name])")
        }
    }

    $command = "$Cmdlet -Method $($Request.Method) -Uri $(ConvertTo-DoubleQuotedLiteral -Value $Request.Uri) -Headers @{$nl$($headerLines -join $nl)$nl}"
    if ($Request.ContentType -and ($hasBody -or $Request.Method -ne 'Get')) {
        $command += " -ContentType $(ConvertTo-DoubleQuotedLiteral -Value $Request.ContentType)"
    }
    if ($hasBody) {
        $command += " -Body $bodyExpression"
    }
    $preamble + $command
}

#endregion

#region Orchestration

function Convert-DevToolsRequest {
    <#
    .SYNOPSIS
        Full pure conversion: text in, status + snippet + token out. No clipboard, registry or UI access.
    .OUTPUTS
        Status: Converted | NotDevTools | NoGraphRequest | NoAuthorization | InvalidToken | Expired
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ValidateSet('Invoke-RestMethod', 'Invoke-RecurenceRestMethod')]
        [string]$Cmdlet = 'Invoke-RestMethod',
        [ValidateSet('Machine', 'User', 'Inline')]
        [string]$TokenStorage = $script:DefaultTokenStorage
    )

    $result = {
        param($status, $message, $snippet, $token, $info, $count)
        [pscustomobject]@{
            Status       = $status
            Message      = $message
            Snippet      = $snippet
            Token        = $token
            TokenInfo    = $info
            RequestCount = $count
        }
    }

    $requests = @(ConvertFrom-DevToolsRequest -Text $Text)
    if ($requests.Count -eq 0) {
        return & $result 'NotDevTools' 'Clipboard does not contain a DevTools PowerShell request.' $null $null $null 0
    }
    $graphRequests = @($requests | Where-Object {
            $uri = $null
            [uri]::TryCreate($_.Uri, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https' -and $uri.Host -match $script:GraphHostPattern
        })
    if ($graphRequests.Count -eq 0) {
        return & $result 'NoGraphRequest' 'No Microsoft Graph request found (host is not graph.microsoft.com).' $null $null 0
    }
    $authorized = @($graphRequests | Where-Object { $_.Headers.Contains('authorization') })
    if ($authorized.Count -eq 0) {
        return & $result 'NoAuthorization' 'The request has no authorization header.' $null $null $graphRequests.Count
    }

    $token = $authorized[0].Headers['authorization'].Trim()
    if ($token -notmatch $script:BearerPattern -or $token.Length -gt 16000) {
        return & $result 'InvalidToken' 'Authorization header is not a valid Bearer token.' $null $null $graphRequests.Count
    }
    $info = Get-JwtInfo -Token $token
    if ($info -and $info.Expires -and $info.Expires -le [DateTimeOffset]::UtcNow.AddSeconds(30)) {
        return & $result 'Expired' "Token already expired at $($info.Expires.LocalDateTime.ToString('HH:mm'))." $null $null $graphRequests.Count
    }

    $snippet = ($graphRequests | ForEach-Object { Format-GraphSnippet -Request $_ -Cmdlet $Cmdlet -TokenStorage $TokenStorage -Token $token }) -join ([Environment]::NewLine * 2)
    & $result 'Converted' 'Converted.' $snippet $token $info $graphRequests.Count
}

function Get-GraphClipTokenStorage {
    <#
    .SYNOPSIS
        Returns the current user's token storage mode: Machine (default), User or Inline.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        if (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf) {
            $mode = (Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json).TokenStorage
            if ($mode -in $script:TokenStorageModes) {
                return [string]$mode
            }
        }
    } catch {
        Write-Verbose "Settings read failed: $($_.Exception.Message)"
    }
    $script:DefaultTokenStorage
}

function Set-GraphClipTokenStorage {
    <#
    .SYNOPSIS
        Saves the current user's token storage mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User', 'Inline')]
        [string]$Mode
    )

    New-Item -ItemType Directory -Path (Split-Path $script:SettingsPath) -Force | Out-Null
    [pscustomobject]@{ TokenStorage = $Mode } | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

function Get-MsGraphUserToken {
    [CmdletBinding()]
    param()
    [Environment]::GetEnvironmentVariable($script:TokenVariableName, 'User')
}

function Set-MsGraphUserToken {
    <#
    .SYNOPSIS
        Stores the token in the current user's MSGRAPH_TOKEN environment variable.
    .OUTPUTS
        Status: Unchanged | Updated | Error
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Token)

    if ((Get-MsGraphUserToken) -ceq $Token) {
        return [pscustomobject]@{ Status = 'Unchanged'; Message = 'Token already up to date.' }
    }

    try {
        [Environment]::SetEnvironmentVariable($script:TokenVariableName, $Token, 'User')
        [pscustomobject]@{ Status = 'Updated'; Message = 'Token saved to the current user environment.' }
    } catch {
        [pscustomobject]@{ Status = 'Error'; Message = $_.Exception.Message }
    }
}

function Get-MsGraphMachineToken {
    [CmdletBinding()]
    param()
    [Environment]::GetEnvironmentVariable($script:TokenVariableName, 'Machine')
}

function Test-GraphClipElevated {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Import-MsGraphMachineToken {
    <#
    .SYNOPSIS
        Elevated half of Set-MsGraphMachineToken: moves a validated token from a pending file into the
        MSGRAPH_TOKEN machine variable. Accepts nothing but a strictly formatted "Bearer <token>" value.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PendingPath)

    if ($PendingPath -notlike '*\AppData\Local\GraphClip\pending.token') {
        throw 'Unexpected pending file path.'
    }
    $file = Get-Item -LiteralPath $PendingPath
    $rejected = $file.LinkType -or $file.Length -gt 20000
    $token = if ($rejected) {
        ''
    } else {
        [IO.File]::ReadAllText($PendingPath).Trim()
    }
    Remove-Item -LiteralPath $PendingPath -Force
    if ($rejected) {
        throw 'Pending file rejected (link or too large).'
    }
    if ($token -notmatch $script:BearerPattern -or $token.Length -gt 16000) {
        throw 'Pending token has an invalid format.'
    }
    [Environment]::SetEnvironmentVariable($script:TokenVariableName, $token, 'Machine')
}

function Get-MachineTokenElevationArgument {
    # pwsh arguments for the elevated process that imports a pending token into the machine variable.
    param([Parameter(Mandatory)][string]$PendingPath)

    $modulePath = Join-Path $PSScriptRoot 'GraphClip.psm1'
    $command = "try {{ Import-Module -Name '{0}' -Force; Import-MsGraphMachineToken -PendingPath '{1}'; exit 0 }} catch {{ exit 1 }}" -f
    $modulePath.Replace("'", "''"), $PendingPath.Replace("'", "''")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
}

function Set-MsGraphMachineToken {
    <#
    .SYNOPSIS
        Stores the token in the MSGRAPH_TOKEN machine variable.
    .DESCRIPTION
        Writing a machine variable requires administrator rights. In order of preference this:
          1. writes directly when the current process is already elevated;
          2. runs the GraphClip-SetToken scheduled task when it exists (pre-MSI installations, no prompt);
          3. starts an elevated PowerShell through a UAC prompt.
    .OUTPUTS
        Status: Unchanged | Updated | Timeout | Error
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [string]$PendingPath = $script:PendingTokenPath,
        [string]$TaskName = $script:TaskName,
        [int]$TimeoutSec = 10
    )

    if ((Get-MsGraphMachineToken) -ceq $Token) {
        return [pscustomobject]@{ Status = 'Unchanged'; Message = 'Token already up to date.' }
    }
    if ($Token -notmatch $script:BearerPattern -or $Token.Length -gt 16000) {
        return [pscustomobject]@{ Status = 'Error'; Message = 'Token has an invalid format.' }
    }

    try {
        if (Test-GraphClipElevated) {
            [Environment]::SetEnvironmentVariable($script:TokenVariableName, $Token, 'Machine')
            return [pscustomobject]@{ Status = 'Updated'; Message = 'Token saved to machine variable.' }
        }

        New-Item -ItemType Directory -Path (Split-Path $PendingPath) -Force | Out-Null
        [IO.File]::WriteAllText($PendingPath, $Token, [Text.UTF8Encoding]::new($false))

        # schtasks.exe is far faster than the ScheduledTasks CIM cmdlets (~0.1 s vs several seconds).
        $null = & schtasks.exe /Query /TN $TaskName 2>&1
        if ($LASTEXITCODE -eq 0) {
            $null = & schtasks.exe /Run /TN $TaskName 2>&1
            if ($LASTEXITCODE -ne 0) {
                return [pscustomobject]@{ Status = 'Error'; Message = "Could not start scheduled task '$TaskName'." }
            }
        } else {
            $process = Start-Process -FilePath ([Environment]::ProcessPath) -Verb RunAs -WindowStyle Hidden -Wait -PassThru `
                -ArgumentList (Get-MachineTokenElevationArgument -PendingPath $PendingPath)
            if ($process.ExitCode -ne 0) {
                return [pscustomobject]@{ Status = 'Error'; Message = "Elevated token update failed (exit code $($process.ExitCode))." }
            }
        }

        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ((Get-MsGraphMachineToken) -ceq $Token) {
                return [pscustomobject]@{ Status = 'Updated'; Message = 'Token saved to machine variable.' }
            }
            Start-Sleep -Milliseconds 200
        }
        [pscustomobject]@{ Status = 'Timeout'; Message = "Token was not applied within $TimeoutSec s (administrator rights are required)." }
    } catch {
        [pscustomobject]@{ Status = 'Error'; Message = $_.Exception.Message }
    } finally {
        Remove-Item -LiteralPath $PendingPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-GraphClipConversion {
    <#
    .SYNOPSIS
        Shared flow for the hotkey and the watcher: convert, store the token, return what to put on the clipboard and what to tell the user.
    .PARAMETER TokenStorage
        Overrides the user's saved token storage mode.
    .OUTPUTS
        Success ($true when a snippet was produced), Level (Info/Warning), Message, Snippet, Status.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ValidateSet('Invoke-RestMethod', 'Invoke-RecurenceRestMethod')]
        [string]$Cmdlet = 'Invoke-RestMethod',
        [ValidateSet('Machine', 'User', 'Inline')]
        [string]$TokenStorage
    )

    if (-not $TokenStorage) {
        $TokenStorage = Get-GraphClipTokenStorage
    }
    $converted = Convert-DevToolsRequest -Text $Text -Cmdlet $Cmdlet -TokenStorage $TokenStorage
    if ($converted.Status -ne 'Converted') {
        return [pscustomobject]@{ Success = $false; Level = 'Warning'; Message = $converted.Message; Snippet = $null; Status = $converted.Status }
    }

    $saved = switch ($TokenStorage) {
        'Machine' { Set-MsGraphMachineToken -Token $converted.Token }
        'User' { Set-MsGraphUserToken -Token $converted.Token }
        'Inline' { [pscustomobject]@{ Status = 'Inline'; Message = 'Token embedded in the snippet.' } }
    }
    $details = @()
    if ($converted.TokenInfo -and $converted.TokenInfo.User) {
        $details += $converted.TokenInfo.User
    }
    if ($converted.TokenInfo -and $converted.TokenInfo.Expires) {
        $details += "valid until $($converted.TokenInfo.Expires.LocalDateTime.ToString('HH:mm'))"
    }
    $suffix = if ($details) {
        " ($($details -join ', '))"
    } else {
        ''
    }

    if ($saved.Status -in 'Updated', 'Unchanged', 'Inline') {
        $level = 'Info'
        $message = switch ($TokenStorage) {
            'Machine' { "Ready$suffix. Token saved in machine variable $script:TokenVariableName." }
            'User' { "Ready$suffix. Token saved in user variable $script:TokenVariableName." }
            'Inline' { "Ready$suffix. Token embedded in the snippet." }
        }
    } else {
        $level = 'Warning'
        $message = "Snippet ready, but the token was NOT saved: $($saved.Message)"
    }
    [pscustomobject]@{ Success = $true; Level = $level; Message = $message; Snippet = $converted.Snippet; Status = $saved.Status; TokenStorage = $TokenStorage }
}

#endregion

#region Logging and notifications

function Write-GraphClipLog {
    # Never pass tokens or request contents here.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)

    try {
        New-Item -ItemType Directory -Path $script:AppDataDir -Force | Out-Null
        $file = Get-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue
        if ($file -and $file.Length -gt 512KB) {
            Move-Item -LiteralPath $script:LogPath -Destination "$script:LogPath.old" -Force
        }
        Add-Content -LiteralPath $script:LogPath -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) -Encoding UTF8
    } catch {
        Write-Verbose "Log write failed: $($_.Exception.Message)"
    }
}

function Show-GraphClipBalloon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Title = 'GraphClip',
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info',
        [object]$NotifyIcon,
        [int]$DurationMs = 3500
    )

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $icon = [System.Windows.Forms.ToolTipIcon]::$Level
    if ($NotifyIcon) {
        $NotifyIcon.ShowBalloonTip($DurationMs, $Title, $Text, $icon)
        return
    }

    $temporary = [System.Windows.Forms.NotifyIcon]::new()
    try {
        $temporary.Icon = [System.Drawing.SystemIcons]::Information
        $temporary.Visible = $true
        $temporary.ShowBalloonTip($DurationMs, $Title, $Text, $icon)
        Start-Sleep -Milliseconds ($DurationMs + 300)
    } finally {
        $temporary.Visible = $false
        $temporary.Dispose()
    }
}

#endregion

Export-ModuleMember -Function ConvertFrom-DevToolsRequest, Format-GraphSnippet, Get-JwtInfo, Test-DevToolsRequestText,
Convert-DevToolsRequest, Get-GraphClipTokenStorage, Set-GraphClipTokenStorage, Get-MsGraphUserToken, Set-MsGraphUserToken,
Get-MsGraphMachineToken, Set-MsGraphMachineToken, Import-MsGraphMachineToken, Invoke-GraphClipConversion,
Write-GraphClipLog, Show-GraphClipBalloon
