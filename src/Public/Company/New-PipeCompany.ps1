<#
.SYNOPSIS
Registers a new company in PipeDFe.

.DESCRIPTION
Orchestrates company registration in three phases:

  1. Validation   - normalizes CNPJ, then delegates all input validation
                    to Assert-CompanyInput (format, check digits, duplicate
                    detection, path existence, certificate consistency).

  2. Construction - resolves OutputPath, encrypts CertPassword via DPAPI,
                    normalizes email recipients, then builds the company
                    object via ConvertTo-CompanyObject (pure factory).

  3. Persistence  - persists via Save-CompanyConfig, then returns the
                    persisted state via Get-CompanyConfig.

XmlPath must already exist. PipeDFe never modifies source XML directories.
OutputPath is created when absent. Defaults to {UserProfile}\Documents\PipeDFe
when omitted.

.PARAMETER Cnpj
Company CNPJ. Accepts formatted (XX.XXX.XXX/XXXX-XX) or raw 14-character
alphanumeric string. Normalized to 14 uppercase characters before use.

.PARAMETER RazaoSocial
Company legal name.

.PARAMETER Uf
State code (e.g. SP, RJ, MG).

.PARAMETER Ambiente
Fiscal environment. Producao requires a mathematically valid CNPJ.

.PARAMETER XmlPath
Directory where the ERP stores outbound DFe XML files. Must already exist.

.PARAMETER XmlPathNfse
Optional directory where NFSe XML files are stored. Must exist when provided.

.PARAMETER XmlPathEntrada
Optional directory where inbound XML files are stored. Must exist when provided.

.PARAMETER NomeFantasia
Optional trade name.

.PARAMETER Ie
Optional state tax registration (Inscricao Estadual).

.PARAMETER OutputPath
Directory where generated ZIP files will be saved. Created when absent.
Defaults to {UserProfile}\Documents\PipeDFe when omitted.

.PARAMETER CertPath
Path to an A1 certificate file (.pfx). Must exist when provided.
Must be provided together with CertPassword.

.PARAMETER CertPassword
Certificate password as SecureString. Must be provided together with CertPath.

.PARAMETER EmailPara
One or more To recipients. Accepts strings (used as email address) or
objects with Name and Email properties.

.PARAMETER EmailCc
One or more Cc recipients. Same format as EmailPara.

.PARAMETER EmailCco
One or more Bcc recipients. Same format as EmailPara.

.PARAMETER Smtp
Optional per-company SMTP override. Falls back to global smtp.json when absent.

.OUTPUTS
System.Management.Automation.PSCustomObject

TypeName: PipeDFe.Company

.EXAMPLE
PS C:\> New-PipeCompany -Cnpj '12345678000195'
>> -RazaoSocial 'ACME COMERCIO LTDA' -Uf SP
>> -Ambiente Producao -XmlPath 'C:\ERP\XML'

.EXAMPLE
PS C:\> $regParams = @{
    Cnpj         = '12.345.678/0001-95'
    RazaoSocial  = 'ACME COMERCIO LTDA'
    NomeFantasia = 'ACME'
    Uf           = 'SP'
    Ambiente     = [Ambiente]::Producao
    XmlPath      = 'C:\ERP\XML'
    EmailPara    = 'contador@escritorio.com.br'
}

PS C:\> New-PipeCompany @regParams

.NOTES
Private dependencies:
  Assert-CompanyInput
  ConvertTo-CompanyObject
  ConvertTo-DpapiString
  ConvertTo-NormalizedCnpj
  ConvertTo-NormalizedMailRecipient
  Get-CompanyConfig
  Get-StorePath
  Save-CompanyConfig
