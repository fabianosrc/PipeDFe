#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Set-PipeCompany.

.DESCRIPTION
Complete unit-test suite for the orchestration contract of Set-PipeCompany.

Covers includes:
  Parameter contract
    - Cnpj is mandatory
    - SupportsShouldProcess is enabled

  Phase 1 - Normalize
    - ConvertTo-NormalizedCnpj is called exactly once
    - Normalized CNPJ is propagated

  Phase 2 - Load
    - Existing company is loaded exactly once before resolution
    - Existing values are used as defaults

  Phase 3 - Resolve
    - Every scalar field is preserved when omitted
    - Every explicitly supplied scalar field replaces the existing value
    - IsActive is correctly distinguished between omitted and $false
    - Empty XmlPathNfse clears the field
    - Empty XmlPathEntrada clears the field
    - Email groups are preserved when omitted
    - Explicit email groups are normalized
    - SMTP is preserved when omitted
    - Explicit $null SMTP clears the field

  Certificate resolution
    - Existing certificate is preserved when CertPath is omitted
    - CertPath requires an existing file
    - CertPath + CertPassword uses ConvertTo-DpapiString
    - CertPath without CertPassword uses Invoke-CertificateSetup
    - CertPassword without CertPath does not alter the existing certificate
    - Certificate setup result is propagated

  Phase 4 - Validate
    - Assert-CompanyInput is called exactly once
    - IsUpdate is $true
    - Normalized CNPJ is used
    - Resolved paths are supplied when non-null
    - Cleared paths are omitted from validation

  Phase 5 - Construct
    - ConvertTo-CompanyObject receives all resolved fields
    - Resolved certificate data is passed
    - Resolved email groups are passed
    - Resolved SMTP is passed
    - IsActive is applied to the resulting object
    - CreatedAt is preserved
    - SchemaVersion is preserved

  Phase 6 - Persist
    - Save-CompanyConfig is called with -AsUpdate
    - Saved object is the constructed object
    - Get-CompanyConfig is called again after save
    - Returned object is the result of the post-save Get-CompanyConfig
    - WhatIf prevents persistence
    - WhatIf prevents the post-save Get-CompanyConfig

This suite intentionally does not perform integration tests.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingConvertToSecureStringWithPlainText',
    '',
    Justification = 'Plain text passwords are acceptable in unit-test context.'
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

