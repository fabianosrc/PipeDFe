<#
.SYNOPSIS
Starts and persists a PipeDFe operational audit execution.

.DESCRIPTION
Creates a new execution record in the company audit database with status
'Running' and the current UTC start timestamp.

The function generates a unique ExecutionId and persists the execution
metadata in a single SQLite transaction.

The audit database must already be initialized through Initialize-DFeAudit.

This function stores operational metadata only. It must not receive or
persist XML content, credentials, access tokens, certificate passwords,
or other sensitive payloads.

.PARAMETER Cnpj
14-character normalized CNPJ identifying the company audit database.

.PARAMETER Mode
Execution mode, such as 'Automatic' or 'Manual'.

.PARAMETER RequestedPeriod
Optional textual representation of the requested processing period.

.PARAMETER ModuleVersion
PipeDFe module version associated with the execution.

.OUTPUTS
System.String
Unique execution identifier.

.EXAMPLE
PS C:\> $executionId = Start-DFeAuditExecution -Cnpj '12345678000199'
>> -Mode 'Manual -RequestedPeriod '2026-08' -ModuleVersion '0.1.0'

.NOTES
Private dependencies:
  Get-StorePath
  Open-SqliteConnection
#>
function Start-DFeAuditExecution {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingEmptyCatchBlock',
        '',
        Justification = 'Rollback is best-effort; do not mask the original exception.'
    )]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Internal audit persistence does not modify user-visible state.'
    )]
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[A-Za-z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Mode,

        [Parameter()]
        [AllowEmptyString()]
        [string]$RequestedPeriod,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ModuleVersion
    )

    $normalizedCnpj = $Cnpj.ToUpperInvariant()

    $databasePath = Get-StorePath -Scope 'Audit' -Cnpj $normalizedCnpj

    $executionId = [guid]::NewGuid().ToString('N')
    $startedAt = [System.DateTimeOffset]::UtcNow.ToString(
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
INSERT INTO audit_execution (
    execution_id,
    started_at,
    mode,
    requested_period,
    status,
    module_version
) VALUES (
    @execution_id,
    @started_at,
    @mode,
    @requested_period,
    @status,
    @module_version
);
'@

        $null = $command.Parameters.AddWithValue(
            '@execution_id',
            $executionId
        )

        $null = $command.Parameters.AddWithValue(
            '@started_at',
            $startedAt
        )

        $null = $command.Parameters.AddWithValue(
            '@mode',
            $Mode
        )

        $null = $command.Parameters.AddWithValue(
            '@requested_period',
            $(
                if ([string]::IsNullOrEmpty($RequestedPeriod)) {
                    [System.DBNull]::Value
                } else {
                    $RequestedPeriod
                }
            )
        )

        $null = $command.Parameters.AddWithValue(
            '@status',
            'Running'
        )

        $null = $command.Parameters.AddWithValue(
            '@module_version',
            $ModuleVersion
        )

        $null = $command.ExecuteNonQuery()

        $transaction.Commit()

        $executionId
    } catch {
        if ($null -ne $transaction) {
            try {
                $transaction.Rollback()
            } catch {
                # Rollback is best-effort; preserve the original exception.
            }
        }

        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $_.Exception,
            'AuditExecutionStartFailed',
            [System.Management.Automation.ErrorCategory]::WriteError,
            $databasePath
        )

        $PSCmdlet.ThrowTerminatingError($errorRecord)
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
