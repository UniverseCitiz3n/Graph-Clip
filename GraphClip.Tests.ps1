#requires -Version 7.0
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GraphClip.psm1') -Force

    function New-FakeJwt {
        param([int]$ExpOffsetSec = 3600)
        $encode = { param($o) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        $exp = [DateTimeOffset]::UtcNow.AddSeconds($ExpOffsetSec).ToUnixTimeSeconds()
        "$(& $encode @{ alg = 'none' }).$(& $encode @{ aud = 'https://graph.microsoft.com'; upn = 'test@contoso.com'; exp = $exp }).fake_sig-1"
    }

    # Quotes a value like Edge DevTools does for PowerShell: double-quoted, backtick escapes, CR/LF as `r`n.
    function ConvertTo-DevToolsLiteral {
        param([string]$Value)
        $escaped = $Value.Replace('`', '``').Replace('$', '`$').Replace('"', '`"').Replace("`r", '`r').Replace("`n", '`n')
        '"' + $escaped + '"'
    }

    # Mirrors what Edge DevTools emits ("Copy as PowerShell").
    function New-DevToolsText {
        param(
            [string]$Token = "Bearer $(New-FakeJwt)",
            [string]$Uri = 'https://graph.microsoft.com/beta/deviceManagement/managedDevices(''bffbbc00-d09f-485a-95a8-2eb222b56830'')/deviceInventories(''ApplicationProperties'')?`$expand=instances(`$expand=Microsoft.Graph.deviceInventorySimpleItem/properties)',
            [string]$Method,
            [string]$Body,
            [switch]$BodyAsBytes,
            [hashtable]$ExtraHeaders = @{}
        )
        $methodArg = if ($Method) { " -Method `"$Method`"" } else { '' }
        $bodyArg = ''
        if ($Body) {
            $literal = ConvertTo-DevToolsLiteral -Value $Body
            $bodyValue = if ($BodyAsBytes) { "([System.Text.Encoding]::UTF8.GetBytes($literal))" } else { $literal }
            $bodyArg = " ``" + [Environment]::NewLine + "-Body $bodyValue"
        }
        $authHeader = if ($Token) { "  `"authorization`"=`"$Token`"" } else { '' }
        $extra = ($ExtraHeaders.GetEnumerator() | ForEach-Object { "  $(ConvertTo-DevToolsLiteral $_.Key)=$(ConvertTo-DevToolsLiteral $_.Value)" }) -join [Environment]::NewLine
        @"
`$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
`$session.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
Invoke-WebRequest -UseBasicParsing -Uri "$Uri"$methodArg ``
-WebSession `$session ``
-Headers @{
"authority"="graph.microsoft.com"
  "method"="GET"
  "path"="/beta/x"
  "scheme"="https"
  "accept"="*/*"
$authHeader
  "origin"="https://intune.microsoft.com"
  "sec-ch-ua"="``"Not-A.Brand``";v=``"99``", ``"Microsoft Edge``";v=``"157``""
  "sec-ms-gec"="ABC"
$extra
} ``
-ContentType "application/json"$bodyArg
"@
    }
}

Describe 'ConvertFrom-DevToolsRequest' {
    It 'extracts uri, method, headers and ignores session lines' {
        $request = @(ConvertFrom-DevToolsRequest -Text (New-DevToolsText))
        $request.Count | Should -Be 1
        $request[0].Method | Should -Be 'Get'
        $request[0].Uri | Should -BeLike "https://graph.microsoft.com/beta/deviceManagement/managedDevices('*')/deviceInventories('ApplicationProperties')?`$expand=instances(`$expand=*)"
        $request[0].Headers.Contains('Authorization') | Should -BeTrue
    }

    It 'reads the method from -Method and falls back to the method header' {
        (ConvertFrom-DevToolsRequest -Text (New-DevToolsText -Method 'PATCH' -Body '{}')).Method | Should -Be 'Patch'
        (ConvertFrom-DevToolsRequest -Text (New-DevToolsText)).Method | Should -Be 'Get'
    }

    It 'unwraps [System.Text.Encoding]::UTF8.GetBytes bodies' {
        $body = '{"name":"zażółć","price":"$5"}'
        $request = ConvertFrom-DevToolsRequest -Text (New-DevToolsText -Method 'POST' -Body $body -BodyAsBytes)
        $request.Body | Should -BeExactly $body
    }

    It 'returns one object per request' {
        $text = (New-DevToolsText) + [Environment]::NewLine + (New-DevToolsText -Method 'DELETE')
        @(ConvertFrom-DevToolsRequest -Text $text).Count | Should -Be 2
    }

    It 'never executes code embedded in the text' {
        $marker = Join-Path $TestDrive 'pwned.txt'
        $evil = (New-DevToolsText -Uri 'https://graph.microsoft.com/v1.0/me') + "`nNew-Item -Path '$marker' -ItemType File"
        $null = ConvertFrom-DevToolsRequest -Text $evil
        $null = Convert-DevToolsRequest -Text $evil
        $marker | Should -Not -Exist
    }

    It 'skips requests whose values need evaluation' {
        $text = 'Invoke-WebRequest -Uri "https://graph.microsoft.com/v1.0/$(New-Item -Path C:\nope -ItemType File)" -Headers @{ "authorization"="Bearer abc" }'
        @(ConvertFrom-DevToolsRequest -Text $text).Count | Should -Be 0
    }

    It 'returns nothing for text that does not parse' {
        @(ConvertFrom-DevToolsRequest -Text 'Invoke-WebRequest -Uri "unterminated').Count | Should -Be 0
    }
}

Describe 'Convert-DevToolsRequest' {
    It 'produces a snippet without token or noisy headers' {
        $jwt = New-FakeJwt
        $result = Convert-DevToolsRequest -Text (New-DevToolsText -Token "Bearer $jwt")
        $result.Status | Should -Be 'Converted'
        $result.Token | Should -Be "Bearer $jwt"
        $result.Snippet | Should -Match '^Invoke-RestMethod -Method Get -Uri "https://graph\.microsoft\.com/beta/'
        $result.Snippet | Should -Match "Authorization = \[Environment\]::GetEnvironmentVariable\('MSGRAPH_TOKEN', 'Machine'\)"
        $result.Snippet | Should -Not -Match 'WebSession|sec-ch|origin|accept|authority|\$session|Invoke-WebRequest'
        $result.Snippet.Contains($jwt) | Should -BeFalse
        $result.Snippet | Should -Not -Match '-ContentType'
    }

    It 'references the user variable or embeds the token according to the storage mode' {
        $jwt = New-FakeJwt
        $text = New-DevToolsText -Token "Bearer $jwt"
        $user = (Convert-DevToolsRequest -Text $text -TokenStorage User).Snippet
        $user | Should -Match "Authorization = \[Environment\]::GetEnvironmentVariable\('MSGRAPH_TOKEN', 'User'\)"
        $user.Contains($jwt) | Should -BeFalse
        $inline = (Convert-DevToolsRequest -Text $text -TokenStorage Inline).Snippet
        $inline | Should -Match ([regex]::Escape("Authorization = 'Bearer $jwt'"))
        $inline | Should -Not -Match 'GetEnvironmentVariable'
    }

    It 'keeps only the functional header allowlist' {
        $extra = @{ ConsistencyLevel = 'eventual'; prefer = 'odata.maxpagesize=999'; 'if-match' = 'W/"abc"' }
        $snippet = (Convert-DevToolsRequest -Text (New-DevToolsText -ExtraHeaders $extra)).Snippet
        $snippet | Should -Match "ConsistencyLevel = 'eventual'"
        $snippet | Should -Match "Prefer = 'odata\.maxpagesize=999'"
        $snippet | Should -Match "If-Match = 'W/`"abc`"'"
    }

    It 'matches the authorization header regardless of case' {
        $text = New-DevToolsText -Token $null -ExtraHeaders @{ Authorization = "Bearer $(New-FakeJwt)" }
        (Convert-DevToolsRequest -Text $text).Status | Should -Be 'Converted'
    }

    It 'accepts opaque (non-JWT) bearer tokens' {
        $result = Convert-DevToolsRequest -Text (New-DevToolsText -Token 'Bearer jTx18J06C0YJkFWFSLA4_suM2EGgVQKjvaq4_LKG9')
        $result.Status | Should -Be 'Converted'
        $result.TokenInfo | Should -BeNullOrEmpty
    }

    It 'keeps content type and body for POST' {
        $result = Convert-DevToolsRequest -Text (New-DevToolsText -Method 'POST' -Body '{"displayName":"x"}')
        $result.Snippet | Should -Match '-Method Post '
        $result.Snippet | Should -Match '-ContentType "application/json"'
        $result.Snippet | Should -Match ([regex]::Escape('-Body ''{"displayName":"x"}'''))
    }

    It 'uses a here-string for multi-line bodies' {
        $result = Convert-DevToolsRequest -Text (New-DevToolsText -Method 'POST' -Body "{`n  `"a`": 1`n}")
        $result.Snippet | Should -Match "(?s)^\`$body = @'.*'@.*-Body \`$body$"
    }

    It 'falls back from Invoke-RecurenceRestMethod when a body is present' {
        $get = Convert-DevToolsRequest -Text (New-DevToolsText) -Cmdlet Invoke-RecurenceRestMethod
        $get.Snippet | Should -Match '^Invoke-RecurenceRestMethod '
        $post = Convert-DevToolsRequest -Text (New-DevToolsText -Method 'POST' -Body '{}') -Cmdlet Invoke-RecurenceRestMethod
        $post.Snippet | Should -Match '^Invoke-RestMethod '
    }

    It 'rejects requests that are not for Microsoft Graph' {
        $text = New-DevToolsText -Uri 'https://api.manage.microsoft.com/x' -Token "Bearer $(New-FakeJwt)"
        (Convert-DevToolsRequest -Text $text).Status | Should -Be 'NoGraphRequest'
    }

    It 'rejects lookalike hosts' {
        $text = New-DevToolsText -Uri 'https://graph.microsoft.com.evil.example/v1.0/me'
        (Convert-DevToolsRequest -Text $text).Status | Should -Be 'NoGraphRequest'
    }

    It 'reports a missing authorization header' {
        (Convert-DevToolsRequest -Text (New-DevToolsText -Token $null)).Status | Should -Be 'NoAuthorization'
    }

    It 'rejects malformed tokens' {
        (Convert-DevToolsRequest -Text (New-DevToolsText -Token 'Basic abc')).Status | Should -Be 'InvalidToken'
        (Convert-DevToolsRequest -Text (New-DevToolsText -Token 'Bearer a b;calc')).Status | Should -Be 'InvalidToken'
    }

    It 'rejects expired tokens' {
        $result = Convert-DevToolsRequest -Text (New-DevToolsText -Token "Bearer $(New-FakeJwt -ExpOffsetSec -600)")
        $result.Status | Should -Be 'Expired'
        $result.Snippet | Should -BeNullOrEmpty
    }

    It 'ignores arbitrary clipboard text' {
        (Convert-DevToolsRequest -Text 'just some text').Status | Should -Be 'NotDevTools'
        (Convert-DevToolsRequest -Text '').Status | Should -Be 'NotDevTools'
    }
}

