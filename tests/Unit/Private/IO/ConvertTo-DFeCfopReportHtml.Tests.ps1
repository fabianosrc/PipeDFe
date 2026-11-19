#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertTo-DFeCfopReportHtml.

.DESCRIPTION
Renders standalone HTML from precomputed CFOP summary rows.

Coverage includes:
  - Standalone document metadata and company identification.
  - Calendar dates displayed using the supplied offsets.
  - Separate NF-e and NFC-e rows and preservation of input order.
  - Brazilian Portuguese formatting of counts and subtotals.
  - Missing CFOP and missing product values.
  - HTML encoding of company names and CFOP values.
  - Empty summaries and rejection of unsupported models and reversed periods.
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

Describe 'ConvertTo-DFeCfopReportHtml' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeEach {
            $Script:ReportHtmlParams = @{
                CompanyName = 'Empresa Exemplo'
                Cnpj        = '12345678000199'
                StartDate   = [System.DateTimeOffset]'2026-11-01T00:00:00-03:00'
                EndDate     = [System.DateTimeOffset]'2026-11-30T23:59:59-03:00'
                Summary     = @(
                    [PSCustomObject]@{
                        Modelo        = 55
                        CFOP          = '5102'
                        Quantidade    = 1234
                        ItensSemValor = 0
                        ValorProdutos = 1234.50d
                    }
                    [PSCustomObject]@{
                        Modelo        = 55
                        CFOP          = '5405'
                        Quantidade    = 2
                        ItensSemValor = 0
                        ValorProdutos = 55.25d
                    }
                    [PSCustomObject]@{
                        Modelo        = 65
                        CFOP          = '5102'
                        Quantidade    = 1
                        ItensSemValor = 0
                        ValorProdutos = 9.10d
                    }
                )
            }
        }

        It 'Returns a complete HTML document with the company and local period' {
            $html = ConvertTo-DFeCfopReportHtml @Script:ReportHtmlParams

            $html | Should -BeOfType ([string])
            $html | Should -Match '(?s)^<!doctype html>.*</html>\s*$'
            $html | Should -Match '<html lang="pt-BR">'
            $html | Should -Match '<meta charset="utf-8">'
            $html | Should -Match 'Empresa Exemplo'
            $html | Should -Match '12\.345\.678/0001-99'
            $html | Should -Match '01/11/2026 a 30/11/2026'
            $html | Should -Not -Match '\{\{'
        }

        It 'Displays the supplied subtotals in separate rows without changing order' {
            $html = ConvertTo-DFeCfopReportHtml @Script:ReportHtmlParams

            $body = [regex]::Match($html, '(?s)<tbody>(.*?)</tbody>').Groups[1].Value
            $rows = [regex]::Matches($body, '(?s)<tr>(.*?)</tr>')

            $rows | Should -HaveCount 3

            $rows[0].Value | Should -Match (
                '<td>NF-e</td>\s*<td>5102</td>\s*' +
                '<td class="number">1\.234</td>\s*' +
                '<td class="number">0</td>\s*<td class="number">1\.234,50</td>'
            )

            $rows[1].Value | Should -Match (
                '<td>NF-e</td>\s*<td>5405</td>\s*' +
                '<td class="number">2</td>\s*' +
                '<td class="number">0</td>\s*<td class="number">55,25</td>'
            )

            $rows[2].Value | Should -Match (
                '<td>NFC-e</td>\s*<td>5102</td>\s*' +
                '<td class="number">1</td>\s*' +
                '<td class="number">0</td>\s*<td class="number">9,10</td>'
            )
        }

        It 'Shows missing CFOP and product values without hiding the item count' {
            $reportParams = @{
                CompanyName = $Script:ReportHtmlParams.CompanyName
                Cnpj        = $Script:ReportHtmlParams.Cnpj
                StartDate   = $Script:ReportHtmlParams.StartDate
                EndDate     = $Script:ReportHtmlParams.EndDate
                Summary     = @(
                    [PSCustomObject]@{
                        Modelo        = 55
                        CFOP          = $null
                        Quantidade    = 2
                        ItensSemValor = 2
                        ValorProdutos = 0d
                    }
                )
            }

            $html = ConvertTo-DFeCfopReportHtml @reportParams

            $html | Should -Match (
                '<td>NF-e</td>\s*<td>Não informado</td>\s*' +
                '<td class="number">2</td>\s*' +
                '<td class="number">2</td>\s*<td class="number">0,00</td>'
            )
        }

        It 'Encodes company and CFOP text instead of treating it as markup' {
            $reportParams = @{
                CompanyName = 'Empresa <b>A & B</b>'
                Cnpj        = $Script:ReportHtmlParams.Cnpj
                StartDate   = $Script:ReportHtmlParams.StartDate
                EndDate     = $Script:ReportHtmlParams.EndDate
                Summary     = @(
                    [PSCustomObject]@{
                        Modelo        = 55
                        CFOP          = '<b>5102</b>'
                        Quantidade    = 1
                        ItensSemValor = 0
                        ValorProdutos = 10d
                    }
                )
            }

            $html = ConvertTo-DFeCfopReportHtml @reportParams

            $html | Should -Match 'Empresa &lt;b&gt;A &amp; B&lt;/b&gt;'
            $html | Should -Match '<td>&lt;b&gt;5102&lt;/b&gt;</td>'
            $html | Should -Not -Match '<b>'
        }

        It 'Renders an explicit empty state instead of a zero-valued fiscal row' {
            $reportParams = @{
                CompanyName = $Script:ReportHtmlParams.CompanyName
                Cnpj        = $Script:ReportHtmlParams.Cnpj
                StartDate   = $Script:ReportHtmlParams.StartDate
                EndDate     = $Script:ReportHtmlParams.EndDate
                Summary     = @()
            }

            $html = ConvertTo-DFeCfopReportHtml @reportParams

            $html | Should -Match 'colspan="5">Nenhum item de NF-e ou NFC-e no período\.'
            $html | Should -Not -Match '<td>NF-e</td>|<td>NFC-e</td>|<td class="number">'
        }

        It 'Rejects reversed period bounds' {
            $reportParams = @{
                CompanyName = $Script:ReportHtmlParams.CompanyName
                Cnpj        = $Script:ReportHtmlParams.Cnpj
                StartDate   = $Script:ReportHtmlParams.StartDate
                EndDate     = $Script:ReportHtmlParams.StartDate.AddTicks(-1)
                Summary     = $Script:ReportHtmlParams.Summary
            }

            { ConvertTo-DFeCfopReportHtml @reportParams } |
                Should -Throw -ErrorId 'InvalidDateRange*'
        }

        It 'Rejects a model outside the NF-e and NFC-e summary contract' {
            $reportParams = @{
                CompanyName = $Script:ReportHtmlParams.CompanyName
                Cnpj        = $Script:ReportHtmlParams.Cnpj
                StartDate   = $Script:ReportHtmlParams.StartDate
                EndDate     = $Script:ReportHtmlParams.EndDate
                Summary     = @(
                    [PSCustomObject]@{
                        Modelo        = 62
                        CFOP          = '5102'
                        Quantidade    = 1
                        ItensSemValor = 0
                        ValorProdutos = 10d
                    }
                )
            }

            { ConvertTo-DFeCfopReportHtml @reportParams } |
                Should -Throw -ErrorId 'UnsupportedCfopSummaryModel*'
        }
    }
}
