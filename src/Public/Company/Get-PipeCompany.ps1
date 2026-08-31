<#
.SYNOPSIS
Retrieves one or all registered companies.

.DESCRIPTION
Returns company configuration objects from the local store.

When -Cnpj is provided, the CNPJ is normalized and the matching company
is returned. Throws CompanyNotFound when the company does not exist.

When -Cnpj is omitted, all registered companies are returned.

When -IsActive is provided, the result is filtered by the active state.
The filter is applied after retrieval and is independent of -Cnpj.

.PARAMETER Cnpj
Company CNPJ. Accepts formatted (XX.XXX.XXX/XXXX-XX) or raw 14-character
alphanumeric string. Normalized before lookup.

When omitted all registered companies are returned.

.PARAMETER IsActive
Optional filter by active state. Only applied when explicitly provided.

.OUTPUTS
System.Management.Automation.PSCustomObject

TypeName: PipeDFe.Company

.EXAMPLE
PS C:\> Get-PipeCompany -Cnpj '12345678000195'

.EXAMPLE
PS C:\> Get-PipeCompany

.EXAMPLE
PS C:\> Get-PipeCompany -IsActive $true

.NOTES
Private dependencies:
  ConvertTo-NormalizedCnpj
  Get-CompanyConfig
#>
function Get-PipeCompany {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter()]
        [string]$Cnpj,

        [Parameter()]
        [bool]$IsActive
    )

    $results = if (-not [string]::IsNullOrWhiteSpace($Cnpj)) {
        $cnpjNormalized = ConvertTo-NormalizedCnpj -Value $Cnpj
        @(Get-CompanyConfig -Cnpj $cnpjNormalized)
    } else {
        @(Get-CompanyConfig)
    }

    if ($PSBoundParameters.ContainsKey('IsActive')) {
        $results = @($results | Where-Object { $_.IsActive -eq $IsActive })
    }

    $results
}
