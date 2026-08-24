<#
.SYNOPSIS
Renders the HTML email body for a DFe notification.

.DESCRIPTION
Loads the HTML template from the module's templates directory and replaces
all placeholders with data from the provided context object.

Conditional blocks ({{#Block}}...{{/Block}}) are included when the
corresponding context property is present and non-empty, or removed
entirely when absent.

Throws MailTemplateNotFound when the HTML template file does not exist.

Placeholders deferred for future implementation (replaced with empty string):
  {{ResumoDocumentos}}
  {{#TemArquivosManuais}}...{{/TemArquivosManuais}}

.PARAMETER Context
A PSCustomObject with the following properties:

  Empresa          [pscustomobject]   - Company data: Cnpj, NomeFantasia,
                                        RazaoSocial, Ie, Logotipo (optional).
  PeriodoDisplay   [string]           - Human-readable period, e.g. 'Marco/2025'.
  DataEmissao      [string]           - Formatted emission date for display.
  ReplyTo          [string]           - Reply-to address. $null if absent.
  NotasNaoLancadas [pscustomobject[]] - Sequence gaps: Inicial, Final, Serie,
                                        Especie. Empty array is valid.

.OUTPUTS
System.String

.EXAMPLE
PS C:\> $html = Build-MailBody -Context $context

.NOTES
Private dependencies:
  ConvertTo-FormattedCnpj
#>
function Build-MailBody {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context
    )

    $templatePath = [System.IO.Path]::Combine(
        $Script:ModuleRoot, 'templates', 'mail', 'dfe-notification.html'
    )

    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.FileNotFoundException]::new(
                    "Mail template not found: '$templatePath'.",
                    $templatePath
                ),
                'MailTemplateNotFound',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $templatePath
            )
        )
    }

    $html    = [System.IO.File]::ReadAllText($templatePath, [System.Text.Encoding]::UTF8)
    $empresa = $Context.Empresa

    $nomeEmpresa = if (-not [string]::IsNullOrWhiteSpace($empresa.NomeFantasia)) {
        $empresa.NomeFantasia
    } else {
        $empresa.RazaoSocial
    }

    $ieValue = if (-not [string]::IsNullOrWhiteSpace($empresa.Ie)) {
        $empresa.Ie
    } else {
        [string]::Empty
    }

    $html = $html.Replace('{{NomeEmpresa}}',       $nomeEmpresa)
    $html = $html.Replace('{{NomeFantasia}}',      $nomeEmpresa)
    $html = $html.Replace('{{RazaoSocial}}',       $empresa.RazaoSocial)
    $html = $html.Replace('{{CnpjFormatado}}',     (ConvertTo-FormattedCnpj -Value $empresa.Cnpj))
    $html = $html.Replace('{{InscricaoEstadual}}', $ieValue)
    $html = $html.Replace('{{PeriodoDisplay}}',    $Context.PeriodoDisplay)
    $html = $html.Replace('{{PeriodoTitulo}}',     $Context.PeriodoDisplay)
    $html = $html.Replace('{{DataEmissao}}',       $Context.DataEmissao)

    $logoProp  = $empresa.PSObject.Properties['Logotipo']
    $logoValue = if ($null -ne $logoProp) { $logoProp.Value } else { $null }

    if (-not [string]::IsNullOrWhiteSpace($logoValue)) {
        $html = $html.Replace('{{#TemLogotipo}}', [string]::Empty)
        $html = $html.Replace('{{/TemLogotipo}}', [string]::Empty)
        $html = $html.Replace('{{Logotipo}}',     $logoValue)
    } else {
        $html = [string]($html -replace '(?s){{#TemLogotipo}}.*?{{/TemLogotipo}}', [string]::Empty)
    }

    if ($Context.NotasNaoLancadas -and $Context.NotasNaoLancadas.Count -gt 0) {
        $rows  = $Context.NotasNaoLancadas
        $lines = for ($i = 0; $i -lt $rows.Count; $i++) {
            $row   = $rows[$i]
            $zebra = if ($i % 2 -ne 0) { 'background-color:#f9f9f9;' } else { [string]::Empty }

            '<tr style="{0}border-bottom:1px solid #eeeeee;">' -f $zebra +
            '<td align="right" style="padding:10px 14px;color:#111111;font-size:13px;">{0}</td>' -f $row.Inicial +
            '<td align="right" style="padding:10px 14px;color:#111111;font-size:13px;">{0}</td>' -f $row.Final +
            '<td align="right" style="padding:10px 14px;color:#111111;font-size:13px;">{0}</td>' -f $row.Serie +
            '<td style="padding:10px 14px;color:#111111;font-size:13px;">{0}</td>' -f $row.Especie +
            '</tr>'
        }

        $html = $html.Replace('{{#TemNotasNaoLancadas}}', [string]::Empty)
        $html = $html.Replace('{{/TemNotasNaoLancadas}}', [string]::Empty)
        $html = $html.Replace('{{NotasNaoLancadas}}',     ($lines -join ''))
    } else {
        $html = [string]($html -replace '(?s){{#TemNotasNaoLancadas}}.*?{{/TemNotasNaoLancadas}}', [string]::Empty)
    }


    if (-not [string]::IsNullOrWhiteSpace($Context.ReplyTo)) {
        $html = $html.Replace('{{#TemReplyTo}}',  [string]::Empty)
        $html = $html.Replace('{{/TemReplyTo}}',  [string]::Empty)
        $html = $html.Replace('{{ReplyTo}}',       $Context.ReplyTo)
    } else {
        $html = [string]($html -replace '(?s){{#TemReplyTo}}.*?{{/TemReplyTo}}', [string]::Empty)
    }

    $html
}
