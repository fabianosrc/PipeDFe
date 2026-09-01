<#
.SYNOPSIS
Updates an existing company registration.

.DESCRIPTION
Updates one or more fields of an existing company. Only parameters
explicitly provided are updated - all others are preserved from the
existing record.

Orchestrated in phases:

  1. Normalize  - CNPJ is normalized via ConvertTo-NormalizedCnpj.
  2. Load       - existing record is read via Get-CompanyConfig.
  3. Resolve    - provided values are merged over existing values.
  4. Validate   - Assert-CompanyInput with IsUpdate to skip duplicate check.
  5. Construct  - clean object is built via ConvertTo-CompanyObject.
  6. Persist    - saved via Save-CompanyConfig -AsUpdate, returned via
                  Get-CompanyConfig.

CNPJ is immutable after registration. When CertPath is provided without
CertPassword, the password is requested interactively via
Invoke-CertificateSetup (up to 3 attempts).

.PARAMETER Cnpj
Company CNPJ. Accepts formatted (XX.XXX.XXX/XXXX-XX) or raw 14-character
alphanumeric string.

.PARAMETER RazaoSocial
Updated legal name.

.PARAMETER NomeFantasia
Updated trade name.

.PARAMETER Ie
Updated state tax registration (Inscricao Estadual).

.PARAMETER Uf
Updated state code (e.g. SP, RJ, MG).

.PARAMETER Ambiente
Updated fiscal environment.

.PARAMETER XmlPath
Updated outbound XML directory. Must exist.

.PARAMETER XmlPathNfse
Updated NFSe XML directory. Pass empty string to clear the field.

.PARAMETER XmlPathEntrada
Updated inbound XML directory. Pass empty string to clear the field.

.PARAMETER OutputPath
Updated output directory for generated ZIP files.

.PARAMETER CertPath
Updated path to the A1 certificate file (.pfx). When provided without
CertPassword, the password is requested interactively.

.PARAMETER CertPassword
Updated certificate password as SecureString.

.PARAMETER EmailPara
Replaces all To recipients.

.PARAMETER EmailCc
Replaces all Cc recipients.

.PARAMETER EmailCco
Replaces all Bcc recipients.

.PARAMETER Smtp
Updated per-company SMTP override. Pass $null to revert to global smtp.json.

.PARAMETER IsActive
Activates or deactivates the company.

.OUTPUTS
System.Management.Automation.PSCustomObject

TypeName: PipeDFe.Company

.EXAMPLE
PS C:\> Set-PipeCompany -Cnpj '12345678000195' -NomeFantasia 'ACME NOVO'

.EXAMPLE
PS C:\> Set-PipeCompany -Cnpj '12345678000195' -IsActive $false

.NOTES
Private dependencies:
  Assert-CompanyInput
  ConvertTo-CompanyObject
  ConvertTo-DpapiString
  ConvertTo-NormalizedCnpj
  ConvertTo-NormalizedMailRecipient
  Get-CompanyConfig
  Invoke-CertificateSetup
  Save-CompanyConfig
