#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for New-DFePeriodReport.

.DESCRIPTION
Uses real file operations in TestDrive and mocks the CFOP query,
HTML renderer, and workbook exporter.

Coverage includes:
  - Forwarding the selected period to the query and both generators.
  - Reading the CFOP projection once and using it for both reports.
  - Publishing only the HTML and XLSX paths, in that order.
  - Company display name fallback and distinct publication directories.
  - Rejecting invalid output paths and empty HTML before publication.
  - Cleaning up staging after an export failure or a missing or empty workbook.
  - Preserving an earlier publication when a later export fails.
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

Describe 'New-DFePeriodReport' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $joinParamsOne = @{
                Path      = $TestDrive
                ChildPath = [guid]::NewGuid().ToString('N')
            }

            $Script:BaseOutputPath = Join-Path @joinParamsOne

            [void][System.IO.Directory]::CreateDirectory($Script:BaseOutputPath)

            $Script:ReportParams = @{
                Company = [PSCustomObject]@{
                    Cnpj         = '11222333000181'
                    NomeFantasia = 'Example'
                    RazaoSocial  = 'Example Ltda'
                    OutputPath   = $Script:BaseOutputPath
                }
                DateRange = [PSCustomObject]@{
                    Start = [System.DateTimeOffset]'2026-01-01T00:00:00-03:00'
                    End   = [System.DateTimeOffset]'2026-12-31T23:59:59-03:00'
                }
                Entries     = @([PSCustomObject]@{ Id = 'nfe'  })
                NFSeEntries = @([PSCustomObject]@{ Id = 'nfse' })
                Gaps        = @([PSCustomObject]@{ Id = 'gap'  })
            }

            Mock -CommandName Get-DFeNFeCfopReportData -MockWith {
                [PSCustomObject]@{
                    Itens         = @()
                    ResumoPorCFOP = @([PSCustomObject]@{ CFOP = '5102' })
                }
            }

            Mock -CommandName ConvertTo-DFeCfopReportHtml -MockWith {
                '<html>CFOP report</html>'
            }

            Mock -CommandName Export-DFeCfopReportXlsx -MockWith {
                [System.IO.File]::WriteAllBytes($LiteralPath, [byte[]]@(1))
                'Exporter output must not be returned by the publisher.'
            }
        }

        #region Successful publication
        Context 'Successful publication' {

            BeforeEach {

                $joinParams = @{
                    Path      = $TestDrive
                    ChildPath = [guid]::NewGuid().ToString('N')
                }

                $itOutputPath = Join-Path @joinParams

                [void][System.IO.Directory]::CreateDirectory($itOutputPath)

                $rootJoinParams = @{
                    Path      = $itOutputPath
                    ChildPath = 'Relatorios'
                }

                $Script:ReportRoot = Join-Path @rootJoinParams

                $Script:ItParams = $Script:ReportParams.Clone()
                $Script:ItParams.Company = $Script:ReportParams.Company.PSObject.Copy()
                $Script:ItParams.Company.NomeFantasia = 'Example'
                $Script:ItParams.Company.OutputPath   = $itOutputPath
            }

            It 'Publishes the pair and returns only the HTML and XLSX paths in order' {
                $paths = @(New-DFePeriodReport @Script:ItParams)

                $paths | Should -HaveCount 2

                (Split-Path -Leaf $paths[0]) | Should -BeExactly 'Resumo-CFOP.html'
                (Split-Path -Leaf $paths[1]) | Should -BeExactly 'Fechamento.xlsx'

                $publicationPath = Split-Path -Parent $paths[0]

                (Split-Path -Parent $paths[1])        | Should -Be $publicationPath
                (Split-Path -Parent $publicationPath) | Should -Be $Script:ReportRoot
                (Split-Path -Leaf $publicationPath)   |
                    Should -Match '^11222333000181_20260101-20261231_[0-9a-f]{32}$'

                [System.IO.File]::ReadAllText($paths[0]) |
                    Should -BeExactly '<html>CFOP report</html>'

                [System.IO.File]::ReadAllBytes($paths[1])[0] | Should -Be 1

                @(Get-ChildItem -LiteralPath $publicationPath -Force) |
                    Should -HaveCount 2

                @(Get-ChildItem -LiteralPath $Script:ReportRoot -Force) |
                    Should -HaveCount 1
            }

            It 'Queries the annual period once and forwards the period and report data' {
                New-DFePeriodReport @Script:ItParams | Out-Null

                $invokeParamsOne = @{
                    CommandName = 'Get-DFeNFeCfopReportData'
                    Exactly     = $true
                    Times       = 1
                    Scope       = 'It'
                    ModuleName  = 'PipeDFe'
                }

                Should -Invoke @invokeParamsOne

                $invokeParamsTwo = @{
                    CommandName     = 'Get-DFeNFeCfopReportData'
                    Exactly         = $true
                    Times           = 1
                    Scope           = 'It'
                    ModuleName      = 'PipeDFe'
                    ParameterFilter = {
                        $Cnpj -eq '11222333000181' -and
                        $StartDate.EqualsExact(
                            [System.DateTimeOffset]'2026-01-01T00:00:00-03:00'
                        ) -and
                        $EndDate.EqualsExact(
                            [System.DateTimeOffset]'2026-12-31T23:59:59-03:00'
                        )
                    }
                }

                Should -Invoke @invokeParamsTwo

                $invokeParamsThree = @{
                    CommandName     = 'ConvertTo-DFeCfopReportHtml'
                    Exactly         = $true
                    Times           = 1
                    Scope           = 'It'
                    ModuleName      = 'PipeDFe'
                    ParameterFilter = {
                        $CompanyName -eq 'Example' -and
                        $Cnpj -eq '11222333000181' -and
                        $StartDate.EqualsExact(
                            [System.DateTimeOffset]'2026-01-01T00:00:00-03:00'
                        ) -and
                        $EndDate.EqualsExact(
                            [System.DateTimeOffset]'2026-12-31T23:59:59-03:00'
                        ) -and
                        $Summary[0].CFOP -eq '5102'
                    }
                }

                Should -Invoke @invokeParamsThree

                $invokeParamsFour = @{
                    CommandName     = 'Export-DFeCfopReportXlsx'
                    Exactly         = $true
                    Times           = 1
                    Scope           = 'It'
                    ModuleName      = 'PipeDFe'
                    ParameterFilter = {
                        $Cnpj -eq '11222333000181' -and
                        $StartDate.EqualsExact(
                            [System.DateTimeOffset]'2026-01-01T00:00:00-03:00'
                        ) -and
                        $EndDate.EqualsExact(
                            [System.DateTimeOffset]'2026-12-31T23:59:59-03:00'
                        ) -and
                        $ReportData.ResumoPorCFOP[0].CFOP -eq '5102' -and
                        $DocumentEntries[0].Id -eq 'nfe' -and
                        $NFSeEntries[0].Id -eq 'nfse' -and
                        $Gaps[0].Id -eq 'gap'
                    }
                }

                Should -Invoke @invokeParamsFour
            }

            It 'Uses the legal name when the trade name is blank' {
                $Script:ItParams.Company.NomeFantasia = ' '

                New-DFePeriodReport @Script:ItParams | Out-Null

                $invokeParams = @{
                    CommandName     = 'ConvertTo-DFeCfopReportHtml'
                    Exactly         = $true
                    Times           = 1
                    Scope           = 'It'
                    ModuleName      = 'PipeDFe'
                    ParameterFilter = {
                        $CompanyName -eq 'Example Ltda'
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Publishes repeated calls to distinct directories without replacing files' {
                $first  = @(New-DFePeriodReport @Script:ItParams)
                $second = @(New-DFePeriodReport @Script:ItParams)

                (Split-Path -Parent $first[0]) |
                    Should -Not -Be (Split-Path -Parent $second[0])

                @(Get-ChildItem -LiteralPath $Script:ReportRoot -Force) |
                    Should -HaveCount 2

                foreach ($path in ($first + $second)) {
                    [System.IO.File]::Exists($path) | Should -BeTrue
                }
            }
        }
        #endregion

        #region Failures before staging
        Context 'Failures before staging' {

            Context 'Invalid output path' {

                BeforeAll {

                    $joinParams = @{
                        Path      = $Script:BaseOutputPath
                        ChildPath = 'not-a-directory.txt'
                    }

                    $filePath = Join-Path @joinParams

                    [System.IO.File]::WriteAllText($filePath, 'Example')

                    $Script:InvalidParams = $Script:ReportParams.Clone()
                    $Script:InvalidParams.Company = $Script:ReportParams.Company.PSObject.Copy()
                    $Script:InvalidParams.Company.OutputPath = $filePath

                    $invalidRootJoinParams = @{
                        Path      = $filePath
                        ChildPath = 'Relatorios'
                    }

                    $Script:InvalidReportRoot = Join-Path @invalidRootJoinParams

                    $Script:InvalidPathThrown = $null

                    try {
                        New-DFePeriodReport @Script:InvalidParams -ErrorAction Stop
                    } catch {
                        $Script:InvalidPathThrown = $_
                    }
                }

                It 'Throws when the output path resolves to a file' {
                    $Script:InvalidPathThrown | Should -Not -BeNullOrEmpty
                }

                It 'Exception message describes an existing filesystem directory' {
                    $Script:InvalidPathThrown.Exception.Message |
                        Should -BeLike '*existing filesystem directory*'
                }

                It 'Does not create the Relatorios directory on invalid path' {
                    Test-Path -LiteralPath $Script:InvalidReportRoot | Should -BeFalse
                }

                It 'Does not call Get-DFeNFeCfopReportData on invalid path' {
                    $invokeParams = @{
                        CommandName = 'Get-DFeNFeCfopReportData'
                        Exactly     = $true
                        Times       = 0
                        Scope       = 'Context'
                        ModuleName  = 'PipeDFe'
                    }

                    Should -Invoke @invokeParams
                }
            }

            Context 'Empty HTML' {

                BeforeAll {

                    $emptyHtmlJoinParams = @{
                        Path      = $TestDrive
                        ChildPath = [guid]::NewGuid().ToString('N')
                    }

                    $emptyHtmlOutputPath = Join-Path @emptyHtmlJoinParams

                    [void][System.IO.Directory]::CreateDirectory($emptyHtmlOutputPath)

                    $Script:EmptyHtmlParams = $Script:ReportParams.Clone()
                    $Script:EmptyHtmlParams.Company = $Script:ReportParams.Company.PSObject.Copy()
                    $Script:EmptyHtmlParams.Company.OutputPath = $emptyHtmlOutputPath

                    $emptyHtmlRootJoinParams = @{
                        Path      = $emptyHtmlOutputPath
                        ChildPath = 'Relatorios'
                    }

                    $Script:EmptyHtmlReportRoot = Join-Path @emptyHtmlRootJoinParams

                    Mock -CommandName ConvertTo-DFeCfopReportHtml -MockWith {
                        ''
                    }

                    $Script:EmptyHtmlThrown = $null

                    try {
                        New-DFePeriodReport @Script:EmptyHtmlParams -ErrorAction Stop
                    } catch {
                        $Script:EmptyHtmlThrown = $_
                    }
                }

                It 'Throws when the HTML renderer returns empty' {
                    $Script:EmptyHtmlThrown | Should -Not -BeNullOrEmpty
                }

                It 'Exception message names the HTML renderer' {
                    $Script:EmptyHtmlThrown.Exception.Message |
                        Should -BeLike '*HTML renderer did not produce a non-empty report*'
                }

                It 'Does not create the Relatorios directory on empty HTML' {
                    Test-Path -LiteralPath $Script:EmptyHtmlReportRoot | Should -BeFalse
                }

                It 'Does not call Export-DFeCfopReportXlsx when HTML is empty' {
                    $invokeParams = @{
                        CommandName = 'Export-DFeCfopReportXlsx'
                        Exactly     = $true
                        Times       = 0
                        Scope       = 'Context'
                        ModuleName  = 'PipeDFe'
                    }

                    Should -Invoke @invokeParams
                }
            }
        }
        #endregion

        #region Workbook export failures
        Context 'Workbook export failures' {

            Context 'Export throws after writing HTML' {

                BeforeAll {

                    $wbJoinParams = @{
                        Path      = $TestDrive
                        ChildPath = [guid]::NewGuid().ToString('N')
                    }

                    $wbExportPath = Join-Path @wbJoinParams

                    [void][System.IO.Directory]::CreateDirectory($wbExportPath)

                    $Script:WbExportParams = $Script:ReportParams.Clone()
                    $Script:WbExportParams.Company = $Script:ReportParams.Company.PSObject.Copy()
                    $Script:WbExportParams.Company.OutputPath = $wbExportPath

                    $wbRootJoinParams = @{
                        Path      = $wbExportPath
                        ChildPath = 'Relatorios'
                    }

                    $Script:WbReportRoot = Join-Path @wbRootJoinParams

                    $Script:Previous = @(New-DFePeriodReport @Script:WbExportParams)

                    Mock -CommandName Export-DFeCfopReportXlsx -MockWith {
                        $stagingDirectory = Split-Path -Parent $LiteralPath

                        $joinParams = @{
                            Path      = $stagingDirectory
                            ChildPath = 'Resumo-CFOP.html'
                        }

                        $stagedHtml = Join-Path @joinParams

                        if ([System.IO.File]::ReadAllText($stagedHtml) -ne
                            '<html>CFOP report</html>'
                        ) {
                            throw (
                                'Expected the rendered HTML to be staged ' +
                                'before workbook export.'
                            )
                        }

                        [System.IO.File]::WriteAllBytes($LiteralPath, [byte[]]@(2))

                        throw 'Simulated workbook export failure.'
                    }

                    $Script:ExportFailThrown = $null

                    try {
                        New-DFePeriodReport @Script:WbExportParams -ErrorAction Stop
                    } catch {
                        $Script:ExportFailThrown = $_
                    }
                }

                It 'Throws when the exporter fails' {
                    $Script:ExportFailThrown | Should -Not -BeNullOrEmpty
                }

                It 'Exception message propagates the exporter error' {
                    $Script:ExportFailThrown.Exception.Message |
                        Should -BeLike '*Simulated workbook export failure*'
                }

                It 'Removes the failed staging directory' {
                    $remaining = @(Get-ChildItem -LiteralPath $Script:WbReportRoot -Force)

                    $remaining | Should -HaveCount 1
                }

                It 'Preserves the previous publication after the failed export' {
                    $remaining = @(Get-ChildItem -LiteralPath $Script:WbReportRoot -Force)

                    $remaining[0].FullName |
                        Should -Be (Split-Path -Parent $Script:Previous[0])
                }

                It 'Previous HTML file is intact after the failed export' {
                    [System.IO.File]::ReadAllText($Script:Previous[0]) |
                        Should -BeExactly '<html>CFOP report</html>'
                }

                It 'Previous XLSX file is intact after the failed export' {
                    [System.IO.File]::ReadAllBytes($Script:Previous[1])[0] |
                        Should -Be 1
                }
            }

            Context 'Exporter returns without creating a workbook' {

                BeforeAll {

                    $noWbJoinParams = @{
                        Path      = $TestDrive
                        ChildPath = [guid]::NewGuid().ToString('N')
                    }

                    $noWbOutputPath = Join-Path @noWbJoinParams

                    [void][System.IO.Directory]::CreateDirectory($noWbOutputPath)

                    $Script:NoWbParams = $Script:ReportParams.Clone()
                    $Script:NoWbParams.Company = $Script:ReportParams.Company.PSObject.Copy()
                    $Script:NoWbParams.Company.OutputPath = $noWbOutputPath

                    $noWbRootJoinParams = @{
                        Path      = $noWbOutputPath
                        ChildPath = 'Relatorios'
                    }

                    $Script:NoWbReportRoot = Join-Path @noWbRootJoinParams

                    Mock -CommandName Export-DFeCfopReportXlsx -MockWith { }

                    $Script:NoWorkbookThrown = $null

                    try {
                        New-DFePeriodReport @Script:NoWbParams -ErrorAction Stop
                    } catch {
                        $Script:NoWorkbookThrown = $_
                    }
                }

                It 'Throws when no workbook is created' {
                    $Script:NoWorkbookThrown | Should -Not -BeNullOrEmpty
                }

                It 'Exception message names the missing workbook' {
                    $Script:NoWorkbookThrown.Exception.Message |
                        Should -BeLike '*did not create a non-empty workbook*'
                }

                It 'Does not publish when the exporter creates no workbook' {
                    @(Get-ChildItem -LiteralPath $Script:NoWbReportRoot -Force) |
                        Should -HaveCount 0
                }
            }

            Context 'Exporter creates an empty workbook' {

                BeforeAll {

                    $emptyWbJoinParams = @{
                        Path      = $TestDrive
                        ChildPath = [guid]::NewGuid().ToString('N')
                    }

                    $emptyWbOutputPath = Join-Path @emptyWbJoinParams

                    [void][System.IO.Directory]::CreateDirectory($emptyWbOutputPath)

                    $Script:EmptyWbParams = $Script:ReportParams.Clone()
                    $Script:EmptyWbParams.Company = $Script:ReportParams.Company.PSObject.Copy()
                    $Script:EmptyWbParams.Company.OutputPath = $emptyWbOutputPath

                    $emptyWbRootJoinParams = @{
                        Path      = $emptyWbOutputPath
                        ChildPath = 'Relatorios'
                    }

                    $Script:EmptyWbReportRoot = Join-Path @emptyWbRootJoinParams

                    Mock -CommandName Export-DFeCfopReportXlsx -MockWith {
                        [System.IO.File]::WriteAllBytes($LiteralPath, [byte[]]@())
                    }

                    $Script:EmptyWorkbookThrown = $null

                    try {
                        New-DFePeriodReport @Script:EmptyWbParams -ErrorAction Stop
                    } catch {
                        $Script:EmptyWorkbookThrown = $_
                    }
                }

                It 'Throws when the workbook is empty' {
                    $Script:EmptyWorkbookThrown | Should -Not -BeNullOrEmpty
                }

                It 'Exception message names the empty workbook' {
                    $Script:EmptyWorkbookThrown.Exception.Message |
                        Should -BeLike '*did not create a non-empty workbook*'
                }

                It 'Does not publish when the workbook is empty' {
                    @(Get-ChildItem -LiteralPath $Script:EmptyWbReportRoot -Force) |
                        Should -HaveCount 0
                }
            }
        }
        #endregion
    }
}
