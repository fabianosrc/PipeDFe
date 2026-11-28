<#
.SYNOPSIS
Returns a health summary of the PipeDFe installation.

.DESCRIPTION
Checks the health of every active registered company, or a single company
when -Cnpj is supplied. For each company the function verifies whether the
SQLite index exists and whether its schema version matches the version
supported by the module. Versioned legacy indexes require explicit migration.

The function never throws. Any exception raised while inspecting a company
is captured and reported as an issue on that company's health entry.

The overall Status field reflects the worst status among all companies:
  Healthy   - all companies passed every check.
  Degraded  - at least one company has a non-critical issue.
  Unhealthy - at least one company failed a critical check.

When no companies are registered (or no active companies match) the overall
Status is Degraded and a corresponding issue is reported.

.PARAMETER Cnpj
Optional. Company CNPJ. Accepts formatted (XX.XXX.XXX/XXXX-XX) or raw
14-character string. When supplied, the matching company is checked
regardless of its active state.

When omitted, all active registered companies are checked.

.OUTPUTS
System.Management.Automation.PSCustomObject

TypeName: PipeDFe.Health

Properties:
  Status      [string]           - 'Healthy', 'Degraded', or 'Unhealthy'
  CheckedAt   [string]           - UTC timestamp (ISO 8601) of the check
  Companies   [pscustomobject[]] - Per-company health entries

Each entry in Companies is typed PipeDFe.CompanyHealth:
  Cnpj        [string]   - Normalized CNPJ
  Name        [string]   - Company display name
  Status      [string]   - 'Healthy', 'Degraded', or 'Unhealthy'
  DbExists    [bool]     - Whether the index.db file exists
  DbVersion   [int]      - Schema version read from PRAGMA user_version; -1 on error
  DbVersionOk [bool]     - Whether DbVersion matches the module's current schema version
  Issues      [string[]] - List of issues found; empty when Status is Healthy

.EXAMPLE
PS C:\> Get-PipeDFeHealth

.EXAMPLE
PS C:\> Get-PipeDFeHealth -Cnpj '12.345.678/0001-95'

.EXTERNALHELP PipeDFe-help.xml

.NOTES
Private dependencies:
  ConvertTo-NormalizedCnpj
  Get-PipeCompany
  Get-StorePath
  Open-SqliteConnection
#>
function Get-PipeDFeHealth {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter()]
        [string]$Cnpj
    )

    $expectedSchemaVersion = $Script:DFeIndexSchemaVersion

    # Resolve the list of companies to check.
    $companies = @()

    if (-not [string]::IsNullOrWhiteSpace($Cnpj)) {
        $cnpjNormalized = ConvertTo-NormalizedCnpj -Value $Cnpj
        $companies = @(Get-PipeCompany -Cnpj $cnpjNormalized)
    } else {
        $companies = @(Get-PipeCompany -IsActive $true)
    }

    # Build per-company health entries.
    $companyResults = @()

    if ($companies.Count -eq 0) {
        $overallStatus = 'Degraded'

        return [PSCustomObject]@{
            PSTypeName = 'PipeDFe.Health'
            Status     = $overallStatus
            CheckedAt  = [System.DateTime]::UtcNow.ToString('o')
            Companies  = $companyResults
        }
    }

    foreach ($company in $companies) {
        $issues           = [System.Collections.Generic.List[string]]::new()
        $dbExists         = $false
        $dbVersion        = -1
        $dbVersionOk      = $false
        $inspectionFailed = $false

        try {
            $dbPath   = Get-StorePath -Scope 'Index' -Cnpj $company.Cnpj
            $dbExists = Test-Path -LiteralPath $dbPath -PathType Leaf

            if (-not $dbExists) {
                $issues.Add('Index database does not exist. Run Invoke-PipeDFe to initialize.')
            } else {
                $connection = $null

                try {
                    $connection = Open-SqliteConnection -Path $dbPath
                    $command    = $null

                    try {
                        $command             = $connection.CreateCommand()
                        $command.CommandText = 'PRAGMA user_version;'
                        $dbVersion           = [int]$command.ExecuteScalar()
                        $dbVersionOk         = $dbVersion -eq $expectedSchemaVersion

                        if (-not $dbVersionOk) {
                            $guidance = if ($dbVersion -eq 0) {
                                'Verify that the index is empty or compatible before initializing it.'
                            } elseif ($dbVersion -lt $expectedSchemaVersion) {
                                'Automatic migration is not supported. Preserve the existing index ' +
                                'and apply a validated migration before running Invoke-PipeDFe.'
                            } else {
                                'Use a PipeDFe version that supports this index schema.'
                            }

                            $issues.Add(
                                "Index schema version is $dbVersion; expected $expectedSchemaVersion. " +
                                $guidance
                            )
                        }
                    } finally {
                        if ($null -ne $command) {
                            $command.Dispose()
                        }
                    }
                } finally {
                    if ($null -ne $connection) {
                        $connection.Dispose()
                    }
                }
            }
        } catch {
            $inspectionFailed = $true
            $issues.Add("Unexpected error: $($_.Exception.Message)")
        }

        $companyName = [string]$company.RazaoSocial

        $nomeFantasiaProperty = $company.PSObject.Properties['NomeFantasia']

        if ($null -ne $nomeFantasiaProperty) {
            $nomeFantasia = [string]$nomeFantasiaProperty.Value

            if (-not [string]::IsNullOrWhiteSpace($nomeFantasia)) {
                $companyName = $nomeFantasia
            }
        }

        $companyStatus = if ($inspectionFailed -or -not $dbExists) {
            'Unhealthy'
        } elseif (-not $dbVersionOk) {
            'Degraded'
        } else {
            'Healthy'
        }

        $companyResults += [PSCustomObject]@{
            PSTypeName   = 'PipeDFe.CompanyHealth'
            Cnpj         = $company.Cnpj
            Name         = $companyName
            Status       = $companyStatus
            DbExists     = $dbExists
            DbVersion    = $dbVersion
            DbVersionOk  = $dbVersionOk
            Issues       = $issues.ToArray()
        }
    }

    # Derive overall status from worst company status.
    $overallStatus = if ($companyResults | Where-Object { $_.Status -eq 'Unhealthy' }) {
        'Unhealthy'
    } elseif ($companyResults | Where-Object { $_.Status -eq 'Degraded' }) {
        'Degraded'
    } else {
        'Healthy'
    }

    [PSCustomObject]@{
        PSTypeName = 'PipeDFe.Health'
        Status     = $overallStatus
        CheckedAt  = [System.DateTime]::UtcNow.ToString('o')
        Companies  = $companyResults
    }
}
