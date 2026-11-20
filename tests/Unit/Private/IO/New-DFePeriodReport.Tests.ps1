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

        BeforeEach {

            $joinParamsOne = @{
                Path      = $TestDrive
                ChildPath = [guid]::NewGuid().ToString('N')
            }

            $outputPath = Join-Path @joinParamsOne

            [void][System.IO.Directory]::CreateDirectory($outputPath)

            $joinParamsTwo = @{
                Path      = $outputPath
                ChildPath = 'Relatorios'
            }

            $Script:ReportRoot = Join-Path @joinParamsTwo

            $Script:ReportParams = @{
                Company = [PSCustomObject]@{
                    Cnpj         = '11222333000181'
                    NomeFantasia = 'Example'
                    RazaoSocial  = 'Example Ltda'
                    OutputPath   = $outputPath
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

            It 'Publishes the pair and returns only the HTML and XLSX paths in order' {
                $paths = @(New-DFePeriodReport @Script:ReportParams)

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
                New-DFePeriodReport @Script:ReportParams | Out-Null

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
                        $StartDate.EqualsExact([System.DateTimeOffset]'2026-01-01T00:00:00-03:00') -and
                        $EndDate.EqualsExact([System.DateTimeOffset]'2026-12-31T23:59:59-03:00')
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
                        $StartDate.EqualsExact([System.DateTimeOffset]'2026-01-01T00:00:00-03:00') -and
                        $EndDate.EqualsExact([System.DateTimeOffset]'2026-12-31T23:59:59-03:00') -and
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
                        $StartDate.EqualsExact([System.DateTimeOffset]'2026-01-01T00:00:00-03:00') -and
                        $EndDate.EqualsExact([System.DateTimeOffset]'2026-12-31T23:59:59-03:00') -and
                        $ReportData.ResumoPorCFOP[0].CFOP -eq '5102' -and
                        $DocumentEntries[0].Id -eq 'nfe' -and
                        $NFSeEntries[0].Id -eq 'nfse' -and
                        $Gaps[0].Id -eq 'gap'
                    }
                }

                Should -Invoke @invokeParamsFour
            }

            It 'Uses the legal name when the trade name is blank' {
                $Script:ReportParams.Company.NomeFantasia = ' '

                New-DFePeriodReport @Script:ReportParams | Out-Null

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
                $first  = @(New-DFePeriodReport @Script:ReportParams)
                $second = @(New-DFePeriodReport @Script:ReportParams)

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

            It 'Rejects an output path that resolves to a file before querying CFOP data' {
                $joinParams = @{
                    Path      = $Script:ReportParams.Company.OutputPath
                    ChildPath = 'not-a-directory.txt'
                }

                $filePath = Join-Path @joinParams

                [System.IO.File]::WriteAllText($filePath, 'Example')

                $Script:ReportParams.Company.OutputPath = $filePath

                $thrown = $null

                try {
                    New-DFePeriodReport @Script:ReportParams -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown                   | Should -Not -BeNullOrEmpty
                $thrown.Exception.Message | Should -BeLike '*existing filesystem directory*'

                Test-Path -LiteralPath $Script:ReportRoot | Should -BeFalse

                $invokeParams = @{
                    CommandName = 'Get-DFeNFeCfopReportData'
                    Exactly     = $true
                    Times       = 0
                    Scope       = 'It'
                    ModuleName  = 'PipeDFe'
                }

                Should -Invoke @invokeParams
            }

            It 'Does not stage reports or call the exporter when the HTML is empty' {
                Mock -CommandName ConvertTo-DFeCfopReportHtml -MockWith {
                    ''
                }

                $thrown = $null

                try {
                    New-DFePeriodReport @Script:ReportParams -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown                   | Should -Not -BeNullOrEmpty
                $thrown.Exception.Message | Should -BeLike '*HTML renderer did not produce a non-empty report*'

                Test-Path -LiteralPath $Script:ReportRoot | Should -BeFalse

                $invokeParams = @{
                    CommandName = 'Export-DFeCfopReportXlsx'
                    Exactly     = $true
                    Times       = 0
                    Scope       = 'It'
                    ModuleName  = 'PipeDFe'
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Workbook export failures
        Context 'Workbook export failures' {

            It 'Removes staging and preserves the previous pair when export fails after writing' {
                $previous = @(New-DFePeriodReport @Script:ReportParams)

                Mock -CommandName Export-DFeCfopReportXlsx -MockWith {
                    $stagingDirectory = Split-Path -Parent $LiteralPath

                    $joinParams = @{
                        Path      = $stagingDirectory
                        ChildPath = 'Resumo-CFOP.html'
                    }

                    $stagedHtml = Join-Path @joinParams

                    if ([System.IO.File]::ReadAllText($stagedHtml) -ne '<html>CFOP report</html>') {
                        throw 'Expected the rendered HTML to be staged before workbook export.'
                    }

                    [System.IO.File]::WriteAllBytes($LiteralPath, [byte[]]@(2))

                    throw 'Simulated workbook export failure.'
                }

                $thrown = $null

                try {
                    New-DFePeriodReport @Script:ReportParams -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown                   | Should -Not -BeNullOrEmpty
                $thrown.Exception.Message | Should -BeLike '*Simulated workbook export failure*'

                $remaining = @(Get-ChildItem -LiteralPath $Script:ReportRoot -Force)

                $remaining             | Should -HaveCount 1
                $remaining[0].FullName | Should -Be (Split-Path -Parent $previous[0])

                [System.IO.File]::ReadAllText($previous[0]) |
                    Should -BeExactly '<html>CFOP report</html>'

                [System.IO.File]::ReadAllBytes($previous[1])[0] | Should -Be 1
            }

            It 'Does not publish if the exporter returns without creating a workbook' {
                Mock -CommandName Export-DFeCfopReportXlsx -MockWith {

                }

                $thrown = $null

                try {
                    New-DFePeriodReport @Script:ReportParams -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown                   | Should -Not -BeNullOrEmpty
                $thrown.Exception.Message | Should -BeLike '*did not create a non-empty workbook*'

                @(Get-ChildItem -LiteralPath $Script:ReportRoot -Force) |
                    Should -HaveCount 0
            }

            It 'Does not publish if the exporter creates an empty workbook' {
                Mock -CommandName Export-DFeCfopReportXlsx -MockWith {
                    [System.IO.File]::WriteAllBytes($LiteralPath, [byte[]]@())
                }

                $thrown = $null

                try {
                    New-DFePeriodReport @Script:ReportParams -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown                   | Should -Not -BeNullOrEmpty
                $thrown.Exception.Message | Should -BeLike '*did not create a non-empty workbook*'

                @(Get-ChildItem -LiteralPath $Script:ReportRoot -Force) |
                    Should -HaveCount 0
            }
        }
        #endregion
    }
}
