<#
.SYNOPSIS
Completes a PipeDFe operational audit execution.

.DESCRIPTION
Updates an existing audit execution with its final status, completion
timestamp, and optional error summary.

The execution must already exist in audit_execution.

A successful completion changes the status to 'Succeeded'.

A failed completion changes the status to 'Failed' and may persist an
optional error summary.

The operation is performed inside a SQLite transaction.

This function stores operational metadata only. It must not receive or
persist XML content, credentials, access tokens, certificate passwords,
or other sensitive payloads.

.PARAMETER Cnpj
14-character normalized CNPJ identifying the company audit database.

.PARAMETER ExecutionId
Unique identifier returned by Start-DFeAuditExecution.

.PARAMETER Status
Final execution status. Supported values are 'Succeeded' and 'Failed'.

.PARAMETER ErrorSummary
Optional human-readable summary of the error that caused the execution
to fail. Ignored when Status is 'Succeeded'.

.OUTPUTS
None.

.EXAMPLE
PS C:\> Complete-DFeAuditExecution -Cnpj '12345678000199'
>>      -ExecutionId $executionId -Status 'Succeeded'

.EXAMPLE
PS C:\> Complete-DFeAuditExecution -Cnpj '12345678000199'
>>      -ExecutionId $executionId -Status 'Failed'
>>      -ErrorSummary 'DFeDownloadFailed: Unable to download the DFe.'

.NOTES
Private dependencies:
  Get-StorePath
  Open-SqliteConnection
#>
function Complete-DFeAuditExecution {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingEmptyCatchBlock',
        '',
        Justification = 'Rollback is best-effort; do not mask the original exception.'
    )]
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[A-Za-z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[0-9a-fA-F]{32}$')]
        [string]$ExecutionId,

        [Parameter(Mandatory)]
        [ValidateSet('Succeeded', 'Failed')]
        [string]$Status,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ErrorSummary
    )

    $normalizedCnpj = $Cnpj.ToUpperInvariant()

    $databasePath = Get-StorePath -Scope 'Audit' -Cnpj $normalizedCnpj

    $completedAt = [System.DateTimeOffset]::UtcNow.ToString(
        'yyyy-MM-ddTHH:mm:ss.fffffffK',
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    $connection  = $null
    $command     = $null
    $transaction = $null

    try {
        $connection = Open-SqliteConnection -Path $databasePath

        $transaction = $connection.BeginTransaction()

        $command = $connection.CreateCommand()
        $command.Transaction = $transaction
        $command.CommandText = @'
UPDATE audit_execution
SET
    completed_at  = @completed_at,
    status        = @status,
    error_summary = @error_summary
WHERE execution_id = @execution_id;
'@

        $null = $command.Parameters.AddWithValue('@completed_at',  $completedAt)
        $null = $command.Parameters.AddWithValue('@status',        $Status)
        $null = $command.Parameters.AddWithValue('@execution_id',  $ExecutionId)

        $null = $command.Parameters.AddWithValue(
            '@error_summary',
            $(
                if ([string]::IsNullOrEmpty($ErrorSummary)) {
                    [System.DBNull]::Value
                } else {
                    $ErrorSummary
                }
            )
        )

        $rowsAffected = $command.ExecuteNonQuery()

        if ($rowsAffected -ne 1) {
            throw [System.InvalidOperationException]::new(
                'The specified audit execution does not exist.'
            )
        }

        $transaction.Commit()

    } catch {
        if ($null -ne $transaction) {
            try {
                $transaction.Rollback()
            } catch {
                # Rollback is best-effort; preserve the original exception.
            }
        }

        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                'AuditExecutionCompletionFailed',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $databasePath
            )
        )

    } finally {
        if ($null -ne $command) {
            $command.Dispose()
        }

        if ($null -ne $transaction) {
            $transaction.Dispose()
        }

        if ($null -ne $connection) {
            $connection.Dispose()
        }
    }
}
