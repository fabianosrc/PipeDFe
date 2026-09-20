#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Get-DFeEventoEntry.

.DESCRIPTION
Verifies that Get-DFeEventoEntry reads evento records correctly from a real
SQLite index initialised by Initialize-DFeIndex.

Coverage includes:
  - Cnpj and ChavePai are mandatory.
  - Cnpj and ChavePai enforce strict digit-only validation.
  - EventoTipo is optional.
  - No filter returns all eventos linked to the given ChavePai.
  - Results are ordered by dh_emi ascending.
  - EventoTipo filters by the requested evento type.
  - No output is produced when EventoTipo does not match.
  - No output is produced when ChavePai has no eventos.
  - CNPJ isolation prevents eventos from another CNPJ from being returned.
  - The output exposes exactly the documented public properties.
  - Output property types match the documented contract.
  - Nullable evento_tipo and dh_emi fields are handled correctly.
  - Read failures are converted to EventoEntryReadFailed.
  - Read failures use ReadError.
  - Read failures expose the database path as TargetObject.
  - Read failures preserve the original exception.

Tests use real SQLite files in an isolated temporary directory.
No production data is accessed.
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

Describe 'Get-DFeEventoEntry' {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $joinPathParams = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = 'PipeDFe.Tests-' + [guid]::NewGuid().ToString('N')
            }

            $Script:TempRoot = Join-Path @joinPathParams

            $newItemParams = @{
                Path        = $Script:TempRoot
                ItemType    = 'Directory'
                Force       = $true
                ErrorAction = 'Stop'
            }

            New-Item @newItemParams | Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot

            $Script:CnpjOne     = '12345678000199'
            $Script:CnpjTwo     = '98765432000100'
            $Script:ChavePaiOne = '1' * 44
            $Script:ChavePaiTwo = '2' * 44
            $Script:FilePath1   = 'C:\xml\evento1.xml'
            $Script:FilePath2   = 'C:\xml\evento2.xml'
            $Script:FilePath3   = 'C:\xml\evento3.xml'
            $Script:Sha256One   = 'a' * 64
            $Script:Sha256Two   = 'b' * 64
            $Script:Sha256Three = 'c' * 64

            Initialize-DFeIndex -Cnpj $Script:CnpjOne | Out-Null
            Initialize-DFeIndex -Cnpj $Script:CnpjTwo | Out-Null

            function New-TestDatabasePath {
                [OutputType([string])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj
                )

                Get-StorePath -Scope 'Index' -Cnpj $Cnpj
            }

            function Save-TestEvento {
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$ChavePai,

                    [Parameter(Mandatory)]
                    [string]$FilePath,

                    [Parameter()]
                    [AllowNull()]
                    [string]$EventoTipo,

                    [Parameter()]
                    [AllowNull()]
                    [string]$DhEmi,

                    [Parameter()]
                    [string]$Sha256 = [guid]::NewGuid().ToString('N'),

                    [Parameter()]
                    [string]$IndexedAt = '2026-08-16T12:00:00.0000000+00:00'
                )

                $databasePath     = New-TestDatabasePath -Cnpj $Cnpj
                $connectionString = 'Data Source={0};Version=3;' -f $databasePath
                $connection       = [System.Data.SQLite.SQLiteConnection]::new($connectionString)
                $transaction      = $null
                $command          = $null

                try {
                    $connection.Open()

                    $transaction             = $connection.BeginTransaction()
                    $command                 = $connection.CreateCommand()
                    $command.Transaction     = $transaction
                    $command.CommandText     = @'
INSERT OR REPLACE INTO dfe_evento (
    chave_pai, file_path, evento_tipo, dh_emi, sha256, indexed_at
) VALUES (
    @chave_pai, @file_path, @evento_tipo, @dh_emi, @sha256, @indexed_at
);
'@

                    $eventoTipoValue = if ($null -eq $EventoTipo) {
                        [System.DBNull]::Value
                    } else {
                        $EventoTipo
                    }

                    $dhEmiValue = if ($null -eq $DhEmi) {
                        [System.DBNull]::Value
                    } else {
                        $DhEmi
                    }

                    $command.Parameters.AddWithValue('@chave_pai',   $ChavePai)        | Out-Null
                    $command.Parameters.AddWithValue('@file_path',   $FilePath)        | Out-Null
                    $command.Parameters.AddWithValue('@evento_tipo', $eventoTipoValue) | Out-Null
                    $command.Parameters.AddWithValue('@dh_emi',      $dhEmiValue)      | Out-Null
                    $command.Parameters.AddWithValue('@sha256',      $Sha256)          | Out-Null
                    $command.Parameters.AddWithValue('@indexed_at',  $IndexedAt)       | Out-Null

                    $command.ExecuteNonQuery() | Out-Null
                    $transaction.Commit()
                } catch {
                    if ($null -ne $transaction) {
                        try {
                            $transaction.Rollback()
                        } catch {
                            $null = $_
                        }
                    }

                    throw
                } finally {
                    if ($null -ne $command) {
                        $command.Dispose()
                    }

                    if ($null -ne $transaction) {
                        $transaction.Dispose()
                    }

                    if ($null -ne $connection) {
                        $connection.Dispose()
                    }
                }
            }

            $saveParams1 = @{
                Cnpj       = $Script:CnpjOne
                ChavePai   = $Script:ChavePaiOne
                FilePath   = $Script:FilePath1
                EventoTipo = ([DFeEvento]::CartaCorrecao).ToString()
                DhEmi      = '2026-08-15T12:00:00.0000000+00:00'
                Sha256     = $Script:Sha256One
            }

            Save-TestEvento @saveParams1

            $saveParams2 = @{
                Cnpj       = $Script:CnpjOne
                ChavePai   = $Script:ChavePaiOne
                FilePath   = $Script:FilePath2
                EventoTipo = ([DFeEvento]::Cancelamento).ToString()
                DhEmi      = '2026-08-16T08:00:00.0000000+00:00'
                Sha256     = $Script:Sha256Two
            }

            Save-TestEvento @saveParams2

            $saveParams3 = @{
                Cnpj       = $Script:CnpjTwo
                ChavePai   = $Script:ChavePaiOne
                FilePath   = $Script:FilePath3
                EventoTipo = ([DFeEvento]::CartaCorrecao).ToString()
                Sha256     = $Script:Sha256Three
            }

            Save-TestEvento @saveParams3

            $saveParams4 = @{
                Cnpj       = $Script:CnpjOne
                ChavePai   = $Script:ChavePaiTwo
                FilePath   = 'C:\xml\evento4.xml'
                EventoTipo = $null
                DhEmi      = $null
                Sha256     = 'd' * 64
            }

            Save-TestEvento @saveParams4
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData

            $removeParams = @{
                LiteralPath = $Script:TempRoot
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeParams
        }
        #endregion

        #region Parameter contract
        Context 'Parameter contract' {

            BeforeAll {
                $Script:Command = Get-Command -Name Get-DFeEventoEntry -ErrorAction Stop
            }

            It 'Exposes the Cnpj parameter' {
                $Script:Command.Parameters.ContainsKey('Cnpj') | Should -BeTrue
            }

            It 'Declares Cnpj as a string' {
                $Script:Command.Parameters['Cnpj'].ParameterType | Should -Be ([string])
            }

            It 'Declares Cnpj as mandatory' {
                $mandatoryAttributes = @(
                    $Script:Command.Parameters['Cnpj'].Attributes |
                        Where-Object {
                            $_ -is [System.Management.Automation.ParameterAttribute] -and
                            $_.Mandatory
                        }
                )

                $mandatoryAttributes | Should -Not -BeNullOrEmpty
            }

            It 'Declares the expected Cnpj validation pattern' {
                $validationAttribute = $Script:Command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ValidatePatternAttribute]
                    } |

                    Select-Object -First 1

                $validationAttribute | Should -Not -BeNullOrEmpty
                $validationAttribute.RegexPattern | Should -Be '^[A-Z0-9]{14}$'
            }

            It 'Exposes the ChavePai parameter' {
                $Script:Command.Parameters.ContainsKey('ChavePai') | Should -BeTrue
            }

            It 'Declares ChavePai as a string' {
                $Script:Command.Parameters['ChavePai'].ParameterType | Should -Be ([string])
            }

            It 'Declares ChavePai as mandatory' {
                $mandatoryAttributes = @(
                    $Script:Command.Parameters['ChavePai'].Attributes |
                        Where-Object {
                            $_ -is [System.Management.Automation.ParameterAttribute] -and
                            $_.Mandatory
                        }
                )

                $mandatoryAttributes | Should -Not -BeNullOrEmpty
            }

            It 'Declares the expected ChavePai validation pattern' {
                $validationAttribute = $Script:Command.Parameters['ChavePai'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ValidatePatternAttribute]
                    } |

                    Select-Object -First 1

                $validationAttribute | Should -Not -BeNullOrEmpty
                $validationAttribute.RegexPattern | Should -Be '^\d{44}$'
            }

            It 'Exposes the EventoTipo parameter' {
                $Script:Command.Parameters.ContainsKey('EventoTipo') | Should -BeTrue
            }

            It 'Declares EventoTipo as DFeEvento' {
                $Script:Command.Parameters['EventoTipo'].ParameterType | Should -Be ([DFeEvento])
            }

            It 'Declares EventoTipo as optional' {
                $mandatoryAttributes = @(
                    $Script:Command.Parameters['EventoTipo'].Attributes |
                        Where-Object {
                            $_ -is [System.Management.Automation.ParameterAttribute] -and
                            $_.Mandatory
                        }
                )

                $mandatoryAttributes | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Successful read
        Context 'Successful read' {

            It 'Returns all eventos for the parent document' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    ChavePai    = $Script:ChavePaiOne
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeEventoEntry @getParams)
                $results | Should -HaveCount 2
            }

            It 'Returns results ordered by dh_emi ascending' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    ChavePai    = $Script:ChavePaiOne
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeEventoEntry @getParams)
                $dates   = @($results | Select-Object -ExpandProperty dh_emi)

                $dates | Should -Be @(
                    '2026-08-15T12:00:00.0000000+00:00'
                    '2026-08-16T08:00:00.0000000+00:00'
                )
            }

            It 'Returns the stored evento values' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    ChavePai    = $Script:ChavePaiOne
                    EventoTipo  = [DFeEvento]::CartaCorrecao
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeEventoEntry @getParams)
                $results | Should -HaveCount 1

                $results[0].chave_pai   | Should -Be $Script:ChavePaiOne
                $results[0].file_path   | Should -Be $Script:FilePath1
                $results[0].evento_tipo | Should -Be ([DFeEvento]::CartaCorrecao).ToString()
                $results[0].dh_emi      | Should -Be '2026-08-15T12:00:00.0000000+00:00'
                $results[0].sha256      | Should -Be $Script:Sha256One
                $results[0].indexed_at  | Should -Be '2026-08-16T12:00:00.0000000+00:00'
            }

            It 'Returns no output when ChavePai has no eventos' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    ChavePai    = ('3' * 44)
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeEventoEntry @getParams)
                $results | Should -HaveCount 0
            }
        }
        #endregion

        #region EventoTipo filter
        Context 'EventoTipo filter' {

            It 'Returns only eventos of the requested type' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    ChavePai    = $Script:ChavePaiOne
                    EventoTipo  = [DFeEvento]::CartaCorrecao
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeEventoEntry @getParams)
                $results | Should -HaveCount 1

                $results[0].file_path   | Should -Be $Script:FilePath1
                $results[0].evento_tipo | Should -Be ([DFeEvento]::CartaCorrecao).ToString()
            }

            It 'Returns no output when EventoTipo does not match' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    ChavePai    = $Script:ChavePaiOne
                    EventoTipo  = [DFeEvento]::Encerramento
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeEventoEntry @getParams)
                $results | Should -HaveCount 0
            }

            It 'Does not return eventos from another CNPJ when filtering by EventoTipo' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    ChavePai    = $Script:ChavePaiOne
                    EventoTipo  = [DFeEvento]::CartaCorrecao
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeEventoEntry @getParams)
                $results | Should -HaveCount 1

                $results[0].file_path | Should -Be $Script:FilePath1
                $results[0].file_path | Should -Not -Be $Script:FilePath3
            }
        }
        #endregion

        #region CNPJ isolation
        Context 'CNPJ isolation' {

            It 'Does not return eventos from another CNPJ' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    ChavePai    = $Script:ChavePaiOne
                    ErrorAction = 'Stop'
                }

                $results   = @(Get-DFeEventoEntry @getParams)
                $filePaths = @($results | Select-Object -ExpandProperty file_path)

                $filePaths | Should -Not -Contain $Script:FilePath3
            }

            It 'Returns only eventos belonging to the requested CNPJ' {
                $getParams = @{
                    Cnpj        = $Script:CnpjTwo
                    ChavePai    = $Script:ChavePaiOne
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeEventoEntry @getParams)

                $results | Should -HaveCount 1
                $results[0].file_path | Should -Be $Script:FilePath3
            }

            It 'Returns different results for the same ChavePai under different CNPJs' {
                $getParamsOne = @{
                    Cnpj        = $Script:CnpjOne
                    ChavePai    = $Script:ChavePaiOne
                    ErrorAction = 'Stop'
                }

                $getParamsTwo = @{
                    Cnpj        = $Script:CnpjTwo
                    ChavePai    = $Script:ChavePaiOne
                    ErrorAction = 'Stop'
                }

                $resultsOne = @(Get-DFeEventoEntry @getParamsOne)
                $resultsTwo = @(Get-DFeEventoEntry @getParamsTwo)

                $resultsOne | Should -HaveCount 2
                $resultsTwo | Should -HaveCount 1
                $resultsOne[0].file_path | Should -Not -Be $resultsTwo[0].file_path
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                $getParams = @{
                    Cnpj     = $Script:CnpjOne
                    ChavePai = $Script:ChavePaiOne
                }

                $Script:Sample = Get-DFeEventoEntry @getParams | Select-Object -First 1

                $Script:ExpectedProperties = @(
                    'chave_pai'
                    'file_path'
                    'evento_tipo'
                    'dh_emi'
                    'sha256'
                    'indexed_at'
                )
            }

            It 'Returns a PSCustomObject' {
                $Script:Sample | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly the documented properties' {
                $actual = @($Script:Sample.PSObject.Properties.Name)
                $actual | Should -Be $Script:ExpectedProperties
            }

            It 'Exposes chave_pai as string' {
                $Script:Sample.chave_pai | Should -BeOfType [string]
            }

            It 'Exposes file_path as string' {
                $Script:Sample.file_path | Should -BeOfType [string]
            }

            It 'Exposes evento_tipo as string' {
                $Script:Sample.evento_tipo | Should -BeOfType [string]
            }

            It 'Exposes dh_emi as string' {
                $Script:Sample.dh_emi | Should -BeOfType [string]
            }

            It 'Exposes sha256 as string' {
                $Script:Sample.sha256 | Should -BeOfType [string]
            }

            It 'Exposes indexed_at as string' {
                $Script:Sample.indexed_at | Should -BeOfType [string]
            }

            It 'Does not expose SQLite rowid' {
                $Script:Sample.PSObject.Properties.Name | Should -Not -Contain 'rowid'
            }

            It 'Does not expose Cnpj as an internal implementation field' {
                $Script:Sample.PSObject.Properties.Name | Should -Not -Contain 'cnpj'
            }
        }
        #endregion

        #region Nullable output
        Context 'Nullable output' {

            It 'Returns null for nullable evento fields when the database contains NULL' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    ChavePai    = $Script:ChavePaiTwo
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeEventoEntry @getParams)

                $results | Should -HaveCount 1
                $results[0].evento_tipo | Should -BeNullOrEmpty
                $results[0].dh_emi      | Should -BeNullOrEmpty
            }

            It 'Returns the non-null fields when nullable database fields are NULL' {
                $getParams = @{
                    Cnpj        = $Script:CnpjOne
                    ChavePai    = $Script:ChavePaiTwo
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeEventoEntry @getParams)

                $results[0].chave_pai  | Should -Be $Script:ChavePaiTwo
                $results[0].file_path  | Should -Be 'C:\xml\evento4.xml'
                $results[0].sha256     | Should -Be ('d' * 64)
                $results[0].indexed_at | Should -Be '2026-08-16T12:00:00.0000000+00:00'
            }
        }
        #endregion

        #region Cnpj validation
        Context 'Cnpj validation' {

            It 'Rejects a CNPJ shorter than 14 digits' {
                $getParams = @{
                    Cnpj     = '1234567800019'
                    ChavePai = $Script:ChavePaiOne
                }

                { Get-DFeEventoEntry @getParams } | Should -Throw
            }

            It 'Rejects a CNPJ longer than 14 digits' {
                $getParams = @{
                    Cnpj     = '123456780001990'
                    ChavePai = $Script:ChavePaiOne
                }

                { Get-DFeEventoEntry @getParams } | Should -Throw
            }

            It 'Rejects alphabetic characters' {
                $getParams = @{
                    Cnpj     = '1234567800019X'
                    ChavePai = $Script:ChavePaiOne
                }

                { Get-DFeEventoEntry @getParams } | Should -Throw
            }

            It 'Rejects punctuation characters' {
                $getParams = @{
                    Cnpj     = '12.345.678/0001-99'
                    ChavePai = $Script:ChavePaiOne
                }

                { Get-DFeEventoEntry @getParams } | Should -Throw
            }
        }
        #endregion

        #region ChavePai validation
        Context 'ChavePai validation' {

            It 'Rejects a ChavePai shorter than 44 digits' {
                $getParams = @{
                    Cnpj     = $Script:CnpjOne
                    ChavePai = '1' * 43
                }

                { Get-DFeEventoEntry @getParams } | Should -Throw
            }

            It 'Rejects a ChavePai longer than 44 digits' {
                $getParams = @{
                    Cnpj     = $Script:CnpjOne
                    ChavePai = '1' * 45
                }

                { Get-DFeEventoEntry @getParams } | Should -Throw
            }

            It 'Rejects alphabetic characters in ChavePai' {
                $getParams = @{
                    Cnpj     = $Script:CnpjOne
                    ChavePai = 'A' * 44
                }

                { Get-DFeEventoEntry @getParams } | Should -Throw
            }

            It 'Rejects punctuation characters in ChavePai' {
                $getParams = @{
                    Cnpj     = $Script:CnpjOne
                    ChavePai = '11111111111111111111111111111111111111111-11'
                }

                { Get-DFeEventoEntry @getParams } | Should -Throw
            }
        }
        #endregion

        #region Read failure
        Context 'Read failure' {

            BeforeAll {

                $Script:DatabasePath = Get-StorePath -Scope 'Index' -Cnpj '00000000000000'

                $Script:FailParams = @{
                    Cnpj        = '00000000000000'
                    ChavePai    = $Script:ChavePaiOne
                    ErrorAction = 'Stop'
                }

                $Script:Thrown = $null

                try {
                    Get-DFeEventoEntry @Script:FailParams
                } catch {
                    $Script:Thrown = $_
                }
            }

            It 'Throws EventoEntryReadFailed when the database does not exist' {
                $Script:Thrown | Should -Not -BeNullOrEmpty
                $Script:Thrown.FullyQualifiedErrorId | Should -BeLike 'EventoEntryReadFailed*'
            }

            It 'Uses ReadError for a read failure' {
                $Script:Thrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::ReadError)
            }

            It 'Uses the database path as TargetObject' {
                $Script:Thrown.TargetObject | Should -Be $Script:DatabasePath
            }

            It 'Does not produce output when a read fails' {
                $result = $null

                try {
                    $result = @(Get-DFeEventoEntry @Script:FailParams)
                } catch {
                    $null = $_
                }

                $result | Should -BeNullOrEmpty
            }
        }
        #endregion
    }
}
