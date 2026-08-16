#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration and contract tests for Get-DFeDocumentEntry.

.DESCRIPTION
Verifies the public contract and integration behavior of Get-DFeDocumentEntry.

Coverage includes:
  - Cnpj is mandatory.
  - Cnpj must contain exactly 14 digits.
  - StartDate is optional.
  - EndDate is optional.
  - Modelo is optional.
  - the declared output type is PSCustomObject.
  - the index path is resolved for the supplied CNPJ.
  - real SQLite data is returned correctly.
  - all documents are returned when no filters are supplied.
  - results are ordered by dh_emi ascending.
  - StartDate is inclusive.
  - EndDate is inclusive.
  - StartDate and EndDate can be combined.
  - Modelo filters by its numeric value.
  - Modelo can be combined with a period filter.
  - no output is produced when no records match.
  - documents from another CNPJ are not returned.
  - the output exposes exactly the documented properties.
  - output property types match the documented contract.
  - internal database fields are not exposed.
  - invalid dates preserve UnsupportedDateFormat.
  - database/read failures are converted to DocumentEntryReadFailed.
  - read failures use ReadError.
  - read failures expose the database path as TargetObject.
  - read failures preserve the original exception.
  - read failures do not produce output.

The success-path tests use real SQLite databases created in an isolated
temporary directory.

The failure-path tests mock Open-SqliteConnection so that failures are
deterministic and independent of SQLite provider behavior.

No production data is accessed.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
)]

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    '',
    Justification = 'Required by the mocked command signature.'
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

