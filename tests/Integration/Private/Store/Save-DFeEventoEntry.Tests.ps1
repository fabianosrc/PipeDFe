#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Save-DFeEventoEntry.

.DESCRIPTION
Verifies that Save-DFeEventoEntry persists evento records correctly against
a real SQLite database initialised by Initialize-DFeIndex.

The tests use an isolated temporary %LOCALAPPDATA% directory and real XML
files on disk for SHA-256 computation. No production data is accessed.

Coverage includes:
  - Insert of a new evento record.
  - Idempotency: same (chave_pai, file_path), same sha256 -> no-op.
  - Update: same (chave_pai, file_path), different sha256 -> record updated.
  - Multiple distinct file_path values under the same chave_pai coexist.
  - indexed_at is set on insert and updated on content change.
  - indexed_at is NOT updated on a no-op call.
  - EventoTipo and DhEmi are persisted correctly.
  - Null EventoTipo and null/empty DhEmi are stored as NULL.
  - DhEmi is normalised to UTC ISO 8601.
  - Parameter validation: invalid Cnpj, null Metadata, wrong Tipo,
    missing ChavePai, missing File.FullName.
  - Write failure produces EventoEntrySaveFailed ErrorId.
  - CNPJ isolation: records from one CNPJ are not visible to another.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    ''
)]

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseSingularNouns',
    '',
    Justification = 'Metadata is an uncountable noun.'
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

