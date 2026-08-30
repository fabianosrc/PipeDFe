#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-CompanyConfig and Read-CompanyFile.

.DESCRIPTION
All external I/O and private dependencies are mocked so that tests run
entirely in memory against a Pester TestDrive.

Coverage includes:
  Get-CompanyConfig - single-company path
    - Throws CompanyNotFound (terminating) when file is absent.
    - Returns a non-empty result when file exists.
    - Result is a [PSCustomObject] with TypeName PipeDFe.Company.
    - Correct scalar fields (Cnpj, RazaoSocial).
    - Get-StorePath is called with the correct Scope and Cnpj.

  Get-CompanyConfig - bulk path
    - Returns one object per company with a valid config file.
    - Returns all results as [PSCustomObject].
    - Silently skips subfolders that have no config file.
    - Emits a warning and continues when a file fails to deserialize.
    - Returns empty (no output) when the root folder does not exist.
    - Returns empty (no output) when the root folder has no subfolders.

  Read-CompanyFile
    - CreatedAt preserved as string (not coerced to DateTime).
    - UpdatedAt preserved as null when JSON value is null.
    - UpdatedAt preserved as string when JSON value is present.
    - Certificado block always present, even when absent in JSON.
    - Certificado.Path and .EncryptedPassword reflect stored values.
    - Email.Para, .Cc, .Cco always return as arrays.
    - Email arrays are empty arrays when JSON arrays are empty.
    - Email arrays filter out null entries.
    - TypeName PipeDFe.Company is inserted as the first entry.
    - TypeName PipeDFe.Company is present in the TypeNames list.

  ValidatePattern (CNPJ parameter)
    - Accepts conventional numeric CNPJ (14 digits).
    - Accepts alphanumeric CNPJ (uppercase letters + digits).
    - Rejects lowercase letters.
    - Rejects CNPJs shorter or longer than 14 characters.
    - Rejects an empty string passed explicitly.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
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

    # Shared fixture JSON - used by most contexts.
    # Defined in BeforeDiscovery so it is available during test collection.
    $Script:BaseJson = @'
{
    "SchemaVersion": 1,
    "Cnpj": "12345678000195",
    "Ie": null,
    "RazaoSocial": "ACME COMERCIO LTDA",
    "NomeFantasia": null,
    "Uf": "SP",
    "Ambiente": "Producao",
    "IsActive": true,
    "XmlPath": "C:\\ERP\\XML",
    "XmlPathNfse": null,
    "XmlPathEntrada": null,
    "OutputPath": "C:\\Out",
    "Certificado": {
        "Path": "C:\\cert.pfx",
        "EncryptedPassword": "dpapi-blob"
    },
    "Email": {
        "Para": [
            { "Nome": "Contador", "Email": "contador@example.com" }
        ],
        "Cc": [],
        "Cco": []
    },
    "Contato": {
        "Email": null,
        "Telefone": null
    },
    "Smtp": null,
    "CreatedAt": "2026-08-01T00:00:00.0000000+00:00",
    "UpdatedAt": null
}
'@
}

