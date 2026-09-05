#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Test-PipeSmtp.

.DESCRIPTION
Tests the public Test-PipeSmtp command against its real module contracts.

Coverage includes:
  - Parameter contract.
  - Default parameter set.
  - CNPJ validation.
  - Global SMTP resolution.
  - Global configuration failure.
  - Company SMTP resolution.
  - Global fallback through Resolve-DFeSmtp.
  - Direct configuration.
  - SMTP configuration validation.
  - Timeout defaulting.
  - DPAPI credential resolution.
  - SMTP client configuration.
  - Test message construction.
  - SMTP send.
  - FailureStage classification.
  - Structured result contract.
  - No unexpected exceptions.

The suite mocks only PowerShell commands used by Test-PipeSmtp.
.NET SMTP types are real objects and are not mocked.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingConvertToSecureStringWithPlainText',
    '',
    Justification = 'Plain text passwords are acceptable in test context.'
)]

param ()

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Test-PipeSmtp' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Test-PipeSmtp -ErrorAction Stop

            $secureStringParams = @{
                String      = 'P@ssw0rd!'
                AsPlainText = $true
                Force       = $true
            }

            $Script:FakeSecurePassword = ConvertTo-SecureString @secureStringParams

            $Script:FakeSmtpConfig = [PSCustomObject]@{
                SchemaVersion = 1
                Server        = 'smtp.example.com'
                Port          = 587
                Ssl           = $true
                Username      = 'user@example.com'
                Password      = 'AQAAANCMnd8BFdERjHoAwAw=='
                From          = [PSCustomObject]@{
                    Name  = 'Empresa'
                    Email = 'noreply@example.com'
                }
                SenderAddress = $null
                ReplyTo       = $null
                Timeout       = 30
                CreatedAt     = '2026-09-01T00:00:00.0000000+00:00'
                UpdatedAt     = '2026-09-01T00:00:00.0000000+00:00'
            }

            $Script:FakeCompanyWithSmtp = [PSCustomObject]@{
                Cnpj     = 'AB12CD34000195'
                IsActive = $true
                Smtp     = $Script:FakeSmtpConfig
            }

            $Script:FakeCompanyWithoutSmtp = [PSCustomObject]@{
                Cnpj     = 'AB12CD34000195'
                IsActive = $true
                Smtp     = $null
            }

            $Script:ExpectedProperties = @(
                'Success'
                'Source'
                'Server'
                'Port'
                'Authenticated'
                'ErrorMessage'
                'FailureStage'
            )
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Uses ByGlobal as the default parameter set' {
                $Script:Command.DefaultParameterSet | Should -Be 'ByGlobal'
            }

            It 'Declares Cnpj in ByCnpj' {
                $attr = $Script:Command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    }

                $attr.ParameterSetName | Should -Be 'ByCnpj'
            }

            It 'Declares SmtpConfig in ByConfig' {
                $attr = $Script:Command.Parameters['SmtpConfig'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    }

                $attr.ParameterSetName | Should -Be 'ByConfig'
            }

            It 'Does not make Cnpj mandatory' {
                $attr = $Script:Command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    }

                $attr.Mandatory | Should -BeFalse
            }

            It 'Does not make SmtpConfig mandatory' {
                $attr = $Script:Command.Parameters['SmtpConfig'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    }

                $attr.Mandatory | Should -BeFalse
            }

            It 'Declares SmtpConfig as PSCustomObject' {
                $Script:Command.Parameters['SmtpConfig'].ParameterType | Should -Be ([pscustomobject])
            }

            It 'Declares Cnpj as string' {
                $Script:Command.Parameters['Cnpj'].ParameterType | Should -Be ([string])
            }
        }
        #endregion

        #region CNPJ validation
        Context 'CNPJ validation' {

            It 'Accepts a valid uppercase alphanumeric CNPJ' {
                { Test-PipeSmtp -Cnpj 'AB12CD34000195' } | Should -Not -Throw
            }

            It 'Rejects lowercase CNPJ characters' {
                { Test-PipeSmtp -Cnpj 'ab12cd34000195' } | Should -Throw
            }

            It 'Rejects a CNPJ shorter than 14 characters' {
                { Test-PipeSmtp -Cnpj 'AB12CD3400019' } | Should -Throw
            }

            It 'Rejects a CNPJ longer than 14 characters' {
                { Test-PipeSmtp -Cnpj 'AB12CD340001950' } | Should -Throw
            }

            It 'Rejects special characters' {
                { Test-PipeSmtp -Cnpj 'AB12-CD34000195' } | Should -Throw
            }

            It 'Rejects spaces' {
                { Test-PipeSmtp -Cnpj 'AB12CD34 00195' } | Should -Throw
            }
        }
        #endregion

        #region ByGlobal
        Context 'ByGlobal' {

            BeforeEach {

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                }

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    param ([pscustomobject]$Company)
                    $null = $Company
                }

                Mock -CommandName Get-SmtpConfig -MockWith {
                    return $Script:FakeSmtpConfig
                }

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $null = $Client
                    $null = $Message
                }
            }

            It 'Resolves the global SMTP configuration' {
                $result = Test-PipeSmtp

                $result.Success | Should -BeTrue
                $result.Source  | Should -Be 'Global'
                $result.Server  | Should -Be 'smtp.example.com'
                $result.Port    | Should -Be 587
            }

            It 'Calls Get-SmtpConfig exactly once' {
                Test-PipeSmtp | Out-Null

                $invokeParams = @{
                    CommandName = 'Get-SmtpConfig'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Does not call company resolution' {
                Test-PipeSmtp | Out-Null

                $invokeParamsOne = @{
                    CommandName = 'Get-CompanyConfig'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                $invokeParamsTwo = @{
                    CommandName = 'Resolve-DFeSmtp'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParamsOne
                Should -Invoke @invokeParamsTwo
            }

            It 'Returns Authenticated true on successful send' {
                (Test-PipeSmtp).Authenticated | Should -BeTrue
            }

            It 'Returns no error on success' {
                $result = Test-PipeSmtp

                $result.ErrorMessage | Should -BeNullOrEmpty
                $result.FailureStage | Should -BeNullOrEmpty
            }

            It 'Returns a configuration failure when global resolution fails' {
                Mock -CommandName Get-SmtpConfig -MockWith {
                    throw 'smtp.json not found.'
                }

                $result = Test-PipeSmtp

                $result.Success      | Should -BeFalse
                $result.Source       | Should -Be 'Global'
                $result.FailureStage | Should -Be 'Configuration'
                $result.ErrorMessage | Should -Be 'smtp.json not found.'
            }

            It 'Never throws when global resolution fails' {
                Mock -CommandName Get-SmtpConfig -MockWith {
                    throw 'smtp.json not found.'
                }

                { Test-PipeSmtp } | Should -Not -Throw
            }

            It 'Returns configuration failure when global configuration is null' {
                Mock -CommandName Get-SmtpConfig -MockWith {
                    return $null
                }

                $result = Test-PipeSmtp

                $result.Success      | Should -BeFalse
                $result.Source       | Should -Be 'Global'
                $result.FailureStage | Should -Be 'Configuration'
                $result.ErrorMessage | Should -Be 'SMTP configuration not found.'
            }
        }
        #endregion

        #region ByCnpj - company SMTP
        Context 'ByCnpj - company SMTP' {

            BeforeEach {

                Mock -CommandName Get-SmtpConfig -MockWith {
                    return $Script:FakeSmtpConfig
                }

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $Value | Should -Be 'AB12CD34000195'
                    return 'AB12CD34000195'
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $Cnpj | Should -Be 'AB12CD34000195'
                    return $Script:FakeCompanyWithSmtp
                }

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    param ([pscustomobject]$Company)
                    $Company | Should -Be $Script:FakeCompanyWithSmtp
                    return $Script:FakeSmtpConfig
                }

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $null = $Client
                    $null = $Message
                }
            }

            It 'Normalizes the CNPJ exactly once' {
                Test-PipeSmtp -Cnpj 'AB12CD34000195' | Out-Null

                $invokeParams = @{
                    CommandName = 'ConvertTo-NormalizedCnpj'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Gets the company using the normalized CNPJ exactly once' {
                Test-PipeSmtp -Cnpj 'AB12CD34000195' | Out-Null

                $invokeParams = @{
                    CommandName = 'Get-CompanyConfig'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times      = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Resolves SMTP from the company exactly once' {
                Test-PipeSmtp -Cnpj 'AB12CD34000195' | Out-Null

                $invokeParams = @{
                    CommandName = 'Resolve-DFeSmtp'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Returns Company as Source' {
                (Test-PipeSmtp -Cnpj 'AB12CD34000195').Source | Should -Be 'Company'
            }

            It 'Returns the company SMTP server and port' {
                $result = Test-PipeSmtp -Cnpj 'AB12CD34000195'

                $result.Server | Should -Be 'smtp.example.com'
                $result.Port   | Should -Be 587
            }

            It 'Returns Success true' {
                (Test-PipeSmtp -Cnpj 'AB12CD34000195').Success | Should -BeTrue
            }

            It 'Does not resolve global SMTP configuration' {
                Test-PipeSmtp -Cnpj 'AB12CD34000195' | Out-Null

                $invokeParams = @{
                    CommandName = 'Get-SmtpConfig'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region ByCnpj - global fallback
        Context 'ByCnpj - global fallback' {

            BeforeEach {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return 'AB12CD34000195'
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return $Script:FakeCompanyWithoutSmtp
                }

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    param ([pscustomobject]$Company)
                    $null = $Company
                    Write-Warning -Message 'No company SMTP found. Falling back to global.'
                    return $Script:FakeSmtpConfig
                }

                Mock -CommandName Get-SmtpConfig -MockWith {
                    return $Script:FakeSmtpConfig
                }

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )
                    $null = $Client
                    $null = $Message
                }
            }

            It 'Uses the normalized CNPJ to obtain the company' {
                Test-PipeSmtp -Cnpj 'AB12CD34000195' | Out-Null

                $invokeParamsOne = @{
                    CommandName = 'ConvertTo-NormalizedCnpj'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                $invokeParamsTwo = @{
                    CommandName = 'Get-CompanyConfig'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParamsOne
                Should -Invoke @invokeParamsTwo
            }

            It 'Uses Resolve-DFeSmtp to resolve the effective configuration' {
                Test-PipeSmtp -Cnpj 'AB12CD34000195' | Out-Null

                $invokeParams = @{
                    CommandName = 'Resolve-DFeSmtp'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Returns Global as Source when Resolve-DFeSmtp falls back' {
                (Test-PipeSmtp -Cnpj 'AB12CD34000195').Source | Should -Be 'Global'
            }

            It 'Successfully tests the fallback configuration' {
                $result = Test-PipeSmtp -Cnpj 'AB12CD34000195'

                $result.Success       | Should -BeTrue
                $result.Server        | Should -Be 'smtp.example.com'
                $result.Port          | Should -Be 587
                $result.Authenticated | Should -BeTrue
            }
        }
        #endregion

        #region ByCnpj - resolution failure
        Context 'ByCnpj - resolution failure' {

            BeforeEach {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return 'AB12CD34000195'
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return $Script:FakeCompanyWithSmtp
                }

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    param ([pscustomobject]$Company)
                    $null = $Company
                    throw 'Company SMTP resolution failed.'
                }
            }

            It 'Never throws when company SMTP resolution fails' {
                { Test-PipeSmtp -Cnpj 'AB12CD34000195' } | Should -Not -Throw
            }

            It 'Returns Configuration as FailureStage' {
                $result = Test-PipeSmtp -Cnpj 'AB12CD34000195'

                $result.Success      | Should -BeFalse
                $result.Source       | Should -Be 'Global'
                $result.FailureStage | Should -Be 'Configuration'
                $result.ErrorMessage | Should -Be 'Company SMTP resolution failed.'
            }
        }
        #endregion

        #region ByCnpj - company not found
        Context 'ByCnpj - company not found' {

            BeforeEach {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return 'AB12CD34000195'
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    throw "Company not found: 'AB12CD34000195'"
                }
            }

            It 'Never throws when the company cannot be loaded' {
                { Test-PipeSmtp -Cnpj 'AB12CD34000195' } | Should -Not -Throw
            }

            It 'Returns Configuration failure' {
                $result = Test-PipeSmtp -Cnpj 'AB12CD34000195'

                $result.Success      | Should -BeFalse
                $result.Source       | Should -Be 'Global'
                $result.FailureStage | Should -Be 'Configuration'
                $result.ErrorMessage | Should -Be "Company not found: 'AB12CD34000195'"
            }
        }
        #endregion

        #region ByConfig
        Context 'ByConfig' {

            BeforeEach {

                Mock -CommandName Get-SmtpConfig -MockWith {
                    return $Script:FakeSmtpConfig
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                }

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    param ([pscustomobject]$Company)
                    $null = $Company
                }

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $null = $Client
                    $null = $Message
                }
            }

            It 'Uses Direct as Source' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Source | Should -Be 'Direct'
            }

            It 'Uses the supplied configuration' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Server | Should -Be 'smtp.example.com'
                $result.Port   | Should -Be 587
            }

            It 'Does not call Get-SmtpConfig' {
                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null

                $invokeParams = @{
                    CommandName = 'Get-SmtpConfig'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Does not call Get-CompanyConfig' {
                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null

                $invokeParams = @{
                    CommandName = 'Get-CompanyConfig'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Does not call Resolve-DFeSmtp' {
                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null

                $invokeParams = @{
                    CommandName = 'Resolve-DFeSmtp'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Returns Success true' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success | Should -BeTrue
            }
        }
        #endregion

        #region Configuration validation
        Context 'Configuration validation' {

            It 'Rejects an empty server' {
                $config        = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Server = [string]::Empty

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
                $result.ErrorMessage | Should -Be 'SMTP server is not configured.'
            }

            It 'Rejects whitespace-only server' {
                $config        = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Server = '   '

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
            }

            It 'Rejects port below 1' {
                $config      = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Port = 0

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
                $result.Port         | Should -Be 0
            }

            It 'Rejects port greater than 65535' {
                $config      = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Port = 65536

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
                $result.Port         | Should -Be 65536
            }

            It 'Rejects an empty username' {
                $config          = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Username = [string]::Empty

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
                $result.ErrorMessage | Should -Be 'SMTP username is not configured.'
            }

            It 'Rejects whitespace-only username' {
                $config          = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Username = '   '

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
            }

            It 'Rejects a null From object' {
                $config      = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.From = $null

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
                $result.ErrorMessage | Should -Be 'SMTP sender address is not configured.'
            }

            It 'Rejects an empty sender address' {
                $config      = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.From = [PSCustomObject]@{
                    Name  = 'Empresa'
                    Email = [string]::Empty
                }

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
                $result.ErrorMessage | Should -Be 'SMTP sender address is not configured.'
            }

            It 'Rejects an invalid sender address' {
                $config      = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.From = [PSCustomObject]@{
                    Name  = 'Empresa'
                    Email = 'not-an-email'
                }

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
                $result.ErrorMessage | Should -Be "SMTP sender address 'not-an-email' is invalid."
            }

            It 'Accepts a valid sender address' {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $null = $Client
                    $null = $Message
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Success | Should -BeTrue
            }

            It 'Uses 30 seconds when Timeout is zero' {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $Client.Timeout | Should -Be 30000
                    $null = $Message
                }

                $config         = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Timeout = 0

                $result = Test-PipeSmtp -SmtpConfig $config
                $result.Success | Should -BeTrue
            }

            It 'Uses 30 seconds when Timeout is negative' {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $Client.Timeout | Should -Be 30000
                    $null = $Message
                }

                $config         = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Timeout = -1

                $result = Test-PipeSmtp -SmtpConfig $config
                $result.Success | Should -BeTrue
            }

            It 'Uses the configured timeout when greater than zero' {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $Client.Timeout | Should -Be 45000
                    $null = $Message
                }

                $config         = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Timeout = 45

                $result = Test-PipeSmtp -SmtpConfig $config
                $result.Success | Should -BeTrue
            }
        }
        #endregion

        #region Credential handling
        Context 'Credential handling' {

            It 'Calls ConvertFrom-DpapiString exactly once' {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $null = $Client
                    $null = $Message
                }

                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null

                $invokeParams = @{
                    CommandName = 'ConvertFrom-DpapiString'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Passes the configured encrypted password to the DPAPI helper' {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    param ([string]$Value)
                    $Value | Should -Be $Script:FakeSmtpConfig.Password
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $null = $Client
                    $null = $Message
                }

                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null
            }

            It 'Returns Credentials failure when DPAPI decryption fails' {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    throw 'DPAPI decryption failed.'
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success       | Should -BeFalse
                $result.Authenticated | Should -BeFalse
                $result.FailureStage  | Should -Be 'Credentials'
                $result.ErrorMessage  | Should -Be 'DPAPI decryption failed.'
            }

            It 'Does not expose the password when credential resolution fails' {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    throw "Authentication failed for password $($Script:FakeSecurePassword)"
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.ErrorMessage | Should -Not -Match 'P@ssw0rd!'
                $result.ErrorMessage | Should -Not -Match 'AQAAANCMnd8BFdERjHoAwAw=='
            }
        }
        #endregion

        #region SMTP client
        Context 'SMTP client' {

            BeforeEach {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }
            }

            It 'Configures the SMTP server and port' {

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $Client.Host | Should -Be 'smtp.example.com'
                    $Client.Port | Should -Be 587
                    $null = $Message
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Success | Should -BeTrue
            }

            It 'Uses SSL when configured' {

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $Client.EnableSsl | Should -BeTrue
                    $null = $Message
                }

                (Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig).Success | Should -BeTrue
            }

            It 'Uses network delivery' {

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $Client.DeliveryMethod |
                        Should -Be ([System.Net.Mail.SmtpDeliveryMethod]::Network)

                    $null = $Message
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Success | Should -BeTrue
            }

            It 'Disables default credentials' {

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $Client.UseDefaultCredentials | Should -BeFalse
                    $null = $Message
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Success | Should -BeTrue
            }

            It 'Configures explicit SMTP credentials' {

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $Client.Credentials | Should -Not -BeNullOrEmpty
                    $null = $Message
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Success | Should -BeTrue
            }
        }
        #endregion

        #region SMTP message
        Context 'SMTP message' {

            BeforeEach {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }
            }

            It 'Sends from the configured sender' {

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $Message.From.Address | Should -Be 'noreply@example.com'
                    $null = $Client
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Success | Should -BeTrue
            }

            It 'Sends to the sender itself' {

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $Message.To.Count      | Should -Be 1
                    $Message.To[0].Address | Should -Be 'noreply@example.com'
                    $null = $Client
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Success | Should -BeTrue
            }

            It 'Uses the expected subject' {

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $Message.Subject | Should -Be '[PipeDFe] SMTP connectivity test'
                    $null = $Client
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Success | Should -BeTrue
            }

            It 'Uses the expected body' {

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $Message.Body | Should -Be 'This is an automated SMTP connectivity test sent by PipeDFe. You can ignore this message.'
                    $null = $Client
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Success | Should -BeTrue
            }

            It 'Uses plain text body' {

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $Message.IsBodyHtml | Should -BeFalse
                    $null = $Client
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Success | Should -BeTrue
            }

            It 'Calls the SMTP send wrapper exactly once' {

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $null = $Client
                    $null = $Message
                }

                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null

                $invokeParams = @{
                    CommandName = 'Send-PipeSmtpTestMessage'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Returns success when SMTP send succeeds' {

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $null = $Client
                    $null = $Message
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success       | Should -BeTrue
                $result.Authenticated | Should -BeTrue
                $result.FailureStage  | Should -BeNullOrEmpty
                $result.ErrorMessage  | Should -BeNullOrEmpty
            }

            It 'Returns Send failure when SMTP send throws' {

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $null = $Client
                    $null = $Message
                    throw 'SMTP server rejected the message.'
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success       | Should -BeFalse
                $result.Authenticated | Should -BeFalse
                $result.FailureStage  | Should -Be 'Send'
                $result.ErrorMessage  | Should -Be 'SMTP server rejected the message.'
            }

            It 'Never exposes SMTP credentials in the send failure result' {

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $null = $Client
                    $null = $Message
                    throw "SMTP authentication failed for password $($Script:FakeSmtpConfig.Password)"
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $passwd = $Script:FakeSmtpConfig.Password

                $result.ErrorMessage | Should -Not -Match [regex]::Escape($passwd)
                $result.ErrorMessage | Should -Not -Match 'P@ssw0rd!'
            }
        }
        #endregion

        #region Return contract
        Context 'Return contract' {

            BeforeEach {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-PipeSmtpTestMessage -MockWith {
                    param (
                        [System.Net.Mail.SmtpClient]$Client,
                        [System.Net.Mail.MailMessage]$Message
                    )

                    $null = $Client
                    $null = $Message
                }
            }

            It 'Returns exactly one object' {
                @(Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig) | Should -HaveCount 1
            }

            It 'Returns a PSCustomObject' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.PSObject.BaseObject.GetType().Name | Should -Be 'PSCustomObject'
            }

            It 'Returns exactly the documented properties' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                @($result.PSObject.Properties.Name) | Should -BeExactly $Script:ExpectedProperties
            }

            It 'Returns Success as bool' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Success | Should -BeOfType ([bool])
            }

            It 'Returns Source as string' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Source | Should -BeOfType ([string])
            }

            It 'Returns Server as string' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Server | Should -BeOfType ([string])
            }

            It 'Returns Port as int' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Port | Should -BeOfType ([int])
            }

            It 'Returns Authenticated as bool' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.Authenticated | Should -BeOfType ([bool])
            }

            It 'Returns ErrorMessage as null on success' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.ErrorMessage | Should -BeNullOrEmpty
            }

            It 'Returns FailureStage as null on success' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $result.FailureStage | Should -BeNullOrEmpty
            }

            It 'Does not return credential properties' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig
                $props  = @($result.PSObject.Properties.Name)

                $props | Should -Not -Contain 'Password'
                $props | Should -Not -Contain 'Credential'
                $props | Should -Not -Contain 'Credentials'
            }
        }
        #endregion
    }
}