#>
function Set-PipeCompany {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Cnpj,

        [Parameter()]
        [string]$RazaoSocial,

        [Parameter()]
        [string]$NomeFantasia,

        [Parameter()]
        [string]$Ie,

        [Parameter()]
        [ValidateSet(
            'AC', 'AL', 'AM', 'AP', 'BA', 'CE', 'DF', 'ES', 'GO',
            'MA', 'MG', 'MS', 'MT', 'PA', 'PB', 'PE', 'PI', 'PR',
            'RJ', 'RN', 'RO', 'RR', 'RS', 'SC', 'SE', 'SP', 'TO'
        )]
        [string]$Uf,

        [Parameter()]
        [Ambiente]$Ambiente,

        [Parameter()]
        [string]$XmlPath,

        [Parameter()]
        [AllowEmptyString()]
        [string]$XmlPathNfse,

        [Parameter()]
        [AllowEmptyString()]
        [string]$XmlPathEntrada,

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
        [pscustomobject]$Smtp,

        [Parameter()]
        [bool]$IsActive
    )

    #region Phase 1 - Normalize
    $cnpjNormalized = ConvertTo-NormalizedCnpj -Value $Cnpj
    #endregion

    #region Phase 2 - Load existing
    $existing = Get-CompanyConfig -Cnpj $cnpjNormalized
    #endregion

    #region Phase 3 - Resolve
    $bound = $PSBoundParameters

    $resolvedRazaoSocial = if ($bound.ContainsKey('RazaoSocial')) {
        $RazaoSocial
    } else {
        $existing.RazaoSocial
    }

    $resolvedNomeFantasia = if ($bound.ContainsKey('NomeFantasia')) {
        $NomeFantasia
    } else {
        $existing.NomeFantasia
    }

    $resolvedIe = if ($bound.ContainsKey('Ie')) {
        $Ie
    } else {
        $existing.Ie
    }

    $resolvedUf = if ($bound.ContainsKey('Uf')) {
        $Uf
    } else {
        $existing.Uf
    }

    $resolvedAmbiente = if ($bound.ContainsKey('Ambiente')) {
        $Ambiente
    } else {
        [Ambiente]$existing.Ambiente
    }

    $resolvedIsActive = if ($bound.ContainsKey('IsActive')) {
        $IsActive
    } else {
        [bool]$existing.IsActive
    }

    $resolvedXmlPath = if ($bound.ContainsKey('XmlPath')) {
        $XmlPath
    } else {
        $existing.XmlPath
    }

    $resolvedXmlPathNfse = if ($bound.ContainsKey('XmlPathNfse')) {
        if ([string]::IsNullOrWhiteSpace($XmlPathNfse)) {
            $null
        } else {
            $XmlPathNfse
        }
    } else {
        $existing.XmlPathNfse
    }

    $resolvedXmlPathEntrada = if ($bound.ContainsKey('XmlPathEntrada')) {
        if ([string]::IsNullOrWhiteSpace($XmlPathEntrada)) {
            $null
        } else {
            $XmlPathEntrada
        }
    } else {
        $existing.XmlPathEntrada
    }

    $resolvedOutputPath = if ($bound.ContainsKey('OutputPath')) {
        $OutputPath
    } else {
        $existing.OutputPath
    }

    $resolvedSmtp = if ($bound.ContainsKey('Smtp')) {
        $Smtp
    } else {
        $existing.Smtp
    }

    $resolvedEmailPara = if ($bound.ContainsKey('EmailPara')) {
        @($EmailPara | ConvertTo-NormalizedMailRecipient)
    } else {
        @($existing.Email.Para | Where-Object { $null -ne $_ })
    }

    $resolvedEmailCc = if ($bound.ContainsKey('EmailCc')) {
        @($EmailCc | ConvertTo-NormalizedMailRecipient)
    } else {
        @($existing.Email.Cc | Where-Object { $null -ne $_ })
    }

    $resolvedEmailCco = if ($bound.ContainsKey('EmailCco')) {
        @($EmailCco | ConvertTo-NormalizedMailRecipient)
    } else {
        @($existing.Email.Cco | Where-Object { $null -ne $_ })
    }

    #endregion

    #region Phase 4 - Validate
    $assertParams = @{
        Cnpj     = $cnpjNormalized
        Ambiente = $resolvedAmbiente
        XmlPath  = $resolvedXmlPath
        IsUpdate = $true
    }

    if ($null -ne $resolvedXmlPathNfse) {
        $assertParams['XmlPathNfse'] = $resolvedXmlPathNfse
    }

    if ($null -ne $resolvedXmlPathEntrada) {
        $assertParams['XmlPathEntrada'] = $resolvedXmlPathEntrada
    }

    Assert-CompanyInput @assertParams
    #endregion

    #region Phase 5 - Construct

    $resolvedCertParams = @{
        Bound        = $bound
        CertPath     = $CertPath
        CertPassword = $CertPassword
        Existing     = $existing.Certificado
    }

    $resolvedCertificado = Resolve-SetCompanyCertificate @resolvedCertParams

    $factoryParams = @{
        Cnpj           = $cnpjNormalized
        RazaoSocial    = $resolvedRazaoSocial
        Uf             = $resolvedUf
        Ambiente       = $resolvedAmbiente
        XmlPath        = $resolvedXmlPath
        OutputPath     = $resolvedOutputPath
        XmlPathNfse    = $resolvedXmlPathNfse
        XmlPathEntrada = $resolvedXmlPathEntrada
        NomeFantasia   = $resolvedNomeFantasia
        Ie             = $resolvedIe
        EmailPara      = $resolvedEmailPara
        EmailCc        = $resolvedEmailCc
        EmailCco       = $resolvedEmailCco
        Smtp           = $resolvedSmtp
        CertPath       = $resolvedCertificado.Path
        CertPassword   = $resolvedCertificado.EncryptedPassword
    }

    $company = ConvertTo-CompanyObject @factoryParams

    # Preserve immutable/persistent metadata.
    $company.Cnpj          = $cnpjNormalized
    $company.IsActive      = $resolvedIsActive
    $company.CreatedAt     = $existing.CreatedAt
    $company.SchemaVersion = $existing.SchemaVersion

    #endregion

    #region Phase 6 - Persist

    if (-not $PSCmdlet.ShouldProcess($cnpjNormalized, 'Update company configuration')) {
        return
    }

    Save-CompanyConfig -Company $company -AsUpdate

    # Always return the persisted representation rather than the
    # pre-persistence object.
    $updated = Get-CompanyConfig -Cnpj $cnpjNormalized

    if ($null -eq $updated) {
        $errorRecord = New-Object System.Management.Automation.ErrorRecord(
            ([System.InvalidOperationException]::new(
                "Company '$cnpjNormalized' could not be reloaded after update."
            )),
            'CompanyReloadFailed',
            [System.Management.Automation.ErrorCategory]::InvalidResult,
            $cnpjNormalized
        )

        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    return $updated

    #endregion
}

#region Private helper
function Resolve-SetCompanyCertificate {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Bound,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$CertPath,

        [Parameter()]
        [AllowNull()]
        [System.Security.SecureString]$CertPassword,

        [Parameter(Mandatory)]
        [AllowNull()]
        [pscustomobject]$Existing
    )

    $existingPath = if ($null -ne $Existing) {
        $Existing.Path
    } else {
        $null
    }

    $existingPassword = if ($null -ne $Existing) {
        $Existing.EncryptedPassword
    } else {
        $null
    }

    if (-not $Bound.ContainsKey('CertPath')) {
        return [PSCustomObject]@{
            Path              = $existingPath
            EncryptedPassword = $existingPassword
        }
    }

    if (-not (Test-Path -LiteralPath $CertPath -PathType Leaf)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.FileNotFoundException]::new(
                    "Certificate file not found: '$CertPath'"
                ),
                'CertNotFound',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $CertPath
            )
        )
    }

    if ($Bound.ContainsKey('CertPassword')) {
        $encryptedPassword = ConvertTo-DpapiString -Value $CertPassword
    } else {
        $certSetup         = Invoke-CertificateSetup -Path $CertPath
        $encryptedPassword = $certSetup.EncryptedPassword
    }

    [PSCustomObject]@{
        Path              = $CertPath
        EncryptedPassword = $encryptedPassword
    }
}
#endregion