Describe 'Save-DFeEventoEntry' {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $joinPathParams = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = 'PipeDFe.Tests-' + [guid]::NewGuid().ToString('N')
            }

            $Script:TempRootPath = Join-Path @joinPathParams

            $newItemParams = @{
                ItemType    = 'Directory'
                Path        = $Script:TempRootPath
                Force       = $true
                ErrorAction = 'Stop'
            }

            New-Item @newItemParams | Out-Null

            $env:LOCALAPPDATA = $Script:TempRootPath

            $Script:Cnpj     = '12345678000199'
            $Script:ChavePai = '35260812345678000199550010000000011234567890'

            # Initialise the schema so Open-DFeIndexConnection has a valid database.
            Initialize-DFeIndex -Cnpj $Script:Cnpj | Out-Null

            # Helper: creates a temporary XML file with the given content and
            # returns its FileInfo. Caller owns cleanup via $Script:TempRootPath.
            function New-TestXmlFile {
                param (
                    [Parameter(Mandatory)]
                    [string]$Content
                )

                $joinPathParams = @{
                    Path      = $Script:TempRootPath
                    ChildPath = [guid]::NewGuid().ToString('N') + '.xml'
                }

                $path = Join-Path @joinPathParams

                [System.IO.File]::WriteAllText($path, $Content, [System.Text.Encoding]::UTF8)
                [System.IO.FileInfo]::new($path)
            }

            # Helper: builds a minimal valid Evento metadata object.
            function New-TestEventoMetadata {
                param (
                    [Parameter(Mandatory)]
                    [System.IO.FileInfo]$File,

                    [Parameter()]
                    [string]$ChavePai = $Script:ChavePai,

                    [Parameter()]
                    [object]$EventoTipo = $null,

                    [Parameter()]
                    [string]$DhEmi = $null
                )

                [PSCustomObject]@{
                    Tipo       = [TipoXmlDFe]::Evento
                    ChavePai   = $ChavePai
                    File       = $File
                    EventoTipo = $EventoTipo
                    DhEmi      = $DhEmi
                }
            }

            # Helper: reads all dfe_evento rows for the given CNPJ.
            function Get-TestEventoRow {
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj
                )

                $databasePath = Get-StorePath -Scope Index -Cnpj $Cnpj

                $connection = Open-SqliteConnection -Path $databasePath

                try {
                    $cmd = $connection.CreateCommand()

                    try {
                        $cmd.CommandText = 'SELECT * FROM dfe_evento ORDER BY rowid;'
                        $reader = $cmd.ExecuteReader()

                        try {
                            $rows = [System.Collections.Generic.List[pscustomobject]]::new()

                            while ($reader.Read()) {
                                $rows.Add([PSCustomObject]@{
                                        ChavePai   = [string]$reader['chave_pai']
                                        FilePath   = [string]$reader['file_path']
                                        EventoTipo = if ($reader['evento_tipo'] -is [System.DBNull]) {
                                            $null
                                        } else {
                                            [string]$reader['evento_tipo']
                                        }
                                        DhEmi      = if ($reader['dh_emi'] -is [System.DBNull]) {
                                            $null
                                        } else {
                                            [string]$reader['dh_emi']
                                        }
                                        Sha256     = [string]$reader['sha256']
                                        IndexedAt  = [string]$reader['indexed_at']
                                    }
                                )
                            }

                            $rows
                        } finally {
                            $reader.Dispose()
                        }
                    } finally {
                        $cmd.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }

            # Helper: returns the SHA-256 hash of the given file, matching the
            # algorithm used by Save-DFeEventoEntry.
            function Get-TestFileSha256 {
                param (
                    [Parameter(Mandatory)]
                    [System.IO.FileInfo]$File
                )

                (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            }
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData
            $removeItemparams = @{
                LiteralPath = $Script:TempRootPath
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            if (Test-Path -LiteralPath $Script:TempRootPath) {
                Remove-Item @removeItemparams
            }

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }
        #endregion

        #region Insert
        Context 'New record insert' {

            BeforeAll {

                $Script:InsertFile = New-TestXmlFile -Content '<evento>insert</evento>'

                $metaParams = @{
                    File       = $Script:InsertFile
                    EventoTipo = [DFeEvento]::Cancelamento
                    DhEmi      = '2026-01-15T10:30:00-03:00'
                }

                $Script:InsertMeta = New-TestEventoMetadata @metaParams

                Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $Script:InsertMeta

                $Script:InsertRows = Get-TestEventoRow -Cnpj $Script:Cnpj |
                    Where-Object { $_.FilePath -eq $Script:InsertFile.FullName }
            }

            It 'Inserts exactly one row' {
                @($Script:InsertRows).Count | Should -Be 1
            }

            It 'Persists chave_pai' {
                $Script:InsertRows[0].ChavePai | Should -Be $Script:ChavePai
            }

            It 'Persists file_path' {
                $Script:InsertRows[0].FilePath |
                    Should -Be $Script:InsertFile.FullName
            }

            It 'Persists the correct sha256' {
                $expected = Get-TestFileSha256 -File $Script:InsertFile
                $Script:InsertRows[0].Sha256 | Should -Be $expected
            }

            It 'Persists evento_tipo' {
                $Script:InsertRows[0].EventoTipo |
                    Should -Be ([DFeEvento]::Cancelamento).ToString()
            }

            It 'Normalises dh_emi to UTC ISO 8601' {
                $expected = [System.DateTimeOffset]::Parse(
                    '2026-01-15T10:30:00-03:00'
                ).ToUniversalTime().ToString('o')

                $Script:InsertRows[0].DhEmi | Should -Be $expected
            }

            It 'Sets indexed_at' {
                $Script:InsertRows[0].IndexedAt | Should -Not -BeNullOrEmpty
            }

            It 'Stores indexed_at as a valid UTC ISO 8601 timestamp' {
                { [System.DateTimeOffset]::Parse($Script:InsertRows[0].IndexedAt) } |
                    Should -Not -Throw
            }
        }
        #endregion

        #region Nullable fields
        Context 'Nullable fields' {

            BeforeAll {

                $Script:NullableFile = New-TestXmlFile -Content '<evento>nullable</evento>'

                $metaParams = @{
                    File       = $Script:NullableFile
                    EventoTipo = $null
                    DhEmi      = $null
                }

                $Script:NullableMeta = New-TestEventoMetadata @metaParams

                Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $Script:NullableMeta

                $Script:NullableRow = Get-TestEventoRow -Cnpj $Script:Cnpj |
                    Where-Object { $_.FilePath -eq $Script:NullableFile.FullName }
            }

            It 'Stores NULL for null EventoTipo' {
                $Script:NullableRow[0].EventoTipo | Should -BeNullOrEmpty
            }

            It 'Stores NULL for null DhEmi' {
                $Script:NullableRow[0].DhEmi | Should -BeNullOrEmpty
            }

            It 'Stores NULL for empty DhEmi' {
                $file = New-TestXmlFile -Content '<evento>emptydhemi</evento>'
                $meta = New-TestEventoMetadata -File $file -DhEmi ''

                Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $meta

                $row = Get-TestEventoRow -Cnpj $Script:Cnpj |
                    Where-Object { $_.FilePath -eq $file.FullName }

                $row[0].DhEmi | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Idempotency - same sha256
        Context 'Idempotency - same sha256' {

            BeforeAll {

                $Script:NoopFile = New-TestXmlFile -Content '<evento>noop</evento>'
                $Script:NoopMeta = New-TestEventoMetadata -File $Script:NoopFile

                # First call - inserts.
                Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $Script:NoopMeta

                $rowBefore = Get-TestEventoRow -Cnpj $Script:Cnpj |
                    Where-Object { $_.FilePath -eq $Script:NoopFile.FullName }

                $Script:NoopIndexedAtBefore = $rowBefore[0].IndexedAt

                # Small delay to ensure clock advances if indexed_at were updated.
                Start-Sleep -Milliseconds 50

                # Second call - same file, same content: must be a no-op.
                Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $Script:NoopMeta

                $Script:NoopRows = Get-TestEventoRow -Cnpj $Script:Cnpj |
                    Where-Object { $_.FilePath -eq $Script:NoopFile.FullName }
            }

            It 'Does not throw on repeated call' {
                { Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $Script:NoopMeta } |
                    Should -Not -Throw
            }

            It 'Does not duplicate the row' {
                @($Script:NoopRows).Count | Should -Be 1
            }

            It 'Does not update indexed_at' {
                $Script:NoopRows[0].IndexedAt | Should -Be $Script:NoopIndexedAtBefore
            }
        }
        #endregion

        #region Update - different sha256
        Context 'Update - different sha256' {

            BeforeAll {

                $Script:UpdateFile = New-TestXmlFile -Content '<evento>v1</evento>'

                $metaParams = @{
                    File       = $Script:UpdateFile
                    EventoTipo = [DFeEvento]::Cancelamento
                }

                $Script:UpdateMeta = New-TestEventoMetadata @metaParams

                # First call - inserts.
                Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $Script:UpdateMeta

                $rowBefore = Get-TestEventoRow -Cnpj $Script:Cnpj |
                    Where-Object { $_.FilePath -eq $Script:UpdateFile.FullName }

                $Script:UpdateSha256Before = $rowBefore[0].Sha256
                $Script:UpdateIndexedAtBefore = $rowBefore[0].IndexedAt

                Start-Sleep -Milliseconds 50

                # Overwrite the file with different content - same path, new sha256.
                [System.IO.File]::WriteAllText(
                    $Script:UpdateFile.FullName,
                    '<evento>v2</evento>',
                    [System.Text.Encoding]::UTF8
                )

                # Refresh FileInfo after rewrite.
                $Script:UpdateFile = [System.IO.FileInfo]::new($Script:UpdateFile.FullName)

                $metaParams = @{
                    File       = $Script:UpdateFile
                    EventoTipo = [DFeEvento]::CartaCorrecao
                }

                $Script:UpdateMeta = New-TestEventoMetadata @metaParams

                # Second call - same path, new content: must update.
                Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $Script:UpdateMeta

                $Script:UpdateRows = Get-TestEventoRow -Cnpj $Script:Cnpj |
                    Where-Object { $_.FilePath -eq $Script:UpdateFile.FullName }
            }

            It 'Does not duplicate the row' {
                @($Script:UpdateRows).Count | Should -Be 1
            }

            It 'Updates sha256' {
                $expected = Get-TestFileSha256 -File $Script:UpdateFile

                $Script:UpdateRows[0].Sha256 | Should -Be $expected
                $Script:UpdateRows[0].Sha256 | Should -Not -Be $Script:UpdateSha256Before
            }

            It 'Updates evento_tipo' {
                $Script:UpdateRows[0].EventoTipo |
                    Should -Be ([DFeEvento]::CartaCorrecao).ToString()
            }

            It 'Updates indexed_at' {
                $Script:UpdateRows[0].IndexedAt |
                    Should -Not -Be $Script:UpdateIndexedAtBefore
            }
        }
        #endregion

        #region Multiple file_path under same chave_pai
        Context 'Multiple file_path under same chave_pai' {

            BeforeAll {
                $Script:MultiChavePai = '35260812345678000199550010000000021234567890'

                $Script:MultiFile1 = New-TestXmlFile -Content '<evento>multi-1</evento>'
                $Script:MultiFile2 = New-TestXmlFile -Content '<evento>multi-2</evento>'

                $meta1 = New-TestEventoMetadata -File $Script:MultiFile1 -ChavePai $Script:MultiChavePai
                $meta2 = New-TestEventoMetadata -File $Script:MultiFile2 -ChavePai $Script:MultiChavePai

                Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $meta1
                Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $meta2

                $Script:MultiRows = Get-TestEventoRow -Cnpj $Script:Cnpj |
                    Where-Object { $_.ChavePai -eq $Script:MultiChavePai }
            }

            It 'Stores both records independently' {
                @($Script:MultiRows).Count | Should -Be 2
            }

            It 'Each row has the correct file_path' {
                $paths = $Script:MultiRows | Select-Object -ExpandProperty FilePath
                $paths | Should -Contain $Script:MultiFile1.FullName
                $paths | Should -Contain $Script:MultiFile2.FullName
            }
        }
        #endregion

        #region CNPJ isolation
        Context 'CNPJ isolation' {

            BeforeAll {

                $Script:OtherCnpj = '98765432000100'
                Initialize-DFeIndex -Cnpj $Script:OtherCnpj | Out-Null

                $isolFile = New-TestXmlFile -Content '<evento>isolation</evento>'
                $isolMeta = New-TestEventoMetadata -File $isolFile

                Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $isolMeta
            }

            It 'Does not write to the other CNPJ database' {
                $rows = Get-TestEventoRow -Cnpj $Script:OtherCnpj
                @($rows).Count | Should -Be 0
            }
        }
        #endregion

        #region Parameter validation
        Context 'Parameter validation' {

            It 'Rejects an invalid Cnpj' {
                $file = New-TestXmlFile -Content '<evento/>'
                $meta = New-TestEventoMetadata -File $file

                { Save-DFeEventoEntry -Cnpj 'INVALID' -Metadata $meta } | Should -Throw
            }

            It 'Rejects null Metadata' {
                { Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $null } | Should -Throw
            }

            It 'Rejects Metadata with wrong Tipo' {
                $file = New-TestXmlFile -Content '<nfe/>'

                $meta = [PSCustomObject]@{
                    Tipo       = [TipoXmlDFe]::Documento
                    ChavePai   = $Script:ChavePai
                    File       = $file
                    EventoTipo = $null
                    DhEmi      = $null
                }

                { Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports InvalidMetadataTipo as ErrorId for wrong Tipo' {
                $file = New-TestXmlFile -Content '<nfe/>'

                $meta = [PSCustomObject]@{
                    Tipo       = [TipoXmlDFe]::Documento
                    ChavePai   = $Script:ChavePai
                    File       = $file
                    EventoTipo = $null
                    DhEmi      = $null
                }

                try {
                    Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeEventoEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'InvalidMetadataTipo*'
                }
            }

            It 'Rejects Metadata with empty ChavePai' {
                $file = New-TestXmlFile -Content '<evento/>'
                $meta = New-TestEventoMetadata -File $file -ChavePai ''

                { Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports MissingChavePai as ErrorId for empty ChavePai' {
                $file = New-TestXmlFile -Content '<evento/>'
                $meta = New-TestEventoMetadata -File $file -ChavePai ''

                try {
                    Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeEventoEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'MissingChavePai*'
                }
            }

            It 'Rejects Metadata with null File' {
                $meta = [PSCustomObject]@{
                    Tipo       = [TipoXmlDFe]::Evento
                    ChavePai   = $Script:ChavePai
                    File       = $null
                    EventoTipo = $null
                    DhEmi      = $null
                }

                { Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports MissingFilePath as ErrorId for null File' {
                $meta = [PSCustomObject]@{
                    Tipo       = [TipoXmlDFe]::Evento
                    ChavePai   = $Script:ChavePai
                    File       = $null
                    EventoTipo = $null
                    DhEmi      = $null
                }

                try {
                    Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeEventoEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'MissingFilePath*'
                }
            }

            It 'Declares Cnpj as a mandatory parameter' {
                $parameter = (Get-Command -Name Save-DFeEventoEntry).Parameters['Cnpj']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } | Select-Object -ExpandProperty Mandatory |

                    Should -Contain $true
            }

            It 'Declares Metadata as a mandatory parameter' {
                $parameter = (Get-Command -Name Save-DFeEventoEntry).Parameters['Metadata']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } | Select-Object -ExpandProperty Mandatory |

                    Should -Contain $true
            }
        }
        #endregion

        #region Write failure
        Context 'Write failure' {

            BeforeAll {

                # Mock Open-DFeIndexConnection to simulate a connection failure.
                # This exercises the outer catch in Save-DFeEventoEntry and confirms
                # that any error from Open-DFeIndexConnection is normalised to
                # EventoEntrySaveFailed.
                Mock -CommandName Open-DFeIndexConnection {
                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.InvalidOperationException]::new('Simulated connection failure.'),
                            'MockConnectionFailure',
                            [System.Management.Automation.ErrorCategory]::ConnectionError,
                            $null
                        )
                    )
                }
            }

            It 'Reports EventoEntrySaveFailed as ErrorId on connection failure' {
                $file = New-TestXmlFile -Content '<evento>fail</evento>'
                $meta = New-TestEventoMetadata -File $file

                try {
                    Save-DFeEventoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeEventoEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'EventoEntrySaveFailed*'
                }
            }
        }
        #endregion
    }
}
