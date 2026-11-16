
<#
.SYNOPSIS
Returns the certificate validity notice for a monthly DFe email.

.DESCRIPTION
Reads the expiration date of the configured company certificate and
returns a notice indicating whether the certificate is valid, expiring,
expired, or unavailable.

A certificate expiring within 30 days, inclusive, is considered expiring.

Certificate and password read failures produce an unavailable notice
without exposing internal error details.

If no certificate is configured, produces no output.

.PARAMETER Company
The company configuration returned by Get-CompanyConfig.

.PARAMETER Now
The reference instant used to classify the certificate.
Defaults to UTC now.

.OUTPUTS
System.String

.NOTES
Private dependencies:
  Get-CompanyCertificatePassword
  Test-CertificateFile
#>
function Get-DFeCertificateNotice {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Company,

        [Parameter()]
        [System.DateTimeOffset]$Now = [System.DateTimeOffset]::UtcNow
    )

    $certificateProperty = $Company.PSObject.Properties['Certificado']

    if ($null -eq $certificateProperty -or
        $null -eq $certificateProperty.Value
    ) {
        return
    }

    $pathProperty = $certificateProperty.Value.PSObject.Properties['Path']

    if ($null -eq $pathProperty -or $pathProperty.Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace($pathProperty.Value)
    ) {
        return
    }

    $unavailable = 'Validade do certificado: indisponível.'
    $password    = $null

    try {
        $pwParams = @{
            Company     = $Company
            ErrorAction = 'Stop'
        }

        $password = Get-CompanyCertificatePassword @pwParams


        if ($null -eq $password) {
            return $unavailable
        }

        $testParams = @{
            Path        = $pathProperty.Value
            Password    = $password
            ErrorAction = 'Stop'
        }

        $certificate = Test-CertificateFile @testParams

        if ($null -eq $certificate) {
            return $unavailable
        }

        $isValidProperty = $certificate.PSObject.Properties['IsValid']
        $expiresProperty = $certificate.PSObject.Properties['ExpiresOn']

        if ($null -eq $isValidProperty -or $null -eq $expiresProperty -or
            $isValidProperty.Value -isnot [bool] -or -not
            $isValidProperty.Value -or $null -eq $expiresProperty.Value
        ) {
            return $unavailable
        }

        if ($expiresProperty.Value -isnot [datetime] -and
            $expiresProperty.Value -isnot [System.DateTimeOffset]
        ) {
            return $unavailable
        }

        $expiresOn = [System.DateTimeOffset]$expiresProperty.Value
    } catch {
        return $unavailable
    } finally {
        if ($null -ne $password) {
            $password.Dispose()
        }
    }

    $culture   = [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')
    $date      = $expiresOn.ToString('dd/MM/yyyy', $culture)
    $remaining = $expiresOn - $Now

    if ($remaining -le [System.TimeSpan]::Zero) {
        return "Certificado vencido em $date."
    }

    if ($remaining -le [System.TimeSpan]::FromDays(30)) {
        return "Certificado com vencimento próximo: $date."
    }

    return "Certificado válido até $date."
}
