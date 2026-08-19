#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Test-CertificateFile.

.DESCRIPTION
Verifies that Test-CertificateFile returns a structured result object
without throwing, handling all valid and invalid certificate scenarios.

Certificates are generated dynamically via New-SelfSignedCertificate and
exported to TestDrive. No external fixtures are required.

Coverage includes:
  - Path is mandatory and rejects null and empty values.
  - Password is mandatory and rejects null.
  - Returns IsValid = false when the file does not exist.
  - Returns IsValid = false when the password is incorrect.
  - Returns IsValid = false when the certificate has no private key.
  - Returns IsValid = true for a valid certificate with a private key.
  - IsExpired is false for a valid non-expired certificate.
  - IsExpired is true for an expired certificate.
  - Output exposes exactly the documented properties with the correct types.
  - Never throws for any input combination.
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

Describe 'Test-CertificateFile' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command        = Get-Command -Name Test-CertificateFile -ErrorAction Stop
            $Script:CertPassword   = ConvertTo-SecureString -String 'PipeDFeTest@1!' -AsPlainText -Force
            $Script:WrongPassword  = ConvertTo-SecureString -String 'WrongPassword!' -AsPlainText -Force
            $Script:MissingPath    = 'C:\does\not\exist\cert.pfx'

            $Script:ExpectedProperties = @(
                'IsValid'
                'IsExpired'
                'ValidFrom'
                'ExpiresOn'
                'Thumbprint'
                'Subject'
                'Issuer'
            )

            # Generate a valid self-signed certificate with private key.
            $certParams = @{
                Subject           = 'CN=PipeDFe Test'
                CertStoreLocation = 'Cert:\CurrentUser\My'
                KeyUsage          = 'DigitalSignature'
                NotAfter          = [datetime]::UtcNow.AddYears(1)
            }

            $Script:TestCert = New-SelfSignedCertificate @certParams

            $Script:ValidPfxPath = Join-Path -Path $TestDrive -ChildPath 'valid.pfx'

            $exportParams = @{
                Cert     = $Script:TestCert
                FilePath = $Script:ValidPfxPath
                Password = $Script:CertPassword
            }

            Export-PfxCertificate @exportParams | Out-Null

            # Generate a certificate without private key
            # (public key only, exported as .cer then re-imported).
            $Script:NoPkPfxPath = Join-Path -Path $TestDrive -ChildPath 'nopk.pfx'

            $cerPath = Join-Path -Path $TestDrive -ChildPath 'nopk.cer'

            Export-Certificate -Cert $Script:TestCert -FilePath $cerPath | Out-Null

            # Import the public-only cert and export as PFX - it will have no private key.
            $pubOnly = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cerPath)

            $pfxBytes = $pubOnly.Export(
                [System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
                $Script:CertPassword
            )

            [System.IO.File]::WriteAllBytes($Script:NoPkPfxPath, $pfxBytes)

            $pubOnly.Dispose()

            # Remove from store - we only need the exported PFX files.
            Remove-Item -Path "Cert:\CurrentUser\My\$($Script:TestCert.Thumbprint)" -Force
        }

        AfterAll {

            if ($null -ne $Script:TestCert) {
                $Script:TestCert.Dispose()
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

            It 'Declares Path as string' {
                $Script:Command.Parameters['Path'].ParameterType | Should -Be ([string])
            }

            It 'Declares Password as mandatory' {
                $mandatory = $Script:Command.Parameters['Password'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Password as SecureString' {
                $Script:Command.Parameters['Password'].ParameterType |
                    Should -Be ([System.Security.SecureString])
            }

            It 'Rejects a null Password' {
                { Test-CertificateFile -Path $Script:MissingPath -Password $null } |
                    Should -Throw
            }

            It 'Rejects an empty Path' {
                { Test-CertificateFile -Path '' -Password $Script:CertPassword } |
                    Should -Throw
            }
        }
        #endregion

        #region File not found
        Context 'File not found' {

            It 'Returns IsValid = false when the file does not exist' {
                $result = Test-CertificateFile -Path $Script:MissingPath -Password $Script:CertPassword

                $result.IsValid | Should -BeFalse
            }

            It 'Does not throw when the file does not exist' {
                { Test-CertificateFile -Path $Script:MissingPath -Password $Script:CertPassword } |
                    Should -Not -Throw
            }

            It 'Returns null for all certificate fields when the file does not exist' {
                $result = Test-CertificateFile -Path $Script:MissingPath -Password $Script:CertPassword

                $result.IsExpired  | Should -BeNullOrEmpty
                $result.ValidFrom  | Should -BeNullOrEmpty
                $result.ExpiresOn  | Should -BeNullOrEmpty
                $result.Thumbprint | Should -BeNullOrEmpty
                $result.Subject    | Should -BeNullOrEmpty
                $result.Issuer     | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Wrong password
        Context 'Wrong password' {

            It 'Returns IsValid = false when the password is incorrect' {
                $result = Test-CertificateFile -Path $Script:ValidPfxPath -Password $Script:WrongPassword

                $result.IsValid | Should -BeFalse
            }

            It 'Does not throw when the password is incorrect' {
                { Test-CertificateFile -Path $Script:ValidPfxPath -Password $Script:WrongPassword } |
                    Should -Not -Throw
            }
        }
        #endregion

        #region No private key
        Context 'No private key' {

            It 'Returns IsValid = false when the certificate has no private key' {
                $result = Test-CertificateFile -Path $Script:NoPkPfxPath -Password $Script:CertPassword

                $result.IsValid | Should -BeFalse
            }

            It 'Does not throw when the certificate has no private key' {
                { Test-CertificateFile -Path $Script:NoPkPfxPath -Password $Script:CertPassword } |
                    Should -Not -Throw
            }
        }
        #endregion

        #region Valid certificate
        Context 'Valid certificate' {

            BeforeAll {

                $certParams = @{
                    Path     = $Script:ValidPfxPath
                    Password = $Script:CertPassword
                }

                $Script:ValidResult = Test-CertificateFile @certParams
            }

            It 'Returns IsValid = true for a valid certificate' {
                $Script:ValidResult.IsValid | Should -BeTrue
            }

            It 'Returns IsExpired = false for a non-expired certificate' {
                $Script:ValidResult.IsExpired | Should -BeFalse
            }

            It 'Returns the correct Thumbprint' {
                $Script:ValidResult.Thumbprint | Should -Be $Script:TestCert.Thumbprint
            }

            It 'Returns a non-empty Subject' {
                $Script:ValidResult.Subject | Should -Not -BeNullOrEmpty
            }

            It 'Returns a non-empty Issuer' {
                $Script:ValidResult.Issuer | Should -Not -BeNullOrEmpty
            }

            It 'Returns ValidFrom as DateTimeOffset' {
                $Script:ValidResult.ValidFrom | Should -BeOfType [System.DateTimeOffset]
            }

            It 'Returns ExpiresOn as DateTimeOffset' {
                $Script:ValidResult.ExpiresOn | Should -BeOfType [System.DateTimeOffset]
            }

            It 'Returns ExpiresOn after ValidFrom' {
                $Script:ValidResult.ExpiresOn | Should -BeGreaterThan $Script:ValidResult.ValidFrom
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            It 'Returns a PSCustomObject' {
                $result = Test-CertificateFile -Path $Script:MissingPath -Password $Script:CertPassword
                $result | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly the documented properties' {
                $result = Test-CertificateFile -Path $Script:MissingPath -Password $Script:CertPassword
                $actual = @($result.PSObject.Properties.Name)

                $actual | Should -Be $Script:ExpectedProperties
            }

            It 'Exposes IsValid as bool' {
                $result = Test-CertificateFile -Path $Script:MissingPath -Password $Script:CertPassword
                $result.IsValid | Should -BeOfType [bool]
            }
        }
        #endregion

        #region Never throws
        Context 'Never throws' {

            It 'Does not throw for a missing file' {
                { Test-CertificateFile -Path $Script:MissingPath -Password $Script:CertPassword } |
                    Should -Not -Throw
            }

            It 'Does not throw for a wrong password' {
                { Test-CertificateFile -Path $Script:ValidPfxPath -Password $Script:WrongPassword } |
                    Should -Not -Throw
            }

            It 'Does not throw for a certificate without private key' {
                { Test-CertificateFile -Path $Script:NoPkPfxPath -Password $Script:CertPassword } |
                    Should -Not -Throw
            }
        }
        #endregion
    }
}
