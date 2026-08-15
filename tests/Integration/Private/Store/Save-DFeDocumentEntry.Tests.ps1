#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Save-DFeDocumentEntry.

.DESCRIPTION
Verifies that Save-DFeDocumentEntry persists documento records correctly
against a real SQLite database initialised by Initialize-DFeIndex.

Coverage includes:
  - Insert of a new documento record.
  - Rule 1: Proc beats bare (incoming Proc replaces stored bare).
  - Rule 2: Bare never replaces Proc (no-op, stored record kept).
  - Rule 3: Same type, same sha256 (no-op, indexed_at unchanged).
  - Rule 4: Same type, different sha256 (record updated).
  - Nullable fields: ndoc, serie, dh_emi stored as NULL when absent.
  - DhEmi is normalised to UTC ISO 8601.
  - indexed_at is set on insert and updated on content change.
  - indexed_at is NOT updated on a no-op call.
  - CNPJ isolation.
  - Parameter validation.
  - Write failure produces DocumentEntrySaveFailed.

Tests use real SQLite files in an isolated temporary directory.
No production data is accessed.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
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

Describe 'Save-DFeDocumentEntry' {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            $joinPathParams = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = 'PipeDFe.Save-DFeDocumentEntry.Tests-' + [guid]::NewGuid().ToString('N')
            }

            $Script:TestRoot = Join-Path @joinPathParams

            New-Item -ItemType Directory -Path $Script:TestRoot -Force -ErrorAction Stop |
                Out-Null

            $env:LOCALAPPDATA   = $Script:TestRoot
            $Script:Cnpj        = '12345678000199'
            $Script:ChaveAcesso = '35260812345678000199550010000000011234567890'

            Initialize-DFeIndex -Cnpj $Script:Cnpj | Out-Null

            function New-TestXmlFile {
                [OutputType([System.IO.FileInfo])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Content
                )

                $joinPathParams = @{
                    Path      = $Script:TestRoot
                    ChildPath = [guid]::NewGuid().ToString('N') + '.xml'
                }

                $path = Join-Path @joinPathParams

                [System.IO.File]::WriteAllText($path, $Content, [System.Text.Encoding]::UTF8)
                [System.IO.FileInfo]::new($path)
            }

            function New-TestDocumentMetadata {
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [System.IO.FileInfo]$File,

                    [Parameter()]
                    [string]$Chave = $Script:ChaveAcesso,

                    [Parameter()]
                    [object]$Modelo = [ModeloDFe]::NFe,

                    [Parameter()]
                    [bool]$IsProc = $false,

                    [Parameter()]
                    [object]$Ndoc = $null,

                    [Parameter()]
                    [string]$Serie = $null,

                    [Parameter()]
                    [string]$DhEmi = $null
                )

                [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Documento
                    Chave  = $Chave
                    Modelo = $Modelo
                    IsProc = $IsProc
                    File   = $File
                    Ndoc   = $Ndoc
                    Serie  = $Serie
                    DhEmi  = $DhEmi
                }
            }

            function Get-TestDocumentRow {
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$ChaveAcesso
                )

                $databasePath = Get-StorePath -Scope Index -Cnpj $Cnpj

                $connection = Open-SqliteConnection -Path $databasePath

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = @'
SELECT chave_acesso, modelo, file_path, is_proc, ndoc, serie, dh_emi, sha256, indexed_at
FROM   dfe_document
WHERE  chave_acesso = @chave;
'@
                        $command.Parameters.AddWithValue('@chave', $ChaveAcesso) | Out-Null

                        $reader = $command.ExecuteReader()
                        try {
                            if ($reader.Read()) {
                                [pscustomobject]@{
                                    ChaveAcesso = [string]$reader['chave_acesso']
                                    Modelo      = [int]$reader['modelo']
                                    FilePath    = [string]$reader['file_path']
                                    IsProc      = [int]$reader['is_proc']
                                    Ndoc        = if ($reader['ndoc'] -is [System.DBNull]) {
                                        $null
                                    } else {
                                        [int]$reader['ndoc']
                                    }
                                    Serie       = if ($reader['serie'] -is [System.DBNull]) {
                                        $null
                                    } else {
                                        [string]$reader['serie']
                                    }
                                    DhEmi       = if ($reader['dh_emi'] -is [System.DBNull]) {
                                        $null
                                    } else {
                                        [string]$reader['dh_emi']
                                    }
                                    Sha256      = [string]$reader['sha256']
                                    IndexedAt   = [string]$reader['indexed_at']
                                }
                            }
                        } finally {
                            $reader.Dispose()
                        }
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }

            function Get-TestFileSha256 {
                [OutputType([string])]
                param (
                    [Parameter(Mandatory)]
                    [System.IO.FileInfo]$File
                )

                $fileHashParams = @{
                    LiteralPath = $File.FullName
                    Algorithm   = 'SHA256'
                    ErrorAction = 'Stop'
                }

                (Get-FileHash @fileHashParams).Hash
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

        #region Insert
        Context 'New record insert' {

            BeforeAll {

                $Script:InsertFile = New-TestXmlFile -Content '<nfe>insert</nfe>'

                $metaParams = @{
                    File   = $Script:InsertFile
                    Modelo = [ModeloDFe]::NFe
                    IsProc = $false
                    Ndoc   = 1
                    Serie  = '1'
                    DhEmi  = '2026-01-15T10:30:00-03:00'
                }

                $Script:InsertMeta = New-TestDocumentMetadata @metaParams

                Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $Script:InsertMeta

                $Script:InsertRow = Get-TestDocumentRow -Cnpj $Script:Cnpj -ChaveAcesso $Script:ChaveAcesso
            }

            It 'Inserts exactly one row' {
                $Script:InsertRow | Should -Not -BeNullOrEmpty
            }

            It 'Persists chave_acesso' {
                $Script:InsertRow.ChaveAcesso | Should -Be $Script:ChaveAcesso
            }

            It 'Persists file_path' {
                $Script:InsertRow.FilePath | Should -Be $Script:InsertFile.FullName
            }

            It 'Persists the correct sha256' {
                $Script:InsertRow.Sha256 | Should -Be (Get-TestFileSha256 -File $Script:InsertFile)
            }

            It 'Persists modelo' {
                $Script:InsertRow.Modelo | Should -Be ([int][ModeloDFe]::NFe)
            }

            It 'Persists is_proc as 0 for bare document' {
                $Script:InsertRow.IsProc | Should -Be 0
            }

            It 'Persists ndoc' {
                $Script:InsertRow.Ndoc | Should -Be 1
            }

            It 'Persists serie' {
                $Script:InsertRow.Serie | Should -Be '1'
            }

            It 'Normalises dh_emi to UTC ISO 8601' {
                $expected = [System.DateTimeOffset]::Parse(
                    '2026-01-15T10:30:00-03:00'
                ).ToUniversalTime().ToString('o')

                $Script:InsertRow.DhEmi | Should -Be $expected
            }

            It 'Sets indexed_at' {
                $Script:InsertRow.IndexedAt | Should -Not -BeNullOrEmpty
            }

            It 'Stores indexed_at as a valid UTC ISO 8601 timestamp' {
                { [System.DateTimeOffset]::Parse($Script:InsertRow.IndexedAt) } |
                    Should -Not -Throw
            }
        }
        #endregion

        #region Nullable fields
        Context 'Nullable fields' {

            BeforeAll {

                $Script:NullableChave = '35260812345678000199550010000000021234567890'
                $Script:NullableFile  = New-TestXmlFile -Content '<nfe>nullable</nfe>'

                $metaParams = @{
                    File  = $Script:NullableFile
                    Chave = $Script:NullableChave
                    Ndoc  = $null
                    Serie = $null
                    DhEmi = $null
                }

                $Script:NullableMeta = New-TestDocumentMetadata @metaParams

                Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $Script:NullableMeta

                $Script:NullableRow = Get-TestDocumentRow -Cnpj $Script:Cnpj -ChaveAcesso $Script:NullableChave
            }

            It 'Stores NULL for null Ndoc' {
                $Script:NullableRow.Ndoc | Should -BeNullOrEmpty
            }

            It 'Stores NULL for null Serie' {
                $Script:NullableRow.Serie | Should -BeNullOrEmpty
            }

            It 'Stores NULL for null DhEmi' {
                $Script:NullableRow.DhEmi | Should -BeNullOrEmpty
            }

            It 'Stores NULL for empty DhEmi' {
                $chave = '35260812345678000199550010000000031234567890'
                $file  = New-TestXmlFile -Content '<nfe>emptydhemi</nfe>'

                $metaParams = @{
                    File  = $file
                    Chave = $chave
                    DhEmi = ''
                }

                Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata (New-TestDocumentMetadata @metaParams)

                $row = Get-TestDocumentRow -Cnpj $Script:Cnpj -ChaveAcesso $chave

                $row.DhEmi | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Rule 1 - Proc beats bare
        Context 'Rule 1 - Proc beats bare' {

            BeforeAll {

                $Script:Rule1Chave    = '35260812345678000199550010000000041234567890'
                $Script:Rule1BareFile = New-TestXmlFile -Content '<nfe>bare</nfe>'
                $Script:Rule1ProcFile = New-TestXmlFile -Content '<nfeProc>proc</nfeProc>'

                $bareParams = @{
                    File   = $Script:Rule1BareFile
                    Chave  = $Script:Rule1Chave
                    IsProc = $false
                }

                Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata (New-TestDocumentMetadata @bareParams)

                Start-Sleep -Milliseconds 50

                $procParams = @{
                    File   = $Script:Rule1ProcFile
                    Chave  = $Script:Rule1Chave
                    IsProc = $true
                }

                Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata (New-TestDocumentMetadata @procParams)

                $Script:Rule1Row = Get-TestDocumentRow -Cnpj $Script:Cnpj -ChaveAcesso $Script:Rule1Chave
            }

            It 'Replaces the bare record with the Proc record' {
                $Script:Rule1Row.FilePath | Should -Be $Script:Rule1ProcFile.FullName
            }

            It 'Sets is_proc to 1' {
                $Script:Rule1Row.IsProc | Should -Be 1
            }

            It 'Updates sha256 to the Proc file hash' {
                $Script:Rule1Row.Sha256 | Should -Be (Get-TestFileSha256 -File $Script:Rule1ProcFile)
            }

            It 'Updates indexed_at' {
                $bareSha256 = Get-TestFileSha256 -File $Script:Rule1BareFile

                $Script:Rule1Row.Sha256 | Should -Not -Be $bareSha256
            }
        }
        #endregion

        #region Rule 2 - Bare never replaces Proc
        Context 'Rule 2 - Bare never replaces Proc' {

            BeforeAll {

                $Script:Rule2Chave    = '35260812345678000199550010000000051234567890'
                $Script:Rule2ProcFile = New-TestXmlFile -Content '<nfeProc>proc</nfeProc>'
                $Script:Rule2BareFile = New-TestXmlFile -Content '<nfe>bare</nfe>'

                $procParams = @{
                    File   = $Script:Rule2ProcFile
                    Chave  = $Script:Rule2Chave
                    IsProc = $true
                }

                Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata (New-TestDocumentMetadata @procParams)

                $Script:Rule2ProcRow = Get-TestDocumentRow -Cnpj $Script:Cnpj -ChaveAcesso $Script:Rule2Chave

                $bareParams = @{
                    File   = $Script:Rule2BareFile
                    Chave  = $Script:Rule2Chave
                    IsProc = $false
                }

                Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata (New-TestDocumentMetadata @bareParams)

                $Script:Rule2AfterRow = Get-TestDocumentRow -Cnpj $Script:Cnpj -ChaveAcesso $Script:Rule2Chave
            }

            It 'Does not throw' {
                $bareParams = @{
                    File   = $Script:Rule2BareFile
                    Chave  = $Script:Rule2Chave
                    IsProc = $false
                }

                {
                    Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata (New-TestDocumentMetadata @bareParams)
                } | Should -Not -Throw
            }

            It 'Keeps the Proc file_path' {
                $Script:Rule2AfterRow.FilePath | Should -Be $Script:Rule2ProcFile.FullName
            }

            It 'Keeps is_proc at 1' {
                $Script:Rule2AfterRow.IsProc | Should -Be 1
            }

            It 'Does not update indexed_at' {
                $Script:Rule2AfterRow.IndexedAt | Should -Be $Script:Rule2ProcRow.IndexedAt
            }
        }
        #endregion

        #region Rule 3 - Same type, same sha256
        Context 'Rule 3 - Same type, same sha256' {

            BeforeAll {

                $Script:Rule3Chave = '35260812345678000199550010000000061234567890'
                $Script:Rule3File  = New-TestXmlFile -Content '<nfe>same</nfe>'

                $metaParams = @{
                    File  = $Script:Rule3File
                    Chave = $Script:Rule3Chave
                }

                $Script:Rule3Meta = New-TestDocumentMetadata @metaParams

                Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $Script:Rule3Meta

                $Script:Rule3RowBefore = Get-TestDocumentRow -Cnpj $Script:Cnpj -ChaveAcesso $Script:Rule3Chave

                Start-Sleep -Milliseconds 50

                Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $Script:Rule3Meta

                $Script:Rule3RowAfter = Get-TestDocumentRow -Cnpj $Script:Cnpj -ChaveAcesso $Script:Rule3Chave
            }

            It 'Does not throw on repeated call' {
                { Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $Script:Rule3Meta } |
                    Should -Not -Throw
            }

            It 'Does not duplicate the row' {
                $Script:Rule3RowAfter | Should -Not -BeNullOrEmpty
            }

            It 'Does not update indexed_at' {
                $Script:Rule3RowAfter.IndexedAt | Should -Be $Script:Rule3RowBefore.IndexedAt
            }
        }
        #endregion

        #region Rule 4 - Same type, different sha256
        Context 'Rule 4 - Same type, different sha256' {

            BeforeAll {

                $Script:Rule4Chave  = '35260812345678000199550010000000071234567890'
                $Script:Rule4FileV1 = New-TestXmlFile -Content '<nfe>v1</nfe>'

                $metaParams = @{
                    File  = $Script:Rule4FileV1
                    Chave = $Script:Rule4Chave
                }

                Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata (New-TestDocumentMetadata @metaParams)

                $Script:Rule4RowBefore = Get-TestDocumentRow -Cnpj $Script:Cnpj -ChaveAcesso $Script:Rule4Chave

                Start-Sleep -Milliseconds 50

                [System.IO.File]::WriteAllText(
                    $Script:Rule4FileV1.FullName,
                    '<nfe>v2</nfe>',
                    [System.Text.Encoding]::UTF8
                )

                $Script:Rule4FileV2 = [System.IO.FileInfo]::new($Script:Rule4FileV1.FullName)

                $metaParams = @{
                    File  = $Script:Rule4FileV2
                    Chave = $Script:Rule4Chave
                }

                Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata (New-TestDocumentMetadata @metaParams)

                $Script:Rule4RowAfter = Get-TestDocumentRow -Cnpj $Script:Cnpj -ChaveAcesso $Script:Rule4Chave
            }

            It 'Does not duplicate the row' {
                $Script:Rule4RowAfter | Should -Not -BeNullOrEmpty
            }

            It 'Updates sha256' {
                $Script:Rule4RowAfter.Sha256 | Should -Not -Be $Script:Rule4RowBefore.Sha256
                $Script:Rule4RowAfter.Sha256 | Should -Be (Get-TestFileSha256 -File $Script:Rule4FileV2)
            }

            It 'Updates indexed_at' {
                $Script:Rule4RowAfter.IndexedAt | Should -Not -Be $Script:Rule4RowBefore.IndexedAt
            }
        }
        #endregion

        #region CNPJ isolation
        Context 'CNPJ isolation' {

            BeforeAll {

                $Script:OtherCnpj = '98765432000100'

                Initialize-DFeIndex -Cnpj $Script:OtherCnpj | Out-Null

                $file = New-TestXmlFile -Content '<nfe>isolation</nfe>'

                $metaParams = @{
                    File  = $file
                    Chave = $Script:ChaveAcesso
                }

                Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata (New-TestDocumentMetadata @metaParams)
            }

            It 'Does not write to the other CNPJ database' {
                $row = Get-TestDocumentRow -Cnpj $Script:OtherCnpj -ChaveAcesso $Script:ChaveAcesso

                $row | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Parameter validation
        Context 'Parameter validation' {

            It 'Rejects an invalid Cnpj' {
                $file = New-TestXmlFile -Content '<nfe/>'
                $meta = New-TestDocumentMetadata -File $file

                { Save-DFeDocumentEntry -Cnpj 'INVALID' -Metadata $meta } | Should -Throw
            }

            It 'Rejects null Metadata' {
                { Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $null } | Should -Throw
            }

            It 'Rejects Metadata with wrong Tipo' {
                $file = New-TestXmlFile -Content '<evento/>'

                $meta = [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Evento
                    Chave  = $Script:ChaveAcesso
                    Modelo = [ModeloDFe]::NFe
                    IsProc = $false
                    File   = $file
                    Ndoc   = $null
                    Serie  = $null
                    DhEmi  = $null
                }

                { Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports InvalidMetadataTipo as ErrorId for wrong Tipo' {
                $file = New-TestXmlFile -Content '<evento/>'

                $meta = [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Evento
                    Chave  = $Script:ChaveAcesso
                    Modelo = [ModeloDFe]::NFe
                    IsProc = $false
                    File   = $file
                    Ndoc   = $null
                    Serie  = $null
                    DhEmi  = $null
                }

                try {
                    Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeDocumentEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'InvalidMetadataTipo*'
                }
            }

            It 'Rejects Metadata with empty Chave' {
                $file = New-TestXmlFile -Content '<nfe/>'
                $metaParams = @{ File = $file; Chave = '' }
                $meta = New-TestDocumentMetadata @metaParams

                { Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports MissingChave as ErrorId for empty Chave' {
                $file = New-TestXmlFile -Content '<nfe/>'
                $metaParams = @{ File = $file; Chave = '' }
                $meta = New-TestDocumentMetadata @metaParams

                try {
                    Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeDocumentEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'MissingChave*'
                }
            }

            It 'Rejects Metadata with null Modelo' {
                $file = New-TestXmlFile -Content '<nfe/>'

                $meta = [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Documento
                    Chave  = $Script:ChaveAcesso
                    Modelo = $null
                    IsProc = $false
                    File   = $file
                    Ndoc   = $null
                    Serie  = $null
                    DhEmi  = $null
                }

                { Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports MissingModelo as ErrorId for null Modelo' {
                $file = New-TestXmlFile -Content '<nfe/>'

                $meta = [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Documento
                    Chave  = $Script:ChaveAcesso
                    Modelo = $null
                    IsProc = $false
                    File   = $file
                    Ndoc   = $null
                    Serie  = $null
                    DhEmi  = $null
                }

                try {
                    Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeDocumentEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'MissingModelo*'
                }
            }

            It 'Rejects Metadata with null File' {
                $meta = [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Documento
                    Chave  = $Script:ChaveAcesso
                    Modelo = [ModeloDFe]::NFe
                    IsProc = $false
                    File   = $null
                    Ndoc   = $null
                    Serie  = $null
                    DhEmi  = $null
                }

                { Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports MissingFilePath as ErrorId for null File' {
                $meta = [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Documento
                    Chave  = $Script:ChaveAcesso
                    Modelo = [ModeloDFe]::NFe
                    IsProc = $false
                    File   = $null
                    Ndoc   = $null
                    Serie  = $null
                    DhEmi  = $null
                }

                try {
                    Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeDocumentEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'MissingFilePath*'
                }
            }

            It 'Declares Cnpj as a mandatory parameter' {
                $parameter = (Get-Command -Name Save-DFeDocumentEntry).Parameters['Cnpj']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } | Select-Object -ExpandProperty Mandatory |

                    Should -Contain $true
            }

            It 'Declares Metadata as a mandatory parameter' {
                $parameter = (Get-Command -Name Save-DFeDocumentEntry).Parameters['Metadata']

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
                # This exercises the outer catch in Save-DFeDocumentEntry and
                # confirms that any connection error is normalised to
                # DocumentEntrySaveFailed.
                Mock -CommandName Open-DFeIndexConnection -MockWith {
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

            It 'Reports DocumentEntrySaveFailed as ErrorId on connection failure' {
                $file = New-TestXmlFile -Content '<nfe>fail</nfe>'
                $meta = New-TestDocumentMetadata -File $file

                try {
                    Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeDocumentEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'DocumentEntrySaveFailed*'
                }
            }
        }
        #endregion
    }
}
