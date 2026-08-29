<#
.SYNOPSIS
Constructs a normalized company PSCustomObject from pre-resolved inputs.

.DESCRIPTION
Builds a clean, typed company object. This is the single source of truth
for the company entity shape. All other layers consume the object this
function produces rather than rebuilding it independently.

This function is pure:
  - No validation - (caller validates via Assert-CompanyInput)
  - No I/O        - (caller resolves and creates OutputPath)
  - No encryption - (caller encrypts CertPassword via DPAPI first)

CreatedAt is stamped here. UpdatedAt is always null on creation and is
the responsibility of the caller on update.

.PARAMETER Cnpj
Normalized CNPJ - 14 uppercase alphanumeric characters.

.PARAMETER RazaoSocial
Company legal name. Normalized to uppercase via ConvertTo-SafeString.

.PARAMETER Uf
State code (e.g. SP, RJ).

.PARAMETER Ambiente
Fiscal environment.

.PARAMETER XmlPath
Directory where the ERP stores outbound XML files.

.PARAMETER OutputPath
Directory where generated ZIP files will be saved.

.PARAMETER XmlPathNfse
Optional directory where NFSe XML files are stored.

.PARAMETER XmlPathEntrada
Optional directory where inbound XML files are stored.

.PARAMETER NomeFantasia
Optional trade name.

.PARAMETER Ie
Optional state tax registration number.

.PARAMETER CertPath
Optional path to the A1 certificate file.

.PARAMETER CertPassword
Optional DPAPI-encrypted certificate password. Must already be encrypted
by the caller - this function does not encrypt.

.PARAMETER EmailPara
Parsed To recipients. Each entry has Nome and Email.

.PARAMETER EmailCc
Parsed Cc recipients.

.PARAMETER EmailCco
Parsed Bcc recipients.

.PARAMETER ContatoEmail
Optional contact email address.

.PARAMETER ContatoTelefone
Optional contact phone number.

.PARAMETER Smtp
Optional per-company SMTP override.

.OUTPUTS
System.Management.Automation.PSCustomObject

.EXAMPLE
PS C:\> $companyParams = @{
    Cnpj        = '12345678000195'
    RazaoSocial = 'Acme Ltda'
    Uf          = 'SP'
    Ambiente    = [Ambiente]::Producao
    XmlPath     = 'C:\ERP\XML'
    OutputPath  = 'C:\Out'
}

>> ConvertTo-CompanyObject @companyParams

.NOTES
Private dependencies:
  ConvertTo-SafeString
#>
function ConvertTo-CompanyObject {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword',
        'CertPassword',
        Justification = 'Value is DPAPI-encrypted by the caller and safe to store as string.'
    )]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RazaoSocial,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Uf,

        [Parameter(Mandatory)]
        [Ambiente]$Ambiente,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$XmlPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath,

        [Parameter()]
        [string]$XmlPathNfse,

        [Parameter()]
        [string]$XmlPathEntrada,

        [Parameter()]
        [string]$NomeFantasia,

        [Parameter()]
        [string]$Ie,

        [Parameter()]
        [string]$CertPath,

        [Parameter()]
        [string]$CertPassword,

        [Parameter()]
        [pscustomobject[]]$EmailPara = @(),

        [Parameter()]
        [pscustomobject[]]$EmailCc = @(),

        [Parameter()]
        [pscustomobject[]]$EmailCco = @(),

        [Parameter()]
        [string]$ContatoEmail,

        [Parameter()]
        [string]$ContatoTelefone,

        [Parameter()]
        [pscustomobject]$Smtp
    )

    # Certificado block is always present to guarantee the property exists
    # after JSON round-trip. Path and EncryptedPassword are null when no
    # certificate is provided.
    $hasCert    = $PSBoundParameters.ContainsKey('CertPath')
    $certificado = [PSCustomObject]@{
        Path              = if ($hasCert) { $CertPath     } else { $null }
        EncryptedPassword = if ($hasCert) { $CertPassword } else { $null }
    }

    $hasXmlPathNfse    = $PSBoundParameters.ContainsKey('XmlPathNfse')    -and
    -not [string]::IsNullOrWhiteSpace($XmlPathNfse)

    $hasXmlPathEntrada = $PSBoundParameters.ContainsKey('XmlPathEntrada') -and
    -not [string]::IsNullOrWhiteSpace($XmlPathEntrada)

    [PSCustomObject]@{
        SchemaVersion  = $Script:JsonSchemaVersion
        Cnpj           = $Cnpj
        Ie             = $Ie
        RazaoSocial    = ConvertTo-SafeString -InputObject $RazaoSocial -UpperCase -Separator ' '
        NomeFantasia   = $NomeFantasia
        Uf             = $Uf
        Ambiente       = $Ambiente.ToString()
        IsActive       = $true
        XmlPath        = $XmlPath
        XmlPathNfse    = if ($hasXmlPathNfse)    { $XmlPathNfse    } else { $null }
        XmlPathEntrada = if ($hasXmlPathEntrada) { $XmlPathEntrada } else { $null }
        OutputPath     = $OutputPath
        Certificado    = $certificado
        Email          = [PSCustomObject]@{
            Para = @($EmailPara | Where-Object { $_ })
            Cc   = @($EmailCc   | Where-Object { $_ })
            Cco  = @($EmailCco  | Where-Object { $_ })
        }
        Contato        = [PSCustomObject]@{
            Email    = $ContatoEmail
            Telefone = $ContatoTelefone
        }
        Smtp           = $Smtp
        CreatedAt      = [System.DateTimeOffset]::UtcNow.ToString('o')
        UpdatedAt      = $null
    }
}
