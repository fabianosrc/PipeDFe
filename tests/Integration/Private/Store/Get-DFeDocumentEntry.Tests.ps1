#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration and contract tests for Get-DFeDocumentEntry.

.DESCRIPTION
Verifies the public contract and integration behavior of Get-DFeDocumentEntry.

Coverage includes:
  - Cnpj is mandatory.
  - Cnpj must match the expected pattern.
  - StartDate, EndDate and Modelo are optional.
  - Real SQLite data is returned correctly.
  - All documents are returned when no filters are supplied.
  - Results are ordered by dh_emi ascending.
  - StartDate is inclusive.
  - EndDate is inclusive.
  - StartDate and EndDate can be combined.
  - Modelo filters by its numeric value.
  - Modelo can be combined with a period filter.
  - No output is produced when no records match.
  - Documents from another CNPJ are not returned.
  - Output exposes exactly the documented properties including ndoc and serie.
  - ndoc is null when the column is NULL in the database.
  - serie is null when the column is NULL in the database.
  - Output property types match the documented contract.
  - Invalid dates preserve UnsupportedDateFormat.
  - Database failures are converted to DocumentEntryReadFailed.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Test helper functions do not require ShouldProcess.'
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

            $Script:TestRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                ('PipeDFe.Get-DFeDocumentEntry.Tests-{0}' -f $testID)
            )

            New-Item -Path $Script:TestRoot -ItemType Directory -Force | Out-Null

            $Script:CnpjOne = '12345678000199'
            $Script:CnpjTwo = '98765432000100'

            function New-TestDatabasePath {
                [CmdletBinding()]
                [OutputType([string])]
                param ()

                $testID = [guid]::NewGuid().ToString('N')

                [System.IO.Path]::Combine($Script:TestRoot, ('{0}.db' -f $testID))
            }

            function New-TestConnection {
                [CmdletBinding()]
                [OutputType([System.Data.SQLite.SQLiteConnection])]
                param (
                    [Parameter(Mandatory)]
                    [string]$DatabasePath
                )

                $connection = [System.Data.SQLite.SQLiteConnection]::new(
                    "Data Source=$DatabasePath;Version=3;"
                )

                try {
                    $connection.Open()
                    return $connection
                } catch {
                    $connection.Dispose()
                    throw
                }
            }

            function Close-TestConnection {
                [CmdletBinding()]
                [OutputType([void])]
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
                [CmdletBinding()]
                [OutputType([void])]
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
                    $command.ExecuteNonQuery() | Out-Null
                } finally {
                    if ($null -ne $command) {
                        $command.Dispose()
                    }
                }
            }

            function New-TestSchema {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [System.Data.SQLite.SQLiteConnection]$Connection
                )

                Invoke-TestNonQuery -Connection $Connection -CommandText @'
