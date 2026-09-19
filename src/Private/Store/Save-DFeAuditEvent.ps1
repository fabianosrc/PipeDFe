<#
.SYNOPSIS
Persists an operational event in the PipeDFe audit database.

.DESCRIPTION
Stores a single operational event associated with an existing PipeDFe
execution.

The audit database must already be initialized.

This function stores operational metadata only. It must not receive or
persist XML content, credentials, access tokens, certificate passwords,
or other sensitive payloads.

The Cnpj parameter accepts the 14-character alphanumeric CNPJ format,
including the Brazilian alphanumeric CNPJ format introduced for 2026.
The value is normalized to uppercase before persistence.

.PARAMETER Cnpj
14-character normalized CNPJ identifying the company audit database.

.PARAMETER ExecutionId
Unique identifier of the PipeDFe execution associated with the event.

.PARAMETER EventType
Operational event classification.

.PARAMETER Status
Outcome/status associated with the event.

.PARAMETER Message
Human-readable operational message.

.PARAMETER DocumentId
Optional fiscal document identifier associated with the event.

.PARAMETER ErrorCode
Optional stable error classification code.

.PARAMETER DurationMs
Optional event duration in milliseconds.

.PARAMETER Timestamp
Optional event timestamp. Defaults to current UTC time.

.OUTPUTS
None.

.EXAMPLE
PS C:> Save-DFeAuditEvent -Cnpj 'AB12CD34EF56GH'
>> -ExecutionId 'execution-001' -EventType 'DocumentIndexed'
>> -Status 'Success' `
>> -Message 'Document indexed successfully.'

.NOTES
Private dependencies:
Get-StorePath
Open-SqliteConnection
#>
function Save-DFeAuditEvent {
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
        [string]$ExecutionId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$EventType,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Status,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter()]
        [AllowEmptyString()]
        [string]$DocumentId,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ErrorCode,

        [Parameter()]
        [ValidateRange(0, [long]::MaxValue)]
        [long]$DurationMs,

        [Parameter()]
        [System.DateTimeOffset]$Timestamp = [System.DateTimeOffset]::UtcNow
    )

    # CNPJ is an identifier, not a numeric value.
    # Normalize it before resolving the database path and persisting it.
    $normalizedCnpj = $Cnpj.ToUpperInvariant()

    $databasePath = Get-StorePath -Scope 'Audit' -Cnpj $normalizedCnpj

    $connection  = $null
    $command     = $null
    $transaction = $null

    try {
        $connection = Open-SqliteConnection -Path $databasePath

        $transaction = $connection.BeginTransaction()

        $command = $connection.CreateCommand()
        $command.Transaction = $transaction
        $command.CommandText = @'

INSERT INTO audit_event (
execution_id,
timestamp,
company_cnpj,
document_id,
event_type,
status,
message,
error_code,
duration_ms
) VALUES (
@execution_id,
@timestamp,
@company_cnpj,
@document_id,
@event_type,
@status,
@message,
@error_code,
@duration_ms
);
'@

        # Required values.
        $null = $command.Parameters.AddWithValue(
            '@execution_id',
            $ExecutionId
        )

        $null = $command.Parameters.AddWithValue(
            '@timestamp',
            $Timestamp.ToUniversalTime().ToString(
                'yyyy-MM-ddTHH:mm:ss.fffffffK',
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        )

        $null = $command.Parameters.AddWithValue(
            '@company_cnpj',
            $normalizedCnpj
        )

        $null = $command.Parameters.AddWithValue(
            '@event_type',
            $EventType
        )

        $null = $command.Parameters.AddWithValue(
            '@status',
            $Status
        )

        # Optional values.
        $null = $command.Parameters.AddWithValue(
            '@document_id',
            $(
                if ([string]::IsNullOrEmpty($DocumentId)) {
                    [System.DBNull]::Value
                } else {
                    $DocumentId
                }
            )
        )

        $null = $command.Parameters.AddWithValue(
            '@message',
            $(
                if ([string]::IsNullOrEmpty($Message)) {
                    [System.DBNull]::Value
                } else {
                    $Message
                }
            )
        )

        $null = $command.Parameters.AddWithValue(
            '@error_code',
            $(
                if ([string]::IsNullOrEmpty($ErrorCode)) {
                    [System.DBNull]::Value
                } else {
                    $ErrorCode
                }
            )
        )

        $null = $command.Parameters.AddWithValue(
            '@duration_ms',
            $(
                if ($PSBoundParameters.ContainsKey('DurationMs')) {
                    $DurationMs
                } else {
                    [System.DBNull]::Value
                }
            )
        )

        $null = $command.ExecuteNonQuery()

        $transaction.Commit()
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
            'AuditEventSaveFailed',
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