Describe 'Format-GraphSnippet round trip' {
    BeforeEach {
        Mock Invoke-RestMethod { }
    }

    It 'reproduces uri and body exactly after execution' -ForEach @(
        @{ Name = 'dollar and quotes'; Uri = 'https://graph.microsoft.com/v1.0/users?$filter=startswith(displayName,''a'')&$top=5'; Body = '{"a":"it''s $x `y"}' }
        @{ Name = 'smart quotes'; Uri = ('https://graph.microsoft.com/v1.0/me?x=' + [char]0x201C + 'q' + [char]0x201D); Body = ('{"a":"' + [char]0x2018 + 'b' + [char]0x2019 + ' ' + [char]0x201C + 'c' + [char]0x201D + '"}') }
        @{ Name = 'multi-line'; Uri = 'https://graph.microsoft.com/v1.0/me'; Body = "{`r`n  `"a`": `"b`"`r`n}" }
        @{ Name = 'here-string terminator inside'; Uri = 'https://graph.microsoft.com/v1.0/me'; Body = "line1`n'@ tricky`nline3" }
    ) {
        $request = [pscustomobject]@{
            Method      = 'Post'
            Uri         = $Uri
            Headers     = [ordered]@{ authorization = 'Bearer x' }
            Body        = $Body
            ContentType = 'application/json'
        }
        $snippet = Format-GraphSnippet -Request $request
        Invoke-Expression $snippet
        $expectedBody = $Body -replace "`r`n|`r|`n", [Environment]::NewLine
        if ($Body -match "'@") {
            $expectedBody = $Body
        }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -ceq $request.Uri -and $Method -eq 'Post' -and $ContentType -eq 'application/json' -and
            ($Body -replace "`r`n|`r|`n", "`n") -ceq ($expectedBody -replace "`r`n|`r|`n", "`n")
        }
    }
}