CREATE TABLE dfe_document (
    chave_acesso TEXT    NOT NULL PRIMARY KEY,
    modelo       INTEGER NOT NULL,
    file_path    TEXT    NOT NULL,
    is_proc      INTEGER NOT NULL DEFAULT 0,
    ndoc         INTEGER,
    serie        TEXT,
    dh_emi       TEXT,
    sha256       TEXT    NOT NULL,
    indexed_at   TEXT    NOT NULL
);
'@
            }

            function New-TestDocument {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$ChaveAcesso,

                    [Parameter()]
                    [ModeloDFe]$Modelo = [ModeloDFe]::NFe,

                    [Parameter()]
                    [string]$DhEmi = '2026-08-15T12:00:00.0000000+00:00',

                    [Parameter()]
                    [string]$FilePath = 'C:\xml\doc.xml',

                    [Parameter()]
                    [bool]$IsProc = $false,

                    [Parameter()]
                    [AllowNull()]
                    [object]$Ndoc = $null,

                    [Parameter()]
                    [AllowNull()]
                    [string]$Serie = $null,

                    [Parameter()]
                    [string]$Sha256 = ([guid]::NewGuid().ToString('N')),

                    [Parameter()]
                    [string]$IndexedAt = '2026-08-15T12:00:00.0000000+00:00'
                )

                [PSCustomObject]@{
                    ChaveAcesso = $ChaveAcesso
                    Modelo      = $Modelo
                    DhEmi       = $DhEmi
                    FilePath    = $FilePath
                    IsProc      = $IsProc
                    Ndoc        = $Ndoc
                    Serie       = $Serie
                    Sha256      = $Sha256
                    IndexedAt   = $IndexedAt
                }
            }

            function Save-TestDocument {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [System.Data.SQLite.SQLiteConnection]$Connection,

                    [Parameter(Mandatory)]
                    [pscustomobject]$Document
                )

                $command = $null

                try {
                    $command = $Connection.CreateCommand()

                    $command.CommandText = @'
INSERT INTO dfe_document (
    chave_acesso,
    modelo,
    file_path,
    is_proc,
    ndoc,
    serie,
    dh_emi,
    sha256,
    indexed_at
) VALUES (
    @chave_acesso,
    @modelo,
    @file_path,
    @is_proc,
    @ndoc,
    @serie,
    @dh_emi,
    @sha256,
    @indexed_at
);
'@

                    $ndocValue  = if ($null -eq $Document.Ndoc) {
                        [System.DBNull]::Value
                    } else {
                        [int]$Document.Ndoc
                    }

                    $serieValue = if ($null -eq $Document.Serie) {
                        [System.DBNull]::Value
                    } else {
                        [string]$Document.Serie
                    }

                    $command.Parameters.AddWithValue('@chave_acesso', $Document.ChaveAcesso)       | Out-Null
                    $command.Parameters.AddWithValue('@modelo',       [int]$Document.Modelo)       | Out-Null
                    $command.Parameters.AddWithValue('@file_path',    $Document.FilePath)          | Out-Null
                    $command.Parameters.AddWithValue('@is_proc',      [int][bool]$Document.IsProc) | Out-Null
                    $command.Parameters.AddWithValue('@ndoc',         $ndocValue)                  | Out-Null
                    $command.Parameters.AddWithValue('@serie',        $serieValue)                 | Out-Null
                    $command.Parameters.AddWithValue('@dh_emi',       $Document.DhEmi)             | Out-Null
                    $command.Parameters.AddWithValue('@sha256',       $Document.Sha256)            | Out-Null
                    $command.Parameters.AddWithValue('@indexed_at',   $Document.IndexedAt)         | Out-Null

                    $command.ExecuteNonQuery() | Out-Null
                } finally {
                    if ($null -ne $command) { $command.Dispose() }
                }
            }

            function New-TestIndex {
                [CmdletBinding()]
                [OutputType([string])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj
                )

                $null = $Cnpj

                $databasePath = New-TestDatabasePath
                $connection   = $null

                try {
                    $connection = New-TestConnection -DatabasePath $databasePath
                    New-TestSchema -Connection $connection
                    return $databasePath
                } finally {
                    Close-TestConnection -Connection $connection
                }
            }

            $Script:DatabasePathCnpjOne = New-TestIndex -Cnpj $Script:CnpjOne
            $Script:DatabasePathCnpjTwo = New-TestIndex -Cnpj $Script:CnpjTwo

            $docJulyParams = @{
                ChaveAcesso = ('0' * 44)
                DhEmi       = '2026-07-31T23:59:59.0000000+00:00'
                Ndoc        = 1
                Serie       = '001'
            }

            $Script:DocJuly = New-TestDocument @docJulyParams

            $docAug01Params = @{
                ChaveAcesso = ('1' * 44)
                DhEmi       = '2026-08-01T00:00:00.0000000+00:00'
                Ndoc        = 2
                Serie       = '001'
            }

            $Script:DocAug01 = New-TestDocument @docAug01Params

            $docAug15Params = @{
                ChaveAcesso = ('2' * 44)
                DhEmi       = '2026-08-15T12:00:00.0000000+00:00'
                Ndoc        = 3
                Serie       = '001'
                IsProc      = $true
            }

            $Script:DocAug15 = New-TestDocument @docAug15Params


            $docAug31Params = @{
                ChaveAcesso = ('3' * 44)
                DhEmi       = '2026-08-31T23:59:59.0000000+00:00'
                Ndoc        = 5
                Serie       = '001'
            }

            $Script:DocAug31 = New-TestDocument @docAug31Params

            $docSepParams = @{
                ChaveAcesso = ('4' * 44)
                DhEmi       = '2026-09-01T00:00:00.0000000+00:00'
                Ndoc        = 6
                Serie       = '001'
            }

            $Script:DocSep = New-TestDocument @docSepParams

            $docCteParams = @{
                ChaveAcesso = ('5' * 44)
                DhEmi       = '2026-08-15T12:00:00.0000000+00:00'
                Modelo      = ([ModeloDFe]::CTe)
                Ndoc        = $null
                Serie       = $null
            }

            $Script:DocCte = New-TestDocument @docCteParams

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
                $removeItemParams = @{
                    LiteralPath = $Script:TestRoot
                    Recurse     = $true
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeItemParams
            }

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }
        #endregion

        #region Parameter contract
        Context 'Parameter contract' {

            BeforeAll {

                $Script:Command = Get-Command -Name Get-DFeDocumentEntry -ErrorAction Stop
            }

            It 'Declares Cnpj as mandatory' {
                $attr = $Script:Command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $attr | Should -Not -BeNullOrEmpty
            }

            It 'Declares Cnpj as string' {
                $Script:Command.Parameters['Cnpj'].ParameterType | Should -Be ([string])
            }

            It 'Validates Cnpj pattern' {
                $attr = $Script:Command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ValidatePatternAttribute]
                    }

                $attr.RegexPattern | Should -Be '^[A-Z0-9]{14}$'
            }

            It 'Declares StartDate as optional string' {
                $attr = $Script:Command.Parameters['StartDate'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $attr | Should -BeNullOrEmpty
                $Script:Command.Parameters['StartDate'].ParameterType | Should -Be ([string])
            }

            It 'Declares EndDate as optional string' {
                $attr = $Script:Command.Parameters['EndDate'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $attr | Should -BeNullOrEmpty
                $Script:Command.Parameters['EndDate'].ParameterType | Should -Be ([string])
            }

            It 'Declares Modelo as optional ModeloDFe' {
                $attr = $Script:Command.Parameters['Modelo'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $attr | Should -BeNullOrEmpty
                $Script:Command.Parameters['Modelo'].ParameterType | Should -Be ([ModeloDFe])
            }
        }
        #endregion

        #region CNPJ validation
        Context 'Cnpj validation' {

            BeforeEach {

                Mock -CommandName Get-StorePath -MockWith {
                    return $Script:DatabasePathCnpjOne
                }
            }

            It 'Accepts a valid 14-character CNPJ' {
                {
                    Get-DFeDocumentEntry -Cnpj $Script:CnpjOne -ErrorAction Stop | Out-Null
                } | Should -Not -Throw
            }

            It 'Rejects a CNPJ shorter than 14 characters' {
                {
                    Get-DFeDocumentEntry -Cnpj '1234567800019' -ErrorAction Stop
                } | Should -Throw
            }

            It 'Rejects a CNPJ longer than 14 characters' {
                {
                    Get-DFeDocumentEntry -Cnpj '123456780001990' -ErrorAction Stop
                } | Should -Throw
            }

            It 'Rejects punctuation characters' {
                { Get-DFeDocumentEntry -Cnpj '12.345.678/0001-99' -ErrorAction Stop } |
                    Should -Throw
            }
        }
        #endregion

        #region Successful read
        Context 'Successful read' {

            BeforeEach {

                Mock -CommandName Get-StorePath -MockWith {
                    param (
                        [Parameter()]
                        [string]$Scope,

                        [Parameter()]
                        [string]$Cnpj
                    )

                    $null = $Scope

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

                $invokeParams = @{
                    CommandName     = 'Get-StorePath'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Scope -eq 'Index' -and $Cnpj -eq $Script:CnpjOne
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Returns all documents when no filters are specified' {
                @(Get-DFeDocumentEntry -Cnpj $Script:CnpjOne -ErrorAction Stop) |
                    Should -HaveCount 6
            }

            It 'Returns documents ordered by dh_emi ascending' {
                $results = @(Get-DFeDocumentEntry -Cnpj $Script:CnpjOne -ErrorAction Stop)
                $dates   = @($results | Select-Object -ExpandProperty dh_emi)

                $dates | Should -Be @($dates | Sort-Object)
            }

            It 'Returns the stored document values including ndoc and serie' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    Modelo      = ([ModeloDFe]::NFe)
                    StartDate   = '2026-08-15T12:00:00+00:00'
                    EndDate     = '2026-08-15T12:00:00+00:00'
                    ErrorAction = 'Stop'
                }

                $result = @(Get-DFeDocumentEntry @entryParams)[0]

                $result.chave_acesso | Should -Be $Script:DocAug15.ChaveAcesso
                $result.modelo       | Should -Be ([int][ModeloDFe]::NFe)
                $result.is_proc      | Should -BeTrue
                $result.ndoc         | Should -Be 3
                $result.serie        | Should -Be '001'
            }

            It 'Returns null ndoc when the column is NULL' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    Modelo      = ([ModeloDFe]::CTe)
                    ErrorAction = 'Stop'
                }

                $result = @(Get-DFeDocumentEntry @entryParams)[0]

                $result.ndoc  | Should -BeNullOrEmpty
                $result.serie | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Period filter
        Context 'Period filter' {

            BeforeEach {

                Mock -CommandName Get-StorePath -MockWith {
                    return $Script:DatabasePathCnpjOne
                }
            }

            It 'Includes the document exactly at StartDate' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    StartDate   = '2026-08-01T00:00:00+00:00'
                    EndDate     = '2026-08-01T23:59:59+00:00'
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
                    Cnpj        = $Script:CnpjOne
                    StartDate   = '2026-08-31'
                    EndDate     = '2026-08-31T23:59:59+00:00'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeDocumentEntry @entryParams)

                $results | Should -HaveCount 1
                $results[0].chave_acesso | Should -Be $Script:DocAug31.ChaveAcesso
            }

            It 'Combines StartDate and EndDate' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    StartDate   = '2026-08-01T00:00:00+00:00'
                    EndDate     = '2026-08-31T23:59:59+00:00'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeDocumentEntry @entryParams)
                $chaves  = @($results | Select-Object -ExpandProperty chave_acesso)

                $results | Should -HaveCount 4
                $chaves  | Should -Contain $Script:DocAug01.ChaveAcesso
                $chaves  | Should -Contain $Script:DocAug15.ChaveAcesso
                $chaves  | Should -Contain $Script:DocAug31.ChaveAcesso
                $chaves  | Should -Contain $Script:DocCte.ChaveAcesso
                $chaves  | Should -Not -Contain $Script:DocJuly.ChaveAcesso
                $chaves  | Should -Not -Contain $Script:DocSep.ChaveAcesso
            }

            It 'Returns no output when no records match' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    StartDate   = '2020-01-01'
                    EndDate     = '2020-01-31'
                    ErrorAction = 'Stop'
                }

                @(Get-DFeDocumentEntry @entryParams ) | Should -HaveCount 0
            }
        }
        #endregion

        #region Modelo filter
        Context 'Modelo filter' {

            BeforeEach {

                Mock -CommandName Get-StorePath -MockWith {
                    return $Script:DatabasePathCnpjOne
                }
            }

            It 'Returns only documents of the requested model' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    Modelo      = ([ModeloDFe]::CTe)
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeDocumentEntry @entryParams)

                $results | Should -HaveCount 1
                $results[0].chave_acesso | Should -Be $Script:DocCte.ChaveAcesso
                $results[0].modelo       | Should -Be ([int][ModeloDFe]::CTe)
            }

            It 'Combines Modelo with the period filter' {
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    Modelo      = ([ModeloDFe]::NFe)
                    StartDate   = '2026-08-01T00:00:00+00:00'
                    EndDate     = '2026-08-31T23:59:59+00:00'
                    ErrorAction = 'Stop'
                }

                $results = @(Get-DFeDocumentEntry @entryParams)
                $chaves  = @($results | Select-Object -ExpandProperty chave_acesso)

                $results | Should -HaveCount 3
                $chaves  | Should -Contain $Script:DocAug01.ChaveAcesso
                $chaves  | Should -Contain $Script:DocAug15.ChaveAcesso
                $chaves  | Should -Contain $Script:DocAug31.ChaveAcesso
                $chaves  | Should -Not -Contain $Script:DocCte.ChaveAcesso
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                Mock -CommandName Get-StorePath -MockWith {
                    return $Script:DatabasePathCnpjOne
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
                    'ndoc'
                    'serie'
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

            It 'Exposes ndoc as int when present' {
                $Script:Sample[0].ndoc | Should -BeOfType ([int])
            }

            It 'Exposes serie as string when present' {
                $Script:Sample[0].serie | Should -BeOfType ([string])
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
                        [Parameter()]
                        [string]$Scope,

                        [Parameter()]
                        [string]$Cnpj
                    )

                    $null = $Scope

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
                $entryParams = @{
                    Cnpj        = $Script:CnpjOne
                    ErrorAction =  'Stop'
                }

                $chaves = @(Get-DFeDocumentEntry @entryParams | Select-Object -ExpandProperty chave_acesso)

                $chaves | Should -Not -Contain $Script:DocCnpjTwo.ChaveAcesso
            }
        }
        #endregion

        #region Date validation
        Context 'Date validation' {

            BeforeEach {

                Mock -CommandName Get-StorePath -MockWith {
                    return $Script:DatabasePathCnpjOne
                }
            }

            It 'Preserves UnsupportedDateFormat for an invalid StartDate' {
                $exception = $null

                try {
                    Get-DFeDocumentEntry -Cnpj $Script:CnpjOne -StartDate 'not-a-date' -ErrorAction Stop
                } catch {
                    $exception = $_
                }

                $exception.FullyQualifiedErrorId | Should -BeLike 'UnsupportedDateFormat*'
            }

            It 'Preserves UnsupportedDateFormat for an invalid EndDate' {
                $exception = $null

                try {
                    Get-DFeDocumentEntry -Cnpj $Script:CnpjOne -EndDate 'not-a-date' -ErrorAction Stop
                } catch {
                    $exception = $_
                }

                $exception.FullyQualifiedErrorId | Should -BeLike 'UnsupportedDateFormat*'
            }

            It 'Does not resolve the database when StartDate is invalid' {
                try {
                    Get-DFeDocumentEntry -Cnpj $Script:CnpjOne -StartDate 'not-a-date' -ErrorAction Stop
                } catch {
                    $null = $_
                }

                Should -Invoke -CommandName Get-StorePath -ModuleName PipeDFe -Scope It -Exactly -Times 0
            }
        }
        #endregion

        #region Read failure
        Context 'Read failure' {

            BeforeEach {

                $Script:FailureDatabasePath = New-TestDatabasePath

                Mock -CommandName Get-StorePath -MockWith {
                    return $Script:FailureDatabasePath
                }

                Mock -CommandName Open-SqliteConnection -MockWith {
                    throw [System.InvalidOperationException]::new(
                        'Simulated SQLite connection failure.'
                    )
                }
            }

            It 'Converts connection failures to DocumentEntryReadFailed' {
                $exception = $null

                try {
                    Get-DFeDocumentEntry -Cnpj '11111111000111' -ErrorAction Stop
                } catch {
                    $exception = $_
                }

                $exception.FullyQualifiedErrorId | Should -BeLike 'DocumentEntryReadFailed*'
            }

            It 'Uses ReadError for a read failure' {
                $exception = $null

                try {
                    Get-DFeDocumentEntry -Cnpj '22222222000122' -ErrorAction Stop
                } catch {
                    $exception = $_
                }

                $exception.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::ReadError)
            }

            It 'Uses the database path as TargetObject' {
                $exception = $null

                try {
                    Get-DFeDocumentEntry -Cnpj '33333333000133' -ErrorAction Stop
                } catch {
                    $exception = $_
                }

                $exception.TargetObject | Should -Be $Script:FailureDatabasePath
            }

            It 'Does not produce output when the read fails' {
                $result = $null

                try {
                    $result = @(Get-DFeDocumentEntry -Cnpj '44444444000144' -ErrorAction Stop)
                } catch {
                    $null = $_
                }

                $result | Should -BeNullOrEmpty
            }
        }
        #endregion
    }
}
