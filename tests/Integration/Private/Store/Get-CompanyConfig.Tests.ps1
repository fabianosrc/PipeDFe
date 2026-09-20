#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Get-CompanyConfig.

.DESCRIPTION
Exercises Get-CompanyConfig against real JSON files on disk, redirecting
$env:LOCALAPPDATA to a GUID-named temporary directory so that each test
run is fully isolated from the user's real store.  No mocks are used.

Coverage includes:
  Single-company read
    - Returns a non-empty result.
    - Result is a [PSCustomObject] with PipeDFe.Company as the first TypeName.
    - Correct scalar fields: Cnpj, RazaoSocial, Ie, Uf, Ambiente,
      XmlPath, XmlPathNfse, XmlPathEntrada (null), OutputPath.

  Timestamp preservation
    - CreatedAt returned as string, not coerced to [DateTime].
    - UpdatedAt returned as null when JSON value is null.
    - UpdatedAt returned as string when JSON value is an ISO 8601 string.

  Certificado normalization
    - Block always present when values are configured.
    - Path and EncryptedPassword reflect the stored values.
    - Block present with null values when the stored block has null values.

  Email array normalization
    - Para, Cc, Cco always returned as arrays (unary-comma assertion).
    - Para contains the expected recipient objects.
    - Empty arrays remain empty arrays.

  CompanyNotFound
    - Throws a terminating error with ErrorId CompanyNotFound.

  Bulk read
    - Returns an object for every company whose config file exists.
    - Each object is a [PSCustomObject].
    - Silently skips a subfolder that has no config file.

  CNPJ isolation
    - Each CNPJ reads its own file independently.

  Alphanumeric CNPJ
    - Accepts and correctly reads a company registered under an
      alphanumeric CNPJ.
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
}

