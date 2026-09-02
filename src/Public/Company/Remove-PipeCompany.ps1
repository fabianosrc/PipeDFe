<#
.SYNOPSIS
Removes an inactive company configuration from PipeDFe storage.

.DESCRIPTION
Removes the configuration file for the company identified by the supplied
CNPJ. Removal is refused when the company is active.

When -DeleteFiles is specified, the company's data directory is also removed
recursively after the configuration file has been successfully removed.

A missing data directory is treated as an expected condition and is silently
ignored. All other removal errors are propagated.

Supports -WhatIf and -Confirm for destructive operations.

.PARAMETER Cnpj
CNPJ identifying the company to remove. Normalized and validated by
ConvertTo-NormalizedCnpj before any lookup is performed.

.PARAMETER DeleteFiles
When specified, also removes the company's complete data directory,
including database files, logs, and generated output.

This operation is destructive and cannot be undone.

.EXAMPLE
PS C\:> Remove-PipeCompany -Cnpj '12345678000195'

Removes the configuration file for the specified inactive company.

.EXAMPLE
PS C\:> Remove-PipeCompany -Cnpj '12345678000195' -DeleteFiles

Removes the configuration file and the company's complete data directory.

.EXAMPLE
PS C\:> Remove-PipeCompany -Cnpj '12345678000195' -DeleteFiles -WhatIf

Shows what would be removed without performing any changes.

.NOTES
Compatibility:

Windows PowerShell 5.1
PowerShell 7+
Private dependencies:
  ConvertTo-NormalizedCnpj
  Get-CompanyConfig
  Get-StorePath
#>
function Remove-PipeCompany {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [string]$Cnpj,

        [Parameter()]
        [switch]$DeleteFiles
    )

    $cnpjNormalized = ConvertTo-NormalizedCnpj -Value $Cnpj

    # Get-CompanyConfig raises CompanyNotFound when the CNPJ does not exist.
    $company = Get-CompanyConfig -Cnpj $cnpjNormalized

    if ($company.IsActive) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "Company '$cnpjNormalized' is active and cannot be removed. " +
                    'Deactivate it first via Set-PipeCompany.'
                ),
                'ActiveCompanyRemoval',
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                $cnpjNormalized
            )
        )
    }

    $configRoot = Get-StorePath -Scope 'Config' -Cnpj $cnpjNormalized
    $configFile = Join-Path -Path $configRoot -ChildPath "$cnpjNormalized.json"

    if (-not $PSCmdlet.ShouldProcess($configFile, 'Remove company configuration')) {
        return
    }

    Remove-Item -LiteralPath $configFile -Force -ErrorAction Stop

    if (-not $DeleteFiles.IsPresent) {
        return
    }

    $dataRoot = Get-StorePath -Scope 'Root'
    $companyDataDir = Join-Path -Path $dataRoot -ChildPath $cnpjNormalized

    if (-not $PSCmdlet.ShouldProcess($companyDataDir, 'Remove company data')) {
        return
    }

    try {
        Remove-Item -LiteralPath $companyDataDir -Recurse -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
        # A company can legitimately have no data directory.
        # Configuration removal has already succeeded, so this is ignored.
        $null = $_
    } catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                'DataRemovalFailed',
                [System.Management.Automation.ErrorCategory]::PermissionDenied,
                $companyDataDir
            )
        )
    }
}
