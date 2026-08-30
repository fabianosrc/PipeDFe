<#
.SYNOPSIS
Persists a company object to its {cnpj}.json file.

.DESCRIPTION
Serializes a company object to disk using atomic write semantics.

The object shape is defined by ConvertTo-CompanyObject. This function
does not rebuild or validate the shape - it only persists what it
receives.

Certificado.EncryptedPassword must already be DPAPI-encrypted before
calling. Encryption is the caller's responsibility.

Write order (commit-first model):
  1. Serialize to JSON
  2. Write {cnpj}.json.tmp
  3. Atomic replace to {cnpj}.json (source of truth)

If the process fails after step 3 a consistent file already exists on
disk. The .tmp file is cleaned up on any failure before step 3.

Single-writer discipline is assumed. Concurrent writes are not supported.

.PARAMETER Company
The company object to persist. Must expose a non-empty Cnpj property.
The caller's object is never modified.

.PARAMETER AsUpdate
When specified, stamps UpdatedAt with the current UTC timestamp.
Omit on creation so UpdatedAt is preserved as-is from the object.

.OUTPUTS
None.

.EXAMPLE
PS C:\> Save-CompanyConfig -Company $company

.EXAMPLE
PS C:\> Save-CompanyConfig -Company $company -AsUpdate

.NOTES
Private dependencies:
  Get-StorePath
#>
function Save-CompanyConfig {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Company,

        [Parameter()]
        [switch]$AsUpdate
    )

    if ([string]::IsNullOrWhiteSpace($Company.Cnpj)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new('Company.Cnpj is required.'),
                'MissingCnpj',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Company
            )
        )
    }

    $cnpj       = $Company.Cnpj
    $configPath = Get-StorePath -Scope Config -Cnpj $cnpj
    $targetPath = Join-Path -Path $configPath -ChildPath ('{0}.json' -f $cnpj)
    $tempPath   = '{0}.tmp' -f $targetPath

    if (-not (Test-Path -LiteralPath $configPath -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($configPath) | Out-Null
    }

    # Build a JSON-safe hashtable from the company object.
    # ConvertTo-Json on a PSCustomObject round-trips cleanly, but we need
    # to stamp UpdatedAt before serializing when AsUpdate is set.
    # A shallow clone via hashtable avoids mutating the caller's object.
    $record = [ordered]@{}

    foreach ($property in $Company.PSObject.Properties) {
        $record[$property.Name] = $property.Value
    }

    if ($AsUpdate) {
        $record['UpdatedAt'] = [System.DateTimeOffset]::UtcNow.ToString('o')
    }

    # Force email groups to arrays so JSON never serializes a scalar when
    # there is exactly one recipient.
    if ($null -ne $record['Email']) {
        $email = $record['Email']
        $record['Email'] = [ordered]@{
            Para = @($email.Para | Where-Object { $null -ne $_ })
            Cc   = @($email.Cc   | Where-Object { $null -ne $_ })
            Cco  = @($email.Cco  | Where-Object { $null -ne $_ })
        }
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    # Step 1/2 - serialize and write temp file.
    try {
        $json = $record | ConvertTo-Json -Depth 10 -ErrorAction Stop

        [System.IO.File]::WriteAllText($tempPath, $json, $utf8NoBom)
    } catch {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }

        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                'CompanyConfigSaveFailed',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $targetPath
            )
        )
    }

    # Step 3 - commit (atomic replace).
    try {
        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            [System.IO.File]::Replace($tempPath, $targetPath, [NullString]::Value)
        } else {
            [System.IO.File]::Move($tempPath, $targetPath)
        }
    } catch {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }

        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                'CompanyConfigSaveFailed',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $targetPath
            )
        )
    }
}
