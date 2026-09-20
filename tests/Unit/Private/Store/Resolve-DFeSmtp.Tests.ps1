#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Resolve-DFeSmtp.

.DESCRIPTION
Coverage includes:
  Parameter contract:
    - Company is mandatory.
    - Company rejects null.

  Company SMTP:
    - Returns company-specific SMTP when present.
    - Does not access global SMTP when company SMTP exists.

  Global SMTP fallback:
    - Falls back when Smtp is null.
    - Falls back when Smtp property is absent.
    - Calls Get-SmtpConfig exactly once during fallback.
    - Emits a verbose fallback message.

  No SMTP available:
    - Converts SmtpConfigNotFound into SmtpNotConfigured.
    - Uses InvalidOperation category.
    - Exposes Company as TargetObject.
    - Calls Get-SmtpConfig exactly once.

  Error propagation:
    - Propagates SmtpConfigInvalid.
    - Propagates unexpected errors from Get-SmtpConfig.
    - Does not convert unexpected errors into SmtpNotConfigured.

  Output contract:
    - Returns the exact company SMTP object.
    - Returns the exact global SMTP object.
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

Describe 'Resolve-DFeSmtp' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {
            $Script:Command = Get-Command -Name Resolve-DFeSmtp -ErrorAction Stop

            $Script:CompanySmtp = [PSCustomObject]@{
                Server   = 'smtp.company.com'
                Port     = 587
                Username = 'company@domain.com'
            }

            $Script:GlobalSmtp = [PSCustomObject]@{
                Server   = 'smtp.global.com'
                Port     = 587
                Username = 'global@domain.com'
            }

            $Script:Cnpj = '12345678000199'

            $Script:SmtpConfigNotFoundMock = {
                $PSCmdlet.ThrowTerminatingError(
                    [System.Management.Automation.ErrorRecord]::new(
                        [System.IO.FileNotFoundException]::new('smtp.json not found.'),
                        'SmtpConfigNotFound',
                        [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                        'smtp.json'
                    )
                )
            }

            $Script:SmtpConfigInvalidMock = {
                $PSCmdlet.ThrowTerminatingError(
                    [System.Management.Automation.ErrorRecord]::new(
                        [System.IO.InvalidDataException]::new('smtp.json failed validation.'),
                        'SmtpConfigInvalid',
                        [System.Management.Automation.ErrorCategory]::InvalidData,
                        'smtp.json'
                    )
                )
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Company as mandatory' {
                $mandatory = $Script:Command.Parameters['Company'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Rejects null Company' {
                { Resolve-DFeSmtp -Company $null } | Should -Throw
            }
        }
        #endregion

        #region Company SMTP
        Context 'Company SMTP' {

            It 'Returns the company Smtp when present' {
                $company = [PSCustomObject]@{
                    Cnpj = $Script:Cnpj
                    Smtp = $Script:CompanySmtp
                }

                $result = Resolve-DFeSmtp -Company $company

                $result | Should -Be $Script:CompanySmtp
            }

            It 'Does not call Get-SmtpConfig when company Smtp is present' {
                Mock -CommandName Get-SmtpConfig -MockWith {
                    $Script:GlobalSmtp
                }

                $company = [PSCustomObject]@{
                    Cnpj = $Script:Cnpj
                    Smtp = $Script:CompanySmtp
                }

                Resolve-DFeSmtp -Company $company | Out-Null

                Should -Invoke -CommandName Get-SmtpConfig -Times 0 -Exactly
            }
        }
        #endregion

        #region Global SMTP fallback
        Context 'Global SMTP fallback' {

            It 'Falls back to Get-SmtpConfig when company Smtp is null' {
                Mock -CommandName Get-SmtpConfig -MockWith {
                    $Script:GlobalSmtp
                }

                $company = [PSCustomObject]@{
                    Cnpj = $Script:Cnpj
                    Smtp = $null
                }

                $result = Resolve-DFeSmtp -Company $company

                $result | Should -Be $Script:GlobalSmtp
            }

            It 'Falls back to Get-SmtpConfig when company Smtp property is absent' {
                Mock -CommandName Get-SmtpConfig -MockWith {
                    $Script:GlobalSmtp
                }

                $company = [PSCustomObject]@{
                    Cnpj = $Script:Cnpj
                }

                $result = Resolve-DFeSmtp -Company $company

                $result | Should -Be $Script:GlobalSmtp
            }

            It 'Calls Get-SmtpConfig exactly once on fallback' {
                Mock -CommandName Get-SmtpConfig -MockWith {
                    $Script:GlobalSmtp
                }

                $company = [PSCustomObject]@{
                    Cnpj = $Script:Cnpj
                    Smtp = $null
                }

                Resolve-DFeSmtp -Company $company | Out-Null

                Should -Invoke -CommandName Get-SmtpConfig -Times 1 -Exactly
            }

            It 'Writes a verbose message when falling back to global SMTP' {
                Mock -CommandName Get-SmtpConfig -MockWith {
                    $Script:GlobalSmtp
                }

                Mock -CommandName Write-Verbose

                $company = [PSCustomObject]@{
                    Cnpj = $Script:Cnpj
                    Smtp = $null
                }

                Resolve-DFeSmtp -Company $company -Verbose

                Should -Invoke -CommandName Write-Verbose -Times 1 -Exactly -ParameterFilter {
                    $Message -like "*$($Script:Cnpj)*" -and
                    $Message -like '*Falling back to global SMTP*'
                }
            }
        }
        #endregion

        #region No SMTP available
        Context 'No SMTP available' {

            BeforeAll {

                Mock -CommandName Get-SmtpConfig -MockWith $Script:SmtpConfigNotFoundMock

                $Script:NoSmtpCompany = [PSCustomObject]@{
                    Cnpj = $Script:Cnpj
                    Smtp = $null
                }

                $Script:NoSmtpThrown = $null

                try {
                    Resolve-DFeSmtp -Company $Script:NoSmtpCompany -ErrorAction Stop
                } catch {
                    $Script:NoSmtpThrown = $_
                }
            }

            It 'Throws SmtpNotConfigured when global SMTP is not found' {
                $Script:NoSmtpThrown | Should -Not -BeNullOrEmpty
                $Script:NoSmtpThrown.FullyQualifiedErrorId | Should -BeLike 'SmtpNotConfigured*'
            }

            It 'Uses InvalidOperation category' {
                $Script:NoSmtpThrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidOperation)
            }

            It 'Exposes the company as TargetObject' {
                $Script:NoSmtpThrown.TargetObject | Should -Be $Script:NoSmtpCompany
            }

            It 'Calls Get-SmtpConfig exactly once when global SMTP is not found' {
                Mock -CommandName Get-SmtpConfig -MockWith $Script:SmtpConfigNotFoundMock

                $company = [PSCustomObject]@{
                    Cnpj = $Script:Cnpj
                    Smtp = $null
                }

                try {
                    Resolve-DFeSmtp -Company $company -ErrorAction Stop
                } catch {
                    $null = $_
                }

                Should -Invoke -CommandName Get-SmtpConfig -Times 1 -Exactly
            }
        }
        #endregion

        #region Error propagation
        Context 'Error propagation' {

            It 'Propagates SmtpConfigInvalid from Get-SmtpConfig' {
                Mock -CommandName Get-SmtpConfig -MockWith $Script:SmtpConfigInvalidMock

                $company = [PSCustomObject]@{
                    Cnpj = $Script:Cnpj
                    Smtp = $null
                }

                $thrown = $null

                try {
                    Resolve-DFeSmtp -Company $company -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown | Should -Not -BeNullOrEmpty
                $thrown.FullyQualifiedErrorId | Should -BeLike 'SmtpConfigInvalid*'
            }

            It 'Propagates unexpected errors from Get-SmtpConfig' {
                Mock -CommandName Get-SmtpConfig -MockWith {
                    throw [System.InvalidOperationException]::new('Unexpected SMTP store failure.')
                }

                $company = [PSCustomObject]@{
                    Cnpj = $Script:Cnpj
                    Smtp = $null
                }

                $thrown = $null

                try {
                    Resolve-DFeSmtp -Company $company -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown | Should -Not -BeNullOrEmpty
                $thrown.Exception | Should -BeOfType [System.InvalidOperationException]
                $thrown.Exception.Message | Should -Be 'Unexpected SMTP store failure.'
            }

            It 'Does not convert unexpected errors into SmtpNotConfigured' {
                Mock -CommandName Get-SmtpConfig -MockWith {
                    throw [System.InvalidOperationException]::new('Unexpected SMTP store failure.')
                }

                $company = [PSCustomObject]@{
                    Cnpj = $Script:Cnpj
                    Smtp = $null
                }

                $thrown = $null

                try {
                    Resolve-DFeSmtp -Company $company -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown.FullyQualifiedErrorId | Should -Not -BeLike 'SmtpNotConfigured*'
            }
        }
        #endregion
    }
}
