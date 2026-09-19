<#
.SYNOPSIS
Resolves filesystem paths used by the PipeDFe module.

.DESCRIPTION
Centralizes path resolution for all module-managed storage locations.

By default, PipeDFe preserves its existing per-user storage location:

    %LOCALAPPDATA%\PipeDFe

For unattended/service execution, the storage root can be explicitly
configured through the PIPEDFE_DATA_ROOT environment variable.

For example:

    C:\ProgramData\PipeDFe

When PIPEDFE_DATA_ROOT is defined, all PipeDFe-managed scopes use that root,
including Output.

This function is pure: it performs no I/O and never creates directories.

.PARAMETER Scope
The storage location to resolve:

  Root    - module root.
  Company - per-CNPJ root folder. Requires -Cnpj.
  Index   - full path to index.db. Requires -Cnpj.
  Audit   - full path to audit.db. Requires -Cnpj.
  Logs    - per-CNPJ logs folder. Requires -Cnpj.
  Config  - per-CNPJ config folder. Requires -Cnpj.
  Output  - per-CNPJ output folder. Requires -Cnpj.

.PARAMETER Cnpj
14-character CNPJ. Required for all scopes except Root.

.EXAMPLE
PS C:\> Get-StorePath -Scope Index -Cnpj '12345678000199'

Returns the index path under the configured PipeDFe data root.

.EXAMPLE
PS C:\> $env:PIPEDFE_DATA_ROOT = 'C:\ProgramData\PipeDFe'

PS C:\> Get-StorePath -Scope Output -Cnpj '12345678000199'

Returns:

C:\ProgramData\PipeDFe\12345678000199\output

.NOTES
PIPEDFE_DATA_ROOT is intentionally an explicit operational configuration
point. PipeDFe does not create or modify the environment variable itself.
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

    $configuredRoot = $env:PIPEDFE_DATA_ROOT

    if (-not [string]::IsNullOrWhiteSpace($configuredRoot)) {
        if (-not [System.IO.Path]::IsPathRooted($configuredRoot)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'PIPEDFE_DATA_ROOT must be an absolute filesystem path.'
                    ),
                    'InvalidDataRoot',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $configuredRoot
                )
            )
        }

        $root = [System.IO.Path]::GetFullPath($configuredRoot)
    } else {
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

        $root = [System.IO.Path]::Combine(
            $env:LOCALAPPDATA,
            'PipeDFe'
        )
    }

    if ($Scope -eq 'Root') {
        return $root
    }

    $companyRoot = [System.IO.Path]::Combine($root, $Cnpj)

    switch ($Scope) {
        'Company' {
            $companyRoot
        }

        'Index' {
            [System.IO.Path]::Combine(
                $companyRoot,
                'data',
                'index.db'
            )
        }

        'Audit' {
            [System.IO.Path]::Combine(
                $companyRoot,
                'data',
                'audit.db'
            )
        }

        'Logs' {
            [System.IO.Path]::Combine(
                $companyRoot,
                'logs'
            )
        }

        'Config' {
            [System.IO.Path]::Combine(
                $companyRoot,
                'config'
            )
        }

        'Output' {
            [System.IO.Path]::Combine(
                $companyRoot,
                'output'
            )
        }
    }
}
