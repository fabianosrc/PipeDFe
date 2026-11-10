<#
.SYNOPSIS
Renders the HTML email body for a DFe notification.

.DESCRIPTION
Loads the HTML template from the module's templates directory and
replaces placeholders with HTML-encoded values from the context object.

Conditional blocks are included when their corresponding data is
available and removed otherwise.

Document summary and sequence-gap rows are rendered as HTML tables.

Throws MailTemplateNotFound when the template file does not exist.

The TemArquivosManuais block is reserved for future implementation
and is currently removed from the rendered output.

.PARAMETER Context
A PSCustomObject containing:

    Empresa          [pscustomobject]
        Cnpj
        NomeFantasia
        RazaoSocial
        Ie
        Logotipo (optional)

    PeriodoDisplay   [string]
    DataEmissao      [string]
    ReplyTo          [string]

    NotasNaoLancadas [pscustomobject[]]
        Inicial
        Final
        Serie
        Especie

    ResumoDocumentos [pscustomobject[]]
        Tipo
        Quantidade

.OUTPUTS
System.String

.EXAMPLE
PS C:\> $html = Build-MailBody -Context $context

.NOTES
Private dependencies:
  ConvertTo-FormattedCnpj

Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>
function Build-MailBody {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseApprovedVerbs',
        '',
        Justification = 'Build- describes the rendering of an HTML email body from a template.'
    )]
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context
    )

    #region Template
    $templatePath = [System.IO.Path]::Combine(
        $Script:ModuleRoot,
        'templates',
        'mail',
        'dfe-notification.html'
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

    $html = [System.IO.File]::ReadAllText(
        $templatePath,
        [System.Text.Encoding]::UTF8
    )
    #endregion

    #region Context
    $empresaProp = $Context.PSObject.Properties['Empresa']

    if ($null -eq $empresaProp -or $null -eq $empresaProp.Value) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    "The context must contain a non-null 'Empresa' property."
                ),
                'MailTemplateInvalidContext',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Context
            )
        )
    }

    $empresa = $empresaProp.Value

    $nomeEmpresa = if (-not [string]::IsNullOrWhiteSpace([string]$empresa.NomeFantasia)) {
        [string]$empresa.NomeFantasia
    } else {
        [string]$empresa.RazaoSocial
    }

    $ieValue = if (-not [string]::IsNullOrWhiteSpace([string]$empresa.Ie)) {
        [string]$empresa.Ie
    } else {
        [string]::Empty
    }

    $logoProp = $empresa.PSObject.Properties['Logotipo']

    $logoValue = if ($null -ne $logoProp) {
        [string]$logoProp.Value
    } else {
        [string]::Empty
    }

    $resumoProp = $Context.PSObject.Properties['ResumoDocumentos']

    $resumoRows = @(
        if ($null -ne $resumoProp -and $null -ne $resumoProp.Value) {
            @($resumoProp.Value) | Where-Object { $null -ne $_ }
        }
    )

    $notasProp = $Context.PSObject.Properties['NotasNaoLancadas']

    $notasRows = @(
        if ($null -ne $notasProp -and $null -ne $notasProp.Value) {
            @($notasProp.Value) | Where-Object { $null -ne $_ }
        }
    )
    #endregion

    #region Conditional blocks
    $conditionalBlocks = @(
        @{
            Name    = 'TemLogotipo'
            Include = -not [string]::IsNullOrWhiteSpace($logoValue)
        },
        @{
            Name    = 'TemNotasNaoLancadas'
            Include = $notasRows.Count -gt 0
        },
        @{
            Name    = 'TemReplyTo'
            Include = -not [string]::IsNullOrWhiteSpace([string]$Context.ReplyTo)
        },
        @{
            Name    = 'TemArquivosManuais'
            Include = $false
        }
    )

    foreach ($block in $conditionalBlocks) {
        $startMarker = '{{#' + $block.Name + '}}'
        $endMarker   = '{{/' + $block.Name + '}}'

        if ($block.Include) {
            $html = $html.Replace($startMarker, [string]::Empty)
            $html = $html.Replace($endMarker,   [string]::Empty)
        } else {
            $pattern = '(?s){0}.*?{1}' -f [regex]::Escape($startMarker), [regex]::Escape($endMarker)
            $html    = [regex]::Replace($html, $pattern, [string]::Empty)
        }
    }
    #endregion

    #region Document summary
    $resumoLines = @(
        for ($i = 0; $i -lt $resumoRows.Count; $i++) {
            $row   = $resumoRows[$i]
            $zebra = if ($i % 2 -ne 0) { 'background-color:#f9f9f9;' } else { [string]::Empty }

            $tipo       = [System.Net.WebUtility]::HtmlEncode([string]$row.Tipo)
            $quantidade = [System.Net.WebUtility]::HtmlEncode([string]$row.Quantidade)

            $rowHtml = @(
                '<tr style="{0}border-bottom:1px solid #eeeeee;">'
                '<td style="padding:10px 14px;color:#111111;font-family:Arial,Helvetica,sans-serif;font-size:13px;line-height:18px;">{1}</td>'
                '<td align="right" style="padding:10px 14px;color:#111111;font-family:Arial,Helvetica,sans-serif;font-size:13px;line-height:18px;">{2}</td>'
                '</tr>'
            ) -join ''

            $rowHtml -f $zebra, $tipo, $quantidade
        }
    )

    $resumoHtml = $resumoLines -join ''
    #endregion

    #region Sequence gaps
    $notasLines = @(
        for ($i = 0; $i -lt $notasRows.Count; $i++) {
            $row   = $notasRows[$i]
            $zebra = if ($i % 2 -ne 0) { 'background-color:#f9f9f9;' } else { [string]::Empty }

            $inicial = [System.Net.WebUtility]::HtmlEncode([string]$row.Inicial)
            $final   = [System.Net.WebUtility]::HtmlEncode([string]$row.Final)
            $serie   = [System.Net.WebUtility]::HtmlEncode([string]$row.Serie)
            $especie = [System.Net.WebUtility]::HtmlEncode([string]$row.Especie)

            $rowHtml = @(
                '<tr style="{0}border-bottom:1px solid #eeeeee;">'
                '<td align="right" style="padding:10px 14px;color:#111111;font-size:13px;">{1}</td>'
                '<td align="right" style="padding:10px 14px;color:#111111;font-size:13px;">{2}</td>'
                '<td align="right" style="padding:10px 14px;color:#111111;font-size:13px;">{3}</td>'
                '<td style="padding:10px 14px;color:#111111;font-size:13px;">{4}</td>'
                '</tr>'
            ) -join ''

            $rowHtml -f $zebra, $inicial, $final, $serie, $especie
        }
    )

    $notasHtml = $notasLines -join ''
    #endregion

    #region Placeholder rendering
    $cnpjFormatado = ConvertTo-FormattedCnpj -Value $empresa.Cnpj

    $encodedValues = @{
        NomeEmpresa       = [System.Net.WebUtility]::HtmlEncode($nomeEmpresa)
        NomeFantasia      = [System.Net.WebUtility]::HtmlEncode($nomeEmpresa)
        RazaoSocial       = [System.Net.WebUtility]::HtmlEncode([string]$empresa.RazaoSocial)
        CnpjFormatado     = [System.Net.WebUtility]::HtmlEncode([string]$cnpjFormatado)
        InscricaoEstadual = [System.Net.WebUtility]::HtmlEncode($ieValue)
        PeriodoDisplay    = [System.Net.WebUtility]::HtmlEncode([string]$Context.PeriodoDisplay)
        PeriodoTitulo     = [System.Net.WebUtility]::HtmlEncode([string]$Context.PeriodoDisplay)
        DataEmissao       = [System.Net.WebUtility]::HtmlEncode([string]$Context.DataEmissao)
        ReplyTo           = [System.Net.WebUtility]::HtmlEncode([string]$Context.ReplyTo)
        Logotipo          = $logoValue

        # Table content is already HTML-encoded row by row.
        ResumoDocumentos  = $resumoHtml
        NotasNaoLancadas  = $notasHtml
    }

    # A single pass prevents inserted values from being interpreted
    # as additional placeholders during subsequent replacements.
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param ([System.Text.RegularExpressions.Match]$match)

        $key = $match.Groups[1].Value

        if ($encodedValues.ContainsKey($key)) {
            return [string]$encodedValues[$key]
        }

        return $match.Value
    }

    $html = [regex]::Replace(
        $html,
        '\{\{([A-Za-z][A-Za-z0-9]*)\}\}',
        $evaluator
    )
    #endregion

    return $html
}