#>
function New-PipeCompany {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RazaoSocial,

        [Parameter(Mandatory)]
        [ValidateSet(
            'AC', 'AL', 'AM', 'AP', 'BA', 'CE', 'DF', 'ES', 'GO',
            'MA', 'MG', 'MS', 'MT', 'PA', 'PB', 'PE', 'PI', 'PR',
            'RJ', 'RN', 'RO', 'RR', 'RS', 'SC', 'SE', 'SP', 'TO'
        )]
        [string]$Uf,

        [Parameter(Mandatory)]
        [Ambiente]$Ambiente,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$XmlPath,

        [Parameter()]
        [string]$XmlPathNfse,

        [Parameter()]
        [string]$XmlPathEntrada,

        [Parameter()]
        [string]$NomeFantasia,

        [Parameter()]
        [string]$Ie,

        [Parameter()]
        [string]$OutputPath,

        [Parameter()]
        [string]$CertPath,

        [Parameter()]
        [System.Security.SecureString]$CertPassword,

        [Parameter()]
        [object[]]$EmailPara,

        [Parameter()]
        [object[]]$EmailCc,

        [Parameter()]
        [object[]]$EmailCco,

        [Parameter()]
        [pscustomobject]$Smtp
    )

    #region Phase 1 - Normalize and validate
    $cnpjNormalized = ConvertTo-NormalizedCnpj -Value $Cnpj

    $assertParams = @{
        Cnpj     = $cnpjNormalized
        Ambiente = $Ambiente
        XmlPath  = $XmlPath
    }

    if ($PSBoundParameters.ContainsKey('XmlPathNfse')) {
        $assertParams['XmlPathNfse'] = $XmlPathNfse
    }

    if ($PSBoundParameters.ContainsKey('XmlPathEntrada')) {
        $assertParams['XmlPathEntrada'] = $XmlPathEntrada
    }

    if ($PSBoundParameters.ContainsKey('CertPath')) {
        $assertParams['CertPath']     = $CertPath
        $assertParams['CertPassword'] = $CertPassword
    }

    Assert-CompanyInput @assertParams
    #endregion

    #region Phase 2 - Resolve side-effects and construct
    $resolvedOutputPath = if ($PSBoundParameters.ContainsKey('OutputPath') -and
        -not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath
    } else {
        Get-StorePath -Scope Output -Cnpj $cnpjNormalized
    }

    if (-not (Test-Path -LiteralPath $resolvedOutputPath -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($resolvedOutputPath) | Out-Null
    }

    $factoryParams = @{
        Cnpj        = $cnpjNormalized
        RazaoSocial = $RazaoSocial
        Uf          = $Uf
        Ambiente    = $Ambiente
        XmlPath     = $XmlPath
        OutputPath  = $resolvedOutputPath
        EmailPara   = @($EmailPara | ConvertTo-NormalizedMailRecipient)
        EmailCc     = @($EmailCc   | ConvertTo-NormalizedMailRecipient)
        EmailCco    = @($EmailCco  | ConvertTo-NormalizedMailRecipient)
    }

    if ($PSBoundParameters.ContainsKey('XmlPathNfse')) {
        $factoryParams['XmlPathNfse'] = $XmlPathNfse
    }

    if ($PSBoundParameters.ContainsKey('XmlPathEntrada')) {
        $factoryParams['XmlPathEntrada'] = $XmlPathEntrada
    }

    if ($PSBoundParameters.ContainsKey('NomeFantasia')) {
        $factoryParams['NomeFantasia'] = $NomeFantasia
    }

    if ($PSBoundParameters.ContainsKey('Ie')) {
        $factoryParams['Ie'] = $Ie
    }

    if ($PSBoundParameters.ContainsKey('Smtp')) {
        $factoryParams['Smtp'] = $Smtp
    }

    if ($PSBoundParameters.ContainsKey('CertPath')) {
        $factoryParams['CertPath']     = $CertPath
        $factoryParams['CertPassword'] = ConvertTo-DpapiString -Value $CertPassword
    }

    $company = ConvertTo-CompanyObject @factoryParams
    #endregion

    #region Phase 3 - Persist and return
    if ($PSCmdlet.ShouldProcess($cnpjNormalized, 'Register company')) {
        Save-CompanyConfig -Company $company
        Get-CompanyConfig  -Cnpj $cnpjNormalized
    }
    #endregion
}
