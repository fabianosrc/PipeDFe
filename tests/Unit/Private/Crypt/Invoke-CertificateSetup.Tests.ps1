#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Invoke-CertificateSetup.

.DESCRIPTION
Verifies that Invoke-CertificateSetup correctly handles both interactive
and non-interactive flows, validates certificate results and throws
structured terminating errors on failure.

Coverage includes:
  - Path is mandatory.
  - Password is optional.
  - When Password is supplied, Read-Host is never called.
  - When Password is supplied and certificate is valid, returns encrypted result.
  - Throws InvalidCertificate when the supplied password produces an invalid result.
  - Throws ExpiredCertificate when the certificate is expired.
  - Interactive flow calls Read-Host up to 3 times on repeated failure.
  - Interactive flow succeeds on the second attempt.
  - Throws InvalidCertificate after 3 failed interactive attempts.
  - Output exposes exactly EncryptedPassword and ExpiresOn.
  - EncryptedPassword is a string.
  - ExpiresOn is a DateTimeOffset.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingConvertToSecureStringWithPlainText',
    '',
    Justification = 'Plain text is acceptable in test context.'
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

Describe 'Invoke-CertificateSetup' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command        = Get-Command -Name Invoke-CertificateSetup -ErrorAction Stop
            $Script:CertPath       = 'C:\certs\empresa.pfx'
            $Script:SecurePassword = ConvertTo-SecureString -String 'correct' -AsPlainText -Force
            $Script:EncryptedBlob  = 'encrypted-blob'
            $Script:ExpiresOn      = [System.DateTimeOffset]::UtcNow.AddDays(365)

            $Script:ValidCertResult = [PSCustomObject]@{
                IsValid    = $true
                IsExpired  = $false
                ExpiresOn  = $Script:ExpiresOn
                Thumbprint = 'AABBCCDD'
                Subject    = 'CN=Test'
                Issuer     = 'CN=CA'
            }

            $Script:InvalidCertResult = [PSCustomObject]@{
                IsValid    = $false
                IsExpired  = $null
                ExpiresOn  = $null
                Thumbprint = $null
                Subject    = $null
                Issuer     = $null
            }

            $Script:ExpiredCertResult = [PSCustomObject]@{
                IsValid    = $true
                IsExpired  = $true
                ExpiresOn  = [System.DateTimeOffset]::UtcNow.AddDays(-1)
                Thumbprint = 'AABBCCDD'
                Subject    = 'CN=Test'
                Issuer     = 'CN=CA'
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Path as mandatory' {
                $mandatory = $Script:Command.Parameters['Path'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Password as optional' {
                $mandatory = $Script:Command.Parameters['Password'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -BeNullOrEmpty
            }

            It 'Declares Password as SecureString' {
                $Script:Command.Parameters['Password'].ParameterType |
                    Should -Be ([System.Security.SecureString])
            }
        }
        #endregion

        #region Non-interactive flow
        Context 'Non-interactive flow' {

            It 'Does not call Read-Host when Password is supplied' {
                Mock -CommandName Test-CertificateFile -MockWith {
                    $Script:ValidCertResult
                }

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    $Script:EncryptedBlob
                }

                Mock -CommandName Read-Host -MockWith {
                    $Script:SecurePassword
                }

                $invokeParams = @{
                    Path     = $Script:CertPath
                    Password = $Script:SecurePassword
                }

                Invoke-CertificateSetup @invokeParams

                Should -Invoke -CommandName Read-Host -Times 0 -Exactly
            }

            It 'Returns EncryptedPassword and ExpiresOn for a valid certificate' {
                Mock -CommandName Test-CertificateFile -MockWith {
                    $Script:ValidCertResult
                }

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    $Script:EncryptedBlob
                }

                $invokeParams = @{
                    Path     = $Script:CertPath
                    Password = $Script:SecurePassword
                }

                $result = Invoke-CertificateSetup @invokeParams

                $result.EncryptedPassword | Should -Be $Script:EncryptedBlob
                $result.ExpiresOn         | Should -Be $Script:ExpiresOn
            }

            It 'Throws InvalidCertificate when the supplied password is incorrect' {
                Mock -CommandName Test-CertificateFile -MockWith {
                    $Script:InvalidCertResult
                }

                $invokeParams = @{
                    Path        = $Script:CertPath
                    Password    = $Script:SecurePassword
                    ErrorAction = 'Stop'
                }

                $thrown = $null

                try {
                    Invoke-CertificateSetup @invokeParams
                } catch {
                    $thrown = $_
                }

                $thrown.FullyQualifiedErrorId | Should -BeLike 'InvalidCertificate*'
            }

            It 'Throws ExpiredCertificate when the certificate is expired' {
                Mock -CommandName Test-CertificateFile -MockWith {
                    $Script:ExpiredCertResult
                }

                $invokeParams = @{
                    Path        = $Script:CertPath
                    Password    = $Script:SecurePassword
                    ErrorAction = 'Stop'
                }

                $thrown = $null

                try {
                    Invoke-CertificateSetup @invokeParams
                } catch {
                    $thrown = $_
                }

                $thrown.FullyQualifiedErrorId | Should -BeLike 'ExpiredCertificate*'
            }

            It 'Uses InvalidArgument category for InvalidCertificate' {
                Mock -CommandName Test-CertificateFile -MockWith { $Script:InvalidCertResult }

                $invokeParams = @{
                    Path        = $Script:CertPath
                    Password    = $Script:SecurePassword
                    ErrorAction = 'Stop'
                }

                $thrown = $null

                try {
                    Invoke-CertificateSetup @invokeParams
                } catch {
                    $thrown = $_
                }

                $thrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidArgument)
            }

            It 'Uses InvalidArgument category for ExpiredCertificate' {
                Mock -CommandName Test-CertificateFile -MockWith {
                    $Script:ExpiredCertResult
                }

                $invokeParams = @{
                    Path        = $Script:CertPath
                    Password    = $Script:SecurePassword
                    ErrorAction = 'Stop'
                }

                $thrown = $null

                try {
                    Invoke-CertificateSetup @invokeParams
                } catch {
                    $thrown = $_
                }

                $thrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidArgument)
            }

            It 'Exposes Path as TargetObject for InvalidCertificate' {
                Mock -CommandName Test-CertificateFile -MockWith {
                    $Script:InvalidCertResult
                }

                $invokeParams = @{
                    Path        = $Script:CertPath
                    Password    = $Script:SecurePassword
                    ErrorAction = 'Stop'
                }

                $thrown = $null

                try {
                    Invoke-CertificateSetup @invokeParams
                } catch {
                    $thrown = $_
                }

                $thrown.TargetObject | Should -Be $Script:CertPath
            }
        }
        #endregion

        #region Interactive flow
        Context 'Interactive flow' {

            It 'Calls Read-Host when Password is not supplied' {
                Mock -CommandName Test-CertificateFile -MockWith {
                    $Script:ValidCertResult
                }

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    $Script:EncryptedBlob
                }

                Mock -CommandName Read-Host -MockWith {
                    $Script:SecurePassword
                }

                Invoke-CertificateSetup -Path $Script:CertPath

                Should -Invoke -CommandName Read-Host -Times 1 -Exactly
            }

            It 'Succeeds on the second attempt when the first password is wrong' {
                $Script:CallCount = 0

                Mock -CommandName Read-Host -MockWith {
                    $Script:SecurePassword
                }

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    $Script:EncryptedBlob
                }

                Mock -CommandName Test-CertificateFile -MockWith {
                    $Script:CallCount++

                    if ($Script:CallCount -eq 1) {
                        $Script:InvalidCertResult
                    } else {
                        $Script:ValidCertResult
                    }
                }

                $result = Invoke-CertificateSetup -Path $Script:CertPath

                $result.EncryptedPassword | Should -Be $Script:EncryptedBlob
                Should -Invoke -CommandName Read-Host -Times 2 -Exactly
            }

            It 'Calls Read-Host exactly 3 times before throwing' {
                Mock -CommandName Test-CertificateFile -MockWith {
                    $Script:InvalidCertResult
                }

                Mock -CommandName Read-Host -MockWith {
                    $Script:SecurePassword
                }

                try {
                    Invoke-CertificateSetup -Path $Script:CertPath -ErrorAction Stop
                } catch {
                    $null = $_
                }

                Should -Invoke -CommandName Read-Host -Times 3 -Exactly
            }

            It 'Throws InvalidCertificate after 3 failed attempts' {
                Mock -CommandName Test-CertificateFile -MockWith {
                    $Script:InvalidCertResult
                }

                Mock -CommandName Read-Host -MockWith {
                    $Script:SecurePassword
                }

                $thrown = $null

                try {
                    Invoke-CertificateSetup -Path $Script:CertPath -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown.FullyQualifiedErrorId | Should -BeLike 'InvalidCertificate*'
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                Mock -CommandName Test-CertificateFile -MockWith {
                    $Script:ValidCertResult
                }

                Mock -CommandName ConvertTo-DpapiString -MockWith {
                    $Script:EncryptedBlob
                }

                $invokeParams = @{
                    Path     = $Script:CertPath
                    Password = $Script:SecurePassword
                }

                $Script:Sample = Invoke-CertificateSetup @invokeParams
            }

            It 'Returns a PSCustomObject' {
                $Script:Sample | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly the documented properties' {
                $expected = @('EncryptedPassword', 'ExpiresOn')
                $actual   = @($Script:Sample.PSObject.Properties.Name)

                $actual | Should -Be $expected
            }

            It 'Exposes EncryptedPassword as string' {
                $Script:Sample.EncryptedPassword | Should -BeOfType [string]
            }

            It 'Exposes ExpiresOn as DateTimeOffset' {
                $Script:Sample.ExpiresOn | Should -BeOfType [System.DateTimeOffset]
            }
        }
        #endregion
    }
}
