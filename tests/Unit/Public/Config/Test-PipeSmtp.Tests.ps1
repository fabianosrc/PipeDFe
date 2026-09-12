#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Test-PipeSmtp.

.DESCRIPTION
Tests the public Test-PipeSmtp command against the current post-refactor
implementation contract.

The suite intentionally isolates all external dependencies:
  - Configuration commands are mocked.
  - DPAPI credential resolution is mocked.
  - TCP connectivity is mocked.
  - Send-SmtpMessage is mocked.

The suite does not open real network connections and does not send real email.

Coverage includes:
  - Parameter contract and parameter sets.
  - CNPJ validation.
  - Global SMTP resolution.
  - Company SMTP resolution.
  - Company-to-global fallback.
  - Resolution failures.
  - Direct SMTP configuration.
  - SMTP configuration validation.
  - Timeout selection and override.
  - DPAPI credential resolution.
  - TCP connectivity probe.
  - SMTP send contract.
  - Test message construction.
  - FailureStage classification.
  - Structured result contract.
  - Credential secrecy.
  - No unexpected exceptions.

IMPORTANT:
This suite targets the current refactored implementation, where
Send-SmtpMessage receives Server/Port/EnableSsl/Credential/Message/TimeoutSeconds
and Test-PipeSmtp performs a TCP connectivity probe before the SMTP send.
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

    $moduleManifest = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleManifest -Force -Global -ErrorAction Stop
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
                'Ssl'
                'Authenticated'
                'ErrorMessage'
                'FailureStage'
            )
        }

        #region Shared test isolation
        BeforeEach {
            # The refactored implementation performs a real TCP probe before
            # calling Send-SmtpMessage. Unit tests must never depend on DNS,
            # routing, firewalls, or an SMTP server being reachable.
            Mock -CommandName Test-SmtpTcpConnection -MockWith {
                return $true
            }
        }
        #endregion

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
                $Script:Command.Parameters['SmtpConfig'].ParameterType |
                    Should -Be ([pscustomobject])
            }

            It 'Declares Cnpj as string' {
                $Script:Command.Parameters['Cnpj'].ParameterType |
                    Should -Be ([string])
            }

            It 'Declares TimeoutSeconds as int' {
                $Script:Command.Parameters['TimeoutSeconds'].ParameterType |
                    Should -Be ([int])
            }

            It 'Requires TimeoutSeconds to be greater than zero' {
                { Test-PipeSmtp -TimeoutSeconds 0 }  | Should -Throw
                { Test-PipeSmtp -TimeoutSeconds -1 } | Should -Throw
            }
        }
        #endregion

        #region CNPJ validation
        Context 'CNPJ validation' {

            It 'Accepts the current uppercase alphanumeric CNPJ contract' {
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

                Mock -CommandName Get-SmtpConfig -MockWith {
                    return $Script:FakeSmtpConfig
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return $null
                }

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    param ([pscustomobject]$Company)
                    $null = $Company
                    return $null
                }

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message
                    $null = $TimeoutSeconds
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
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 1
                }

                Should -Invoke Get-SmtpConfig @invokeParams
            }

            It 'Does not call company resolution' {
                Test-PipeSmtp | Out-Null

                $invokeParamsOne = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 0
                }

                Should -Invoke Get-CompanyConfig @invokeParamsOne

                $invokeParamsTwo = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 0
                }

                Should -Invoke Resolve-DFeSmtp @invokeParamsTwo
            }

            It 'Resolves credentials before the TCP probe' {
                Test-PipeSmtp | Out-Null

                $invokeParamsOne = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 1
                }

                Should -Invoke ConvertFrom-DpapiString @invokeParamsOne

                $invokeParamsTwo = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 1
                }

                Should -Invoke Test-SmtpTcpConnection @invokeParamsTwo
            }

            It 'Performs the TCP probe before sending SMTP' {
                $Script:CallOrder = [System.Collections.Generic.List[string]]::new()

                Mock -CommandName Test-SmtpTcpConnection -MockWith {
                    $Script:CallOrder.Add('TCP')
                    return $true
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    $Script:CallOrder.Add('SMTP')
                }

                Test-PipeSmtp | Out-Null

                $Script:CallOrder    | Should -HaveCount 2
                $Script:CallOrder[0] | Should -Be 'TCP'
                $Script:CallOrder[1] | Should -Be 'SMTP'
            }

            It 'Returns Authenticated true after a successful SMTP send' {
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

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message
                    $null = $TimeoutSeconds
                }
            }

            It 'Normalizes the CNPJ exactly once' {
                Test-PipeSmtp -Cnpj 'AB12CD34000195' | Out-Null

                $invokeParams = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 1
                }

                Should -Invoke ConvertTo-NormalizedCnpj @invokeParams
            }

            It 'Gets the company using the normalized CNPJ exactly once' {
                Test-PipeSmtp -Cnpj 'AB12CD34000195' | Out-Null

                $invokeParams = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 1
                }

                Should -Invoke Get-CompanyConfig @invokeParams
            }

            It 'Resolves SMTP from the company exactly once' {
                Test-PipeSmtp -Cnpj 'AB12CD34000195' | Out-Null

                $invokeParams = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 1
                }

                Should -Invoke Resolve-DFeSmtp @invokeParams
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

            It 'Does not resolve the global SMTP configuration' {
                Test-PipeSmtp -Cnpj 'AB12CD34000195' | Out-Null

                $invokeParams = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 0
                }

                Should -Invoke Get-SmtpConfig @invokeParams
            }
        }
        #endregion

        #region ByCnpj - global fallback
        Context 'ByCnpj - global fallback' {

            BeforeEach {

                Mock -CommandName Get-SmtpConfig -MockWith {
                    return $Script:FakeSmtpConfig
                }

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

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message
                    $null = $TimeoutSeconds
                }
            }

            It 'Uses the normalized CNPJ to obtain the company' {
                Test-PipeSmtp -Cnpj 'AB12CD34000195' | Out-Null

                $invokeParams = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 1
                }

                Should -Invoke Get-CompanyConfig @invokeParams
            }

            It 'Uses Resolve-DFeSmtp to resolve the effective configuration' {
                Test-PipeSmtp -Cnpj 'AB12CD34000195' | Out-Null

                $invokeParams = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 1
                }

                Should -Invoke Resolve-DFeSmtp @invokeParams
            }

            It 'Returns Global as Source when Resolve-DFeSmtp emits a warning' {
                (Test-PipeSmtp -Cnpj 'AB12CD34000195').Source | Should -Be 'Global'
            }

            It 'Successfully tests the fallback configuration' {
                $result = Test-PipeSmtp -Cnpj 'AB12CD34000195'

                $result.Success       | Should -BeTrue
                $result.Server        | Should -Be 'smtp.example.com'
                $result.Port          | Should -Be 587
                $result.Authenticated | Should -BeTrue
            }

            It 'Does not call Get-SmtpConfig during Resolve-DFeSmtp fallback' {
                Test-PipeSmtp -Cnpj 'AB12CD34000195' | Out-Null

                $invokeParams = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 0
                }

                Should -Invoke Get-SmtpConfig @invokeParams
            }
        }
        #endregion

        #region ByCnpj - resolution failures
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

            It 'Does not attempt credentials, TCP, or SMTP after resolution failure' {
                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    throw 'Should not be called.'
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    throw 'Should not be called.'
                }

                Test-PipeSmtp -Cnpj 'AB12CD34000195' | Out-Null

                $invokeParamsOne = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 0
                }

                Should -Invoke ConvertFrom-DpapiString @invokeParamsOne

                $invokeParamsTwo = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 0
                }

                Should -Invoke Test-SmtpTcpConnection @invokeParamsTwo

                $invokeParamsThree = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 0
                }

                Should -Invoke Send-SmtpMessage @invokeParamsThree
            }
        }

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

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message
                    $null = $TimeoutSeconds
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
                $result.Ssl    | Should -BeTrue
            }

            It 'Does not call Get-SmtpConfig' {
                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null

                $invokeParams = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 0
                }

                Should -Invoke Get-SmtpConfig @invokeParams
            }

            It 'Does not call Get-CompanyConfig' {
                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null

                $invokeParams = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 0
                }

                Should -Invoke Get-CompanyConfig @invokeParams
            }

            It 'Does not call Resolve-DFeSmtp' {
                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null

                $invokeParams = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 0
                }

                Should -Invoke Resolve-DFeSmtp @invokeParams
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
                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Server = [string]::Empty

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
                $result.ErrorMessage | Should -Be 'SMTP server is not configured.'
            }

            It 'Rejects a whitespace-only server' {
                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Server = '   '

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
                $result.ErrorMessage | Should -Be 'SMTP server is not configured.'
            }

            It 'Rejects port below 1' {
                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Port = 0

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
                $result.Port         | Should -Be 0
                $result.ErrorMessage | Should -Be "SMTP port '0' is outside the valid range 1-65535."
            }

            It 'Rejects port greater than 65535' {
                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Port = 65536

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
                $result.Port         | Should -Be 65536
                $result.ErrorMessage | Should -Be "SMTP port '65536' is outside the valid range 1-65535."
            }

            It 'Rejects an empty username' {
                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Username = [string]::Empty

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
                $result.ErrorMessage |
                    Should -Be 'SMTP username is not configured.'
            }

            It 'Rejects a whitespace-only username' {
                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Username = '   '

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
            }

            It 'Rejects a null From object' {
                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.From = $null

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
                $result.ErrorMessage | Should -Be 'SMTP sender address is not configured.'
            }

            It 'Rejects an empty sender address' {
                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.From = [PSCustomObject]@{
                    Name  = 'Empresa'
                    Email = [string]::Empty
                }

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
                $result.ErrorMessage | Should -Be 'SMTP sender address is not configured.'
            }

            It 'Rejects a whitespace-only sender address' {
                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.From = [PSCustomObject]@{
                    Name  = 'Empresa'
                    Email = '   '
                }

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success      | Should -BeFalse
                $result.FailureStage | Should -Be 'Configuration'
            }

            It 'Rejects an invalid sender address' {
                $config = $Script:FakeSmtpConfig.PSObject.Copy()
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

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message
                    $null = $TimeoutSeconds
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success | Should -BeTrue
            }

            It 'Uses 15 seconds when Timeout is zero' {
                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message

                    $TimeoutSeconds | Should -Be 15
                }

                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Timeout = 0

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success | Should -BeTrue
            }

            It 'Uses 15 seconds when Timeout is negative' {
                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message

                    $TimeoutSeconds | Should -Be 15
                }

                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Timeout = -1

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success | Should -BeTrue
            }

            It 'Uses 15 seconds when Timeout is absent' {
                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message

                    $TimeoutSeconds | Should -Be 15
                }

                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.PSObject.Properties.Remove('Timeout')

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success | Should -BeTrue
            }

            It 'Uses the configured timeout when greater than zero' {
                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message

                    $TimeoutSeconds | Should -Be 45
                }

                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Timeout = 45

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success | Should -BeTrue
            }

            It 'Uses TimeoutSeconds parameter as an override' {
                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message

                    $TimeoutSeconds | Should -Be 5
                }

                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Timeout = 45

                $result = Test-PipeSmtp -SmtpConfig $config -TimeoutSeconds 5

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

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message
                    $null = $TimeoutSeconds
                }

                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null

                $invokeParams = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 1
                }

                Should -Invoke ConvertFrom-DpapiString @invokeParams
            }

            It 'Passes the configured encrypted password to the DPAPI helper' {
                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    param ([string]$Value)

                    $Value | Should -Be $Script:FakeSmtpConfig.Password
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message
                    $null = $TimeoutSeconds
                }

                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null
            }

            It 'Builds a NetworkCredential with the configured username' {
                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Message
                    $null = $TimeoutSeconds

                    $Credential | Should -Not -BeNullOrEmpty
                    $Credential.UserName | Should -Be 'user@example.com'
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success | Should -BeTrue
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

            It 'Does not attempt TCP or SMTP when credential resolution fails' {
                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    throw 'DPAPI decryption failed.'
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    throw 'Should not be called.'
                }

                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null

                $invokeParamsOne = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 0
                }

                Should -Invoke Test-SmtpTcpConnection @invokeParamsOne

                $invokeParamsTwo = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 0
                }

                Should -Invoke Send-SmtpMessage @invokeParamsTwo
            }

            It 'Does not expose the encrypted password when credential resolution fails' {
                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    throw "Authentication failed for password $($Script:FakeSmtpConfig.Password)"
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.ErrorMessage | Should -Not -Match [regex]::Escape($Script:FakeSmtpConfig.Password)
                $result.ErrorMessage | Should -Not -Match 'P@ssw0rd!'
            }
        }
        #endregion

        #region TCP connectivity
        Context 'TCP connectivity' {

            BeforeEach {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message
                    $null = $TimeoutSeconds
                }
            }

            It 'Passes the effective server, port, and timeout to the TCP probe' {
                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Timeout = 42

                Test-PipeSmtp -SmtpConfig $config | Out-Null

                $invokeParams = @{
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Server -eq 'smtp.example.com' -and
                        $Port -eq 587 -and
                        $TimeoutMs -eq 42000
                    }
                }

                Should -Invoke Test-SmtpTcpConnection @invokeParams
            }

            It 'Uses TimeoutSeconds override for the TCP probe' {
                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig -TimeoutSeconds 7 |
                    Out-Null

                $invokeParams = @{
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter =  {
                        $Server -eq 'smtp.example.com' -and
                        $Port -eq 587 -and
                        $TimeoutMs -eq 7000
                    }
                }

                Should -Invoke Test-SmtpTcpConnection @invokeParams
            }

            It 'Proceeds to SMTP send when TCP connectivity succeeds' {
                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null

                $invokeParams = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 1
                }

                Should -Invoke Send-SmtpMessage @invokeParams
            }

            It 'Returns Connection failure when the TCP probe returns false' {
                Mock -CommandName Test-SmtpTcpConnection -MockWith {
                    return $false
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success       | Should -BeFalse
                $result.Authenticated | Should -BeFalse
                $result.FailureStage  | Should -Be 'Connection'
                $result.ErrorMessage  | Should -Be (
                    "TCP connection to 'smtp.example.com':'587' timed out. " +
                    "Check server address, port and firewall rules."
                )
            }

            It 'Does not call SMTP send when TCP connectivity fails' {
                Mock -CommandName Test-SmtpTcpConnection -MockWith {
                    return $false
                }

                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null

                $invokeParams = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 0
                }

                Should -Invoke Send-SmtpMessage @invokeParams
            }

            It 'Returns Connection failure when the TCP probe throws' {
                Mock -CommandName Test-SmtpTcpConnection -MockWith {
                    throw 'Network is unreachable.'
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success       | Should -BeFalse
                $result.Authenticated | Should -BeFalse
                $result.FailureStage  | Should -Be 'Connection'
                $result.ErrorMessage  | Should -Be (
                    "TCP connection to 'smtp.example.com':'587' failed: " +
                    "Network is unreachable."
                )
            }

            It 'Does not call SMTP send when the TCP probe throws' {
                Mock -CommandName Test-SmtpTcpConnection -MockWith {
                    throw 'Network is unreachable.'
                }

                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null

                $invokeParams = @{
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke Send-SmtpMessage @invokeParams
            }

            It 'Returns the effective SSL setting on TCP failure' {
                Mock -CommandName Test-SmtpTcpConnection -MockWith {
                    return $false
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Ssl | Should -BeTrue
            }
        }
        #endregion

        #region SMTP send contract
        Context 'SMTP send contract' {

            BeforeEach {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }
            }

            It 'Calls Send-SmtpMessage exactly once after a successful TCP probe' {
                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message
                    $null = $TimeoutSeconds
                }

                Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig | Out-Null

                $invokeParams = @{
                    ModuleName = 'PipeDFe'
                    Scope      = 'It'
                    Exactly    = $true
                    Times      = 1
                }

                Should -Invoke Send-SmtpMessage @invokeParams
            }

            It 'Passes the configured SMTP server and port' {
                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message
                    $null = $TimeoutSeconds

                    $Server | Should -Be 'smtp.example.com'
                    $Port   | Should -Be 587
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success | Should -BeTrue
            }

            It 'Passes the configured SSL setting' {
                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $Credential
                    $null = $Message
                    $null = $TimeoutSeconds

                    $EnableSsl | Should -BeTrue
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success | Should -BeTrue
            }

            It 'Passes the credential object' {
                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Message
                    $null = $TimeoutSeconds

                    $Credential | Should -Not -BeNullOrEmpty
                    $Credential.GetType().FullName | Should -Be 'System.Net.NetworkCredential'
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success | Should -BeTrue
            }

            It 'Passes the effective timeout' {
                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message

                    $TimeoutSeconds | Should -Be 30
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success | Should -BeTrue
            }

            It 'Returns Success when Send-SmtpMessage completes successfully' {
                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message
                    $null = $TimeoutSeconds
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success       | Should -BeTrue
                $result.Authenticated | Should -BeTrue
                $result.FailureStage  | Should -BeNullOrEmpty
                $result.ErrorMessage  | Should -BeNullOrEmpty
            }

            It 'Returns Send failure when Send-SmtpMessage throws' {
                Mock -CommandName Send-SmtpMessage -MockWith {
                    throw 'SMTP authentication failed.'
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success       | Should -BeFalse
                $result.Authenticated | Should -BeFalse
                $result.FailureStage  | Should -Be 'Send'
                $result.ErrorMessage  | Should -Be 'SMTP authentication failed.'
            }

            It 'Never throws when Send-SmtpMessage fails' {
                Mock -CommandName Send-SmtpMessage -MockWith {
                    throw 'SMTP authentication failed.'
                }

                { Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig } |
                    Should -Not -Throw
            }
        }
        #endregion

        #region Test message construction
        Context 'Test message construction' {

            BeforeEach {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }
            }

            It 'Uses the configured sender as From' {
                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $TimeoutSeconds

                    $Message.From.Address | Should -Be 'noreply@example.com'
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success | Should -BeTrue
            }

            It 'Sends the test message to the sender itself' {
                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $TimeoutSeconds

                    $Message.To | Should -HaveCount 1
                    $Message.To[0].Address | Should -Be 'noreply@example.com'
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success | Should -BeTrue
            }

            It 'Uses the expected subject' {
                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $TimeoutSeconds

                    $Message.Subject | Should -Be '[PipeDFe] SMTP connectivity test'
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success | Should -BeTrue
            }

            It 'Uses the expected automated test body' {
                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $TimeoutSeconds

                    $Message.Body |
                        Should -Be 'This is an automated SMTP connectivity test sent by PipeDFe. You can ignore this message.'
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success | Should -BeTrue
            }

            It 'Uses plain text instead of HTML' {
                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $TimeoutSeconds

                    $Message.IsBodyHtml | Should -BeFalse
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success | Should -BeTrue
            }

            It 'Uses UTF-8 body encoding' {
                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $TimeoutSeconds

                    $Message.BodyEncoding.WebName | Should -Be 'utf-8'
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success | Should -BeTrue
            }

            It 'Uses UTF-8 subject encoding' {
                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $TimeoutSeconds

                    $Message.SubjectEncoding.WebName | Should -Be 'utf-8'
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success | Should -BeTrue
            }
        }
        #endregion

        #region Result contract
        Context 'Result contract' {

            BeforeEach {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message
                    $null = $TimeoutSeconds
                }
            }

            It 'Returns exactly one object' {
                $output = @(Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig)

                $output | Should -HaveCount 1
            }

            It 'Returns a PSCustomObject' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.PSObject.BaseObject |
                    Should -BeOfType [pscustomobject]
            }

            It 'Uses the expected custom type name' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.PSObject.TypeNames[0] |
                    Should -Be 'PipeDFe.SmtpTestResult'
            }

            It 'Returns exactly the expected public properties' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                @($result.PSObject.Properties.Name) |
                    Should -Be $Script:ExpectedProperties
            }

            It 'Returns correctly typed success fields' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success       | Should -BeOfType [bool]
                $result.Source        | Should -BeOfType [string]
                $result.Server        | Should -BeOfType [string]
                $result.Port          | Should -BeOfType [int]
                $result.Ssl           | Should -BeOfType [bool]
                $result.Authenticated | Should -BeOfType [bool]
            }

            It 'Returns null ErrorMessage and FailureStage on success' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.ErrorMessage | Should -BeNullOrEmpty
                $result.FailureStage | Should -BeNullOrEmpty
            }

            It 'Does not expose credentials in the result' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                @($result.PSObject.Properties.Name) |
                    Should -Not -Contain 'Password'

                @($result.PSObject.Properties.Name) |
                    Should -Not -Contain 'Credential'

                $result | Out-String |
                    Should -Not -Match 'P@ssw0rd!'

                $result | Out-String |
                    Should -Not -Match [regex]::Escape($Script:FakeSmtpConfig.Password)
            }

            It 'Returns the expected success metadata' {
                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success       | Should -BeTrue
                $result.Source        | Should -Be 'Direct'
                $result.Server        | Should -Be 'smtp.example.com'
                $result.Port          | Should -Be 587
                $result.Ssl           | Should -BeTrue
                $result.Authenticated | Should -BeTrue
            }
        }
        #endregion

        #region Failure result contract
        Context 'Failure result contract' {

            It 'Returns structured Configuration failure' {
                $config = $Script:FakeSmtpConfig.PSObject.Copy()
                $config.Server = [string]::Empty

                $result = Test-PipeSmtp -SmtpConfig $config

                $result.Success       | Should -BeFalse
                $result.Authenticated | Should -BeFalse
                $result.FailureStage  | Should -Be 'Configuration'
                $result.ErrorMessage  | Should -Not -BeNullOrEmpty
            }

            It 'Returns structured Credentials failure' {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    throw 'Credential resolution failed.'
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success       | Should -BeFalse
                $result.Authenticated | Should -BeFalse
                $result.FailureStage  | Should -Be 'Credentials'
                $result.ErrorMessage  | Should -Be 'Credential resolution failed.'
            }

            It 'Returns structured Connection failure' {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Test-SmtpTcpConnection -MockWith {
                    return $false
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success       | Should -BeFalse
                $result.Authenticated | Should -BeFalse
                $result.FailureStage  | Should -Be 'Connection'
                $result.ErrorMessage  | Should -Not -BeNullOrEmpty
            }

            It 'Returns structured Send failure' {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    throw 'SMTP send failed.'
                }

                $result = Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig

                $result.Success       | Should -BeFalse
                $result.Authenticated | Should -BeFalse
                $result.FailureStage  | Should -Be 'Send'
                $result.ErrorMessage  | Should -Be 'SMTP send failed.'
            }
        }
        #endregion

        #region No unexpected exceptions
        Context 'No unexpected exceptions' {

            It 'Does not throw for a valid direct configuration and successful SMTP send' {
                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    param (
                        [string]$Server,
                        [int]$Port,
                        [bool]$EnableSsl,
                        [System.Net.NetworkCredential]$Credential,
                        [System.Net.Mail.MailMessage]$Message,
                        [int]$TimeoutSeconds
                    )

                    $null = $Server
                    $null = $Port
                    $null = $EnableSsl
                    $null = $Credential
                    $null = $Message
                    $null = $TimeoutSeconds
                }

                { Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig } |
                    Should -Not -Throw
            }

            It 'Does not throw when the TCP probe fails' {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Test-SmtpTcpConnection -MockWith {
                    return $false
                }

                { Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig } |
                    Should -Not -Throw
            }

            It 'Does not throw when the SMTP send fails' {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    return $Script:FakeSecurePassword
                }

                Mock -CommandName Send-SmtpMessage -MockWith {
                    throw 'SMTP send failed.'
                }

                { Test-PipeSmtp -SmtpConfig $Script:FakeSmtpConfig } |
                    Should -Not -Throw
            }
        }
        #endregion
    }
}
