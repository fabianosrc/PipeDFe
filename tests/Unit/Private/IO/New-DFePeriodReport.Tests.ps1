#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for publishing the analytical HTML report.

.DESCRIPTION
Covers filtered models, empty periods, unique publication paths,
company display name, and failure before publication.

Coverage includes:
  - Filtered model selection passes only NF-e and NFC-e entries to the data reader.
  - Each publication produces a unique path; prior publications remain intact.
  - Company RazaoSocial is forwarded to the HTML renderer.
  - No archive or report root is created when no supported model is selected.
  - Staging directory is cleaned up when the HTML renderer returns empty content.
#>

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

            $testID = [guid]::NewGuid().ToString('N')

            $path   = Join-Path -Path $TestDrive -ChildPath $testID

            [void][System.IO.Directory]::CreateDirectory($path)

            $Script:ReportParams = @{
                Company   = [PSCustomObject]@{
                    Cnpj         = '12345678000199'
                    NomeFantasia = 'Nome Fantasia'
                    RazaoSocial  = 'Empresa Teste'
                    OutputPath   = $path
                }
                DateRange = [PSCustomObject]@{
                    Start = [System.DateTimeOffset]'2026-11-01T00:00:00-03:00'
                    End   = [System.DateTimeOffset]'2026-11-30T23:59:59-03:00'
                }
                Entries   = @(
                    [PSCustomObject]@{
                        modelo = 55
                    },
                    [PSCustomObject]@{
                        modelo = 62
                    }
                )
            }

            Mock -CommandName Get-DFeAnalyticalReportData -MockWith {
                [PSCustomObject]@{
                    Modelo = 55
                }
            }

            Mock -CommandName ConvertTo-DFeCfopReportHtml -MockWith {
                '<html>Relatório</html>'
            }
        }

        It 'Publishes one HTML and leaves the previous publication intact' {
            $first  = @(New-DFePeriodReport @Script:ReportParams)
            $second = @(New-DFePeriodReport @Script:ReportParams)

            $first    | Should -HaveCount 1
            $second   | Should -HaveCount 1
            $first[0] | Should -Not -Be $second[0]

            [System.IO.Path]::GetFileName($first[0]) |
                Should -BeExactly 'RelatorioAnalitico.html'

            [System.IO.File]::ReadAllText($first[0]) |
                Should -BeExactly '<html>Relatório</html>'

            @(Get-ChildItem -LiteralPath (Split-Path -Parent $first[0])) |
                Should -HaveCount 1

            $filterAssertion = @{
                CommandName     = 'Get-DFeAnalyticalReportData'
                Times           = 2
                Exactly         = $true
                Scope           = 'It'
                ParameterFilter = {
                    $Entries.Count -eq 1 -and $Entries[0].modelo -eq 55
                }
            }

            Should -Invoke @filterAssertion

            $htmlAssertion = @{
                CommandName     = 'ConvertTo-DFeCfopReportHtml'
                Times           = 2
                Exactly         = $true
                Scope           = 'It'
                ParameterFilter = { $CompanyName -eq 'Empresa Teste' }
            }

            Should -Invoke @htmlAssertion
        }

        It 'Skips publication when neither NF-e nor NFC-e is selected' {
            $Script:ReportParams.Entries = @(
                [PSCustomObject]@{
                    modelo = 62
                }
            )

            @(New-DFePeriodReport @Script:ReportParams).Count | Should -Be 0

            $reportRoot = Join-Path -Path $path -ChildPath 'Relatorios'

            Test-Path -LiteralPath $reportRoot | Should -BeFalse

            Should -Invoke Get-DFeAnalyticalReportData -Times 0 -Exactly -Scope It
        }

        It 'Does not publish when rendering returns empty HTML' {
            Mock -CommandName ConvertTo-DFeCfopReportHtml -MockWith {
                ''
            }

            { New-DFePeriodReport @Script:ReportParams } |
                Should -Throw -ExpectedMessage '*non-empty report*'

            $reportRoot = Join-Path -Path $path -ChildPath 'Relatorios'

            Test-Path -LiteralPath $reportRoot | Should -BeFalse
        }
    }
}
