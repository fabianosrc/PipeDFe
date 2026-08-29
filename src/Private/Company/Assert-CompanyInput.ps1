<#
.SYNOPSIS
Validates company input parameters before persistence.

.DESCRIPTION
Centralizes validation logic for company registration and update operations.

Business rules enforced:
  - Cnpj must be normalized (14 uppercase alphanumeric characters).
  - Producao requires a mathematically valid CNPJ.
  - Homologacao accepts fictitious CNPJs.
  - Duplicate CNPJ detection via Test-Path on the companies store.
  - XmlPath must exist and be a directory.
  - XmlPathNfse is optional; when provided it must exist and be a directory.
  - XmlPathEntrada is optional; when provided it must exist and be a directory.
  - CertPath and CertPassword must always be provided together.
  - CertPath, when provided, must resolve to an existing file.
  - CertPassword, when provided, must be a non-empty SecureString.

Throws a terminating error on the first validation failure.

.PARAMETER Cnpj
Normalized CNPJ - 14 uppercase alphanumeric characters.

.PARAMETER Ambiente
Target fiscal environment.

Producao:
  Mathematical CNPJ validation is required.

Homologacao:
  Mathematical CNPJ validation is skipped, allowing fictitious CNPJs.

.PARAMETER XmlPath
Mandatory directory where the ERP stores outbound XML files.

.PARAMETER XmlPathNfse
Optional directory where NFSe XML files are stored.

.PARAMETER XmlPathEntrada
Optional directory where inbound XML files are stored.

.PARAMETER CertPath
Optional path to the A1 certificate file (.pfx).

.PARAMETER CertPassword
Certificate password as SecureString.

.PARAMETER IsUpdate
When specified, skips duplicate CNPJ detection. Used by Set-PipeCompany.

.OUTPUTS
None.

.EXAMPLE
PS C:\> $assertParams = @{
    Cnpj     = '12345678000195'
    Ambiente = [Ambiente]::Producao
    XmlPath  = 'C:\ERP\XMLs'
}

>> Assert-CompanyInput @assertParams

.NOTES
Private dependencies:
  Test-Cnpj
  Test-HasValue
  Get-StorePath
#>
function Assert-CompanyInput {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [Ambiente]$Ambiente,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$XmlPath,

        [Parameter()]
        [AllowEmptyString()]
        [string]$XmlPathNfse,

        [Parameter()]
        [AllowEmptyString()]
        [string]$XmlPathEntrada,

        [Parameter()]
        [AllowEmptyString()]
        [string]$CertPath,

        [Parameter()]
        [System.Security.SecureString]$CertPassword,

        [Parameter()]
        [switch]$IsUpdate
    )

    # 1. CNPJ normalization / format
    #
    # The function expects normalized input.
    #
    # Do not silently remove punctuation, trim, uppercase or otherwise mutate
    # the supplied value here. Normalization belongs to the input boundary.
    #
    # Current accepted structure:
    #   - exactly 14 characters
    #   - digits and uppercase letters
    #
    # The mathematical validation itself remains delegated to Test-Cnpj.
    if ($Cnpj -cnotmatch '^[0-9A-Z]{14}$') {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    "Cnpj must be 14 uppercase alphanumeric characters. Got: '$Cnpj'"
                ),
                'CnpjNotNormalized',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Cnpj
            )
        )
    }

    # 2. Mathematical CNPJ validation
    #
    # Production only.
    #
    # Test-Cnpj is an existing project dependency and remains responsible for
    # the mathematical validation algorithm.
    if ($Ambiente -eq [Ambiente]::Producao) {
        if (-not (Test-Cnpj -Value $Cnpj -Ambiente $Ambiente)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "CNPJ '$Cnpj' failed check digit validation. " +
                        'Producao requires a mathematically valid CNPJ.'
                    ),
                    'InvalidCnpj',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Cnpj
                )
            )
        }
    }

    # 3. XmlPath
    if (-not (Test-Path -LiteralPath $XmlPath -PathType Container)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.DirectoryNotFoundException]::new(
                    "XmlPath not found or is not a directory: '$XmlPath'"
                ),
                'XmlPathNotFound',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $XmlPath
            )
        )
    }

    # 4. XmlPathNfse
    if (Test-HasValue -InputObject $XmlPathNfse) {
        if (-not (Test-Path -LiteralPath $XmlPathNfse -PathType Container)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.DirectoryNotFoundException]::new(
                        "XmlPathNfse not found or is not a directory: '$XmlPathNfse'"
                    ),
                    'XmlPathNfseNotFound',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                    $XmlPathNfse
                )
            )
        }
    }

    # 5. XmlPathEntrada
    if (Test-HasValue -InputObject $XmlPathEntrada) {
        if (-not (Test-Path -LiteralPath $XmlPathEntrada -PathType Container)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.DirectoryNotFoundException]::new(
                        "XmlPathEntrada not found or is not a directory: '$XmlPathEntrada'"
                    ),
                    'XmlPathEntradaNotFound',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                    $XmlPathEntrada
                )
            )
        }
    }

    # 6. Certificate consistency
    $hasCertPath     = Test-HasValue -InputObject $CertPath
    $hasCertPassword = ($null -ne $CertPassword -and $CertPassword.Length -gt 0)

    # CertPath without password.
    if ($hasCertPath -and -not $hasCertPassword) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'CertPassword is required when CertPath is provided.'
                ),
                'MissingCertPassword',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $CertPath
            )
        )
    }

    # Password without CertPath.
    if ($hasCertPassword -and -not $hasCertPath) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'CertPath is required when CertPassword is provided.'
                ),
                'MissingCertPath',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $null
            )
        )
    }

    # 7. Certificate file existence
    if ($hasCertPath) {
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
    }

    # 8. Duplicate company detection
    #
    # This check is intentionally skipped for updates.
    #
    # Get-StorePath remains the single source of truth for the physical
    # company storage location.
    if (-not $IsUpdate) {
        $storeParams = @{
            Scope = 'Config'
            Cnpj  = $Cnpj
        }

        $configPath  = Get-StorePath @storeParams
        $companyFile = Join-Path -Path $configPath -ChildPath 'company.json'

        if (Test-Path -LiteralPath $companyFile -PathType Leaf) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        "Company '$Cnpj' is already registered. 'Use Set-PipeCompany to update."
                    ),
                    'DuplicateCompany',
                    [System.Management.Automation.ErrorCategory]::ResourceExists,
                    $Cnpj
                )
            )
        }
    }

    return
}
