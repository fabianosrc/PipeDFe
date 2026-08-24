#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Build-MailBody.

.DESCRIPTION
Covers template loading, placeholder replacement, conditional block
rendering (Logotipo, NotasNaoLancadas, ReplyTo) and error on missing
template.

A real HTML template file is written to a temp directory and
$Script:ModuleRoot is redirected to it for isolation.

Coverage includes:
  - Returns a non-empty string for a valid context.
  - Throws MailTemplateNotFound when template is missing.
  - Uses ObjectNotFound category for missing template.
  - Replaces NomeEmpresa with NomeFantasia when present.
  - Replaces NomeEmpresa with RazaoSocial when NomeFantasia is blank.
  - Replaces CnpjFormatado with formatted CNPJ.
  - Replaces PeriodoDisplay and DataEmissao.
  - Renders InscricaoEstadual when Ie is present.
  - Renders empty InscricaoEstadual when Ie is null.
  - Includes logo block when Logotipo is present.
  - Removes logo block when Logotipo property is absent or blank.
  - Includes gaps block when NotasNaoLancadas has entries.
  - Removes gaps block when NotasNaoLancadas is empty.
  - Renders zebra striping for odd-index rows.
  - Does not apply zebra striping to the first row.
  - Removes ArquivosManuais block.
  - Includes reply block when ReplyTo is present.
  - Removes reply block when ReplyTo is null or whitespace.
  - Leaves no unreplaced {{...}} tokens in the output.
