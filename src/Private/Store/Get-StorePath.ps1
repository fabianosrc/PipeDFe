<#
.SYNOPSIS
Resolves filesystem paths used by the PipeDFe module.

.DESCRIPTION
Centralizes path resolution for all module-managed storage locations.
Uses %LOCALAPPDATA% and %USERPROFILE% directly - no module-scoped state
is involved.

This function is pure: it performs no I/O and never creates directories.
Callers that need the path to exist must create it explicitly.

.PARAMETER Scope
The storage location to resolve:

  Root    - module root under %LOCALAPPDATA%.
  Company - per-CNPJ root folder. Requires -Cnpj.
  Index   - full path to index.db. Requires -Cnpj.
  Audit   - full path to audit.db. Requires -Cnpj.
  Logs    - per-CNPJ logs folder. Requires -Cnpj.
  Config  - per-CNPJ config folder. Requires -Cnpj.
  Output  - per-CNPJ output folder under %USERPROFILE%. Requires -Cnpj.

.PARAMETER Cnpj
14-digit CNPJ. Required for all scopes except Root.

.EXAMPLE
PS C:\> Get-StorePath -Scope Index -Cnpj '12345678000199'

Returns: C:\Users\user\AppData\Local\PipeDFe\12345678000199\data\index.db

.EXAMPLE
PS C:\> Get-StorePath -Scope Output -Cnpj '12345678000199'

Returns: C:\Users\user\PipeDFe\12345678000199\output

.OUTPUTS
System.String
#>
function Get-StorePath {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Root', 'Company', 'Index', 'Audit', 'Logs', 'Config', 'Output')]
        [string]$Scope,

        [Parameter()]
        [ValidatePattern('^[A-Z0-9]{14}$')]
        [string]$Cnpj
    )

    if ($Scope -ne 'Root' -and [string]::IsNullOrWhiteSpace($Cnpj)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new("Scope '$Scope' requires -Cnpj."),
                'MissingCnpj',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Scope
            )
        )
    }

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    'LOCALAPPDATA environment variable is not available.'
                ),
                'EnvironmentVariableMissing',
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                'LOCALAPPDATA'
            )
        )
    }

    if ($Scope -eq 'Output' -and [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    'USERPROFILE environment variable is not available.'
                ),
                'EnvironmentVariableMissing',
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                'USERPROFILE'
            )
        )
    }

    $root = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'PipeDFe')

    if ($Scope -eq 'Root') {
        return $root
    }

    $companyRoot = [System.IO.Path]::Combine($root, $Cnpj)

    switch ($Scope) {
        'Company' {
            $companyRoot
        }

        'Index' {
            [System.IO.Path]::Combine($companyRoot, 'data', 'index.db')
        }

        'Audit' {
            [System.IO.Path]::Combine($companyRoot, 'data', 'audit.db')
        }

        'Logs' {
            [System.IO.Path]::Combine($companyRoot, 'logs')
        }

        'Config' {
            [System.IO.Path]::Combine($companyRoot, 'config')
        }

        'Output' {
            [System.IO.Path]::Combine($env:USERPROFILE, 'PipeDFe', $Cnpj, 'output')
        }
    }
}
