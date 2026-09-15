<#
.SYNOPSIS
Returns a health summary of the PipeDFe installation.

.DESCRIPTION
Checks the health of every active registered company, or a single company
when -Cnpj is supplied. For each company the function verifies whether the
SQLite index exists and whether its schema version matches the current
expected version (2).

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
  DbVersionOk [bool]     - Whether DbVersion matches the expected schema version (2)
  Issues      [string[]] - List of issues found; empty when Status is Healthy

.EXAMPLE
PS C:\> Get-PipeDFeHealth

.EXAMPLE
PS C:\> Get-PipeDFeHealth -Cnpj '12.345.678/0001-95'

.NOTES
Private dependencies:
  ConvertTo-NormalizedCnpj
  Get-PipeCompany
  Get-StorePath
  Open-SqliteConnection

Expected schema version: 2.
#>
function Get-PipeDFeHealth {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter()]
        [string]$Cnpj
    )

    $expectedSchemaVersion = 2

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
        $issues    = [System.Collections.Generic.List[string]]::new()
        $dbExists  = $false
        $dbVersion = -1
        $dbVersionOk = $false

        try {
            $dbPath   = Get-StorePath -Scope 'Index' -Cnpj $company.Cnpj
            $dbExists = Test-Path -LiteralPath $dbPath -PathType Leaf

            if (-not $dbExists) {
                $issues.Add('Index database does not exist. Run Invoke-PipeDFe to initialize.')
            } else {
                $connection = $null

                try {
                    $connection  = Open-SqliteConnection -Path $dbPath
                    $command     = $null

                    try {
                        $command             = $connection.CreateCommand()
                        $command.CommandText = 'PRAGMA user_version;'
                        $dbVersion           = [int]$command.ExecuteScalar()
                        $dbVersionOk         = $dbVersion -eq $expectedSchemaVersion

                        if (-not $dbVersionOk) {
                            $issues.Add(
                                "Index schema version is $dbVersion; expected $expectedSchemaVersion. " +
                                'Run Invoke-PipeDFe to upgrade.'
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
            $issues.Add("Unexpected error: $($_.Exception.Message)")
        }

        $companyStatus = if ($issues.Count -eq 0) {
            'Healthy'
        } elseif ($dbExists -and -not $dbVersionOk) {
            'Degraded'
        } else {
            'Unhealthy'
        }

        $companyResults += [PSCustomObject]@{
            PSTypeName   = 'PipeDFe.CompanyHealth'
            Cnpj         = $company.Cnpj
            Name         = $company.Name
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