#>

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Build-MailBody' {

        InModuleScope PipeDFe {

        BeforeAll {

            $Script:OriginalModuleRoot = $Script:ModuleRoot

            $Script:TestID = [guid]::NewGuid().ToString('N')

            $joinPathParams = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = 'PipeDFe.BuildMailBody-{0}' -f $Script:TestID
            }

            $Script:TempRoot    = Join-Path @joinPathParams
            $Script:TemplateDir = Join-Path -Path $Script:TempRoot -ChildPath 'templates\mail'

            $newItemParams = @{
                Path     = $Script:TemplateDir
                ItemType = 'Directory'
                Force    = $true
            }

            New-Item @newItemParams | Out-Null

            $Script:TemplatePath = Join-Path -Path $Script:TemplateDir -ChildPath 'dfe-notification.html'

            $templateContent = @'
<html>
    <body>
        {{NomeEmpresa}}|{{RazaoSocial}}|{{CnpjFormatado}}|{{PeriodoDisplay}}|{{PeriodoTitulo}}|{{DataEmissao}}|{{InscricaoEstadual}}
        {{#TemLogotipo}}
            <logo>{{Logotipo}}|{{NomeFantasia}}</logo>
        {{/TemLogotipo}}
        {{#TemNotasNaoLancadas}}
            <gaps>{{NotasNaoLancadas}}</gaps>
        {{/TemNotasNaoLancadas}}
        {{#TemReplyTo}}
            <reply>{{ReplyTo}}</reply>
        {{/TemReplyTo}}
    </body>
</html>
'@

            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($Script:TemplatePath, $templateContent, $utf8NoBom)

            $Script:ModuleRoot = $Script:TempRoot

            function New-BaseContext {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param ()

                [PSCustomObject]@{
                    Empresa          = [PSCustomObject]@{
                        NomeFantasia = 'Empresa Teste'
                        RazaoSocial  = 'Empresa Teste Ltda'
                        Cnpj         = '11222333000181'
                        Ie           = $null
                    }
                    PeriodoDisplay   = 'Janeiro/2026'
                    DataEmissao      = '01/01/2026 10:00'
                    ReplyTo          = $null
                    NotasNaoLancadas = @()
                }
            }
        }

        AfterAll {

            $Script:ModuleRoot = $Script:OriginalModuleRoot

            $removeParams = @{
                LiteralPath = $Script:TempRoot
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeParams
        }

        #region Template loading
        Context 'Template loading' {

            It 'Returns a non-empty string for a valid context' {
                $result = Build-MailBody -Context (New-BaseContext)
                $result | Should -Not -BeNullOrEmpty
            }

            It 'Throws MailTemplateNotFound when template is missing' {
                $Script:ModuleRoot = 'C:\nonexistent-path-xyz'

                $thrown = $null

                try {
                    Build-MailBody -Context (New-BaseContext) -ErrorAction Stop
                } catch {
                    $thrown = $_
                } finally {
                    $Script:ModuleRoot = $Script:TempRoot
                }

                $thrown | Should -Not -BeNullOrEmpty
                $thrown.FullyQualifiedErrorId | Should -BeLike 'MailTemplateNotFound*'
            }

            It 'Uses ObjectNotFound category for missing template' {
                $Script:ModuleRoot = 'C:\nonexistent-path-xyz'

                $thrown = $null

                try {
                    Build-MailBody -Context (New-BaseContext) -ErrorAction Stop
                } catch {
                    $thrown = $_
                } finally {
                    $Script:ModuleRoot = $Script:TempRoot
                }

                $thrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::ObjectNotFound)
            }
        }
        #endregion

        #region Base placeholder replacement
        Context 'Base placeholder replacement' {

            It 'Replaces NomeEmpresa with NomeFantasia when present' {
                $result = Build-MailBody -Context (New-BaseContext)
                $result | Should -Match 'Empresa Teste'
            }

            It 'Replaces NomeEmpresa with RazaoSocial when NomeFantasia is blank' {
                $ctx = New-BaseContext
                $ctx.Empresa.NomeFantasia = ''

                $result = Build-MailBody -Context $ctx
                $result | Should -Match 'Empresa Teste Ltda'
            }

            It 'Replaces CnpjFormatado with the formatted CNPJ' {
                $result = Build-MailBody -Context (New-BaseContext)
                $result | Should -Match '11\.222\.333/0001-81'
            }

            It 'Replaces PeriodoDisplay' {
                $result = Build-MailBody -Context (New-BaseContext)
                $result | Should -Match 'Janeiro/2026'
            }

            It 'Replaces DataEmissao' {
                $result = Build-MailBody -Context (New-BaseContext)
                $result | Should -Match '01/01/2026 10:00'
            }

            It 'Renders InscricaoEstadual when Ie is present' {
                $ctx = New-BaseContext
                $ctx.Empresa.Ie = '123456789'

                $result = Build-MailBody -Context $ctx
                $result | Should -Match '123456789'
            }

            It 'Renders empty InscricaoEstadual when Ie is null' {
                $result = Build-MailBody -Context (New-BaseContext)
                $result | Should -Not -Match '{{InscricaoEstadual}}'
            }
        }
        #endregion

        #region Logotipo conditional block
        Context 'Logotipo conditional block' {

            It 'Includes the logo block when Logotipo is present' {
                $ctx = New-BaseContext

                $addMemberParams = @{
                    MemberType = 'NoteProperty'
                    Name       = 'Logotipo'
                    Value      = 'data:image/png;base64,abc'
                }

                $ctx.Empresa | Add-Member @addMemberParams

                $result = Build-MailBody -Context $ctx
                $result | Should -Match '<logo>'
            }

            It 'Removes the logo block when Logotipo property is absent' {
                $result = Build-MailBody -Context (New-BaseContext)
                $result | Should -Not -Match '<logo>'
            }

            It 'Removes the logo block when Logotipo is blank' {
                $ctx = New-BaseContext

                $addMemberParams = @{
                    MemberType = 'NoteProperty'
                    Name       = 'Logotipo'
                    Value      = ''
                }

                $ctx.Empresa | Add-Member @addMemberParams

                $result = Build-MailBody -Context $ctx
                $result | Should -Not -Match '<logo>'
            }
        }
        #endregion

        #region NotasNaoLancadas conditional block
        Context 'NotasNaoLancadas conditional block' {

            It 'Includes the gaps block when NotasNaoLancadas has entries' {
                $ctx = New-BaseContext
                $ctx.NotasNaoLancadas = @(
                    [PSCustomObject]@{
                        Inicial = 1
                        Final   = 5
                        Serie   = '001'
                        Especie = 'NF-e'
                    }
                )

                $result = Build-MailBody -Context $ctx
                $result | Should -Match '<gaps>'
            }

            It 'Removes the gaps block when NotasNaoLancadas is empty' {
                $result = Build-MailBody -Context (New-BaseContext)
                $result | Should -Not -Match '<gaps>'
            }

            It 'Renders zebra striping for odd-index rows' {
                $ctx = New-BaseContext
                $ctx.NotasNaoLancadas = @(
                    [PSCustomObject]@{
                        Inicial = 1
                        Final   = 2
                        Serie   = '001'
                        Especie = 'NF-e'
                    }
                    [PSCustomObject]@{
                        Inicial = 8
                        Final   = 9
                        Serie   = '001'
                        Especie = 'NF-e'
                    }
                )

                $result = Build-MailBody -Context $ctx
                $result | Should -Match 'background-color:#f9f9f9;'
            }

            It 'Does not apply zebra striping to the first row' {
                $ctx = New-BaseContext
                $ctx.NotasNaoLancadas = @(
                    [PSCustomObject]@{
                        Inicial = 1
                        Final   = 2
                        Serie   = '001'
                        Especie = 'NF-e'
                    }
                )

                $result = Build-MailBody -Context $ctx
                $result | Should -Not -Match 'background-color:#f9f9f9;'
            }
        }
        #endregion

        #region ArquivosManuais block
        Context 'ArquivosManuais block' {

            It 'Removes the ArquivosManuais block entirely' {
                $result = Build-MailBody -Context (New-BaseContext)
                $result | Should -Not -Match '<manuais>'
                $result | Should -Not -Match '{{#TemArquivosManuais}}'
            }
        }
        #endregion

        #region ReplyTo conditional block
        Context 'ReplyTo conditional block' {

            It 'Includes the reply block when ReplyTo is present' {
                $ctx = New-BaseContext
                $ctx.ReplyTo = 'reply@example.com'

                $result = Build-MailBody -Context $ctx
                $result | Should -Match '<reply>reply@example.com</reply>'
            }

            It 'Removes the reply block when ReplyTo is null' {
                $result = Build-MailBody -Context (New-BaseContext)
                $result | Should -Not -Match '<reply>'
            }

            It 'Removes the reply block when ReplyTo is whitespace' {
                $ctx = New-BaseContext
                $ctx.ReplyTo = '   '

                $result = Build-MailBody -Context $ctx
                $result | Should -Not -Match '<reply>'
            }
        }
        #endregion

        #region No leftover placeholders
        Context 'No leftover placeholders' {

            It 'Leaves no unreplaced tokens when all blocks are included' {
                $ctx = New-BaseContext
                $ctx.Empresa.Ie  = '123456789'
                $ctx.ReplyTo     = 'reply@example.com'
                $ctx.NotasNaoLancadas = @(
                    [PSCustomObject]@{
                        Inicial = 1
                        Final   = 3
                        Serie   = '001'
                        Especie = 'NF-e'
                    }
                )

                $addMemberParams = @{
                    MemberType = 'NoteProperty'
                    Name       = 'Logotipo'
                    Value      = 'data:image/png;base64,abc'
                }

                $ctx.Empresa | Add-Member @addMemberParams

                $result = Build-MailBody -Context $ctx
                $result | Should -Not -Match '\{\{[^}]+\}\}'
            }

            It 'Leaves no unreplaced tokens when all blocks are excluded' {
                $result = Build-MailBody -Context (New-BaseContext)
                $result | Should -Not -Match '\{\{[^}]+\}\}'
            }
        }
        #endregion
    }
}
