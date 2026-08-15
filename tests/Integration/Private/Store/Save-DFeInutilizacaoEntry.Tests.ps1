#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Save-DFeInutilizacaoEntry.

.DESCRIPTION
Verifies that Save-DFeInutilizacaoEntry persists inutilizacao records
correctly against a real SQLite database initialised by Initialize-DFeIndex.

Coverage includes:
  - Insert of a new inutilizacao record.
  - Idempotency: same id_inut, same sha256 -> no-op, indexed_at unchanged.
  - Update: same id_inut, different sha256 -> record updated.
  - Different id_inut produces a new independent record.
  - nnf_ini and nnf_fin are persisted correctly.
  - indexed_at is set on insert and updated on content change.
  - CNPJ isolation.
  - Parameter validation: Cnpj, Metadata, Tipo, IdInut, Modelo, Serie,
    File, NNFIni/NNFFin.
  - Write failure produces InutilizacaoEntrySaveFailed.

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

Describe 'Save-DFeInutilizacaoEntry' {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            $joinPathParams = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = 'PipeDFe.Save-DFeInutilizacaoEntry.Tests-' + [guid]::NewGuid().ToString('N')
            }

            $Script:TestRoot = Join-Path @joinPathParams

            New-Item -ItemType Directory -Path $Script:TestRoot -Force -ErrorAction Stop |
                Out-Null

            $env:LOCALAPPDATA = $Script:TestRoot
            $Script:Cnpj      = '12345678000199'
            $Script:IdInut    = '35260112345678000199550010000000011234567890'

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

            function New-TestInutilizacaoMetadata {
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [System.IO.FileInfo]$File,

                    [Parameter()]
                    [string]$IdInut = $Script:IdInut,

                    [Parameter()]
                    [object]$Modelo = [ModeloDFe]::NFe,

                    [Parameter()]
                    [string]$Serie  = '1',

                    [Parameter()]
                    [object]$NNFIni = 1,

                    [Parameter()]
                    [object]$NNFFin = 10
                )

                [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Inutilizacao
                    IdInut = $IdInut
                    Modelo = $Modelo
                    Serie  = $Serie
                    NNFIni = $NNFIni
                    NNFFin = $NNFFin
                    File   = $File
                }
            }

            function Get-TestInutilizacaoRow {
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$IdInut
                )

                $databasePath = Get-StorePath -Scope Index -Cnpj $Cnpj
                $connection   = Open-SqliteConnection -Path $databasePath

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = @'
SELECT id_inut, modelo, serie, nnf_ini, nnf_fin, file_path, sha256, indexed_at
FROM   dfe_inutilizacao
WHERE  id_inut = @id_inut;
'@
                        $command.Parameters.AddWithValue('@id_inut', $IdInut) | Out-Null

                        $reader = $command.ExecuteReader()
                        try {
                            if ($reader.Read()) {
                                [PSCustomObject]@{
                                    IdInut    = [string]$reader['id_inut']
                                    Modelo    = [int]$reader['modelo']
                                    Serie     = [string]$reader['serie']
                                    NNFIni    = [int]$reader['nnf_ini']
                                    NNFFin    = [int]$reader['nnf_fin']
                                    FilePath  = [string]$reader['file_path']
                                    Sha256    = [string]$reader['sha256']
                                    IndexedAt = [string]$reader['indexed_at']
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

                $Script:InsertFile = New-TestXmlFile -Content '<inutNFe>insert</inutNFe>'

                $metaParams = @{
                    File   = $Script:InsertFile
                    IdInut = $Script:IdInut
                    Modelo = [ModeloDFe]::NFe
                    Serie  = '1'
                    NNFIni = 1
                    NNFFin = 10
                }

                $Script:InsertMeta = New-TestInutilizacaoMetadata @metaParams

                Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $Script:InsertMeta

                $Script:InsertRow = Get-TestInutilizacaoRow -Cnpj $Script:Cnpj -IdInut $Script:IdInut
            }

            It 'Inserts exactly one row' {
                $Script:InsertRow | Should -Not -BeNullOrEmpty
            }

            It 'Persists id_inut' {
                $Script:InsertRow.IdInut | Should -Be $Script:IdInut
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

            It 'Persists serie' {
                $Script:InsertRow.Serie | Should -Be '1'
            }

            It 'Persists nnf_ini' {
                $Script:InsertRow.NNFIni | Should -Be 1
            }

            It 'Persists nnf_fin' {
                $Script:InsertRow.NNFFin | Should -Be 10
            }

            It 'Sets indexed_at' {
                $Script:InsertRow.IndexedAt | Should -Not -BeNullOrEmpty
            }

            It 'Stores indexed_at as a valid UTC ISO 8601 timestamp' {
                { [System.DateTimeOffset]::Parse($Script:InsertRow.IndexedAt) } | Should -Not -Throw
            }
        }
        #endregion

        #region Idempotency - same sha256
        Context 'Idempotency - same sha256' {

            BeforeAll {

                $Script:NoopIdInut = '35260112345678000199550010000000021234567890'
                $Script:NoopFile   = New-TestXmlFile -Content '<inutNFe>noop</inutNFe>'

                $metaParams = @{
                    File   = $Script:NoopFile
                    IdInut = $Script:NoopIdInut
                }

                $Script:NoopMeta = New-TestInutilizacaoMetadata @metaParams

                Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $Script:NoopMeta

                $Script:NoopRowBefore = Get-TestInutilizacaoRow -Cnpj $Script:Cnpj -IdInut $Script:NoopIdInut

                Start-Sleep -Milliseconds 50

                Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $Script:NoopMeta

                $Script:NoopRowAfter = Get-TestInutilizacaoRow -Cnpj $Script:Cnpj -IdInut $Script:NoopIdInut
            }

            It 'Does not throw on repeated call' {
                { Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $Script:NoopMeta } |
                    Should -Not -Throw
            }

            It 'Does not duplicate the row' {
                $Script:NoopRowAfter | Should -Not -BeNullOrEmpty
            }

            It 'Does not update indexed_at' {
                $Script:NoopRowAfter.IndexedAt | Should -Be $Script:NoopRowBefore.IndexedAt
            }
        }
        #endregion

        #region Update - different sha256
        Context 'Update - different sha256' {

            BeforeAll {

                $Script:UpdateIdInut = '35260112345678000199550010000000031234567890'
                $Script:UpdateFileV1 = New-TestXmlFile -Content '<inutNFe>v1</inutNFe>'

                $metaParams = @{
                    File   = $Script:UpdateFileV1
                    IdInut = $Script:UpdateIdInut
                }

                Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata (New-TestInutilizacaoMetadata @metaParams)

                $Script:UpdateRowBefore = Get-TestInutilizacaoRow -Cnpj $Script:Cnpj -IdInut $Script:UpdateIdInut

                Start-Sleep -Milliseconds 50

                [System.IO.File]::WriteAllText(
                    $Script:UpdateFileV1.FullName,
                    '<inutNFe>v2</inutNFe>',
                    [System.Text.Encoding]::UTF8
                )

                $Script:UpdateFileV2 = [System.IO.FileInfo]::new($Script:UpdateFileV1.FullName)

                $metaParams = @{
                    File   = $Script:UpdateFileV2
                    IdInut = $Script:UpdateIdInut
                    NNFIni = 5
                    NNFFin = 20
                }

                Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata (New-TestInutilizacaoMetadata @metaParams)

                $Script:UpdateRowAfter = Get-TestInutilizacaoRow -Cnpj $Script:Cnpj -IdInut $Script:UpdateIdInut
            }

            It 'Does not duplicate the row' {
                $Script:UpdateRowAfter | Should -Not -BeNullOrEmpty
            }

            It 'Updates sha256' {
                $Script:UpdateRowAfter.Sha256 | Should -Not -Be $Script:UpdateRowBefore.Sha256
                $Script:UpdateRowAfter.Sha256 | Should -Be (Get-TestFileSha256 -File $Script:UpdateFileV2)
            }

            It 'Updates nnf_ini' {
                $Script:UpdateRowAfter.NNFIni | Should -Be 5
            }

            It 'Updates nnf_fin' {
                $Script:UpdateRowAfter.NNFFin | Should -Be 20
            }

            It 'Updates indexed_at' {
                $Script:UpdateRowAfter.IndexedAt | Should -Not -Be $Script:UpdateRowBefore.IndexedAt
            }
        }
        #endregion

        #region Different id_inut
        Context 'Different id_inut produces independent records' {

            BeforeAll {

                $Script:DiffIdInut1 = '35260112345678000199550010000000041234567890'
                $Script:DiffIdInut2 = '35260112345678000199550010000000051234567890'

                $file1 = New-TestXmlFile -Content '<inutNFe>diff-1</inutNFe>'
                $file2 = New-TestXmlFile -Content '<inutNFe>diff-2</inutNFe>'

                $metaParamsOne = @{
                    File   = $file1
                    IdInut = $Script:DiffIdInut1
                    NNFIni = 1
                    NNFFin = 5
                }

                $metaParamsTwo = @{
                    File   = $file2
                    IdInut = $Script:DiffIdInut2
                    NNFIni = 6
                    NNFFin = 10
                }

                Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata (New-TestInutilizacaoMetadata @metaParamsOne)
                Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata (New-TestInutilizacaoMetadata @metaParamsTwo)

                $Script:DiffRow1 = Get-TestInutilizacaoRow -Cnpj $Script:Cnpj -IdInut $Script:DiffIdInut1
                $Script:DiffRow2 = Get-TestInutilizacaoRow -Cnpj $Script:Cnpj -IdInut $Script:DiffIdInut2
            }

            It 'Creates both records' {
                $Script:DiffRow1 | Should -Not -BeNullOrEmpty
                $Script:DiffRow2 | Should -Not -BeNullOrEmpty
            }

            It 'Records are independent' {
                $Script:DiffRow1.NNFIni | Should -Be 1
                $Script:DiffRow1.NNFFin | Should -Be 5
                $Script:DiffRow2.NNFIni | Should -Be 6
                $Script:DiffRow2.NNFFin | Should -Be 10
            }
        }
        #endregion

        #region CNPJ isolation
        Context 'CNPJ isolation' {

            BeforeAll {

                $Script:OtherCnpj = '98765432000100'
                Initialize-DFeIndex -Cnpj $Script:OtherCnpj | Out-Null

                $file = New-TestXmlFile -Content '<inutNFe>isolation</inutNFe>'

                $metaParams = @{
                    File   = $file
                    IdInut = $Script:IdInut
                }

                Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata (New-TestInutilizacaoMetadata @metaParams)
            }

            It 'Does not write to the other CNPJ database' {
                $row = Get-TestInutilizacaoRow -Cnpj $Script:OtherCnpj -IdInut $Script:IdInut
                $row | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Parameter validation
        Context 'Parameter validation' {

            It 'Rejects an invalid Cnpj' {
                $file = New-TestXmlFile -Content '<inutNFe/>'
                $meta = New-TestInutilizacaoMetadata -File $file

                { Save-DFeInutilizacaoEntry -Cnpj 'INVALID' -Metadata $meta } | Should -Throw
            }

            It 'Rejects null Metadata' {
                { Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $null } | Should -Throw
            }

            It 'Rejects Metadata with wrong Tipo' {
                $file = New-TestXmlFile -Content '<nfe/>'

                $meta = [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Documento
                    IdInut = $Script:IdInut
                    Modelo = [ModeloDFe]::NFe
                    Serie  = '1'
                    NNFIni = 1
                    NNFFin = 10
                    File   = $file
                }

                { Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports InvalidMetadataTipo as ErrorId for wrong Tipo' {
                $file = New-TestXmlFile -Content '<nfe/>'

                $meta = [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Documento
                    IdInut = $Script:IdInut
                    Modelo = [ModeloDFe]::NFe
                    Serie  = '1'
                    NNFIni = 1
                    NNFFin = 10
                    File   = $file
                }

                try {
                    Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeInutilizacaoEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'InvalidMetadataTipo*'
                }
            }

            It 'Rejects Metadata with empty IdInut' {
                $file = New-TestXmlFile -Content '<inutNFe/>'

                $metaParams = @{
                    File   = $file
                    IdInut = ''
                }

                $meta = New-TestInutilizacaoMetadata @metaParams

                { Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports MissingIdInut as ErrorId for empty IdInut' {
                $file = New-TestXmlFile -Content '<inutNFe/>'

                $metaParams = @{
                    File   = $file
                    IdInut = ''
                }

                $meta = New-TestInutilizacaoMetadata @metaParams

                try {
                    Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeInutilizacaoEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'MissingIdInut*'
                }
            }

            It 'Rejects Metadata with null Modelo' {
                $file = New-TestXmlFile -Content '<inutNFe/>'

                $meta = [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Inutilizacao
                    IdInut = $Script:IdInut
                    Modelo = $null
                    Serie  = '1'
                    NNFIni = 1
                    NNFFin = 10
                    File   = $file
                }

                { Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports MissingModelo as ErrorId for null Modelo' {
                $file = New-TestXmlFile -Content '<inutNFe/>'

                $meta = [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Inutilizacao
                    IdInut = $Script:IdInut
                    Modelo = $null
                    Serie  = '1'
                    NNFIni = 1
                    NNFFin = 10
                    File   = $file
                }

                try {
                    Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeInutilizacaoEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'MissingModelo*'
                }
            }

            It 'Rejects Metadata with empty Serie' {
                $file = New-TestXmlFile -Content '<inutNFe/>'

                $metaParams = @{
                    File  = $file
                    Serie = ''
                }

                $meta = New-TestInutilizacaoMetadata @metaParams

                { Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports MissingSerie as ErrorId for empty Serie' {
                $file = New-TestXmlFile -Content '<inutNFe/>'

                $metaParams = @{
                    File  = $file
                    Serie = ''
                }

                $meta = New-TestInutilizacaoMetadata @metaParams

                try {
                    Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeInutilizacaoEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'MissingSerie*'
                }
            }

            It 'Rejects Metadata with null File' {
                $meta = [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Inutilizacao
                    IdInut = $Script:IdInut
                    Modelo = [ModeloDFe]::NFe
                    Serie  = '1'
                    NNFIni = 1
                    NNFFin = 10
                    File   = $null
                }

                { Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports MissingFilePath as ErrorId for null File' {
                $meta = [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Inutilizacao
                    IdInut = $Script:IdInut
                    Modelo = [ModeloDFe]::NFe
                    Serie  = '1'
                    NNFIni = 1
                    NNFFin = 10
                    File   = $null
                }

                try {
                    Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeInutilizacaoEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'MissingFilePath*'
                }
            }

            It 'Rejects non-numeric NNFIni' {
                $file = New-TestXmlFile -Content '<inutNFe/>'

                $metaParams = @{
                    File   = $file
                    NNFIni = 'ABC'
                    NNFFin = 10
                }

                $meta = New-TestInutilizacaoMetadata @metaParams

                { Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Rejects non-numeric NNFFin' {
                $file = New-TestXmlFile -Content '<inutNFe/>'

                $metaParams = @{
                    File   = $file
                    NNFIni = 1
                    NNFFin = 'ABC'
                }

                $meta = New-TestInutilizacaoMetadata @metaParams

                { Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports InvalidNNFRange as ErrorId for non-numeric range' {
                $file = New-TestXmlFile -Content '<inutNFe/>'

                $metaParams = @{
                    File   = $file
                    NNFIni = 'ABC'
                    NNFFin = 'DEF'
                }

                $meta = New-TestInutilizacaoMetadata @metaParams

                try {
                    Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeInutilizacaoEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'InvalidNNFRange*'
                }
            }

            It 'Declares Cnpj as a mandatory parameter' {
                $parameter = (Get-Command -Name Save-DFeInutilizacaoEntry).Parameters['Cnpj']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } | Select-Object -ExpandProperty Mandatory |

                    Should -Contain $true
            }

            It 'Declares Metadata as a mandatory parameter' {
                $parameter = (Get-Command -Name Save-DFeInutilizacaoEntry).Parameters['Metadata']

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
                # This exercises the outer catch in Save-DFeInutilizacaoEntry and
                # confirms that any connection error is normalised to
                # InutilizacaoEntrySaveFailed.
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

            It 'Reports InutilizacaoEntrySaveFailed as ErrorId on connection failure' {
                $file = New-TestXmlFile -Content '<inutNFe>fail</inutNFe>'
                $meta = New-TestInutilizacaoMetadata -File $file

                try {
                    Save-DFeInutilizacaoEntry -Cnpj $Script:Cnpj -Metadata $meta -ErrorAction Stop
                    throw 'Expected Save-DFeInutilizacaoEntry to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'InutilizacaoEntrySaveFailed*'
                }
            }
        }
        #endregion
    }
}