Describe 'Get-CompanyConfig' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $testID = [guid]::NewGuid().ToString('N')

            # Redirect LOCALAPPDATA to an isolated temp directory.
            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                ('PipeDFe.IntegrationTests-{0}' -f $testID)
            )

            $newItemParams = @{
                Path        = $Script:TempRoot
                ItemType    = 'Directory'
                Force       = $true
                ErrorAction = 'Stop'
            }

            New-Item @newItemParams | Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot

            $Script:Cnpj    = '12345678000195'
            $Script:Utf8Bom = [System.Text.UTF8Encoding]::new($true)

            $Script:CompanyJson = @'
{
    "SchemaVersion": 1,
    "Cnpj": "12345678000195",
    "Ie": "123456789",
    "RazaoSocial": "ACME COMERCIO LTDA",
    "NomeFantasia": "ACME",
    "Uf": "SP",
    "Ambiente": "Producao",
    "IsActive": true,
    "XmlPath": "C:\\ERP\\XML",
    "XmlPathNfse": "C:\\ERP\\NFSe",
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
        "Email": "contato@acme.com",
        "Telefone": "11999999999"
    },
    "Smtp": null,
    "CreatedAt": "2026-08-01T12:00:00.0000000+00:00",
    "UpdatedAt": null
}
'@

            function New-CompanyFile {
                [CmdletBinding()]
                [OutputType([string])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$Json
                )

                $configPath = [System.IO.Path]::Combine(
                    $Script:TempRoot, 'PipeDFe', $Cnpj, 'config'
                )

                $newItemParams = @{
                    Path        = $configPath
                    ItemType    = 'Directory'
                    Force       = $true
                    ErrorAction = 'Stop'
                }

                New-Item @newItemParams | Out-Null

                $filePath = [System.IO.Path]::Combine($configPath, "$Cnpj.json")
                [System.IO.File]::WriteAllText($filePath, $Json, $Script:Utf8Bom)

                $filePath
            }

            # Create the primary company file used by most contexts.
            New-CompanyFile -Cnpj $Script:Cnpj -Json $Script:CompanyJson | Out-Null
        }

        AfterAll {

            # Always restore LOCALAPPDATA, even when tests fail.
            $env:LOCALAPPDATA = $Script:OriginalLocalAppData
            $removeItemParams = @{
                LiteralPath = $Script:TempRoot
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeItemParams
            # Module cleanup is intentionally omitted: the test runner (Invoke-Pester)
            # is responsible for module lifecycle; removing it here would interfere
            # with other test files in the same run.
        }

        #region Single-company read
        Context 'Single-company read' {

            BeforeAll {

                $Script:Result = Get-CompanyConfig -Cnpj $Script:Cnpj
            }

            It 'Returns a non-empty result' {
                $Script:Result | Should -Not -BeNullOrEmpty
            }

            It 'Returns a [PSCustomObject]' {
                $Script:Result | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Inserts PipeDFe.Company as the first TypeName' {
                $Script:Result.PSObject.TypeNames[0] | Should -Be 'PipeDFe.Company'
            }

            It 'PipeDFe.Company is present anywhere in TypeNames' {
                $Script:Result.PSObject.TypeNames | Should -Contain 'PipeDFe.Company'
            }

            It 'Returns the correct Cnpj' {
                $Script:Result.Cnpj | Should -Be $Script:Cnpj
            }

            It 'Returns the correct RazaoSocial' {
                $Script:Result.RazaoSocial | Should -Be 'ACME COMERCIO LTDA'
            }

            It 'Returns the correct Ie' {
                $Script:Result.Ie | Should -Be '123456789'
            }

            It 'Returns the correct Uf' {
                $Script:Result.Uf | Should -Be 'SP'
            }

            It 'Returns the correct Ambiente' {
                $Script:Result.Ambiente | Should -Be 'Producao'
            }

            It 'Returns the correct XmlPath' {
                $Script:Result.XmlPath | Should -Be 'C:\ERP\XML'
            }

            It 'Returns the correct XmlPathNfse' {
                $Script:Result.XmlPathNfse | Should -Be 'C:\ERP\NFSe'
            }

            It 'Returns XmlPathEntrada as null' {
                $Script:Result.XmlPathEntrada | Should -BeNull
            }

            It 'Returns the correct OutputPath' {
                $Script:Result.OutputPath | Should -Be 'C:\Out'
            }
        }
        #endregion

        #region Timestamp preservation
        Context 'Timestamp preservation' {

            It 'CreatedAt is a string (not coerced to [DateTime])' {
                $result = Get-CompanyConfig -Cnpj $Script:Cnpj

                $result.CreatedAt | Should -BeOfType [string]
                $result.CreatedAt | Should -Be '2026-08-01T12:00:00.0000000+00:00'
            }

            It 'UpdatedAt is null when the JSON value is null' {
                $result = Get-CompanyConfig -Cnpj $Script:Cnpj

                $result.UpdatedAt | Should -BeNull
            }

            It 'UpdatedAt is a string when a value is present in JSON' {
                $updatedCnpj = '11111111000191'

                $json = $Script:CompanyJson
                $json = $json -replace '12345678000195', $updatedCnpj
                $json = $json -replace '"UpdatedAt": null', '"UpdatedAt": "2026-08-15T08:00:00.0000000+00:00"'

                New-CompanyFile -Cnpj $updatedCnpj -Json $json | Out-Null

                $result = Get-CompanyConfig -Cnpj $updatedCnpj

                $result.UpdatedAt | Should -BeOfType [string]
                $result.UpdatedAt | Should -Be '2026-08-15T08:00:00.0000000+00:00'
            }
        }
        #endregion

        #region Certificado normalization
        Context 'Certificado normalization' {

            It 'Certificado block is present' {
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

            It 'Certificado block is present with null values when stored values are null' {
                $noCertCnpj = '22222222000172'

                $json = $Script:CompanyJson
                $json = $json -replace '12345678000195', $noCertCnpj
                $json = $json -replace '"Path": "C:\\\\cert.pfx"', '"Path": null'
                $json = $json -replace '"EncryptedPassword": "dpapi-blob"', '"EncryptedPassword": null'

                New-CompanyFile -Cnpj $noCertCnpj -Json $json | Out-Null

                $result = Get-CompanyConfig -Cnpj $noCertCnpj

                $result.Certificado                   | Should -Not -BeNull
                $result.Certificado.Path              | Should -BeNull
                $result.Certificado.EncryptedPassword | Should -BeNull
            }
        }
        #endregion

        #region Email array normalization
        Context 'Email array normalization' {

            It 'Email.Para is always an array' {
                $result = Get-CompanyConfig -Cnpj $Script:Cnpj

                ,$result.Email.Para | Should -BeOfType [object[]]
            }

            It 'Email.Para contains the stored recipients' {
                $result = Get-CompanyConfig -Cnpj $Script:Cnpj

                $result.Email.Para             | Should -HaveCount 1
                $result.Email.Para[0].Email    | Should -Be 'contador@example.com'
                $result.Email.Para[0].Nome     | Should -Be 'Contador'
            }

            It 'Email.Cc is always an array' {
                $result = Get-CompanyConfig -Cnpj $Script:Cnpj

                ,$result.Email.Cc | Should -BeOfType [object[]]
            }

            It 'Email.Cco is always an array' {
                $result = Get-CompanyConfig -Cnpj $Script:Cnpj

                ,$result.Email.Cco | Should -BeOfType [object[]]
            }

            It 'Empty JSON arrays remain empty arrays' {
                $result = Get-CompanyConfig -Cnpj $Script:Cnpj

                $result.Email.Cc  | Should -HaveCount 0
                $result.Email.Cco | Should -HaveCount 0
            }
        }
        #endregion

        #region CompanyNotFound
        Context 'CompanyNotFound' {

            It 'Throws a terminating error with ErrorId CompanyNotFound when file is absent' {
                { Get-CompanyConfig -Cnpj '99999999000191' } |
                    Should -Throw -ErrorId 'CompanyNotFound*'
            }
        }
        #endregion

        #region Bulk read
        Context 'Bulk read' {

            BeforeAll {

                $Script:BulkCnpj2 = '33333333000187'

                $json2 = $Script:CompanyJson
                $json2 = $json2 -replace '12345678000195', $Script:BulkCnpj2
                $json2 = $json2 -replace 'ACME COMERCIO LTDA', 'BETA INDUSTRIA LTDA'

                New-CompanyFile -Cnpj $Script:BulkCnpj2 -Json $json2 | Out-Null

                $Script:BulkResults = @(Get-CompanyConfig)
            }

            It 'Returns an object for each registered company' {
                $cnpjs = @($Script:BulkResults | Select-Object -ExpandProperty Cnpj)

                $cnpjs | Should -Contain $Script:Cnpj
                $cnpjs | Should -Contain $Script:BulkCnpj2
            }

            It 'Returns [PSCustomObject] for each company' {
                $Script:BulkResults | ForEach-Object {
                    $_ | Should -BeOfType [System.Management.Automation.PSCustomObject]
                }
            }

            It 'Silently skips a subfolder without a config file' {
                $orphan = [System.IO.Path]::Combine(
                    $Script:TempRoot, 'PipeDFe', 'NOTACOMPANY123AB'
                )

                New-Item -Path $orphan -ItemType Directory -Force | Out-Null

                $cnpjs = @(Get-CompanyConfig | Select-Object -ExpandProperty Cnpj)
                $cnpjs | Should -Not -Contain 'NOTACOMPANY123AB'
                $cnpjs | Should -Contain $Script:Cnpj
                $cnpjs | Should -Contain $Script:BulkCnpj2
            }
        }
        #endregion

        #region CNPJ isolation
        Context 'CNPJ isolation' {

            # $Script:BulkCnpj2 was created in the 'Bulk read' BeforeAll above.
            # Redeclare it here so this context is self-contained if Bulk read
            # is skipped or run in isolation.
            BeforeAll {

                $Script:IsolationCnpj2 = '33333333000187'

                if (-not (Get-CompanyConfig -Cnpj $Script:IsolationCnpj2 -ErrorAction SilentlyContinue)) {
                    $json2 = $Script:CompanyJson
                    $json2 = $json2 -replace '12345678000195', $Script:IsolationCnpj2
                    $json2 = $json2 -replace 'ACME COMERCIO LTDA', 'BETA INDUSTRIA LTDA'

                    New-CompanyFile -Cnpj $Script:IsolationCnpj2 -Json $json2 | Out-Null
                }
            }

            It 'Each CNPJ reads its own company file' {
                $result1 = Get-CompanyConfig -Cnpj $Script:Cnpj
                $result2 = Get-CompanyConfig -Cnpj $Script:IsolationCnpj2

                $result1.RazaoSocial | Should -Be 'ACME COMERCIO LTDA'
                $result2.RazaoSocial | Should -Be 'BETA INDUSTRIA LTDA'
                $result1.Cnpj        | Should -Be $Script:Cnpj
                $result2.Cnpj        | Should -Be $Script:IsolationCnpj2
            }
        }
        #endregion

        #region Alphanumeric CNPJ
        Context 'Alphanumeric CNPJ' {

            BeforeAll {

                $Script:AlphaCnpj = 'AB1234567890CD'

                $alphaJson = $Script:CompanyJson
                $alphaJson = $alphaJson -replace '12345678000195', $Script:AlphaCnpj
                $alphaJson = $alphaJson -replace 'ACME COMERCIO LTDA', 'GAMMA TECH LTDA'

                New-CompanyFile -Cnpj $Script:AlphaCnpj -Json $alphaJson | Out-Null

                $Script:AlphaResult = Get-CompanyConfig -Cnpj $Script:AlphaCnpj
            }

            It 'Returns a result for an alphanumeric CNPJ' {
                $Script:AlphaResult | Should -Not -BeNullOrEmpty
            }

            It 'Returns the correct Cnpj for an alphanumeric CNPJ' {
                $Script:AlphaResult.Cnpj | Should -Be $Script:AlphaCnpj
            }

            It 'Returns the correct RazaoSocial for an alphanumeric CNPJ' {
                $Script:AlphaResult.RazaoSocial | Should -Be 'GAMMA TECH LTDA'
            }

            It 'Inserts PipeDFe.Company TypeName for an alphanumeric CNPJ' {
                $Script:AlphaResult.PSObject.TypeNames[0] | Should -Be 'PipeDFe.Company'
            }
        }
        #endregion
    }
}
