#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Regression tests for New-DFeArchive direction-aware archive planning.

.DESCRIPTION
Coverage includes:
  - Incoming and outgoing NF-e are isolated.
  - Events follow only their owning fiscal document.
  - Other document models remain grouped by model.
  - Invalid, missing, uncovered, and duplicated NF-e directions are rejected.
  - Empty groups and archive path collisions are rejected before compression.
  - Invalid archive plans have no compression or publication side effects.
  - Publishing failures propagate and temporary files are cleaned.
  - Output contract remains stable.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
)]

param ()

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $modulePath -Force -Global -ErrorAction Stop
}

Describe 'New-DFeArchive direction-aware planning' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Cnpj    = '12345678000199'

            $Script:Company = [PSCustomObject]@{
                XmlPath    = (Join-Path $TestDrive 'xml')
                OutputPath = (Join-Path $TestDrive 'out')
            }

            $Script:DateRange = [PSCustomObject]@{
                Start = [DateTimeOffset]::new(2026, 8, 1, 0, 0, 0, [TimeSpan]::Zero)
                End   = [DateTimeOffset]::new(2026, 8, 31, 23, 59, 59, [TimeSpan]::Zero)
            }

            $Script:OutKey = '1' * 44
            $Script:InKey  = '2' * 44
            $Script:CteKey = '3' * 44

            $Script:OutEntry = [PSCustomObject]@{
                chave_acesso = $Script:OutKey
                modelo       = 55
                direcao      = 'Saida'
                file_path    = 'out.xml'
                sha256       = 'out-hash'
            }

            $Script:InEntry = [PSCustomObject]@{
                chave_acesso = $Script:InKey
                modelo       = 55
                direcao      = 'Entrada'
                file_path    = 'in.xml'
                sha256       = 'in-hash'
            }

            $Script:CteEntry = [PSCustomObject]@{
                chave_acesso = $Script:CteKey
                modelo       = 57
                file_path    = 'cte.xml'
                sha256       = 'cte-hash'
            }

            #region Helpers
            function New-DirectionTestInfo {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [ValidateNotNullOrEmpty()]
                    [string]$TipoDFe,

                    [Parameter()]
                    [ValidateSet('Entrada', 'Saida')]
                    [string]$Direcao
                )

                $hasDirection = $PSBoundParameters.ContainsKey('Direcao')

                $suffix = if ($hasDirection) {
                    '{0}_{1}' -f $TipoDFe, $Direcao
                } else {
                    $TipoDFe
                }

                $info = [ordered]@{
                    TipoDFe  = $TipoDFe
                    FileName = "$suffix.zip"
                    TempPath = Join-Path -Path $TestDrive -ChildPath "$suffix.tmp.zip"
                    DestPath = Join-Path -Path $Script:Company.OutputPath -ChildPath "$suffix.zip"
                }

                $info['Direcao'] = if ($hasDirection) {
                    $Direcao
                } else {
                    $null
                }

                [PSCustomObject]$info
            }

            function Invoke-DirectionTestArchive {
                param (
                    [Parameter(Mandatory)]
                    [AllowEmptyCollection()]
                    [pscustomobject[]]$Entries,
                    [Parameter(Mandatory)]
                    [AllowEmptyCollection()]
                    [pscustomobject[]]$ArchiveInfos
                )

                $params = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:Company
                    Entries      = $Entries
                    ArchiveInfos = $ArchiveInfos
                    DateRange    = $Script:DateRange
                    ErrorAction  = 'Stop'
                }

                New-DFeArchive @params
            }
        }
        #endregion

        BeforeEach {

            $Script:CapturedCalls  = @()
            $Script:PublishedCalls = @()

            $Script:OutInfo = New-DirectionTestInfo -TipoDFe 'NFe' -Direcao 'Saida'
            $Script:InInfo  = New-DirectionTestInfo -TipoDFe 'NFe' -Direcao 'Entrada'
            $Script:CteInfo = New-DirectionTestInfo -TipoDFe 'CTe'

            $Script:AllEntries = @($Script:OutEntry, $Script:InEntry, $Script:CteEntry)
            $Script:AllInfos   = @($Script:OutInfo, $Script:InInfo, $Script:CteInfo)

            Mock -CommandName Get-ArchivePeriodSegment -MockWith {
                '202608'
            }

            Mock -CommandName Get-DFeEventoEntry -MockWith {
                if ($ChavePai -eq $Script:OutKey) {
                    [PSCustomObject]@{
                        chave_pai = $Script:OutKey
                        file_path = 'out-event.xml'
                        sha256 = 'out-event-hash'
                    }
                }

                if ($ChavePai -eq $Script:InKey) {
                    [PSCustomObject]@{
                        chave_pai = $Script:InKey
                        file_path = 'in-event.xml'
                        sha256 = 'in-event-hash'
                    }
                }
            }

            Mock -CommandName Compress-DFeArchive -MockWith {
                $Script:CapturedCalls += [PSCustomObject]@{
                    Entries = @($Entries)
                    Eventos = @($Eventos)
                    ZipPath = $ZipPath
                    PeriodSegment = $PeriodSegment
                }

                [System.IO.File]::WriteAllText($ZipPath, 'fake-zip')
            }

            Mock -CommandName Get-FileSha256 -MockWith {
                'a' * 64
            }

            Mock -CommandName Publish-DFeArchive -MockWith {
                $Script:PublishedCalls += [PSCustomObject]@{
                    SourcePath = $SourcePath
                    DestinationPath = $DestinationPath
                    ExpectedHash = $ExpectedHash
                }
            }
        }

        It 'Creates independent Entrada, Saida, and CTe archives' {
            $params = @{
                Entries      = $Script:AllEntries
                ArchiveInfos = $Script:AllInfos
            }

            $result = @(Invoke-DirectionTestArchive @params)

            $result | Should -HaveCount 3

            $Script:CapturedCalls  | Should -HaveCount 3
            $Script:PublishedCalls | Should -HaveCount 3

            $out = @(
                $Script:CapturedCalls |
                    Where-Object ZipPath -EQ $Script:OutInfo.TempPath
            )[0]

            $in  = @(
                $Script:CapturedCalls |
                    Where-Object ZipPath -EQ $Script:InInfo.TempPath
            )[0]

            $cte = @(
                $Script:CapturedCalls |
                    Where-Object ZipPath -EQ $Script:CteInfo.TempPath
            )[0]

            @($out.Entries.ChaveAcesso) | Should -Be @($Script:OutKey)
            @($in.Entries.ChaveAcesso)  | Should -Be @($Script:InKey)
            @($cte.Entries.ChaveAcesso) | Should -Be @($Script:CteKey)
            @($out.Eventos.ChavePai)    | Should -Be @($Script:OutKey)
            @($in.Eventos.ChavePai)     | Should -Be @($Script:InKey)
            @($cte.Eventos)             | Should -HaveCount 0

            $out.PeriodSegment | Should -Be '202608'
        }

        It 'Creates only Saida when only outgoing NF-e are present' {
            $params = @{
                Entries      = @($Script:OutEntry)
                ArchiveInfos = @($Script:OutInfo)
            }

            $result = @(Invoke-DirectionTestArchive @params)

            $result | Should -HaveCount 1

            $result[0].PSObject.Properties.Name | Should -Be @(
                'TipoDFe'
                'Direcao'
                'FileName'
                'FileHash'
                'TempPath'
                'DestPath'
            )

            $result[0].FileHash | Should -Be ('a' * 64)
        }

        It 'Rejects an NF-e with missing direction without side effects' {
            $invalid = $Script:OutEntry.PSObject.Copy()
            $invalid.PSObject.Properties.Remove('direcao')

            $params = @{
                Entries      = @($invalid)
                ArchiveInfos = @($Script:OutInfo)
            }

            { Invoke-DirectionTestArchive @params } |
                Should -Throw -ErrorId 'ArchiveDirectionUncovered*'

            Should -Invoke -CommandName Compress-DFeArchive -Times 0
            Should -Invoke -CommandName Publish-DFeArchive  -Times 0
        }

        It 'Rejects unclassified NF-e with invalid direction' {
            $invalid = $Script:OutEntry.PSObject.Copy()
            $invalid.direcao = 'Terceiro'

            $params = @{
                Entries      = @($invalid)
                ArchiveInfos = @($Script:OutInfo)
            }

            { Invoke-DirectionTestArchive @params } |
                Should -Throw -ErrorId 'ArchiveDirectionUncovered*'
        }

        It 'Rejects an omitted Entrada archive before compression' {
            $params = @{
                Entries      = @($Script:OutEntry, $Script:InEntry)
                ArchiveInfos = @($Script:OutInfo)
            }

            { Invoke-DirectionTestArchive @params } |
                Should -Throw -ErrorId 'ArchiveDirectionUncovered*'

            Should -Invoke -CommandName Compress-DFeArchive -Times 0
        }

        It 'Rejects duplicate Saida definitions before compression' {
            $another = New-DirectionTestInfo -TipoDFe 'NFe' -Direcao 'Saida'
            $another.FileName = 'Another.zip'
            $another.TempPath = Join-Path $TestDrive 'another.tmp.zip'
            $another.DestPath = Join-Path $Script:Company.OutputPath 'another.zip'

            $params = @{
                Entries      = @($Script:OutEntry)
                ArchiveInfos = @($Script:OutInfo, $another)
            }

            { Invoke-DirectionTestArchive @params } |
                Should -Throw -ErrorId 'ArchiveDirectionDuplicate*'

            Should -Invoke -CommandName Compress-DFeArchive -Times 0
        }

        It 'Rejects a non-NFe archive with direction' {
            $invalid = New-DirectionTestInfo -TipoDFe 'CTe' -Direcao 'Saida'

            $params = @{
                Entries      = @($Script:CteEntry)
                ArchiveInfos = @($invalid)
            }

            { Invoke-DirectionTestArchive @params } |
                Should -Throw -ErrorId 'ArchiveDirectionUnsupported*'
        }

        It 'Rejects an NFe archive with null direction' {
            $invalid = New-DirectionTestInfo -TipoDFe 'NFe'

            $params = @{
                Entries      = @($Script:OutEntry)
                ArchiveInfos = @($invalid)
            }

            { Invoke-DirectionTestArchive @params } |
                Should -Throw -ErrorId 'ArchiveDirectionRequired*'
        }

        It 'Rejects an archive with no matching entries' {
            $params = @{
                Entries      = @($Script:CteEntry)
                ArchiveInfos = @($Script:OutInfo)
            }

            { Invoke-DirectionTestArchive @params } |
                Should -Throw -ErrorId 'ArchiveEntriesNotFound*'
        }

        It 'Rejects a destination collision before compression' {
            $Script:InInfo.DestPath = $Script:OutInfo.DestPath

            $params = @{
                Entries      = @($Script:OutEntry, $Script:InEntry)
                ArchiveInfos = @($Script:OutInfo, $Script:InInfo)
            }

            { Invoke-DirectionTestArchive @params } |
                Should -Throw -ErrorId 'ArchivePathConflict*'

            Should -Invoke -CommandName Compress-DFeArchive -Times 0
        }

        It 'Rejects a temporary path collision before compression' {
            $Script:InInfo.TempPath = $Script:OutInfo.TempPath

            $params = @{
                Entries      = @($Script:OutEntry, $Script:InEntry)
                ArchiveInfos = @($Script:OutInfo, $Script:InInfo)
            }

            { Invoke-DirectionTestArchive @params } |
                Should -Throw -ErrorId 'ArchivePathConflict*'
        }

        It 'Rejects an archive temporary path overlapping another destination' {
            $Script:InInfo.TempPath = $Script:OutInfo.DestPath

            $params = @{
                Entries      = @($Script:OutEntry, $Script:InEntry)
                ArchiveInfos = @($Script:OutInfo, $Script:InInfo)
            }

            { Invoke-DirectionTestArchive @params } |
                Should -Throw -ErrorId 'ArchivePathConflict*'

            Should -Invoke -CommandName Compress-DFeArchive -Times 0
            Should -Invoke -CommandName Publish-DFeArchive  -Times 0
        }

        It 'Preserves ZipNotCreated when compression does not create the file' {
            Mock -CommandName Compress-DFeArchive -MockWith {

            }

            $params = @{
                Entries      = @($Script:OutEntry)
                ArchiveInfos = @($Script:OutInfo)
            }

            { Invoke-DirectionTestArchive @params } |
                Should -Throw -ErrorId 'ZipNotCreated*'

            Should -Invoke -CommandName Publish-DFeArchive -Times 0
        }

        It 'Propagates publication errors and removes its temporary ZIP' {
            Mock -CommandName Publish-DFeArchive -MockWith {
                throw [System.InvalidOperationException]::new(
                    'Simulated publication failure'
                )
            }

            $params = @{
                Entries      = @($Script:OutEntry)
                ArchiveInfos = @($Script:OutInfo)
            }

            { Invoke-DirectionTestArchive @params  } |
                Should -Throw '*Simulated publication failure*'

            Test-Path -LiteralPath $Script:OutInfo.TempPath | Should -BeFalse
        }

        It 'Returns no output when there is no work' {
            $result = @(Invoke-DirectionTestArchive -Entries @() -ArchiveInfos @())

            $result | Should -HaveCount 0

            Should -Invoke -CommandName Compress-DFeArchive -Times 0
        }
    }
}
