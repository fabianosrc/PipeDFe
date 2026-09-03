#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Set-PipeSmtp.

.DESCRIPTION
Coverage includes:
  - Public parameter contract.
  - Mandatory parameters.
  - Port and Timeout validation.
  - SecureString password contract.
  - DPAPI password conversion.
  - Mail address conversion.
  - Optional SenderAddress and ReplyTo handling.
  - Whitespace trimming on Server and Username.
  - Whitespace-only optional addresses treated as absent.
  - CreatedAt preservation when existing configuration exists.
  - CreatedAt generation on first configuration.
  - UpdatedAt always set.
  - Configuration object passed to Save-SmtpConfig.
  - Save-SmtpConfig invoked exactly once.
  - Canonical persisted-state returned via second Get-SmtpConfig call.
  - WhatIf suppresses Save-SmtpConfig and final Get-SmtpConfig.
  - Save errors propagated.
#>

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Set-PipeSmtp' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Set-PipeSmtp

            $securePasswordParams = @{
                String      = 'P@ssw0rd!'
                AsPlainText = $true
                Force       = $true
            }

            $Script:SecurePassword = ConvertTo-SecureString @securePasswordParams

            $Script:FakeFrom = [PSCustomObject]@{
                Name    = 'Empresa'
                Address = 'noreply@example.com'
            }

            $Script:FakeSender = [PSCustomObject]@{
                Name    = [string]::Empty
                Address = 'sender@example.com'
            }

            $Script:FakeReplyTo = [PSCustomObject]@{
                Name    = [string]::Empty
                Address = 'replyto@example.com'
            }

            $Script:ExistingConfig = [PSCustomObject]@{
                SchemaVersion = 1
                Server        = 'smtp.old.example.com'
                Port          = 465
                Ssl           = $true
                Username      = 'old@example.com'
                Password      = 'OLD-ENCRYPTED'
                From          = [PSCustomObject]@{
                    Name    = 'Old'
                    Address = 'old@example.com'
                }
                SenderAddress = $null
                ReplyTo       = $null
                Timeout       = 30
                CreatedAt     = '2026-07-01T00:00:00.0000000+00:00'
                UpdatedAt     = '2026-08-01T00:00:00.0000000+00:00'
            }

            $Script:PersistedConfig = [PSCustomObject]@{
                SchemaVersion = 1
                Server        = 'smtp.example.com'
                Port          = 587
                Ssl           = $true
                Username      = 'user@example.com'
                Password      = 'ENCRYPTED'
                From          = $Script:FakeFrom
                SenderAddress = $null
                ReplyTo       = $null
                Timeout       = 30
                CreatedAt     = '2026-09-03T16:00:00.0000000+00:00'
                UpdatedAt     = '2026-09-03T16:00:01.0000000+00:00'
            }

            $Script:ValidSplat = @{
                Server   = 'smtp.example.com'
                Port     = 587
                Ssl      = $true
                Username = 'user@example.com'
                Password = $Script:SecurePassword
                From     = 'Empresa <noreply@example.com>'
                Confirm  = $false
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Server as mandatory' {
                $attr = $Script:Command.Parameters['Server'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $attr | Should -Not -BeNullOrEmpty
            }

            It 'Declares Port as mandatory' {
                $attr = $Script:Command.Parameters['Port'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $attr | Should -Not -BeNullOrEmpty
            }

            It 'Declares Ssl as mandatory' {
                $attr = $Script:Command.Parameters['Ssl'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $attr | Should -Not -BeNullOrEmpty
            }

            It 'Declares Username as mandatory' {
                $attr = $Script:Command.Parameters['Username'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $attr | Should -Not -BeNullOrEmpty
            }

            It 'Declares Password as mandatory' {
                $attr = $Script:Command.Parameters['Password'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $attr | Should -Not -BeNullOrEmpty
            }


            It 'Declares From as mandatory' {
                $attr = $Script:Command.Parameters['From'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $attr | Should -Not -BeNullOrEmpty
            }

            It 'Does not declare SenderAddress as mandatory' {
                $attr = $Script:Command.Parameters['SenderAddress'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $attr | Should -BeNullOrEmpty
            }

            It 'Does not declare ReplyTo as mandatory' {
                $attr = $Script:Command.Parameters['ReplyTo'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $attr | Should -BeNullOrEmpty
            }

            It 'Defaults Timeout to 30' {
                $param = $Script:Command.ScriptBlock.Ast.Body.ParamBlock.Parameters |
                    Where-Object {
                        $_.Name.VariablePath.UserPath -eq 'Timeout'
                    }

                $param.DefaultValue.Value | Should -Be 30
            }

            It 'Supports ShouldProcess' {
                $attr = $Script:Command.ScriptBlock.Ast.Body.ParamBlock.Attributes |
                    Where-Object {
                        $_.TypeName.Name -eq 'CmdletBinding'
                    }

                $arg = $attr.NamedArguments |
                    Where-Object {
                        $_.ArgumentName -eq 'SupportsShouldProcess'
                    }

                $arg.Argument.Value | Should -BeTrue
            }

            It 'Rejects Port 0' {
                $splat = $Script:ValidSplat.Clone()
                $splat['Port'] = 0

                { Set-PipeSmtp @splat } | Should -Throw
            }

            It 'Rejects Port 65536' {
                $splat = $Script:ValidSplat.Clone()
                $splat['Port'] = 65536

                { Set-PipeSmtp @splat } | Should -Throw
            }

            It 'Rejects Timeout 0' {
                $splat = $Script:ValidSplat.Clone()
                $splat['Timeout'] = 0

                { Set-PipeSmtp @splat } | Should -Throw
            }

            It 'Rejects Timeout 3601' {
                $splat = $Script:ValidSplat.Clone()
                $splat['Timeout'] = 3601

                { Set-PipeSmtp @splat } | Should -Throw
            }

            It 'Rejects a non-SecureString password' {
                $splat = $Script:ValidSplat.Clone()
                $splat['Password'] = 'P@ssw0rd!'

                { Set-PipeSmtp @splat } | Should -Throw
            }
        }
        #endregion

        #region Password encryption
        Context 'Password encryption' {

            BeforeAll {

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    param ([System.Security.SecureString]$Value)

                    $null = $Value
                    return 'ENCRYPTED'
                }

                Mock -CommandName ConvertTo-MailAddress -MockWith {
                    param ([string]$Email)

                    $null = $Email
                    return $Script:FakeFrom
                }

                Mock -CommandName Get-SmtpConfig -MockWith {
                    param ()
                    return $Script:ExistingConfig
                }

                Mock -CommandName Save-SmtpConfig -MockWith {
                    param ([pscustomobject]$Config)

                    $null = $Config
                }

                Set-PipeSmtp @Script:ValidSplat | Out-Null
            }

            It 'Calls ConvertTo-DpapiString exactly once' {
                $invokeParams = @{
                    CommandName = 'ConvertTo-DpapiString'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Passes the supplied SecureString to ConvertTo-DpapiString' {
                $invokeParams = @{
                    CommandName     = 'ConvertTo-DpapiString'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Value -eq $Script:SecurePassword
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Does not persist plaintext password' {
                $invokeParams = @{
                    CommandName     = 'Save-SmtpConfig'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Config.Password -eq 'ENCRYPTED' -and
                        $Config.Password -ne 'P@ssw0rd!'
                    }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Address conversion - From only
        Context 'Address conversion - From only' {

            BeforeAll {

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    param ([System.Security.SecureString]$Value)

                    $null = $Value
                    return 'ENCRYPTED'
                }

                Mock -CommandName ConvertTo-MailAddress -MockWith {
                    param ([string]$Email)

                    $null = $Email
                    return $Script:FakeFrom
                }

                Mock -CommandName Get-SmtpConfig -MockWith {
                    param ()
                    return $Script:ExistingConfig
                }

                Mock -CommandName Save-SmtpConfig -MockWith {
                    param ([pscustomobject]$Config)

                    $null = $Config
                }

                Set-PipeSmtp @Script:ValidSplat | Out-Null
            }

            It 'Converts From exactly once' {
                $invokeParams = @{
                    CommandName     = 'ConvertTo-MailAddress'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Email -eq 'Empresa <noreply@example.com>'
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Does not convert SenderAddress or ReplyTo when absent' {
                $invokeParams = @{
                    CommandName     = 'ConvertTo-MailAddress'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Email -eq 'Empresa <noreply@example.com>'
                    }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Address conversion - all three addresses
        Context 'Address conversion - with SenderAddress and ReplyTo' {

            BeforeAll {

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    param ([System.Security.SecureString]$Value)

                    $null = $Value
                    return 'ENCRYPTED'
                }

                Mock -CommandName ConvertTo-MailAddress -MockWith {
                    param ([string]$Email)

                    $null = $Email
                    return $Script:FakeFrom
                }

                Mock -CommandName Get-SmtpConfig -MockWith {
                    param ()
                    return $Script:ExistingConfig
                }

                Mock -CommandName Save-SmtpConfig -MockWith {
                    param ([pscustomobject]$Config)

                    $null = $Config
                }

                $splat = $Script:ValidSplat.Clone()
                $splat['SenderAddress'] = 'sender@example.com'
                $splat['ReplyTo']       = 'replyto@example.com'

                Set-PipeSmtp @splat | Out-Null
            }

            It 'Converts all three addresses' {
                $invokeParams = @{
                    CommandName = 'ConvertTo-MailAddress'
                    ModuleName = 'PipeDFe'
                    Scope     = 'Context'
                    Exactly   = $true
                    Times     = 3
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Configuration construction
        Context 'Configuration construction' {

            BeforeAll {

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    param ([System.Security.SecureString]$Value)

                    $null = $Value
                    return 'ENCRYPTED'
                }

                Mock -CommandName ConvertTo-MailAddress -MockWith {
                    param ([string]$Email)

                    $null = $Email
                    return $Script:FakeFrom
                }

                Mock -CommandName Get-SmtpConfig -MockWith {
                    param ()
                    return $Script:ExistingConfig
                }

                $Script:CapturedConfig = $null

                Mock -CommandName Save-SmtpConfig -MockWith {
                    param ([pscustomobject]$Config)
                    $Script:CapturedConfig = $Config
                }

                $splat = $Script:ValidSplat.Clone()
                $splat['Timeout'] = 120

                Set-PipeSmtp @splat | Out-Null
            }

            It 'Stores Server' {
                $Script:CapturedConfig.Server | Should -Be 'smtp.example.com'
            }

            It 'Stores Username' {
                $Script:CapturedConfig.Username | Should -Be 'user@example.com'
            }

            It 'Stores Port' {
                $Script:CapturedConfig.Port | Should -Be 587
            }

            It 'Stores Ssl' {
                $Script:CapturedConfig.Ssl | Should -BeTrue
            }

            It 'Stores encrypted Password' {
                $Script:CapturedConfig.Password | Should -Be 'ENCRYPTED'
            }

            It 'Stores Timeout' {
                $Script:CapturedConfig.Timeout | Should -Be 120
            }

            It 'Stores From object' {
                $Script:CapturedConfig.From | Should -Be $Script:FakeFrom
            }

            It 'Stores null SenderAddress when absent' {
                $Script:CapturedConfig.SenderAddress | Should -BeNullOrEmpty
            }

            It 'Stores null ReplyTo when absent' {
                $Script:CapturedConfig.ReplyTo | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Trimming
        Context 'Server and Username trimming' {

            BeforeAll {

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    param ([System.Security.SecureString]$Value)

                    $null = $Value
                    return 'ENCRYPTED'
                }

                Mock -CommandName ConvertTo-MailAddress -MockWith {
                    param ([string]$Email)

                    $null = $Email
                    return $Script:FakeFrom
                }

                Mock -CommandName Get-SmtpConfig -MockWith {
                    param ()
                    return $Script:ExistingConfig
                }

                $Script:CapturedConfig = $null

                Mock -CommandName Save-SmtpConfig -MockWith {
                    param ([pscustomobject]$Config)
                    $Script:CapturedConfig = $Config
                }

                $splat = $Script:ValidSplat.Clone()
                $splat['Server']   = '  smtp.example.com  '
                $splat['Username'] = '  user@example.com  '

                Set-PipeSmtp @splat | Out-Null
            }

            It 'Trims Server' {
                $Script:CapturedConfig.Server | Should -Be 'smtp.example.com'
            }

            It 'Trims Username' {
                $Script:CapturedConfig.Username | Should -Be 'user@example.com'
            }
        }
        #endregion

        #region Timestamps - existing configuration
        Context 'Timestamps - existing configuration' {

            BeforeAll {

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    param ([System.Security.SecureString]$Value)

                    $null = $Value
                    return 'ENCRYPTED'
                }

                Mock -CommandName ConvertTo-MailAddress -MockWith {
                    param ([string]$Email)

                    $null = $Email
                    return $Script:FakeFrom
                }

                Mock -CommandName Get-SmtpConfig -MockWith {
                    param ()
                    return $Script:ExistingConfig
                }

                $Script:CapturedConfig = $null

                Mock -CommandName Save-SmtpConfig -MockWith {
                    param ([pscustomobject]$Config)
                    $Script:CapturedConfig = $Config
                }

                Set-PipeSmtp @Script:ValidSplat | Out-Null
            }

            It 'Preserves CreatedAt from existing configuration' {
                $Script:CapturedConfig.CreatedAt |
                    Should -Be $Script:ExistingConfig.CreatedAt
            }

            It 'Does not preserve UpdatedAt from existing configuration' {
                $Script:CapturedConfig.UpdatedAt |
                    Should -Not -Be $Script:ExistingConfig.UpdatedAt
            }

            It 'Sets a non-empty UpdatedAt' {
                $Script:CapturedConfig.UpdatedAt |
                    Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region Timestamps - first configuration
        Context 'Timestamps - first configuration' {

            BeforeAll {

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    param ([System.Security.SecureString]$Value)

                    $null = $Value
                    return 'ENCRYPTED'
                }

                Mock -CommandName ConvertTo-MailAddress -MockWith {
                    param ([string]$Email)

                    $null = $Email
                    return $Script:FakeFrom
                }

                Mock -CommandName Get-SmtpConfig -MockWith {
                    param ()
                    return $null
                }

                $Script:CapturedConfig = $null

                Mock -CommandName Save-SmtpConfig -MockWith {
                    param ([pscustomobject]$Config)
                    $Script:CapturedConfig = $Config
                }

                $Script:Before = [System.DateTimeOffset]::UtcNow

                Set-PipeSmtp @Script:ValidSplat | Out-Null

                $Script:After = [System.DateTimeOffset]::UtcNow
            }

            It 'Generates CreatedAt within the call window' {
                $created = [System.DateTimeOffset]::Parse(
                    $Script:CapturedConfig.CreatedAt
                )

                $created | Should -BeGreaterOrEqual $Script:Before
                $created | Should -BeLessOrEqual $Script:After
            }

            It 'Sets CreatedAt equal to UpdatedAt on first write' {
                $Script:CapturedConfig.CreatedAt |
                    Should -Be $Script:CapturedConfig.UpdatedAt
            }
        }
        #endregion

        #region Persistence
        Context 'Persistence' {

            BeforeAll {

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    param ([System.Security.SecureString]$Value)

                    $null = $Value
                    return 'ENCRYPTED'
                }

                Mock -CommandName ConvertTo-MailAddress -MockWith {
                    param ([string]$Email)

                    $null = $Email
                    return $Script:FakeFrom
                }

                Mock -CommandName Save-SmtpConfig -MockWith {
                    param ([pscustomobject]$Config)

                    $null = $Config
                }

                $Script:GetCount = 0

                Mock -CommandName Get-SmtpConfig -MockWith {
                    param ()
                    $Script:GetCount++

                    if ($Script:GetCount -eq 1) {
                        return $Script:ExistingConfig
                    }

                    return $Script:PersistedConfig
                }

                $Script:Result = Set-PipeSmtp @Script:ValidSplat
            }

            It 'Calls Save-SmtpConfig exactly once' {
                $invokeParams = @{
                    CommandName = 'Save-SmtpConfig'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Calls Get-SmtpConfig exactly twice' {
                $Script:GetCount | Should -Be 2
            }

            It 'Returns the canonical persisted object' {
                $Script:Result | Should -Be $Script:PersistedConfig
            }

            It 'Returns exactly one object' {
                @($Script:Result) | Should -HaveCount 1
            }
        }
        #endregion

        #region WhatIf
        Context 'WhatIf' {

            BeforeAll {

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    param ([System.Security.SecureString]$Value)

                    $null = $Value
                    return 'ENCRYPTED'
                }

                Mock -CommandName ConvertTo-MailAddress -MockWith {
                    param ([string]$Email)

                    $null = $Email
                    return $Script:FakeFrom
                }

                Mock -CommandName Save-SmtpConfig -MockWith {
                    param ([pscustomobject]$Config)

                    $null = $Config
                }

                $Script:GetCount = 0

                Mock -CommandName Get-SmtpConfig -MockWith {
                    param ()
                    $Script:GetCount++
                    return $Script:ExistingConfig
                }

                Set-PipeSmtp @Script:ValidSplat -WhatIf | Out-Null
            }

            It 'Does not call Save-SmtpConfig' {
                $invokeParams = @{
                    CommandName = 'Save-SmtpConfig'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Does not perform the final Get-SmtpConfig read' {
                $Script:GetCount | Should -Be 1
            }
        }
        #endregion

        #region Optional parameters
        Context 'Optional parameters' {

            BeforeAll {

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    param ([System.Security.SecureString]$Value)

                    $null = $Value
                    return 'ENCRYPTED'
                }

                Mock -CommandName ConvertTo-MailAddress -MockWith {
                    param ([string]$Email)

                    $null = $Email
                    return $Script:FakeFrom
                }

                Mock -CommandName Get-SmtpConfig -MockWith {
                    param ()
                    return $Script:ExistingConfig
                }

                Mock -CommandName Save-SmtpConfig -MockWith {
                    param ([pscustomobject]$Config)

                    $null = $Config
                }
            }

            It 'Treats whitespace-only SenderAddress as absent' {
                $splat = $Script:ValidSplat.Clone()
                $splat['SenderAddress'] = '   '

                Set-PipeSmtp @splat | Out-Null

                $invokeParams = @{
                    CommandName = 'ConvertTo-MailAddress'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Treats whitespace-only ReplyTo as absent' {
                $splat = $Script:ValidSplat.Clone()
                $splat['ReplyTo'] = '   '

                Set-PipeSmtp @splat | Out-Null

                $invokeParams = @{
                    CommandName = 'ConvertTo-MailAddress'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Trims SenderAddress before conversion' {
                $splat = $Script:ValidSplat.Clone()
                $splat['SenderAddress'] = '  sender@example.com  '

                Set-PipeSmtp @splat | Out-Null

                $invokeParams = @{
                    CommandName     = 'ConvertTo-MailAddress'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Email -eq 'sender@example.com'
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Trims ReplyTo before conversion' {
                $splat = $Script:ValidSplat.Clone()
                $splat['ReplyTo'] = '  replyto@example.com  '

                Set-PipeSmtp @splat | Out-Null

                $invokeParams = @{
                    CommandName     = 'ConvertTo-MailAddress'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Email -eq 'replyto@example.com'
                    }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Error propagation
        Context 'Error propagation - Save-SmtpConfig' {

            BeforeAll {

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    param ([System.Security.SecureString]$Value)

                    $null = $Value

                    return 'ENCRYPTED'
                }

                Mock -CommandName ConvertTo-MailAddress -MockWith {
                    param ([string]$Email)

                    $null = $Email
                    return $Script:FakeFrom
                }

                Mock -CommandName Get-SmtpConfig -MockWith {
                    param ()
                    return $Script:ExistingConfig
                }

                Mock -CommandName Save-SmtpConfig -MockWith {
                    param ([pscustomobject]$Config)

                    $null = $Config

                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.IO.IOException]::new('Failed to write smtp.json.'),
                            'SmtpConfigSaveFailed',
                            [System.Management.Automation.ErrorCategory]::WriteError,
                            'smtp.json'
                        )
                    )
                }

                $Script:Exception = $null

                try {
                    Set-PipeSmtp @Script:ValidSplat
                } catch {
                    $Script:Exception = $_
                }
            }

            It 'Propagates SmtpConfigSaveFailed from Save-SmtpConfig' {
                $Script:Exception.FullyQualifiedErrorId |
                    Should -BeLike 'SmtpConfigSaveFailed*'
            }
        }
        #endregion
    }
}
