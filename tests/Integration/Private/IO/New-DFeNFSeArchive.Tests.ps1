#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for New-DFeNFSeArchive.

.DESCRIPTION
Verifies that national NFS-e index entries produce a published ZIP
without requiring documents from any other fiscal model.

Coverage includes:
  - Empty input without archive preparation.
  - Standard archive name, destination, and published SHA-256.
  - Monthly and partial-period ZIP paths without access-key directories.
  - Exact ZIP contents and preservation of the original XML files.
  - Rejection of invalid access keys and relative source paths.
  - Rejection of missing files, missing hashes, and changed XML files.
  - Duplicate internal ZIP path detection.
  - Temporary ZIP cleanup after success, write failure, and publication conflict.
  - Preservation of an existing destination with different content.
#>

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'New-DFeNFSeArchive' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            Add-Type -AssemblyName 'System.IO.Compression'
            Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                ('PipeDFe.Tests-' + [guid]::NewGuid().ToString('N'))
            )

            [void][System.IO.Directory]::CreateDirectory($Script:TempRoot)

            $Script:PreviousDataRoot = $env:LOCALAPPDATA
            $env:LOCALAPPDATA = $Script:TempRoot

            function New-TestNFSeEntry {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                    'PSUseShouldProcessForStateChangingFunctions',
                    '',
                    Justification = 'Test helper; ShouldProcess not applicable.'
                )]
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$AccessKey
                )

                $xml = '<NFSe xmlns="http://www.sped.fazenda.gov.br/nfse"><infNFSe Id="NFS{0}" /></NFSe>' -f $AccessKey
                [System.IO.File]::WriteAllText($Path, $xml)

                [PSCustomObject]@{
                    chave_acesso  = $AccessKey
                    file_path     = $Path
                    source_sha256 = (Get-FileHash -LiteralPath $Path).Hash
                }
            }
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:PreviousDataRoot

            $removeItemParams = @{
                LiteralPath = $Script:TempRoot
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeItemParams
        }

        BeforeEach {

            $testId = [guid]::NewGuid().ToString('N')

            $Script:CasePath = [System.IO.Path]::Combine(
                $TestDrive,
                $testId
            )

            $sourcePath = Join-Path -Path $Script:CasePath -ChildPath 'xml'
            $outputPath = Join-Path -Path $Script:CasePath -ChildPath 'output'

            [void][System.IO.Directory]::CreateDirectory($sourcePath)

            $entryParams = @{
                Path      = Join-Path -Path $sourcePath -ChildPath 'nota-001.xml'
                AccessKey = '1' * 50
            }

            $Script:Entry = New-TestNFSeEntry @entryParams

            $Script:ArchiveParams = @{
                Cnpj      = '12345678000199'
                Company   = [PSCustomObject]@{
                    NomeFantasia = 'Empresa Exemplo'
                    RazaoSocial  = 'Empresa Exemplo Ltda'
                    OutputPath   = $outputPath
                }
                DateRange = [PSCustomObject]@{
                    Start = [System.DateTimeOffset]'2026-11-01T00:00:00-03:00'
                    End   = [System.DateTimeOffset]'2026-11-30T23:59:59-03:00'
                }
                Entries   = @($Script:Entry)
            }
        }
        #endregion

        #region Published ZIP
        Context 'Published ZIP' {

            It 'Does not prepare an archive for empty input' {
                $params = $Script:ArchiveParams.Clone()
                $params.Entries = @()

                Mock -CommandName Resolve-DFeArchiveInfo -MockWith {
                    throw 'Archive metadata must not be resolved for empty input.'
                }

                @(New-DFeNFSeArchive @params) | Should -HaveCount 0
                Test-Path -LiteralPath $params.Company.OutputPath | Should -BeFalse
            }

            It 'Publishes exactly the supplied NFS-e XMLs under <PeriodSegment>' -ForEach @(
                @{
                    End           = '2026-11-30T23:59:59-03:00'
                    PeriodSegment = '202611'
                }
                @{
                    End           = '2026-11-15T23:59:59-03:00'
                    PeriodSegment = '20261101_20261115'
                }
            ) {
                $params = $Script:ArchiveParams.Clone()
                $params.DateRange = [PSCustomObject]@{
                    Start = $params.DateRange.Start
                    End   = [datetimeoffset]$End
                }

                $secondEntryParams = @{
                    Path      = [System.IO.Path]::Combine(
                        $Script:CasePath,
                        'xml',
                        'nota-002.xml'
                    )
                    AccessKey = '2' * 50
                }

                $secondEntry = New-TestNFSeEntry @secondEntryParams
                $params.Entries = @($Script:Entry, $secondEntry)

                $results = @(New-DFeNFSeArchive @params)

                $results | Should -HaveCount 1

                $result = $results[0]
                $expectedName = 'NFSe_12345678000199_EMPRESA_EXEMPLO_{0}.zip' -f $PeriodSegment
                $expectedPath = Join-Path -Path $params.Company.OutputPath -ChildPath $expectedName

                $result.TipoDFe  | Should -BeExactly 'NFSe'
                $result.FileName | Should -BeExactly $expectedName
                $result.DestPath | Should -BeExactly $expectedPath

                Test-Path -LiteralPath $expectedPath -PathType Leaf | Should -BeTrue
                Test-Path -LiteralPath $result.TempPath             | Should -BeFalse

                (Get-FileHash -LiteralPath $expectedPath).Hash |
                    Should -Be $result.FileHash

                $zip = [System.IO.Compression.ZipFile]::OpenRead($expectedPath)

                try {
                    $zip.Entries | Should -HaveCount 2

                    foreach ($source in $params.Entries) {
                        $fileName = [System.IO.Path]::GetFileName($source.file_path)
                        $entryPath = 'NFSe/{0}/{1}' -f $PeriodSegment, $fileName
                        $zipEntry = $zip.GetEntry($entryPath)

                        $zipEntry | Should -Not -BeNullOrEmpty

                        $entryStream = $zipEntry.Open()

                        try {
                            (Get-FileHash -InputStream $entryStream).Hash |
                                Should -Be $source.source_sha256
                        } finally {
                            $entryStream.Dispose()
                        }

                        (Get-FileHash -LiteralPath $source.file_path).Hash |
                            Should -Be $source.source_sha256
                    }
                } finally {
                    $zip.Dispose()
                }
            }
        }
        #endregion

        #region Indexed sources
        Context 'Indexed sources' {

            It 'Rejects <Scenario> without publishing an archive' -ForEach @(
                @{
                    Scenario = 'a 44-digit access key'
                    ErrorId  = 'InvalidNFSeArchiveEntry'
                }
                @{
                    Scenario = 'a relative source path'
                    ErrorId  = 'InvalidNFSeArchiveEntry'
                }
                @{
                    Scenario = 'a missing XML'
                    ErrorId  = 'ArchiveSourceNotFound'
                }
                @{
                    Scenario = 'a missing indexed hash'
                    ErrorId  = 'ArchiveSourceHashMissing'
                }
                @{
                    Scenario = 'an XML changed after indexing'
                    ErrorId  = 'ArchiveSourceHashMismatch'
                }
            ) {
                $params = $Script:ArchiveParams

                switch ($Scenario) {
                    'a 44-digit access key' {
                        $Script:Entry.chave_acesso = '1' * 44
                    }
                    'a relative source path' {
                        $Script:Entry.file_path = 'xml/nota-001.xml'
                    }
                    'a missing XML' {
                        [System.IO.File]::Delete($Script:Entry.file_path)
                    }
                    'a missing indexed hash' {
                        $Script:Entry.source_sha256 = [string]::Empty
                    }
                    'an XML changed after indexing' {
                        [System.IO.File]::AppendAllText(
                            $Script:Entry.file_path,
                            '<!-- changed after indexing -->'
                        )
                    }
                }

                { New-DFeNFSeArchive @params } | Should -Throw -ErrorId "$ErrorId*"

                Test-Path -LiteralPath $params.Company.OutputPath | Should -BeFalse
            }

            It 'Rejects equal ZIP paths from XMLs in different source directories' {
                $otherPath = Join-Path -Path $Script:CasePath -ChildPath 'other'
                [void][System.IO.Directory]::CreateDirectory($otherPath)

                $entryParams = @{
                    Path      = Join-Path -Path $otherPath -ChildPath 'nota-001.xml'
                    AccessKey = '2' * 50
                }

                $secondEntry = New-TestNFSeEntry @entryParams
                $params = $Script:ArchiveParams.Clone()
                $params.Entries = @($Script:Entry, $secondEntry)

                { New-DFeNFSeArchive @params } |
                    Should -Throw -ErrorId 'ArchiveDuplicatePath*'

                Test-Path -LiteralPath $params.Company.OutputPath | Should -BeFalse
            }
        }
        #endregion

        #region Failure cleanup
        Context 'Failure cleanup' {

            BeforeAll {

                $infoParams = @{
                    TipoDFe   = 'NFSe'
                    Cnpj      = $Script:ArchiveParams.Cnpj
                    Company   = $Script:ArchiveParams.Company
                    DateRange = $Script:ArchiveParams.DateRange
                }

                $Script:ArchiveInfo = Resolve-DFeArchiveInfo @infoParams
                $Script:ArchiveInfo.TempPath = [System.IO.Path]::Combine(
                    $Script:CasePath,
                    'temp',
                    'archive.tmp'
                )

                Mock -CommandName Resolve-DFeArchiveInfo -MockWith {
                    $Script:ArchiveInfo
                }
            }

            It 'Removes the temporary ZIP when writing an entry fails' {
                $params = $Script:ArchiveParams

                Mock -CommandName Add-ZipEntry -MockWith {
                    if (-not [System.IO.File]::Exists($Script:ArchiveInfo.TempPath)) {
                        throw 'The temporary ZIP was not opened for writing.'
                    }

                    throw [System.IO.IOException]::new('Forced ZIP entry write failure.')
                }

                { New-DFeNFSeArchive @params } |
                    Should -Throw -ExpectedMessage '*Forced ZIP entry write failure*'

                Test-Path -LiteralPath $Script:ArchiveInfo.TempPath | Should -BeFalse
                Test-Path -LiteralPath $Script:ArchiveInfo.DestPath | Should -BeFalse
            }

            It 'Preserves an existing destination and removes staging files on conflict' {
                $nfseParams  = $Script:ArchiveParams
                $destination = $Script:ArchiveInfo.DestPath

                [void][System.IO.Directory]::CreateDirectory(
                    [System.IO.Path]::GetDirectoryName($destination)
                )

                [System.IO.File]::WriteAllText($destination, 'Existing destination content')

                $originalHash = (Get-FileHash -LiteralPath $destination).Hash

                { New-DFeNFSeArchive @nfseParams } |
                    Should -Throw -ErrorId 'ArchivePublishConflict*'

                (Get-FileHash -LiteralPath $destination).Hash |
                    Should -BeExactly $originalHash

                Test-Path -LiteralPath $Script:ArchiveInfo.TempPath | Should -BeFalse

                $remainingFiles = [System.IO.Directory]::GetFiles(
                    [System.IO.Path]::GetDirectoryName($destination)
                )

                $remainingFiles    | Should -HaveCount 1
                $remainingFiles[0] | Should -BeExactly $destination
            }
        }
        #endregion
    }
}