Describe 'Test-DevToolsRequestText' {
    It 'matches DevTools output for Graph' {
        Test-DevToolsRequestText -Text (New-DevToolsText) | Should -BeTrue
    }
    It 'matches a bare Invoke-WebRequest for Graph' {
        Test-DevToolsRequestText -Text 'Invoke-WebRequest -Uri "https://graph.microsoft.com/v1.0/me"' | Should -BeTrue
    }
    It 'ignores everything else, including its own output' {
        Test-DevToolsRequestText -Text 'hello' | Should -BeFalse
        Test-DevToolsRequestText -Text $null | Should -BeFalse
        Test-DevToolsRequestText -Text 'Invoke-WebRequest -Uri "https://example.com"' | Should -BeFalse
        Test-DevToolsRequestText -Text (Convert-DevToolsRequest -Text (New-DevToolsText)).Snippet | Should -BeFalse
    }
}

Describe 'Get-JwtInfo' {
    It 'decodes user and expiry' {
        $info = Get-JwtInfo -Token "Bearer $(New-FakeJwt)"
        $info.User | Should -Be 'test@contoso.com'
        $info.Audience | Should -Be 'https://graph.microsoft.com'
        $info.Expires | Should -BeGreaterThan ([DateTimeOffset]::UtcNow)
    }
    It 'returns null for opaque tokens' {
        Get-JwtInfo -Token 'Bearer abc.def' | Should -BeNullOrEmpty
    }
}