Describe 'Get-CompanyConfig' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Cnpj     = '12345678000195'
            $Script:BaseJson = @'
{
    "SchemaVersion": 1,
    "Cnpj": "12345678000195",
    "Ie": null,
    "RazaoSocial": "ACME COMERCIO LTDA",
    "NomeFantasia": null,
    "Uf": "SP",
    "Ambiente": "Producao",
    "IsActive": true,
    "XmlPath": "C:\\ERP\\XML",
    "XmlPathNfse": null,
    "XmlPathEntrada": null,
    "OutputPath": "C:\\Out",
    "Certificado": {
        "Path": "C:\\cert.pfx",
        "EncryptedPassword": "dpapi-blob"
    },
    "Email": {
        "Para": [
            { "Nome": "Contador", "Email": "contador@example.com" }
        ],
        "Cc": [],
        "Cco": []
    },
    "Contato": {
        "Email": null,
        "Telefone": null
    },
    "Smtp": null,
    "CreatedAt": "2026-08-01T00:00:00.0000000+00:00",
    "UpdatedAt": null
}
'@
            function New-TestCompanyFile {
                [OutputType([string])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$Json
                )

                $joinParams = @{
                    Path      = Join-Path -Path $TestDrive -ChildPath $Cnpj
                    ChildPath = 'config'
                }

                $file = Join-Path -Path (Join-Path @joinParams) -ChildPath "$Cnpj.json"

                New-Item -Path (Join-Path @joinParams) -ItemType Directory -Force | Out-Null
                [System.IO.File]::WriteAllText($file, $Json, [System.Text.UTF8Encoding]::new($true))

                $file
            }

            # Primary company file - used by single-company tests.
            New-TestCompanyFile -Cnpj $Script:Cnpj -Json $Script:BaseJson | Out-Null

            # Parameterized mock: Root → $TestDrive; Config → $TestDrive\<Cnpj>\config.
            # Two targeted mocks are registered; no ambiguous generic fallback.

            Mock -CommandName Get-StorePath -ParameterFilter {
                $Scope -eq 'Root'
            } -MockWith {
                $TestDrive
            }

            Mock -CommandName Get-StorePath -ParameterFilter {
                $Scope -eq 'Config'
            } -MockWith {
                param ([string]$Cnpj)

                $joinParams = @{
                    Path      = Join-Path -Path $TestDrive -ChildPath $Cnpj
                    ChildPath = 'config'
                }

                Join-Path @joinParams
            }
        }

        #region Single-company path
        Context 'Single-company path' {

            It 'Throws a terminating error with ErrorId CompanyNotFound when the file is absent' {
                { Get-CompanyConfig -Cnpj '99999999000191' } |
                    Should -Throw -ErrorId 'CompanyNotFound*'
            }

            It 'Returns a non-empty result when the file exists' {
                Get-CompanyConfig -Cnpj $Script:Cnpj | Should -Not -BeNullOrEmpty
            }

            It 'Returns a [PSCustomObject]' {
                Get-CompanyConfig -Cnpj $Script:Cnpj |
                    Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Returns an object whose first TypeName is PipeDFe.Company' {
                $result = Get-CompanyConfig -Cnpj $Script:Cnpj

                $result.PSObject.TypeNames[0] | Should -Be 'PipeDFe.Company'
            }

            It 'Returns the correct Cnpj' {
                (Get-CompanyConfig -Cnpj $Script:Cnpj).Cnpj | Should -Be $Script:Cnpj
            }

            It 'Returns the correct RazaoSocial' {
                (Get-CompanyConfig -Cnpj $Script:Cnpj).RazaoSocial |
                    Should -Be 'ACME COMERCIO LTDA'
            }

            It 'Calls Get-StorePath with Scope Config and the supplied Cnpj' {
                Get-CompanyConfig -Cnpj $Script:Cnpj | Out-Null
                Should -Invoke Get-StorePath -Times 1 -Exactly -ParameterFilter {
                    $Scope -eq 'Config' -and $Cnpj -eq '12345678000195'
                }
            }
        }
        #endregion

        #region Bulk path
        Context 'Bulk path' {

            BeforeAll {

                $Script:BulkCnpj2 = '98765432000100'

                $json2 = $Script:BaseJson
                $json2 = $json2 -replace '12345678000195', $Script:BulkCnpj2
                $json2 = $json2 -replace 'ACME COMERCIO LTDA', 'BETA INDUSTRIA LTDA'

                New-TestCompanyFile -Cnpj $Script:BulkCnpj2 -Json $json2 | Out-Null

                $Script:BulkResults = @(Get-CompanyConfig)
            }

            It 'Returns one result per registered company' {
                $Script:BulkResults | Should -HaveCount 2
            }

            It 'Returns all results as [PSCustomObject]' {
                $Script:BulkResults | ForEach-Object {
                    $_ | Should -BeOfType [System.Management.Automation.PSCustomObject]
                }
            }

            It 'Silently skips a subfolder that has no config file' {
                # Create a subfolder with no matching JSON file.
                $orphan = Join-Path -Path $TestDrive -ChildPath 'ORPHANFOLDER000AB'
                New-Item -Path $orphan -ItemType Directory -Force | Out-Null

                $cnpjs = @(Get-CompanyConfig | Select-Object -ExpandProperty Cnpj)

                $cnpjs | Should -Not -Contain 'ORPHANFOLDER000AB'

                # The two valid companies must still be present.
                $cnpjs | Should -Contain $Script:Cnpj
                $cnpjs | Should -Contain $Script:BulkCnpj2
            }

            It 'Emits a warning and continues when a file fails to deserialize' {
                $badCnpj    = '11111111000191'
                $joinParams = @{
                    Path      = Join-Path -Path $TestDrive -ChildPath $badCnpj
                    ChildPath = 'config'
                }

                New-Item -Path (Join-Path @joinParams) -ItemType Directory -Force | Out-Null

                $badFile = Join-Path -Path (Join-Path @joinParams) -ChildPath "$badCnpj.json"

                [System.IO.File]::WriteAllText(
                    $badFile,
                    'NOT VALID JSON }{',
                    [System.Text.UTF8Encoding]::new($true)
                )

                $results = @(
                    Get-CompanyConfig -WarningVariable warnings 3>&1 |
                        Where-Object {
                            $_ -isnot [System.Management.Automation.WarningRecord]
                        }
                )

                $warnings | Should -Not -BeNullOrEmpty

                # The two valid companies must still be returned.
                ($results | Select-Object -ExpandProperty Cnpj) |
                    Should -Contain $Script:Cnpj

                ($results | Select-Object -ExpandProperty Cnpj) |
                    Should -Contain $Script:BulkCnpj2
            }
        }
        #endregion

        #region Empty store
        Context 'Empty store - root does not exist' {

            It 'Returns no output when the root folder does not exist' {
                Mock -CommandName Get-StorePath -ParameterFilter {
                    $Scope -eq 'Root'
                } -MockWith {
                    'C:\DoesNotExist\PipeDFe'
                }

                @(Get-CompanyConfig) | Should -HaveCount 0
            }
        }

        Context 'Empty store - root exists but has no subfolders' {

            It 'Returns no output when the root folder has no subfolders' {
                $emptyRoot = Join-Path -Path $TestDrive -ChildPath 'EmptyRoot'
                New-Item -Path $emptyRoot -ItemType Directory -Force | Out-Null

                Mock -CommandName Get-StorePath -ParameterFilter {
                    $Scope -eq 'Root'
                } -MockWith {
                    $emptyRoot
                }

                @(Get-CompanyConfig) | Should -HaveCount 0
            }
        }
        #endregion

        #region Read-CompanyFile - timestamp preservation
        Context 'Read-CompanyFile - timestamp preservation' {

            It 'Returns CreatedAt as a string (not coerced to DateTime)' {
                $result = Get-CompanyConfig -Cnpj $Script:Cnpj

                $result.CreatedAt | Should -BeOfType [string]
                $result.CreatedAt | Should -Be '2026-08-01T00:00:00.0000000+00:00'
            }

            It 'Returns UpdatedAt as null when the JSON value is null' {
                $result = Get-CompanyConfig -Cnpj $Script:Cnpj

                $result.UpdatedAt | Should -BeNull
            }

            It 'Returns UpdatedAt as a string when a value is present in JSON' {
                $updatedCnpj = 'UPDT00000001AB'
                $json = $Script:BaseJson
                $json = $json -replace '12345678000195', $updatedCnpj
                $json = $json -replace '"UpdatedAt": null', '"UpdatedAt": "2026-08-15T08:00:00.0000000+00:00"'

                New-TestCompanyFile -Cnpj $updatedCnpj -Json $json | Out-Null

                $result = Get-CompanyConfig -Cnpj $updatedCnpj

                $result.UpdatedAt | Should -BeOfType [string]
                $result.UpdatedAt | Should -Be '2026-08-15T08:00:00.0000000+00:00'
            }
        }
        #endregion

        #region Read-CompanyFile - Certificado normalization
        Context 'Read-CompanyFile - Certificado normalization' {

            It 'Certificado block is always present' {
                (Get-CompanyConfig -Cnpj $Script:Cnpj).Certificado |
                    Should -Not -BeNull
            }

            It 'Certificado.Path contains the stored value' {
                (Get-CompanyConfig -Cnpj $Script:Cnpj).Certificado.Path |
                    Should -Be 'C:\cert.pfx'
            }

            It 'Certificado.EncryptedPassword contains the stored value' {
                (Get-CompanyConfig -Cnpj $Script:Cnpj).Certificado.EncryptedPassword |
                    Should -Be 'dpapi-blob'
            }

            It 'Certificado block is present with null values when the JSON block is absent' {
                $noCertCnpj = 'NOCERT00000001'

                $json = @'
                {
                    "Cnpj": "NOCERT00000001",
                    "CreatedAt": null,
                    "UpdatedAt": null,
                    "Email": {
                        "Para": [],
                        "Cc": [],
                        "Cco": []
                    }
                }
'@

                New-TestCompanyFile -Cnpj $noCertCnpj -Json $json | Out-Null

                $result = Get-CompanyConfig -Cnpj $noCertCnpj
                $result.Certificado                   | Should -Not -BeNull
                $result.Certificado.Path              | Should -BeNull
                $result.Certificado.EncryptedPassword | Should -BeNull
            }

            It 'Certificado.Path is null when configured as null in JSON' {
                $nullCertCnpj = 'NULLCERT000001'

                $json = $Script:BaseJson
                $json = $json -replace '12345678000195', $nullCertCnpj
                $json = $json -replace '"Path": "C:\\\\cert.pfx"', '"Path": null'
                $json = $json -replace '"EncryptedPassword": "dpapi-blob"', '"EncryptedPassword": null'

                New-TestCompanyFile -Cnpj $nullCertCnpj -Json $json | Out-Null

                $result = Get-CompanyConfig -Cnpj $nullCertCnpj

                $result.Certificado.Path              | Should -BeNull
                $result.Certificado.EncryptedPassword | Should -BeNull
            }
        }
        #endregion

        #region Read-CompanyFile - Email array normalization
        Context 'Read-CompanyFile - Email array normalization' {

            It 'Email.Para is always an array (unary-comma forces pipeline wrap)' {
                $result = Get-CompanyConfig -Cnpj $Script:Cnpj

                ,$result.Email.Para | Should -BeOfType [object[]]
            }

            It 'Email.Cc is always an array' {
                $result = Get-CompanyConfig -Cnpj $Script:Cnpj

                ,$result.Email.Cc | Should -BeOfType [object[]]
            }

            It 'Email.Cco is always an array' {
                $result = Get-CompanyConfig -Cnpj $Script:Cnpj

                ,$result.Email.Cco | Should -BeOfType [object[]]
            }

            It 'Email.Para contains the stored recipients' {
                $result = Get-CompanyConfig -Cnpj $Script:Cnpj

                $result.Email.Para          | Should -HaveCount 1
                $result.Email.Para[0].Email | Should -Be 'contador@example.com'
            }

            It 'Email.Para is an empty array when the JSON array is empty' {
                $result = Get-CompanyConfig -Cnpj $Script:Cnpj

                ,$result.Email.Cc | Should -BeOfType [object[]]
                $result.Email.Cc  | Should -HaveCount 0
            }

            It 'Email arrays filter out null entries' {
                $nullEntryCnpj = 'NULLEMAIL00001'

                $json = $Script:BaseJson
                $json = $json -replace '12345678000195', $nullEntryCnpj
                $json = $json -replace '"Para": \[\s*\{[^}]+\}\s*\]', '"Para": [null, { "Nome": "A", "Email": "a@b.com" }, null]'

                New-TestCompanyFile -Cnpj $nullEntryCnpj -Json $json | Out-Null

                $result = Get-CompanyConfig -Cnpj $nullEntryCnpj

                $result.Email.Para | Should -HaveCount 1
                $result.Email.Para[0].Email | Should -Be 'a@b.com'
            }

            It 'Email block is normalised to empty arrays when absent in JSON' {
                $noEmailCnpj = 'NOEMAIL0000001'

                $json = '{ "Cnpj": "NOEMAIL0000001", "CreatedAt": null, "UpdatedAt": null }'

                New-TestCompanyFile -Cnpj $noEmailCnpj -Json $json | Out-Null

                $result = Get-CompanyConfig -Cnpj $noEmailCnpj

                ,$result.Email.Para | Should -BeOfType [object[]]
                ,$result.Email.Cc   | Should -BeOfType [object[]]
                ,$result.Email.Cco  | Should -BeOfType [object[]]
                $result.Email.Para  | Should -HaveCount 0
            }
        }
        #endregion

        #region ValidatePattern - CNPJ parameter
        Context 'ValidatePattern - CNPJ parameter' {

            It 'Accepts a conventional numeric CNPJ (14 digits)' {
                # Function will look for the file and throw CompanyNotFound -
                # NOT a ValidationMetadataException, which means the pattern passed.
                { Get-CompanyConfig -Cnpj '01234567000189' } |
                    Should -Throw -ErrorId 'CompanyNotFound*'
            }

            It 'Accepts an alphanumeric CNPJ (uppercase letters + digits)' {
                { Get-CompanyConfig -Cnpj 'AB1234567890CD' } |
                    Should -Throw -ErrorId 'CompanyNotFound*'
            }

            It 'Rejects a CNPJ with lowercase letters' {
                { Get-CompanyConfig -Cnpj 'ab1234567890cd' } |
                    Should -Throw -ErrorId 'ParameterArgumentValidationError*'
            }

            It 'Rejects a CNPJ shorter than 14 characters' {
                { Get-CompanyConfig -Cnpj '1234567800019' } |
                    Should -Throw -ErrorId 'ParameterArgumentValidationError*'
            }

            It 'Rejects a CNPJ longer than 14 characters' {
                { Get-CompanyConfig -Cnpj '123456780001950' } |
                    Should -Throw -ErrorId 'ParameterArgumentValidationError*'
            }
        }
        #endregion
    }
}