Describe 'Set-PipeCompany' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Cnpj     = '12345678000195'
            $Script:CertPath = Join-Path -Path $TestDrive -ChildPath 'cert.pfx'

            $certPassParams = @{
                String      = 'P@ssw0rd'
                AsPlainText = $true
                Force       = $true
            }

            $Script:CertPassword = ConvertTo-SecureString @certPassParams
            $Script:NewCertPath  = Join-Path -Path $TestDrive -ChildPath 'new-cert.pfx'

            $newCertPassParams = @{
                String      = 'N3w-P@ss'
                AsPlainText = $true
                Force       = $true
            }

            $Script:NewCertPassword = ConvertTo-SecureString @newCertPassParams

            [System.IO.File]::WriteAllText($Script:CertPath, 'fake-certificate')
            [System.IO.File]::WriteAllText($Script:NewCertPath, 'new-fake-certificate')

            # ---------------------------------------------------------------
            # Existing record
            #
            # IMPORTANT:
            # This object represents the record loaded during Phase 2.
            # It must NOT be confused with the object returned after save.
            # ---------------------------------------------------------------
            $Script:ExistingCompany = [PSCustomObject]@{
                SchemaVersion  = 7
                Cnpj           = $Script:Cnpj
                Ie             = '123456789'
                RazaoSocial    = 'ACME COMERCIO LTDA'
                NomeFantasia   = 'ACME'
                Uf             = 'SP'
                Ambiente       = 'Producao'
                IsActive       = $true
                XmlPath        = 'C:\ERP\XML'
                XmlPathNfse    = 'C:\ERP\NFSE'
                XmlPathEntrada = 'C:\ERP\ENTRADA'
                OutputPath     = 'C:\ERP\OUT'
                Certificado    = [PSCustomObject]@{
                    Path = 'C:\CERTS\existing.pfx'
                    EncryptedPassword = 'existing-encrypted-password'
                }
                Email          = [PSCustomObject]@{
                    Para = @('existing-to@example.com')
                    Cc   = @('existing-cc@example.com')
                    Cco  = @('existing-bcc@example.com')
                }
                Contato        = [PSCustomObject]@{
                    Email    = 'contato@example.com'
                    Telefone = '+55 11 99999-9999'
                }
                Smtp           = [PSCustomObject]@{
                    Host   = 'smtp.existing.local'
                    Port   = 587
                    User   = 'existing-user'
                    UseSsl = $true
                }
                CreatedAt      = '2026-08-01T00:00:00.0000000+00:00'
                UpdatedAt      = '2026-08-31T00:00:00.0000000+00:00'
            }

            # ---------------------------------------------------------------
            # Result returned by Get-CompanyConfig after persistence
            #
            # IMPORTANT:
            # This is intentionally a DIFFERENT object from ExistingCompany.
            # SchemaVersion and CreatedAt are deliberately distinct so that
            # tests can prove the function preserves ExistingCompany values
            # rather than inadvertently carrying over UpdatedCompany values.
            # ---------------------------------------------------------------
            $Script:UpdatedCompany = [PSCustomObject]@{
                SchemaVersion  = 99
                Cnpj           = $Script:Cnpj
                Ie             = '987654321'
                RazaoSocial    = 'ACME ATUALIZADO LTDA'
                NomeFantasia   = 'ACME NOVO'
                Uf             = 'RJ'
                Ambiente       = 'Homologacao'
                IsActive       = $false
                XmlPath        = 'D:\ERP\XML'
                XmlPathNfse    = 'D:\ERP\NFSE'
                XmlPathEntrada = 'D:\ERP\ENTRADA'
                OutputPath     = 'D:\ERP\OUT'
                Certificado    = [PSCustomObject]@{
                    Path              = $Script:NewCertPath
                    EncryptedPassword = 'encrypted-new-password'
                }
                Email          = [PSCustomObject]@{
                    Para = @('new-to@example.com')
                    Cc   = @('new-cc@example.com')
                    Cco  = @('new-bcc@example.com')
                }
                Contato        = [PSCustomObject]@{
                    Email    = 'novo-contato@example.com'
                    Telefone = '+55 11 98888-8888'
                }
                Smtp           = [PSCustomObject]@{
                    Host   = 'smtp.updated.local'
                    Port   = 465
                    User   = 'updated-user'
                    UseSsl = $true
                }
                CreatedAt      = '2099-01-01T00:00:00.0000000+00:00'
                UpdatedAt      = '2026-08-31T00:00:00.0000000+00:00'
            }
        }

        BeforeEach {

            $Script:GetCompanyConfigCallCount = 0
            $Script:CapturedFactoryParams     = $null
            $Script:CapturedSaveCompany       = $null
            $Script:CapturedAssertParams      = $null
            $Script:NormalizedMailValues      = @()

            # CNPJ normalization
            Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                param (
                    [string]$Value
                )

                $null = $Value

                return $Script:Cnpj
            }

            # Existing -> Updated behavior
            #
            # First call:
            #   Phase 2 / Load
            #   -> ExistingCompany
            #
            # Second call:
            #   Phase 6 / Return
            #   -> UpdatedCompany
            #
            Mock -CommandName Get-CompanyConfig -MockWith {
                param (
                    [string]$Cnpj
                )

                $null = $Cnpj

                $Script:GetCompanyConfigCallCount++

                if ($Script:GetCompanyConfigCallCount -eq 1) {
                    return $Script:ExistingCompany
                }

                return $Script:UpdatedCompany
            }

            # Validation
            Mock -CommandName Assert-CompanyInput -MockWith {
                param (
                    [string]$Cnpj,
                    [string]$Ambiente,
                    [string]$XmlPath,
                    [string]$XmlPathNfse,
                    [string]$XmlPathEntrada,
                    [bool]$IsUpdate
                )

                $Script:CapturedAssertParams = @{
                    Cnpj           = $Cnpj
                    Ambiente       = $Ambiente
                    XmlPath        = $XmlPath
                    XmlPathNfse    = $XmlPathNfse
                    XmlPathEntrada = $XmlPathEntrada
                    IsUpdate       = $IsUpdate
                }
            }

            # E-mail normalization
            Mock -CommandName ConvertTo-NormalizedMailRecipient -MockWith {
                param (
                    [pscustomobject]$InputObject
                )

                "normalized:$InputObject"
            }

            # DPAPI
            Mock -CommandName ConvertTo-DpapiString -MockWith {
                param (
                    [System.Security.SecureString]$Value
                )

                $null = $Value

                return 'encrypted-blob'
            }

            # Interactive certificate setup
            Mock -CommandName Invoke-CertificateSetup -MockWith {
                param (
                    [string]$Path
                )

                $null = $Path

                return [PSCustomObject]@{
                    EncryptedPassword = 'interactive-blob'
                }
            }

            # Company factory
            #
            # The mock captures EVERYTHING passed by Set-PipeCompany.
            #
            # It then creates a company object from those parameters so that
            # the tests can verify the final object independently from the
            # post-save UpdatedCompany.
            Mock -CommandName ConvertTo-CompanyObject -MockWith {
                param (
                    [string]$Cnpj,
                    [string]$RazaoSocial,
                    [string]$Uf,
                    [string]$Ambiente,
                    [string]$XmlPath,
                    [string]$OutputPath,
                    [string]$XmlPathNfse,
                    [string]$XmlPathEntrada,
                    [string]$NomeFantasia,
                    [string]$Ie,
                    [object[]]$EmailPara,
                    [object[]]$EmailCc,
                    [object[]]$EmailCco,
                    [object[]]$Smtp,
                    [string]$CertPath,
                    [string]$CertPassword
                )

                $Script:CapturedFactoryParams = @{
                    Cnpj           = $Cnpj
                    RazaoSocial    = $RazaoSocial
                    Uf             = $Uf
                    Ambiente       = $Ambiente
                    XmlPath        = $XmlPath
                    OutputPath     = $OutputPath
                    XmlPathNfse    = $XmlPathNfse
                    XmlPathEntrada = $XmlPathEntrada
                    NomeFantasia   = $NomeFantasia
                    Ie             = $Ie
                    EmailPara      = @($EmailPara)
                    EmailCc        = @($EmailCc)
                    EmailCco       = @($EmailCco)
                    Smtp           = $Smtp
                    CertPath       = $CertPath
                    CertPassword   = $CertPassword
                }

                return [PSCustomObject]@{
                    SchemaVersion  = $null
                    Cnpj           = $Cnpj
                    Ie             = $Ie
                    RazaoSocial    = $RazaoSocial
                    NomeFantasia   = $NomeFantasia
                    Uf             = $Uf
                    Ambiente       = $Ambiente
                    IsActive       = $null
                    XmlPath        = $XmlPath
                    XmlPathNfse    = $XmlPathNfse
                    XmlPathEntrada = $XmlPathEntrada
                    OutputPath     = $OutputPath
                    Certificado    = [PSCustomObject]@{
                        Path              = $CertPath
                        EncryptedPassword = $CertPassword
                    }
                    Email          = [PSCustomObject]@{
                        Para = @($EmailPara)
                        Cc   = @($EmailCc)
                        Cco  = @($EmailCco)
                    }
                    Smtp           = $Smtp
                    CreatedAt      = $null
                    UpdatedAt      = $null
                }
            }

            # Persistence
            Mock -CommandName Save-CompanyConfig -MockWith {
                param (
                    [pscustomobject[]]$Company,

                    [switch]$AsUpdate
                )

                $null = $AsUpdate

                $Script:CapturedSaveCompany = $Company
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Cnpj as mandatory' {
                $command = Get-Command -Name Set-PipeCompany

                $attribute = $command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1

                $attribute | Should -Not -BeNullOrEmpty
                $attribute.Mandatory | Should -BeTrue
            }

            It 'Declares SupportsShouldProcess' {
                $command = Get-Command -Name Set-PipeCompany

                $command.Parameters['WhatIf'] | Should -Not -BeNullOrEmpty
            }

            It 'Declares all documented update parameters' {
                $command = Get-Command -Name Set-PipeCompany

                $expectedParameters = @(
                    'Cnpj', 'RazaoSocial', 'NomeFantasia', 'Ie', 'Uf'
                    'Ambiente', 'XmlPath', 'XmlPathNfse', 'XmlPathEntrada'
                    'OutputPath', 'CertPath', 'CertPassword', 'EmailPara',
                    'EmailCc', 'EmailCco', 'Smtp', 'IsActive'
                )

                foreach ($parameterName in $expectedParameters) {
                    $command.Parameters[$parameterName] | Should -Not -BeNullOrEmpty
                }
            }
        }
        #endregion

        #region Phase 1 - Normalize
        Context 'Phase 1 - Normalize' {

            It 'Calls ConvertTo-NormalizedCnpj exactly once with the provided Cnpj' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                Should -Invoke -CommandName ConvertTo-NormalizedCnpj -Times 1 -Exactly -ParameterFilter {
                    $Value -eq $Script:Cnpj
                }
            }

            It 'Uses the normalized Cnpj when loading the company' {
                Set-PipeCompany -Cnpj '12.345.678/0001-95'

                Should -Invoke -CommandName Get-CompanyConfig -Times 2 -Exactly -ParameterFilter {
                    $Cnpj -eq $Script:Cnpj
                }
            }
        }
        #endregion

        #region Phase 2 - Load
        Context 'Phase 2 - Load' {

            It 'Loads the existing company exactly once before resolution' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                Should -Invoke -CommandName Get-CompanyConfig -Times 2 -Exactly
            }

            It 'Uses ExistingCompany as the source of omitted values' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedFactoryParams.RazaoSocial |
                    Should -Be $Script:ExistingCompany.RazaoSocial

                $Script:CapturedFactoryParams.NomeFantasia |
                    Should -Be $Script:ExistingCompany.NomeFantasia

                $Script:CapturedFactoryParams.Ie |
                    Should -Be $Script:ExistingCompany.Ie

                $Script:CapturedFactoryParams.Uf |
                    Should -Be $Script:ExistingCompany.Uf

                $Script:CapturedFactoryParams.XmlPath |
                    Should -Be $Script:ExistingCompany.XmlPath

                $Script:CapturedFactoryParams.XmlPathNfse |
                    Should -Be $Script:ExistingCompany.XmlPathNfse

                $Script:CapturedFactoryParams.XmlPathEntrada |
                    Should -Be $Script:ExistingCompany.XmlPathEntrada

                $Script:CapturedFactoryParams.OutputPath |
                    Should -Be $Script:ExistingCompany.OutputPath
            }
        }
        #endregion

        #region Phase 3 - Scalar field resolution
        Context 'Phase 3 - Scalar field resolution' {

            It 'Preserves RazaoSocial when not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedFactoryParams.RazaoSocial | Should -Be 'ACME COMERCIO LTDA'
            }

            It 'Updates RazaoSocial when provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -RazaoSocial 'NOVA RAZAO SOCIAL'

                $Script:CapturedFactoryParams.RazaoSocial | Should -Be 'NOVA RAZAO SOCIAL'
            }

            It 'Preserves NomeFantasia when not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedFactoryParams.NomeFantasia | Should -Be 'ACME'
            }

            It 'Updates NomeFantasia when provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -NomeFantasia 'ACME NOVO'

                $Script:CapturedFactoryParams.NomeFantasia | Should -Be 'ACME NOVO'
            }

            It 'Preserves Ie when not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedFactoryParams.Ie | Should -Be '123456789'
            }

            It 'Updates Ie when provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -Ie '987654321'

                $Script:CapturedFactoryParams.Ie | Should -Be '987654321'
            }

            It 'Preserves Uf when not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                [string]$Script:CapturedFactoryParams.Uf | Should -Be 'SP'
            }

            It 'Updates Uf when provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -Uf 'RJ'

                [string]$Script:CapturedFactoryParams.Uf | Should -Be 'RJ'
            }

            It 'Preserves Ambiente when not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                [string]$Script:CapturedFactoryParams.Ambiente | Should -Be 'Producao'
            }

            It 'Updates Ambiente when provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -Ambiente ([Ambiente]::Homologacao)

                [string]$Script:CapturedFactoryParams.Ambiente | Should -Be 'Homologacao'
            }

            It 'Preserves XmlPath when not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedFactoryParams.XmlPath | Should -Be 'C:\ERP\XML'
            }

            It 'Updates XmlPath when provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -XmlPath 'D:\NOVO\XML'

                $Script:CapturedFactoryParams.XmlPath | Should -Be 'D:\NOVO\XML'
            }

            It 'Preserves XmlPathNfse when not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedFactoryParams.XmlPathNfse | Should -Be 'C:\ERP\NFSE'
            }

            It 'Updates XmlPathNfse when provided with a non-empty value' {
                Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathNfse 'D:\NOVO\NFSE'

                $Script:CapturedFactoryParams.XmlPathNfse | Should -Be 'D:\NOVO\NFSE'
            }

            It 'Clears XmlPathNfse when an empty string is provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathNfse ''

                $Script:CapturedFactoryParams.XmlPathNfse | Should -BeNullOrEmpty
            }

            It 'Clears XmlPathNfse when whitespace is provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathNfse '   '

                $Script:CapturedFactoryParams.XmlPathNfse | Should -BeNullOrEmpty
            }

            It 'Preserves XmlPathEntrada when not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedFactoryParams.XmlPathEntrada | Should -Be 'C:\ERP\ENTRADA'
            }

            It 'Updates XmlPathEntrada when provided with a non-empty value' {
                Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathEntrada 'D:\NOVO\ENTRADA'

                $Script:CapturedFactoryParams.XmlPathEntrada | Should -Be 'D:\NOVO\ENTRADA'
            }

            It 'Clears XmlPathEntrada when an empty string is provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathEntrada ''

                $Script:CapturedFactoryParams.XmlPathEntrada | Should -BeNullOrEmpty
            }

            It 'Clears XmlPathEntrada when whitespace is provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathEntrada '   '

                $Script:CapturedFactoryParams.XmlPathEntrada | Should -BeNullOrEmpty
            }

            It 'Preserves OutputPath when not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedFactoryParams.OutputPath | Should -Be 'C:\ERP\OUT'
            }

            It 'Updates OutputPath when provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -OutputPath 'D:\NOVO\OUT'

                $Script:CapturedFactoryParams.OutputPath | Should -Be 'D:\NOVO\OUT'
            }

            It 'Preserves IsActive when not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedSaveCompany.IsActive | Should -BeTrue
            }

            It 'Updates IsActive to $true when explicitly provided' {
                $Script:ExistingCompany.IsActive = $false

                Set-PipeCompany -Cnpj $Script:Cnpj -IsActive $true

                $Script:CapturedSaveCompany.IsActive | Should -BeTrue
            }

            It 'Updates IsActive to $false when explicitly provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -IsActive $false

                $Script:CapturedSaveCompany.IsActive | Should -BeFalse
            }
        }
        #endregion

        #region Phase 3 - E-mail
        Context 'Phase 3 - Email resolution' {

            It 'Preserves EmailPara when not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                @($Script:CapturedFactoryParams.EmailPara) |
                    Should -Be @('existing-to@example.com')
            }

            It 'Preserves EmailCc when not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                @($Script:CapturedFactoryParams.EmailCc) |
                    Should -Be @('existing-cc@example.com')
            }

            It 'Preserves EmailCco when not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                @($Script:CapturedFactoryParams.EmailCco) |
                    Should -Be @('existing-bcc@example.com')
            }

            It 'Normalizes EmailPara when provided' {
                $setParams = @{
                    Cnpj      = $Script:Cnpj
                    EmailPara = @('user@example.com', 'other@example.com')
                }

                Set-PipeCompany @setParams

                Should -Invoke -CommandName ConvertTo-NormalizedMailRecipient -Times 2 -Exactly

                @($Script:CapturedFactoryParams.EmailPara) |
                    Should -Be @(
                        'normalized:user@example.com',
                        'normalized:other@example.com'
                    )
            }

            It 'Normalizes EmailCc when provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -EmailCc @('cc@example.com')

                Should -Invoke -CommandName ConvertTo-NormalizedMailRecipient -Times 1 -Exactly

                @($Script:CapturedFactoryParams.EmailCc) |
                    Should -Be @('normalized:cc@example.com')
            }

            It 'Normalizes EmailCco when provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -EmailCco @('bcc@example.com')

                Should -Invoke -CommandName ConvertTo-NormalizedMailRecipient -Times 1 -Exactly

                @($Script:CapturedFactoryParams.EmailCco) |
                    Should -Be @('normalized:bcc@example.com')
            }

            It 'Normalizes all supplied email groups independently' {
                $setParams = @{
                    Cnpj      = $Script:Cnpj
                    EmailPara = @('to@example.com')
                    EmailCc   = @('cc@example.com')
                    EmailCco  = @('bcc@example.com')
                }

                Set-PipeCompany @setParams

                Should -Invoke -CommandName ConvertTo-NormalizedMailRecipient -Times 3 -Exactly
            }
        }
        #endregion

        #region Phase 3 - SMTP
        Context 'Phase 3 - SMTP resolution' {

            It 'Preserves existing SMTP when Smtp is not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedFactoryParams.Smtp | Should -Be $Script:ExistingCompany.Smtp
            }

            It 'Replaces SMTP when a new value is provided' {
                $newSmtp = [PSCustomObject]@{
                    Host = 'smtp.new.local'
                    Port = 2525
                    User = 'new-user'
                    UseSsl = $false
                }

                Set-PipeCompany -Cnpj $Script:Cnpj -Smtp $newSmtp

                $Script:CapturedFactoryParams.Smtp | Should -Be $newSmtp
            }

            It 'Allows explicit $null SMTP to clear the existing value' {
                Set-PipeCompany -Cnpj $Script:Cnpj -Smtp $null

                $Script:CapturedFactoryParams.Smtp | Should -BeNull
            }
        }
        #endregion

        #region Certificate resolution
        Context 'Certificate resolution' {

            It 'Preserves existing certificate when CertPath is not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedFactoryParams.CertPath |
                    Should -Be $Script:ExistingCompany.Certificado.Path

                $Script:CapturedFactoryParams.CertPassword |
                    Should -Be $Script:ExistingCompany.Certificado.EncryptedPassword

                Should -Invoke -CommandName ConvertTo-DpapiString   -Times 0 -Exactly
                Should -Invoke -CommandName Invoke-CertificateSetup -Times 0 -Exactly
            }

            It 'Calls ConvertTo-DpapiString when CertPath and CertPassword are supplied' {
                $setParams = @{
                    Cnpj         = $Script:Cnpj
                    CertPath     = $Script:CertPath
                    CertPassword = $Script:CertPassword
                }

                Set-PipeCompany @setParams

                Should -Invoke -CommandName ConvertTo-DpapiString -Times 1 -Exactly -ParameterFilter {
                    $null -ne $Value
                }

                Should -Invoke -CommandName Invoke-CertificateSetup -Times 0 -Exactly

                $Script:CapturedFactoryParams.CertPath     | Should -Be $Script:CertPath
                $Script:CapturedFactoryParams.CertPassword | Should -Be 'encrypted-blob'
            }

            It 'Calls Invoke-CertificateSetup when CertPath is provided without CertPassword' {
                Set-PipeCompany -Cnpj $Script:Cnpj -CertPath $Script:CertPath

                Should -Invoke -CommandName Invoke-CertificateSetup -Times 1 -Exactly -ParameterFilter {
                    $Path -eq $Script:CertPath
                }

                Should -Invoke -CommandName ConvertTo-DpapiString -Times 0 -Exactly

                $Script:CapturedFactoryParams.CertPath     | Should -Be $Script:CertPath
                $Script:CapturedFactoryParams.CertPassword | Should -Be 'interactive-blob'
            }

            It 'Propagates the interactive certificate password to ConvertTo-CompanyObject' {
                Set-PipeCompany -Cnpj $Script:Cnpj -CertPath $Script:CertPath

                $Script:CapturedFactoryParams.CertPassword | Should -Be 'interactive-blob'
            }

            It 'Rejects a certificate path that does not exist' {
                $missingPath = Join-Path -Path $TestDrive -ChildPath 'does-not-exist.pfx'

                { Set-PipeCompany -Cnpj $Script:Cnpj -CertPath $missingPath } |
                    Should -Throw
            }

            It 'Does not call certificate setup when the certificate file is missing' {
                $missingPath = Join-Path -Path $TestDrive -ChildPath 'missing-cert.pfx'

                try {
                    Set-PipeCompany -Cnpj $Script:Cnpj -CertPath $missingPath
                } catch {
                    # Expected.
                    $null = $_
                }

                Should -Invoke -CommandName Invoke-CertificateSetup -Times 0 -Exactly
                Should -Invoke -CommandName ConvertTo-DpapiString   -Times 0 -Exactly
            }

            It 'Ignores CertPassword when CertPath is not provided' {
                $setParams = @{
                    Cnpj         = $Script:Cnpj
                    CertPassword = $Script:CertPassword

                }

                Set-PipeCompany @setParams

                Should -Invoke -CommandName ConvertTo-DpapiString   -Times 0 -Exactly
                Should -Invoke -CommandName Invoke-CertificateSetup -Times 0 -Exactly

                $Script:CapturedFactoryParams.CertPath |
                    Should -Be $Script:ExistingCompany.Certificado.Path

                $Script:CapturedFactoryParams.CertPassword |
                    Should -Be $Script:ExistingCompany.Certificado.EncryptedPassword
            }

            It 'Replaces the existing certificate when a new certificate is supplied' {
                $setParams = @{
                    Cnpj         = $Script:Cnpj
                    CertPath     = $Script:NewCertPath
                    CertPassword = $Script:NewCertPassword
                }

                Set-PipeCompany @setParams

                $Script:CapturedFactoryParams.CertPath     | Should -Be $Script:NewCertPath
                $Script:CapturedFactoryParams.CertPassword | Should -Be 'encrypted-blob'
            }
        }
        #endregion

        #region Phase 4 - Validation
        Context 'Phase 4 - Validation' {

            It 'Calls Assert-CompanyInput exactly once' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                Should -Invoke -CommandName Assert-CompanyInput -Times 1 -Exactly
            }

            It 'Calls Assert-CompanyInput with IsUpdate equal to $true' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedAssertParams.IsUpdate | Should -BeTrue
            }

            It 'Passes normalized Cnpj to Assert-CompanyInput' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedAssertParams.Cnpj | Should -Be $Script:Cnpj
            }

            It 'Passes the resolved XmlPath to Assert-CompanyInput' {
                Set-PipeCompany -Cnpj $Script:Cnpj -XmlPath 'D:\XML'

                $Script:CapturedAssertParams.XmlPath | Should -Be 'D:\XML'
            }

            It 'Passes XmlPathNfse to Assert-CompanyInput when non-null' {
                Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathNfse 'D:\NFSE'

                $Script:CapturedAssertParams.XmlPathNfse | Should -Be 'D:\NFSE'
            }

            It 'Passes XmlPathEntrada to Assert-CompanyInput when non-null' {
                Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathEntrada 'D:\ENTRADA'

                $Script:CapturedAssertParams.XmlPathEntrada | Should -Be 'D:\ENTRADA'
            }

            It 'Does not pass cleared XmlPathNfse to validation' {
                $Script:CapturedAssertParams = $null

                Mock -CommandName Assert-CompanyInput -MockWith {
                    $Script:CapturedAssertParams = @{

                    } + $PSBoundParameters
                }

                Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathNfse ''

                $Script:CapturedAssertParams.ContainsKey('XmlPathNfse') | Should -BeFalse
            }

            It 'Does not pass cleared XmlPathEntrada to validation' {
                $Script:CapturedAssertParams = $null

                Mock -CommandName Assert-CompanyInput -MockWith {
                    $Script:CapturedAssertParams = @{} + $PSBoundParameters
                }

                Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathEntrada ''

                $Script:CapturedAssertParams.ContainsKey('XmlPathEntrada') | Should -BeFalse
            }

            It 'Passes the resolved Ambiente to Assert-CompanyInput' {
                Set-PipeCompany -Cnpj $Script:Cnpj -Ambiente ([Ambiente]::Homologacao)

                [string]$Script:CapturedAssertParams.Ambiente | Should -Be 'Homologacao'
            }
        }
        #endregion

        #region Phase 5 - Construction
        Context 'Phase 5 - Construction' {

            It 'Calls ConvertTo-CompanyObject exactly once' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                Should -Invoke -CommandName ConvertTo-CompanyObject -Times 1 -Exactly
            }

            It 'Passes every resolved field to ConvertTo-CompanyObject' {
                $setParams = @{
                    Cnpj           = $Script:Cnpj
                    RazaoSocial    = 'Updated Legal Name'
                    NomeFantasia   = 'Updated Trade Name'
                    Ie             = '999999999'
                    Uf             = 'MG'
                    Ambiente       = ([Ambiente]::Homologacao)
                    XmlPath        =  'D:\XML'
                    XmlPathNfse    =  'D:\NFSE'
                    XmlPathEntrada = 'D:\ENTRADA'
                    OutputPath     = 'D:\OUT'
                    CertPath       = $Script:CertPath
                    CertPassword   = $Script:CertPassword
                    EmailPara      = @('to@example.com')
                    EmailCc        = @('cc@example.com')
                    EmailCco       = @('bcc@example.com')
                }

                Set-PipeCompany @setParams

                $p = $Script:CapturedFactoryParams

                $p.Cnpj             | Should -Be $Script:Cnpj
                $p.RazaoSocial      | Should -Be 'Updated Legal Name'
                $p.NomeFantasia     | Should -Be 'Updated Trade Name'
                $p.Ie               | Should -Be '999999999'
                [string]$p.Uf       | Should -Be 'MG'
                [string]$p.Ambiente | Should -Be 'Homologacao'
                $p.XmlPath          | Should -Be 'D:\XML'
                $p.XmlPathNfse      | Should -Be 'D:\NFSE'
                $p.XmlPathEntrada   | Should -Be 'D:\ENTRADA'
                $p.OutputPath       | Should -Be 'D:\OUT'
                $p.CertPath         | Should -Be $Script:CertPath
                $p.CertPassword     | Should -Be 'encrypted-blob'
                @($p.EmailPara)     | Should -Be @('normalized:to@example.com')
                @($p.EmailCc)       | Should -Be @('normalized:cc@example.com')
                @($p.EmailCco)      | Should -Be @('normalized:bcc@example.com')
            }

            It 'Passes preserved certificate values to ConvertTo-CompanyObject when CertPath is omitted' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedFactoryParams.CertPath |
                    Should -Be $Script:ExistingCompany.Certificado.Path

                $Script:CapturedFactoryParams.CertPassword |
                    Should -Be $Script:ExistingCompany.Certificado.EncryptedPassword
            }

            It 'Passes preserved SMTP to ConvertTo-CompanyObject when Smtp is omitted' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedFactoryParams.Smtp |
                    Should -Be $Script:ExistingCompany.Smtp
            }
        }
        #endregion

        #region Immutable metadata
        Context 'Immutable metadata' {

            It 'Preserves CreatedAt from ExistingCompany' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedSaveCompany.CreatedAt |
                    Should -Be $Script:ExistingCompany.CreatedAt
            }

            It 'Preserves SchemaVersion from ExistingCompany' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedSaveCompany.SchemaVersion |
                    Should -Be $Script:ExistingCompany.SchemaVersion
            }

            It 'Does not take CreatedAt from the post-save UpdatedCompany' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedSaveCompany.CreatedAt |
                    Should -Not -Be $Script:UpdatedCompany.CreatedAt
            }

            It 'Does not take SchemaVersion from the post-save UpdatedCompany' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                $Script:CapturedSaveCompany.SchemaVersion |
                    Should -Not -Be $Script:UpdatedCompany.SchemaVersion
            }
        }
        #endregion

        #region Persistence
        Context 'Phase 6 - Persistence' {

            It 'Calls Save-CompanyConfig exactly once' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                Should -Invoke -CommandName Save-CompanyConfig -Times 1 -Exactly
            }

            It 'Calls Save-CompanyConfig with AsUpdate equal to $true' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                Should -Invoke -CommandName Save-CompanyConfig -Times 1 -Exactly -ParameterFilter {
                    $AsUpdate -eq $true
                }
            }

            It 'Persists the constructed company object' {
                Set-PipeCompany -Cnpj $Script:Cnpj -RazaoSocial 'PERSIST TEST'

                $Script:CapturedSaveCompany | Should -Not -BeNullOrEmpty
                $Script:CapturedSaveCompany.RazaoSocial | Should -Be 'PERSIST TEST'
            }

            It 'Calls Get-CompanyConfig once before save and once after save' {
                Set-PipeCompany -Cnpj $Script:Cnpj

                Should -Invoke -CommandName Get-CompanyConfig -Times 2 -Exactly
            }

            It 'Calls Get-CompanyConfig with the normalized Cnpj after save' {
                Set-PipeCompany -Cnpj '12.345.678/0001-95'

                Should -Invoke -CommandName Get-CompanyConfig -Times 2 -Exactly -ParameterFilter {
                    $Cnpj -eq $Script:Cnpj
                }
            }

            It 'Returns the result of the post-save Get-CompanyConfig' {
                $result = Set-PipeCompany -Cnpj $Script:Cnpj

                $result | Should -Be $Script:UpdatedCompany
                $result | Should -Not -Be $Script:ExistingCompany
            }
        }
        #endregion

        #region WhatIf
        Context 'WhatIf' {

            It 'Does not call Save-CompanyConfig when WhatIf is specified' {
                Set-PipeCompany -Cnpj $Script:Cnpj -WhatIf

                Should -Invoke -CommandName Save-CompanyConfig -Times 0 -Exactly
            }

            It 'Does not perform the post-save Get-CompanyConfig when WhatIf is specified' {
                Set-PipeCompany -Cnpj $Script:Cnpj -WhatIf

                Should -Invoke -CommandName Get-CompanyConfig -Times 1 -Exactly
            }

            It 'Still performs normalization when WhatIf is specified' {
                Set-PipeCompany -Cnpj $Script:Cnpj -WhatIf

                Should -Invoke -CommandName ConvertTo-NormalizedCnpj -Times 1 -Exactly
            }

            It 'Still loads the existing company when WhatIf is specified' {
                Set-PipeCompany -Cnpj $Script:Cnpj -WhatIf

                Should -Invoke -CommandName Get-CompanyConfig -Times 1 -Exactly
            }

            It 'Still validates when WhatIf is specified' {
                Set-PipeCompany -Cnpj $Script:Cnpj -WhatIf

                Should -Invoke -CommandName Assert-CompanyInput -Times 1 -Exactly
            }

            It 'Still constructs the company when WhatIf is specified' {
                Set-PipeCompany -Cnpj $Script:Cnpj -WhatIf

                Should -Invoke -CommandName ConvertTo-CompanyObject -Times 1 -Exactly
            }
        }
        #endregion

        #region Orchestration contract
        Context 'Orchestration contract' {

            It 'Executes the complete update pipeline for a normal update' {
                $setParams = @{
                    Cnpj           = $Script:Cnpj
                    RazaoSocial    = 'ACME FINAL'
                    NomeFantasia   = 'ACME FINAL'
                    Ie             = '111222333'
                    Uf             = 'SP'
                    Ambiente       = ([Ambiente]::Producao)
                    XmlPath        = 'D:\XML'
                    XmlPathNfse    = 'D:\NFSE'
                    XmlPathEntrada = 'D:\ENTRADA'
                    OutputPath     = 'D:\OUT'
                    EmailPara      = @('to@example.com')
                    EmailCc        = @('cc@example.com')
                    EmailCco       = @('bcc@example.com')
                    IsActive       = $false
                }

                Set-PipeCompany @setParams

                Should -Invoke -CommandName ConvertTo-NormalizedCnpj -Times 1 -Exactly
                Should -Invoke -CommandName Get-CompanyConfig -Times 2 -Exactly
                Should -Invoke -CommandName Assert-CompanyInput -Times 1 -Exactly
                Should -Invoke -CommandName ConvertTo-CompanyObject -Times 1 -Exactly
                Should -Invoke -CommandName Save-CompanyConfig -Times 1 -Exactly

                $Script:CapturedSaveCompany.RazaoSocial   | Should -Be 'ACME FINAL'
                $Script:CapturedSaveCompany.IsActive      | Should -BeFalse
                $Script:CapturedSaveCompany.CreatedAt     | Should -Be $Script:ExistingCompany.CreatedAt
                $Script:CapturedSaveCompany.SchemaVersion | Should -Be $Script:ExistingCompany.SchemaVersion
            }

            It 'Does not perform persistence when WhatIf is specified' {
                Set-PipeCompany -Cnpj $Script:Cnpj -RazaoSocial 'WHATIF UPDATE' -WhatIf

                Should -Invoke -CommandName ConvertTo-NormalizedCnpj -Times 1 -Exactly
                Should -Invoke -CommandName Get-CompanyConfig -Times 1 -Exactly
                Should -Invoke -CommandName Assert-CompanyInput -Times 1 -Exactly
                Should -Invoke -CommandName ConvertTo-CompanyObject -Times 1 -Exactly
                Should -Invoke -CommandName Save-CompanyConfig -Times 0 -Exactly
            }
        }
        #endregion
    }
}
