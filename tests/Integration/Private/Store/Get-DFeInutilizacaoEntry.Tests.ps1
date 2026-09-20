#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Get-DFeInutilizacaoEntry.

.DESCRIPTION
Coverage includes:
  - No filters: returns all inutilizacoes for the CNPJ.
  - Modelo filter.
  - Serie filter.
  - Modelo + Serie combined.
  - Empty result when no records match.
  - CNPJ isolation.
  - Result ordering: modelo ASC, serie ASC, nnf_ini ASC.
  - Output contract: property names and types.
  - Parameter validation: Cnpj mandatory and pattern.
  - Read failure produces InutilizacaoEntryReadFailed.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Test infrastructure helpers do not ship as module functions.'
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

Describe 'Get-DFeInutilizacaoEntry' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $testID = [guid]::NewGuid().ToString('N')

            $joinPathParams = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = 'PipeDFe.Tests-{0}' -f $testID
            }

            $Script:TempRoot = Join-Path @joinPathParams


            New-Item -Path $Script:TempRoot -ItemType Directory -Force | Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot

            $Script:CnpjOne = '12345678000199'
            $Script:CnpjTwo = '98765432000100'

            Initialize-DFeIndex -Cnpj $Script:CnpjOne | Out-Null
            Initialize-DFeIndex -Cnpj $Script:CnpjTwo | Out-Null

            function New-TestDatabasePath {
                [CmdletBinding()]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj
                )

                Get-StorePath -Scope 'Index' -Cnpj $Cnpj
            }

            function Save-TestInutilizacao {
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$IdInut,

                    [Parameter(Mandatory)]
                    [int]$Modelo,

                    [Parameter(Mandatory)]
                    [string]$Serie,

                    [Parameter(Mandatory)]
                    [int]$NnfIni,

                    [Parameter(Mandatory)]
                    [int]$NnfFin,

                    [Parameter()]
                    [string]$FilePath = 'C:\xml\inut.xml',

                    [Parameter()]
                    [string]$Sha256 = [guid]::NewGuid().ToString('N')
                )

                $databasePath     = New-TestDatabasePath -Cnpj $Cnpj
                $connectionString = "Data Source=$databasePath;Version=3;"

                $connection = [System.Data.SQLite.SQLiteConnection]::new($connectionString)

                try {
                    $connection.Open()
                    $transaction = $connection.BeginTransaction()

                    try {
                        $indexedAt = [System.DateTimeOffset]::UtcNow.ToString('o')

                        $cmd = $connection.CreateCommand()
                        $cmd.Transaction = $transaction
                        $cmd.CommandText = @'
INSERT OR REPLACE INTO dfe_inutilizacao (
    id_inut, modelo, serie, nnf_ini, nnf_fin, file_path, sha256, indexed_at
) VALUES (
    @id_inut, @modelo, @serie, @nnf_ini, @nnf_fin, @file_path, @sha256, @indexed_at
);
'@
                        $cmd.Parameters.AddWithValue('@id_inut',       $IdInut) | Out-Null
                        $cmd.Parameters.AddWithValue('@modelo',        $Modelo) | Out-Null
                        $cmd.Parameters.AddWithValue('@serie',          $Serie) | Out-Null
                        $cmd.Parameters.AddWithValue('@nnf_ini',       $NnfIni) | Out-Null
                        $cmd.Parameters.AddWithValue('@nnf_fin',       $NnfFin) | Out-Null
                        $cmd.Parameters.AddWithValue('@file_path',   $FilePath) | Out-Null
                        $cmd.Parameters.AddWithValue('@sha256',        $Sha256) | Out-Null
                        $cmd.Parameters.AddWithValue('@indexed_at', $indexedAt) | Out-Null

                        $cmd.ExecuteNonQuery() | Out-Null
                        $cmd.Dispose()
                        $transaction.Commit()
                    } catch {
                        $transaction.Rollback()
                        throw
                    } finally {
                        $transaction.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }

            # Fixtures: two models, two series, overlapping nnf ranges.
            $Script:InutNFe001A = @{
                IdInut = 'INUT001'
                Modelo = 55
                Serie  = '001'
                NnfIni = 1
                NnfFin = 10
            }
            $Script:InutNFe001B = @{
                IdInut = 'INUT002'
                Modelo = 55
                Serie  = '001'
                NnfIni = 20
                NnfFin = 30
            }
            $Script:InutNFe002 = @{
                IdInut = 'INUT003'
                Modelo = 55
                Serie  = '002'
                NnfIni = 5
                NnfFin = 15
            }
            $Script:InutCTe001 = @{
                IdInut = 'INUT004'
                Modelo = 57
                Serie  = '001'
                NnfIni = 1
                NnfFin = 5
            }

            $inutilizacao = @(
                $Script:InutNFe001A
                $Script:InutNFe001B
                $Script:InutNFe002
                $Script:InutCTe001
            )

            foreach ($inut in $inutilizacao) {
                $saveParams = @{
                    Cnpj   = $Script:CnpjOne
                    IdInut = $inut.IdInut
                    Modelo = $inut.Modelo
                    Serie  = $inut.Serie
                    NnfIni = $inut.NnfIni
                    NnfFin = $inut.NnfFin
                }

                Save-TestInutilizacao @saveParams
            }

            # One record in CnpjTwo for isolation tests.
            $Script:InutCnpjTwo = @{
                IdInut = 'INUT099'
                Modelo = 55
                Serie  = '001'
                NnfIni = 1
                NnfFin = 5
            }

            $saveParamsCnpjTwo = @{
                Cnpj   = $Script:CnpjTwo
                IdInut = $Script:InutCnpjTwo.IdInut
                Modelo = $Script:InutCnpjTwo.Modelo
                Serie  = $Script:InutCnpjTwo.Serie
                NnfIni = $Script:InutCnpjTwo.NnfIni
                NnfFin = $Script:InutCnpjTwo.NnfFin
            }

            Save-TestInutilizacao @saveParamsCnpjTwo
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData
            Remove-Item -LiteralPath $Script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        #region No filters
        Context 'No filters' {

            It 'Returns all inutilizacoes for the CNPJ' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeInutilizacaoEntry @getParams)

                $results | Should -HaveCount 4
            }

            It 'Returns results ordered by modelo, serie, nnf_ini ascending' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeInutilizacaoEntry @getParams)

                $results[0].id_inut | Should -Be $Script:InutNFe001A.IdInut
                $results[1].id_inut | Should -Be $Script:InutNFe001B.IdInut
                $results[2].id_inut | Should -Be $Script:InutNFe002.IdInut
                $results[3].id_inut | Should -Be $Script:InutCTe001.IdInut
            }
        }
        #endregion

        #region Modelo filter
        Context 'Modelo filter' {

            It 'Returns only inutilizacoes of the requested model' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    Modelo      = [ModeloDFe]::NFe
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeInutilizacaoEntry @getParams)

                $results | Should -HaveCount 3
                $results | ForEach-Object { $_.modelo | Should -Be 55 }
            }

            It 'Returns no output when no inutilizacoes match the model' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    Modelo      = [ModeloDFe]::MDFe
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeInutilizacaoEntry @getParams)

                $results | Should -HaveCount 0
            }
        }
        #endregion

        #region Serie filter
        Context 'Serie filter' {

            It 'Returns only inutilizacoes of the requested serie' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    Serie       = '001'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeInutilizacaoEntry @getParams)

                $results | Should -HaveCount 3
                $results | ForEach-Object { $_.serie | Should -Be '001' }
            }

            It 'Returns no output when no inutilizacoes match the serie' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    Serie       = '999'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeInutilizacaoEntry @getParams)

                $results | Should -HaveCount 0
            }
        }
        #endregion

        #region Modelo and Serie combined
        Context 'Modelo and Serie combined' {

            It 'Returns only inutilizacoes matching both filters' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    Modelo      = [ModeloDFe]::NFe
                    Serie       = '001'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeInutilizacaoEntry @getParams)

                $results | Should -HaveCount 2
                $results | ForEach-Object { $_.modelo | Should -Be 55 }
                $results | ForEach-Object { $_.serie  | Should -Be '001' }
            }

            It 'Returns no records when Modelo and Serie do not match any entry' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    Modelo      = [ModeloDFe]::NFe
                    Serie       = '999'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeInutilizacaoEntry @getParams)

                $results | Should -HaveCount 0
            }

            It 'Returns no output for an empty result set' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    Modelo      = [ModeloDFe]::MDFe
                    Serie       = '999'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeInutilizacaoEntry @getParams)

                $results | Should -HaveCount 0
            }
        }
        #endregion

        #region CNPJ isolation
        Context 'CNPJ isolation' {

            It 'Does not return inutilizacoes from another CNPJ' {
                $getParamsOne = @{
                    Cnpj        = $Script:CnpjOne
                    ErrorAction = 'Stop'
                }

                $getParamsTwo = @{
                    Cnpj        = $Script:CnpjTwo
                    ErrorAction = 'Stop'
                }

                $resultsOne = @(Get-DFeInutilizacaoEntry @getParamsOne)
                $resultsTwo = @(Get-DFeInutilizacaoEntry @getParamsTwo)

                $resultsOne | Should -HaveCount 4
                $resultsTwo | Should -HaveCount 1
                $resultsTwo[0].id_inut | Should -Be $Script:InutCnpjTwo.IdInut
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    ErrorAction = 'Stop'
                }

                $Script:Sample = @(Get-DFeInutilizacaoEntry @getParams)[0]
            }

            It 'Returns PSCustomObject entries' {
                $Script:Sample | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly the documented properties' {
                $expected = @(
                    'id_inut'
                    'modelo'
                    'serie'
                    'nnf_ini'
                    'nnf_fin'
                    'file_path'
                    'sha256'
                    'indexed_at'
                )

                $actual = @($Script:Sample.PSObject.Properties.Name)

                $actual | Should -Be $expected
            }

            It 'Exposes properties with the documented types' {
                $Script:Sample.id_inut    | Should -BeOfType [string]
                $Script:Sample.modelo     | Should -BeOfType [int]
                $Script:Sample.serie      | Should -BeOfType [string]
                $Script:Sample.nnf_ini    | Should -BeOfType [int]
                $Script:Sample.nnf_fin    | Should -BeOfType [int]
                $Script:Sample.file_path  | Should -BeOfType [string]
                $Script:Sample.sha256     | Should -BeOfType [string]
                $Script:Sample.indexed_at | Should -BeOfType [string]
            }
        }
        #endregion

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Cnpj as mandatory' {
                $parameter = (Get-Command Get-DFeInutilizacaoEntry).Parameters['Cnpj']

                $mandatory = $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region Cnpj validation
        Context 'Cnpj validation' {

            It 'Rejects a CNPJ shorter than 14 digits' {
                { Get-DFeInutilizacaoEntry -Cnpj '1234567800019' } | Should -Throw
            }

            It 'Rejects a CNPJ longer than 14 digits' {
                { Get-DFeInutilizacaoEntry -Cnpj '123456780001990' } |Should -Throw
            }

            It 'Rejects a CNPJ containing non-numeric characters' {
                { Get-DFeInutilizacaoEntry -Cnpj '12345678000!9' } |Should -Throw
            }
        }
        #endregion

        #region Read failure
        Context 'Read failure' {

            It 'Throws InutilizacaoEntryReadFailed when the database does not exist' {
                $thrown = $null

                try {
                    Get-DFeInutilizacaoEntry -Cnpj '00000000000000' -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown.FullyQualifiedErrorId | Should -BeLike 'InutilizacaoEntryReadFailed*'
            }
        }
        #endregion
    }
}