Describe 'Set-MsGraphUserToken' {
    It 'writes to the current user scope without changing the machine variable' {
        $originalUser = [Environment]::GetEnvironmentVariable('MSGRAPH_TOKEN', 'User')
        $originalMachine = [Environment]::GetEnvironmentVariable('MSGRAPH_TOKEN', 'Machine')
        try {
            $result = Set-MsGraphUserToken -Token 'Bearer test.value.x'
            $result.Status | Should -Be 'Updated'
            [Environment]::GetEnvironmentVariable('MSGRAPH_TOKEN', 'User') | Should -Be 'Bearer test.value.x'
            [Environment]::GetEnvironmentVariable('MSGRAPH_TOKEN', 'Machine') | Should -Be $originalMachine
        } finally {
            [Environment]::SetEnvironmentVariable('MSGRAPH_TOKEN', $originalUser, 'User')
        }
    }
}

Describe 'Token storage setting' {
    BeforeAll {
        $settingsPath = Join-Path $TestDrive 'GraphClip\settings.json'
        InModuleScope GraphClip -Parameters @{ Path = $settingsPath } { param($Path) $script:SettingsPath = $Path }
    }

    It 'defaults to Machine and persists the selected mode' {
        Get-GraphClipTokenStorage | Should -Be 'Machine'
        Set-GraphClipTokenStorage -Mode Inline
        Get-GraphClipTokenStorage | Should -Be 'Inline'
        Set-GraphClipTokenStorage -Mode User
        Get-GraphClipTokenStorage | Should -Be 'User'
    }

    It 'falls back to Machine for an invalid saved value' {
        Set-Content -LiteralPath $settingsPath -Value '{"TokenStorage":"Registry"}'
        Get-GraphClipTokenStorage | Should -Be 'Machine'
    }
}

