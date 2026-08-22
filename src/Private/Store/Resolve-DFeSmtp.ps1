<#
.SYNOPSIS
Resolves the effective SMTP configuration for a company.

.DESCRIPTION
Returns the company-specific SMTP configuration when configured.

When the company does not define SMTP, falls back to the global SMTP
configuration returned by Get-SmtpConfig.

If no global SMTP configuration exists, throws SmtpNotConfigured.

Errors from Get-SmtpConfig other than SmtpConfigNotFound are propagated
unchanged so that configuration, I/O and unexpected failures are not
silently masked.

.PARAMETER Company
Company object. Must expose a nullable Smtp property and a Cnpj property.

.OUTPUTS
System.Management.Automation.PSCustomObject

.EXAMPLE
PS C:\> $smtp = Resolve-DFeSmtp -Company $company

.NOTES
Private dependencies:
  Get-SmtpConfig
#>
function Resolve-DFeSmtp {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Company
    )

    $smtpProp = $Company.PSObject.Properties['Smtp']

    if ($null -ne $smtpProp -and $null -ne $smtpProp.Value) {
        return $smtpProp.Value
    }

    Write-Verbose -Message (
        "[$($Company.Cnpj)] No company-specific SMTP found. " +
        "Falling back to global SMTP."
    )

    try {
        return Get-SmtpConfig -ErrorAction Stop
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'SmtpConfigNotFound*') {
            throw
        }
    }

    $PSCmdlet.ThrowTerminatingError(
        [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new(
                "[$($Company.Cnpj)] No SMTP configuration available. " +
                "Configure a company-specific SMTP or a global SMTP " +
                "before running the pipeline."
            ),
            'SmtpNotConfigured',
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $Company
        )
    )
}