Describe 'Get-DFeDocumentEntry' {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            $testID = [guid]::NewGuid().ToString('N')

            $joinPathParams = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = 'PipeDFe.Get-DFeDocumentEntry.Tests-' -f $testID
            }

            $Script:TestRoot = Join-Path @joinPathParams

            $newItemParams = @{
                Path        = $Script:TestRoot
                ItemType    = 'Directory'
                Force       = $true
                ErrorAction = 'Stop'
            }

            New-Item @newItemParams | Out-Null

            $Script:CnpjOne = '12345678000199'
            $Script:CnpjTwo = '98765432000100'

            function New-TestDatabasePath {
                [OutputType([string])]
                param ()

                Join-Path -Path $Script:TestRoot -ChildPath ([guid]::NewGuid().ToString('N') + '.db')
            }

            function New-TestConnection {
                [OutputType([System.Data.SQLite.SQLiteConnection])]
                param (
                    [Parameter(Mandatory)]
                    [string]$DatabasePath
                )

                $connectionString = "Data Source=$DatabasePath;Version=3;"
                $connection = [System.Data.SQLite.SQLiteConnection]::new($connectionString)

                try {
                    $connection.Open()

                    $connection
                } catch {
                    $connection.Dispose()
                    throw
                }
            }

            function Close-TestConnection {
                param (
                    [AllowNull()]
                    [System.Data.SQLite.SQLiteConnection]$Connection
                )

                if ($null -ne $Connection) {
                    try {
                        $Connection.Dispose()
                    } catch {
                        $null = $_
                    }
                }
            }

            function Invoke-TestNonQuery {
                param (
                    [Parameter(Mandatory)]
                    [System.Data.SQLite.SQLiteConnection]$Connection,

                    [Parameter(Mandatory)]
                    [string]$CommandText
                )

                $command = $null

                try {
                    $command = $Connection.CreateCommand()
                    $command.CommandText = $CommandText

                    $command.ExecuteNonQuery()
                } finally {
                    if ($null -ne $command) {
                        $command.Dispose()
                    }
                }
            }

            function New-TestSchema {
                param (
                    [Parameter(Mandatory)]
                    [System.Data.SQLite.SQLiteConnection]$Connection
                )

                Invoke-TestNonQuery -Connection $Connection -CommandText @'
CREATE TABLE dfe_document (
    chave_acesso TEXT NOT NULL,
    modelo       INTEGER NOT NULL,
    dh_emi       TEXT NOT NULL,
    file_path    TEXT NOT NULL,
    is_proc      INTEGER NOT NULL,
    sha256       TEXT NOT NULL,
    indexed_at   TEXT NOT NULL
);
'@ | Out-Null
            }

            function New-TestDocument {
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$ChaveAcesso,

                    [Parameter()]
                    [ModeloDFe]$Modelo = [ModeloDFe]::NFe,

                    [Parameter()]
                    [string]$DhEmi = '2026-08-15T12:00:00.0000000-03:00',

                    [Parameter()]
                    [string]$FilePath = 'C:\xml\doc.xml',

                    [Parameter()]
                    [bool]$IsProc = $false,

                    [Parameter()]
                    [string]$Sha256 = ([guid]::NewGuid().ToString('N')),

                    [Parameter()]
                    [string]$IndexedAt = '2026-08-15T12:00:00.0000000-03:00'
                )

                [PSCustomObject]@{
                    ChaveAcesso = $ChaveAcesso
                    Modelo      = $Modelo
                    DhEmi       = $DhEmi
                    FilePath    = $FilePath
                    IsProc      = $IsProc
                    Sha256      = $Sha256
                    IndexedAt   = $IndexedAt
                }
            }

            function Save-TestDocument {
                param (
                    [Parameter(Mandatory)]
                    [System.Data.SQLite.SQLiteConnection]$Connection,

                    [Parameter(Mandatory)]
                    [pscustomobject]$Document
                )

                $command = $null

                try {
                    $dhEmiUtc = [System.DateTimeOffset]::Parse($Document.DhEmi).ToUniversalTime().ToString('o')
                    $command  = $Connection.CreateCommand()

                    $command.CommandText = @'
INSERT INTO dfe_document (
    chave_acesso, modelo, dh_emi, file_path, is_proc, sha256, indexed_at
) VALUES (
    @chave_acesso, @modelo, @dh_emi, @file_path, @is_proc, @sha256, @indexed_at
);
'@

                    $command.Parameters.AddWithValue('@chave_acesso', $Document.ChaveAcesso)  | Out-Null
                    $command.Parameters.AddWithValue('@modelo', [int]$Document.Modelo)        | Out-Null
                    $command.Parameters.AddWithValue('@dh_emi', $dhEmiUtc)                    | Out-Null
                    $command.Parameters.AddWithValue('@file_path', $Document.FilePath)        | Out-Null
                    $command.Parameters.AddWithValue('@is_proc', [int][bool]$Document.IsProc) | Out-Null
                    $command.Parameters.AddWithValue('@sha256', $Document.Sha256)             | Out-Null
                    $command.Parameters.AddWithValue('@indexed_at', $Document.IndexedAt)      | Out-Null

                    $command.ExecuteNonQuery() | Out-Null
                } finally {
                    if ($null -ne $command) {
                        $command.Dispose()
                    }
                }
            }

            function New-TestIndex {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                    'PSReviewUnusedParameter',
                    'Cnpj',
                    Justification = 'Required by the test contract.'
                )]
                [OutputType([string])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj
                )

                $databasePath = New-TestDatabasePath
                $connection = $null

                try {
                    $connection = New-TestConnection -DatabasePath $databasePath
                    New-TestSchema -Connection $connection

                    $databasePath
                } finally {
                    Close-TestConnection -Connection $connection
                }
            }

            $Script:DatabasePathCnpjOne = New-TestIndex -Cnpj $Script:CnpjOne
            $Script:DatabasePathCnpjTwo = New-TestIndex -Cnpj $Script:CnpjTwo

            $docJulyParams = @{
                ChaveAcesso = ('0' * 44)
                DhEmi       = '2026-07-31T23:59:59.0000000+00:00'
            }

            $Script:DocJuly  = New-TestDocument @docJulyParams

            $docAug01Params = @{
                ChaveAcesso = ('1' * 44)
                DhEmi       = '2026-08-01T00:00:00.0000000+00:00'
            }

            $Script:DocAug01 = New-TestDocument @docAug01Params

            $docAug15Params = @{
                ChaveAcesso = ('2' * 44)
                DhEmi       = '2026-08-15T12:00:00.0000000+00:00'
                IsProc      = $true
            }

            $Script:DocAug15 = New-TestDocument @docAug15Params

            $docAug31Params = @{
                ChaveAcesso = ('3' * 44)
                DhEmi       = '2026-08-31T23:59:59.0000000+00:00'
            }

            $Script:DocAug31 = New-TestDocument @docAug31Params

            $docStepParams = @{
                ChaveAcesso = ('4' * 44)
                DhEmi       = '2026-09-01T00:00:00.0000000+00:00'
            }

            $Script:DocSep   = New-TestDocument @docStepParams

            $docCteParams = @{
                ChaveAcesso = ('5' * 44)
                Modelo      = ([ModeloDFe]::CTe)
                DhEmi       = '2026-08-15T12:00:00.0000000+00:00'
            }

            $Script:DocCte   = New-TestDocument @docCteParams

            $docCnpjTwoParams = @{
                ChaveAcesso = ('6' * 44)
                DhEmi       = '2026-08-15T12:00:00.0000000+00:00'
            }

            $Script:DocCnpjTwo = New-TestDocument @docCnpjTwoParams

            $setupConnection = $null

            try {
                $setupConnection = New-TestConnection -DatabasePath $Script:DatabasePathCnpjOne

                $documents = @(
                    $Script:DocJuly
                    $Script:DocAug01
                    $Script:DocAug15
                    $Script:DocAug31
                    $Script:DocSep
                    $Script:DocCte
                )

                foreach ($doc in $documents) {
                    Save-TestDocument -Connection $setupConnection -Document $doc
                }
            } finally {
                Close-TestConnection -Connection $setupConnection
            }

            $setupConnection = $null

            try {
                $setupConnection = New-TestConnection -DatabasePath $Script:DatabasePathCnpjTwo
                Save-TestDocument -Connection $setupConnection -Document $Script:DocCnpjTwo
            } finally {
                Close-TestConnection -Connection $setupConnection
            }
        }

        AfterAll {

            if ($null -ne $Script:TestRoot -and (Test-Path -LiteralPath $Script:TestRoot)) {
                Remove-Item -LiteralPath $Script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
            }

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }
        #endregion

        #region Parameter contract
        Context 'Parameter contract' {

            BeforeAll {

                $Script:Command = Get-Command -Name Get-DFeDocumentEntry -ErrorAction Stop
            }

            It 'Exposes the Cnpj parameter' {
                $Script:Command.Parameters.ContainsKey('Cnpj') | Should -BeTrue
            }

            It 'Declares Cnpj as a string' {
                $Script:Command.Parameters['Cnpj'].ParameterType | Should -Be ([string])
            }

            It 'Declares Cnpj as mandatory' {
                $attributes = @(
                    $Script:Command.Parameters['Cnpj'].Attributes |
                        Where-Object {
                            $_ -is [System.Management.Automation.ParameterAttribute] -and
                            $_.Mandatory
                        }
                )

                $attributes | Should -Not -BeNullOrEmpty
            }

            It 'Declares ValidatePattern on Cnpj' {
                $attributes = @(
                    $Script:Command.Parameters['Cnpj'].Attributes |
                        Where-Object {
                            $_ -is [System.Management.Automation.ValidatePatternAttribute]
                        }
                )

                $attributes | Should -Not -BeNullOrEmpty
            }

            It 'Uses the expected CNPJ validation pattern' {
                $attribute = $Script:Command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ValidatePatternAttribute]
                    } |

                    Select-Object -First 1

                $attribute.RegexPattern | Should -Be '^\d{14}$'
            }

            It 'Exposes StartDate as a string' {
                $Script:Command.Parameters['StartDate'].ParameterType | Should -Be ([string])
            }

            It 'Declares StartDate as optional' {
                $attributes = @(
                    $Script:Command.Parameters['StartDate'].Attributes |
                        Where-Object {
                            $_ -is [System.Management.Automation.ParameterAttribute] -and
                            $_.Mandatory
                        }
                )

                $attributes | Should -BeNullOrEmpty
            }

            It 'Exposes EndDate as a string' {
                $Script:Command.Parameters['EndDate'].ParameterType | Should -Be ([string])
            }

            It 'Declares EndDate as optional' {
                $attributes = @(
                    $Script:Command.Parameters['EndDate'].Attributes |
                        Where-Object {
                            $_ -is [System.Management.Automation.ParameterAttribute] -and
                            $_.Mandatory
                        }
                )

                $attributes | Should -BeNullOrEmpty
            }

            It 'Exposes Modelo as ModeloDFe' {
                $Script:Command.Parameters['Modelo'].ParameterType | Should -Be ([ModeloDFe])
            }

            It 'Declares Modelo as optional' {
                $attributes = @(
                    $Script:Command.Parameters['Modelo'].Attributes |
                        Where-Object {
                            $_ -is [System.Management.Automation.ParameterAttribute] -and
                            $_.Mandatory
                        }
                )

                $attributes | Should -BeNullOrEmpty
            }

            It 'Declares PSObject as the output type' {
                $outputTypes = @(
                    $Script:Command.OutputType |
                        ForEach-Object {
                            if ($_ -is [System.Type]) {
                                $_
                            } elseif ($null -ne $_.Type) {
                                $_.Type
                            }
                        }
                )

                $outputTypes.FullName |
                    Should -Contain 'System.Management.Automation.PSObject'
            }
        }
        #endregion

        #region CNPJ validation
        Context 'Cnpj validation' {

            It 'Accepts a valid 14-digit CNPJ' {
                Mock -CommandName Get-StorePath -MockWith { $Script:DatabasePathCnpjOne }

                {
                    Get-DFeDocumentEntry -Cnpj $Script:CnpjOne -ErrorAction Stop | Out-Null
                } | Should -Not -Throw
            }

            It 'Rejects a CNPJ shorter than 14 digits' {
                {
                    Get-DFeDocumentEntry -Cnpj '1234567800019' -ErrorAction Stop
                } | Should -Throw
            }

            It 'Rejects a CNPJ longer than 14 digits' {
                {
                    Get-DFeDocumentEntry -Cnpj '123456780001990' -ErrorAction Stop
                } | Should -Throw
            }

            It 'Rejects alphabetic characters' {
                { Get-DFeDocumentEntry -Cnpj '1234567800019A' -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Rejects punctuation characters' {
                { Get-DFeDocumentEntry -Cnpj '12.345.678/0001-99' -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Rejects an empty CNPJ' {
                { Get-DFeDocumentEntry -Cnpj '' -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Rejects a null CNPJ' {
                { Get-DFeDocumentEntry -Cnpj $null -ErrorAction Stop } |
                    Should -Throw
            }
        }
        #endregion

        #region Successful read
        Context 'Successful read' {

            BeforeEach {

                Mock -CommandName Get-StorePath -MockWith {
                    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                        'PSReviewUnusedParameter',
                        'Scope',
                        Justification = 'Required by the mocked command signature.'
                    )]
                    param (
                        [string]$Scope,
                        [string]$Cnpj
                    )

                    if ($Cnpj -eq $Script:CnpjOne) {
                        return $Script:DatabasePathCnpjOne
                    }

                    if ($Cnpj -eq $Script:CnpjTwo) {
                        return $Script:DatabasePathCnpjTwo
                    }

                    throw "Unexpected CNPJ: $Cnpj"
                }
            }

            It 'Resolves the index path for the supplied CNPJ' {
                Get-DFeDocumentEntry -Cnpj $Script:CnpjOne -ErrorAction Stop | Out-Null

                Should -Invoke -CommandName Get-StorePath -Times 1 -Exactly -ParameterFilter {
                    $Scope -eq 'Index' -and $Cnpj -eq $Script:CnpjOne
                }
            }

            It 'Returns all documents when no filters are specified' {
                $results = @(Get-DFeDocumentEntry -Cnpj $Script:CnpjOne -ErrorAction Stop)
                $results | Should -HaveCount 6
            }

            It 'Returns documents ordered by dh_emi ascending' {
                $results = @(Get-DFeDocumentEntry -Cnpj $Script:CnpjOne -ErrorAction Stop)

                $dates  = @($results | Select-Object -ExpandProperty dh_emi)
                $sorted = @($dates | Sort-Object)

                # DocAug15 and DocCte share the same dh_emi; their relative
                # order is non-deterministic, so we verify sort stability
                # by comparing against the sorted sequence.
                $dates | Should -Be $sorted
            }

            It 'Returns PSCustomObject instances' {
                $results = @(Get-DFeDocumentEntry -Cnpj $Script:CnpjOne -ErrorAction Stop)

                foreach ($result in $results) {
                    $result | Should -BeOfType ([System.Management.Automation.PSCustomObject])
                }
            }

            It 'Returns the stored document values' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    Modelo      = ([ModeloDFe]::NFe)
                    StartDate   = '2026-08-15T12:00:00+00:00'
                    EndDate     = '2026-08-15T12:00:00+00:00'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeDocumentEntry @entryParams )
                $results | Should -HaveCount 1

                $result = $results[0]
                $result.chave_acesso | Should -Be $Script:DocAug15.ChaveAcesso
                $result.modelo       | Should -Be ([int][ModeloDFe]::NFe)
                $result.dh_emi       | Should -Be $Script:DocAug15.DhEmi
                $result.file_path    | Should -Be $Script:DocAug15.FilePath
                $result.is_proc      | Should -BeTrue
                $result.sha256       | Should -Be $Script:DocAug15.Sha256
                $result.indexed_at   | Should -Be $Script:DocAug15.IndexedAt
            }
        }
        #endregion

        #region Period filter
        Context 'Period filter' {

            BeforeEach {
                Mock -CommandName Get-StorePath -MockWith {
                    $Script:DatabasePathCnpjOne
                }
            }

            It 'Includes the document exactly at StartDate' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    StartDate   = '2026-08-01T00:00:00+00:00'
                    EndDate     = '2026-08-01T23:59:59.9999999+00:00'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeDocumentEntry @entryParams)
                $results | Should -HaveCount 1

                $results[0].chave_acesso | Should -Be $Script:DocAug01.ChaveAcesso
            }

            It 'Excludes documents before StartDate' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    StartDate   = '2026-08-01T00:00:00+00:00'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeDocumentEntry @entryParams)
                $chaves  = @($results | Select-Object -ExpandProperty chave_acesso)

                $chaves | Should -Not -Contain $Script:DocJuly.ChaveAcesso
            }

            It 'Includes the document exactly at EndDate' {
                $entryParams = @{
                    Cnpj         = $Script:CnpjOne
                    StartDate    = '2026-08-31'
                    EndDate      = '2026-08-31T23:59:59.9999999+00:00'
                    ErrorAction  = 'Stop'
                }

                $results = @(Get-DFeDocumentEntry @entryParams)
                $results | Should -HaveCount 1

                $results[0].chave_acesso | Should -Be $Script:DocAug31.ChaveAcesso
            }

            It 'Excludes documents after EndDate' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    EndDate     = '2026-07-31T23:59:59.9999999+00:00'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeDocumentEntry @entryParams)
                $results | Should -HaveCount 1

                $results[0].chave_acesso | Should -Be $Script:DocJuly.ChaveAcesso
            }

            It 'Combines StartDate and EndDate' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    StartDate   = '2026-08-01T00:00:00+00:00'
                    EndDate     = '2026-08-31T23:59:59.9999999+00:00'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeDocumentEntry @entryParams)
                $results | Should -HaveCount 4

                $chaves = @($results | Select-Object -ExpandProperty chave_acesso)
                $chaves | Should -Contain $Script:DocAug01.ChaveAcesso
                $chaves | Should -Contain $Script:DocAug15.ChaveAcesso
                $chaves | Should -Contain $Script:DocAug31.ChaveAcesso
                $chaves | Should -Contain $Script:DocCte.ChaveAcesso
                $chaves | Should -Not -Contain $Script:DocJuly.ChaveAcesso
                $chaves | Should -Not -Contain $Script:DocSep.ChaveAcesso
            }

            It 'Accepts ISO 8601 date strings' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    StartDate   = '2026-08-01T00:00:00+00:00'
                    EndDate     ='2026-08-31T23:59:59.9999999+00:00'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeDocumentEntry @entryParams)
                $results | Should -HaveCount 4
            }

            It 'Returns no output when no records match' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    StartDate   = '2020-01-01'
                    EndDate     ='2020-01-31T23:59:59.9999999+00:00'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeDocumentEntry @entryParams )
                $results | Should -HaveCount 0
            }
        }
        #endregion

        #region Modelo filter
        Context 'Modelo filter' {

            BeforeEach {
                Mock -CommandName Get-StorePath -MockWith {
                    $Script:DatabasePathCnpjOne
                }
            }

            It 'Returns only documents of the requested model' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    Modelo      = ([ModeloDFe]::CTe)
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeDocumentEntry @entryParams )
                $results | Should -HaveCount 1

                $results[0].chave_acesso | Should -Be $Script:DocCte.ChaveAcesso
                $results[0].modelo | Should -Be ([int][ModeloDFe]::CTe)
            }

            It 'Returns no output when no document matches the model' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    Modelo      = ([ModeloDFe]::MDFe)
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeDocumentEntry @entryParams)
                $results | Should -HaveCount 0
            }

            It 'Combines Modelo with the period filter' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    Modelo      = ([ModeloDFe]::NFe)
                    StartDate   = '2026-08-01T00:00:00+00:00'
                    EndDate     = '2026-08-31T23:59:59.9999999+00:00'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeDocumentEntry @entryParams)
                $results | Should -HaveCount 3

                $chaves = @($results | Select-Object -ExpandProperty chave_acesso)
                $chaves | Should -Contain $Script:DocAug01.ChaveAcesso
                $chaves | Should -Contain $Script:DocAug15.ChaveAcesso
                $chaves | Should -Contain $Script:DocAug31.ChaveAcesso
                $chaves | Should -Not -Contain $Script:DocCte.ChaveAcesso
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                Mock -CommandName Get-StorePath -MockWith {
                    $Script:DatabasePathCnpjOne
                }

                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    Modelo      = ([ModeloDFe]::NFe)
                    StartDate   = '2026-08-15T12:00:00+00:00'
                    EndDate     = '2026-08-15T12:00:00+00:00'
                    ErrorAction = 'Stop'
                }

                $Script:Sample = @(Get-DFeDocumentEntry @entryParams)

                $Script:ExpectedProperties = @(
                    'chave_acesso'
                    'modelo'
                    'dh_emi'
                    'file_path'
                    'is_proc'
                    'sha256'
                    'indexed_at'
                )
            }

            It 'Returns exactly one sample record' {
                $Script:Sample | Should -HaveCount 1
            }

            It 'Exposes exactly the documented properties' {
                @($Script:Sample[0].PSObject.Properties.Name) |
                    Should -Be $Script:ExpectedProperties
            }

            It 'Exposes chave_acesso as string' {
                $Script:Sample[0].chave_acesso | Should -BeOfType ([string])
            }

            It 'Exposes modelo as int' {
                $Script:Sample[0].modelo | Should -BeOfType ([int])
            }

            It 'Exposes dh_emi as string' {
                $Script:Sample[0].dh_emi | Should -BeOfType ([string])
            }

            It 'Exposes file_path as string' {
                $Script:Sample[0].file_path | Should -BeOfType ([string])
            }

            It 'Exposes is_proc as bool' {
                $Script:Sample[0].is_proc | Should -BeOfType ([bool])
            }

            It 'Exposes sha256 as string' {
                $Script:Sample[0].sha256 | Should -BeOfType ([string])
            }

            It 'Exposes indexed_at as string' {
                $Script:Sample[0].indexed_at | Should -BeOfType ([string])
            }

            It 'Does not expose SQLite rowid' {
                $Script:Sample[0].PSObject.Properties.Name |
                    Should -Not -Contain 'rowid'
            }

            It 'Does not expose CNPJ as an internal field' {
                $Script:Sample[0].PSObject.Properties.Name |
                    Should -Not -Contain 'cnpj'
            }
        }
        #endregion

        #region CNPJ isolation
        Context 'CNPJ isolation' {

            BeforeEach {
                Mock -CommandName Get-StorePath -MockWith {
                    param (
                        [string]$Scope,
                        [string]$Cnpj
                    )

                    if ($Cnpj -eq $Script:CnpjOne) {
                        return $Script:DatabasePathCnpjOne
                    }

                    if ($Cnpj -eq $Script:CnpjTwo) {
                        return $Script:DatabasePathCnpjTwo
                    }

                    throw "Unexpected CNPJ: $Cnpj"
                }
            }

            It 'Returns only documents from the requested CNPJ index' {
                $results = @(Get-DFeDocumentEntry -Cnpj $Script:CnpjTwo -ErrorAction Stop)
                $results | Should -HaveCount 1

                $results[0].chave_acesso | Should -Be $Script:DocCnpjTwo.ChaveAcesso
            }

            It 'Does not return documents from another CNPJ index' {
                $results = @(Get-DFeDocumentEntry -Cnpj $Script:CnpjOne -ErrorAction Stop)
                $chaves = @($results | Select-Object -ExpandProperty chave_acesso)

                $chaves | Should -Not -Contain $Script:DocCnpjTwo.ChaveAcesso
            }
        }
        #endregion

        #region Date validation
        Context 'Date validation' {

            BeforeEach {

                Mock -CommandName Get-StorePath -MockWith {
                    $Script:DatabasePathCnpjOne
                }
            }

            It 'Preserves UnsupportedDateFormat for an invalid StartDate' {
                try {
                    $entryParams = @{
                        Cnpj        = $Script:CnpjOne
                        StartDate   = 'not-a-date'
                        ErrorAction = 'Stop'
                    }

                    Get-DFeDocumentEntry @entryParams

                    throw 'Expected Get-DFeDocumentEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'UnsupportedDateFormat*'
                }
            }

            It 'Preserves UnsupportedDateFormat for an invalid EndDate' {
                try {
                    $entryParams = @{
                        Cnpj        = $Script:CnpjOne
                        EndDate     = 'not-a-date'
                        ErrorAction = 'Stop'
                    }

                    Get-DFeDocumentEntry @entryParams

                    throw 'Expected Get-DFeDocumentEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'UnsupportedDateFormat*'
                }
            }

            It 'Does not attempt to resolve the database when StartDate is invalid' {
                try {
                    $entryParams = @{
                        Cnpj        = $Script:CnpjOne
                        StartDate   = 'not-a-date'
                        ErrorAction = 'Stop'
                    }

                    Get-DFeDocumentEntry @entryParams
                } catch {
                    $null = $_
                }

                Should -Invoke -CommandName Get-StorePath -Times 0 -Exactly
            }

            It 'Does not attempt to resolve the database when EndDate is invalid' {
                try {
                    $entryParams = @{
                        Cnpj        = $Script:CnpjOne
                        EndDate     ='not-a-date'
                        ErrorAction = 'Stop'
                    }

                    Get-DFeDocumentEntry @entryParams
                } catch {
                    $null = $_
                }

                Should -Invoke -CommandName Get-StorePath -Times 0 -Exactly
            }
        }
        #endregion

        #region Read failure
        Context 'Read failure' {

            BeforeEach {

                $Script:FailureDatabasePath = New-TestDatabasePath

                Mock -CommandName Get-StorePath -MockWith {
                    $Script:FailureDatabasePath
                }

                Mock -CommandName Open-SqliteConnection -MockWith {
                    throw [System.InvalidOperationException]::new(
                        'Simulated SQLite connection failure.'
                    )
                }
            }

            It 'Converts connection failures to DocumentEntryReadFailed' {
                try {
                    Get-DFeDocumentEntry -Cnpj '11111111000111' -ErrorAction Stop
                    throw 'Expected Get-DFeDocumentEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'DocumentEntryReadFailed*'
                }
            }

            It 'Uses ReadError for a read failure' {
                try {
                    Get-DFeDocumentEntry -Cnpj '22222222000122' -ErrorAction Stop
                    throw 'Expected Get-DFeDocumentEntry to fail.'
                } catch {
                    $_.CategoryInfo.Category |
                        Should -Be ([System.Management.Automation.ErrorCategory]::ReadError)
                }
            }

            It 'Uses the database path as TargetObject' {
                try {
                    Get-DFeDocumentEntry -Cnpj '33333333000133' -ErrorAction Stop
                    throw 'Expected Get-DFeDocumentEntry to fail.'
                } catch {
                    $_.TargetObject | Should -Be $Script:FailureDatabasePath
                }
            }

            It 'Preserves the original exception' {
                try {
                    Get-DFeDocumentEntry -Cnpj '44444444000144' -ErrorAction Stop
                    throw 'Expected Get-DFeDocumentEntry to fail.'
                } catch {
                    $_.Exception | Should -Not -BeNullOrEmpty
                    $_.Exception.Message | Should -Be 'Simulated SQLite connection failure.'
                }
            }

            It 'Does not produce output when the read fails' {
                $result = $null

                try {
                    $result = @(Get-DFeDocumentEntry -Cnpj '55555555000155' -ErrorAction Stop)
                } catch {
                    $null = $_
                }

                $result | Should -BeNullOrEmpty
            }
        }
        #endregion
    }
}