Describe 'Import-MsGraphMachineToken' {
    It 'rejects unexpected paths and malformed tokens without writing the machine variable' {
        $badPath = Join-Path $TestDrive 'pending.token'
        Set-Content -LiteralPath $badPath -Value 'Bearer abc'
        { Import-MsGraphMachineToken -PendingPath $badPath } | Should -Throw '*Unexpected pending file path*'

        $pendingPath = Join-Path $TestDrive 'AppData\Local\GraphClip\pending.token'
        $null = New-Item -ItemType Directory -Path (Split-Path $pendingPath) -Force
        Set-Content -LiteralPath $pendingPath -Value 'Bearer a b;calc'
        { Import-MsGraphMachineToken -PendingPath $pendingPath } | Should -Throw '*invalid format*'
        $pendingPath | Should -Not -Exist
    }

    It 'is invoked by the generated elevation command line' {
        $pendingPath = Join-Path $TestDrive "it's\AppData\Local\GraphClip\pending.token"
        $null = New-Item -ItemType Directory -Path (Split-Path $pendingPath) -Force
        Set-Content -LiteralPath $pendingPath -Value 'Bearer a b;calc'
        $arguments = InModuleScope GraphClip -Parameters @{ Path = $pendingPath } {
            param($Path) Get-MachineTokenElevationArgument -PendingPath $Path
        }
        & ([Environment]::ProcessPath) @arguments
        $LASTEXITCODE | Should -Be 1
        $pendingPath | Should -Not -Exist
    }
}

Describe 'Invoke-GraphClipConversion' {
    BeforeAll {
        $settingsPath = Join-Path $TestDrive 'GraphClip\settings.json'
        InModuleScope GraphClip -Parameters @{ Path = $settingsPath } { param($Path) $script:SettingsPath = $Path }
    }

    It 'stores the token in the variable of the saved storage mode' {
        Mock -ModuleName GraphClip Set-MsGraphMachineToken { [pscustomobject]@{ Status = 'Updated'; Message = 'ok' } }
        Mock -ModuleName GraphClip Set-MsGraphUserToken { [pscustomobject]@{ Status = 'Updated'; Message = 'ok' } }
        Set-GraphClipTokenStorage -Mode Machine
        (Invoke-GraphClipConversion -Text (New-DevToolsText)).Message | Should -Match 'machine variable'
        Should -Invoke -ModuleName GraphClip Set-MsGraphMachineToken -Times 1 -Exactly
        Should -Invoke -ModuleName GraphClip Set-MsGraphUserToken -Times 0

        Set-GraphClipTokenStorage -Mode User
        (Invoke-GraphClipConversion -Text (New-DevToolsText)).Message | Should -Match 'user variable'
        Should -Invoke -ModuleName GraphClip Set-MsGraphUserToken -Times 1 -Exactly
    }

    It 'does not store the token anywhere in Inline mode' {
        Mock -ModuleName GraphClip Set-MsGraphMachineToken { throw 'must not be called' }
        Mock -ModuleName GraphClip Set-MsGraphUserToken { throw 'must not be called' }
        $jwt = New-FakeJwt
        $result = Invoke-GraphClipConversion -Text (New-DevToolsText -Token "Bearer $jwt") -TokenStorage Inline
        $result.Success | Should -BeTrue
        $result.Level | Should -Be 'Info'
        $result.Snippet.Contains($jwt) | Should -BeTrue
    }

    It 'returns a snippet and an Info message when the token was saved' {
        Mock -ModuleName GraphClip Set-MsGraphUserToken { [pscustomobject]@{ Status = 'Updated'; Message = 'ok' } }
        $result = Invoke-GraphClipConversion -Text (New-DevToolsText) -TokenStorage User
        $result.Success | Should -BeTrue
        $result.Level | Should -Be 'Info'
        $result.Snippet | Should -Match '^Invoke-RestMethod '
        $result.Snippet | Should -Not -Match 'Bearer'
    }

    It 'still returns the snippet but warns when the token could not be saved' {
        Mock -ModuleName GraphClip Set-MsGraphMachineToken { [pscustomobject]@{ Status = 'Error'; Message = 'write denied' } }
        $result = Invoke-GraphClipConversion -Text (New-DevToolsText) -TokenStorage Machine
        $result.Success | Should -BeTrue
        $result.Level | Should -Be 'Warning'
        $result.Message | Should -Match 'NOT saved'
    }

    It 'does not touch the token for text that is not a Graph request' {
        Mock -ModuleName GraphClip Set-MsGraphMachineToken { throw 'must not be called' }
        Mock -ModuleName GraphClip Set-MsGraphUserToken { throw 'must not be called' }
        $result = Invoke-GraphClipConversion -Text 'just some text'
        $result.Success | Should -BeFalse
        $result.Snippet | Should -BeNullOrEmpty
        Should -Invoke -ModuleName GraphClip Set-MsGraphMachineToken -Times 0
        Should -Invoke -ModuleName GraphClip Set-MsGraphUserToken -Times 0
    }
}
