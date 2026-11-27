<#
.SYNOPSIS
Applies a guarded lifecycle transition to a persistent DFe delivery.

.DESCRIPTION
Applies only the supported delivery lifecycle transitions:

    Prepared      -> Sending
    Failed        -> Sending
    Sending       -> Delivered
    Sending       -> Failed
    Sending       -> Indeterminate
    Indeterminate -> Delivered or Failed with an operator resolution reason

The caller supplies the state and delivery_started_at value it observed.
Both values are compared by the UPDATE statement, preventing stale operations
from overwriting a newer state or a newer sending attempt.

The delivery_started_at value is also used as an attempt token. A retry from
Failed always receives a timestamp later than the previous attempt, preventing
an ABA sequence from accepting a late result from an earlier send attempt.

An operator resolution preserves the previous SMTP error and the decision
in the index database in the same transaction as the state update.

All timestamps are stored as UTC ISO 8601 round-trip strings.

.PARAMETER Cnpj
14-character normalized CNPJ identifying the company index.

.PARAMETER DeliveryId
32-character lowercase hexadecimal delivery identifier.

.PARAMETER ExpectedStatus
Exact delivery status observed by the caller before this transition.

.PARAMETER ExpectedDeliveryStartedAt
Exact delivery_started_at value observed by the caller.
Must be null only when ExpectedStatus is Prepared.

.PARAMETER Status
Target delivery status.

.PARAMETER ErrorMessage
Required when Status is Failed or Indeterminate. Not accepted for other
target states.

.PARAMETER ResolutionReason
Required when resolving Indeterminate. Records why the operator confirmed
acceptance or non-acceptance.

.OUTPUTS
System.Management.Automation.PSCustomObject

PSTypeName:
  PipeDFe.DeliveryStateTransition

Properties:
  Cnpj
  DeliveryId
  PreviousStatus
  DeliveryStatus
  UpdatedAt
  DeliveryStartedAt
  DeliveredAt
  DeliveryError

.NOTES
Private dependencies:
  Open-DFeIndexConnection

Errors:
  ConcurrentDeliveryStateChange
  DeliveryNotFound
  DeliveryStateUpdateFailed
  InvalidDeliveryStateTransition
  InvalidExpectedDeliveryStartedAt
  MissingDeliveryStateError
  UnexpectedDeliveryStateError
#>
function Set-DFeDeliveryState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'State changes are controlled by the delivery workflow.'
    )]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingEmptyCatchBlock',
        '',
        Justification = 'Rollback is best-effort; do not mask the original exception.'
    )]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^(?-i)[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^(?-i)[0-9a-f]{32}$')]
        [string]$DeliveryId,

        [Parameter(Mandatory)]
        [ValidateSet('Prepared', 'Sending', 'Failed', 'Indeterminate')]
        [string]$ExpectedStatus,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$ExpectedDeliveryStartedAt,

        [Parameter(Mandatory)]
        [ValidateSet('Sending', 'Delivered', 'Failed', 'Indeterminate')]
        [string]$Status,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ErrorMessage,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ResolutionReason
    )

    # Normalize ValidateSet values before writing them to the case-sensitive
    # SQLite CHECK constraint.
    $ExpectedStatus = switch ($ExpectedStatus.ToLowerInvariant()) {
        'prepared'      { 'Prepared'      }
        'sending'       { 'Sending'       }
        'failed'        { 'Failed'        }
        'indeterminate' { 'Indeterminate' }
    }

    $Status = switch ($Status.ToLowerInvariant()) {
        'sending'       { 'Sending'       }
        'delivered'     { 'Delivered'     }
        'failed'        { 'Failed'        }
        'indeterminate' { 'Indeterminate' }
    }

    #region Transition validation
    $transitionAllowed = switch ($ExpectedStatus) {
        'Prepared' {
            $Status -eq 'Sending'
        }

        'Failed' {
            $Status -eq 'Sending'
        }

        'Sending' {
            $Status -in @('Delivered', 'Failed', 'Indeterminate')
        }

        'Indeterminate' {
            $Status -in @('Delivered', 'Failed')
        }
    }

    if (-not $transitionAllowed) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "Invalid delivery state transition from '$ExpectedStatus' to '$Status'."
                ),
                'InvalidDeliveryStateTransition',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $DeliveryId
            )
        )
    }

    $isResolution = $ExpectedStatus -eq 'Indeterminate'

    if ($isResolution -and [string]::IsNullOrWhiteSpace($ResolutionReason)) {
        throw [System.ArgumentException]::new(
            'ResolutionReason is required when resolving an Indeterminate delivery.',
            'ResolutionReason'
        )
    }

    if (-not $isResolution -and $PSBoundParameters.ContainsKey('ResolutionReason')) {
        throw [System.ArgumentException]::new(
            'ResolutionReason applies only to Indeterminate deliveries.',
            'ResolutionReason'
        )
    }

    if ($Status -in @('Failed', 'Indeterminate')) {
        if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "ErrorMessage is required when Status is '$Status'."
                    ),
                    'MissingDeliveryStateError',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Status
                )
            )
        }
    } elseif (-not [string]::IsNullOrEmpty($ErrorMessage)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'ErrorMessage can only be specified when Status is Failed or Indeterminate.'
                ),
                'UnexpectedDeliveryStateError',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Status
            )
        )
    }

    $invariantCulture        = [System.Globalization.CultureInfo]::InvariantCulture
    $parsedExpectedStartedAt = $null
    $expectedStartedAtText   = $null

    if ($null -eq $ExpectedDeliveryStartedAt) {
        if ($ExpectedStatus -ne 'Prepared') {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'ExpectedDeliveryStartedAt is required after a delivery has started.'
                    ),
                    'InvalidExpectedDeliveryStartedAt',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $ExpectedDeliveryStartedAt
                )
            )
        }
    } else {
        if ($ExpectedDeliveryStartedAt -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$ExpectedDeliveryStartedAt)) {

            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'ExpectedDeliveryStartedAt must be null or an ISO 8601 round-trip string.'
                    ),
                    'InvalidExpectedDeliveryStartedAt',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $ExpectedDeliveryStartedAt
                )
            )
        }

        $parsedValue = [System.DateTimeOffset]::MinValue

        $parseSucceeded = [System.DateTimeOffset]::TryParseExact(
            [string]$ExpectedDeliveryStartedAt,
            'o',
            $invariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsedValue
        )

        if (-not $parseSucceeded -or $parsedValue.Offset -ne [System.TimeSpan]::Zero) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'ExpectedDeliveryStartedAt must be a UTC ISO 8601 round-trip string.'
                    ),
                    'InvalidExpectedDeliveryStartedAt',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $ExpectedDeliveryStartedAt
                )
            )
        }

        if ($ExpectedStatus -eq 'Prepared') {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'ExpectedDeliveryStartedAt must be null when ExpectedStatus is Prepared.'
                    ),
                    'InvalidExpectedDeliveryStartedAt',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $ExpectedDeliveryStartedAt
                )
            )
        }

        $parsedExpectedStartedAt = $parsedValue
        $expectedStartedAtText   = [string]$ExpectedDeliveryStartedAt
    }
    #endregion

    #region Transition values
    $transitionTime = [System.DateTimeOffset]::UtcNow

    if ($Status -eq 'Sending' -and $null -ne $parsedExpectedStartedAt) {
        $previousAttemptUtc = $parsedExpectedStartedAt.ToUniversalTime()

        # Guarantee a new attempt token even if the system clock has not
        # advanced since the previous delivery_started_at value.
        if ($transitionTime -le $previousAttemptUtc) {
            $transitionTime = $previousAttemptUtc.AddTicks(1)
        }
    }

    $timestamp = $transitionTime.ToString('o', $invariantCulture)
    $updatedAt = $timestamp
    #endregion

    #region Transition SQL
    $updateSql = switch ($Status) {
        'Sending' {
            @'
UPDATE dfe_delivery
SET
    delivery_status = @status,
    delivery_started_at = @transition_at,
    delivered_at = NULL,
    delivery_error = NULL,
    updated_at = @updated_at
WHERE
    delivery_id = @delivery_id
    AND delivery_status = @expected_status
    AND (
        (@expected_started_at IS NULL AND delivery_started_at IS NULL)
        OR delivery_started_at = @expected_started_at
    );
'@
        }

        'Delivered' {
            @'
UPDATE dfe_delivery
SET
    delivery_status = @status,
    delivered_at = @transition_at,
    delivery_error = NULL,
    updated_at = @updated_at
WHERE
    delivery_id = @delivery_id
    AND delivery_status = @expected_status
    AND delivery_started_at = @expected_started_at;
'@
        }

        { $_ -in @('Failed', 'Indeterminate') } {
            @'
UPDATE dfe_delivery
SET
    delivery_status = @status,
    delivered_at = NULL,
    delivery_error = @delivery_error,
    updated_at = @updated_at
WHERE
    delivery_id = @delivery_id
    AND delivery_status = @expected_status
    AND delivery_started_at = @expected_started_at;
'@
        }
    }
    #endregion

    $connection    = $null
    $transaction   = $null
    $command       = $null
    $lookupCommand = $null
    $selectCommand = $null
    $reader        = $null

    $domainErrorId    = $null
    $transitionResult = $null

    try {
        $connection = Open-DFeIndexConnection -Cnpj $Cnpj
        $transaction = $connection.BeginTransaction()

        if ($isResolution) {
            # Provision the resolution log for existing v8 indexes in the same
            # transaction as the first resolution.
            $resolutionCommand = $connection.CreateCommand()

            try {

                $resolutionCommand.Transaction = $transaction
                $resolutionCommand.CommandText = @'
CREATE TABLE IF NOT EXISTS dfe_delivery_resolution (
    delivery_id         TEXT NOT NULL,
    delivery_started_at TEXT NOT NULL,
    resolved_at         TEXT NOT NULL,
    resolution_status   TEXT NOT NULL CHECK (resolution_status IN ('Delivered', 'Failed')),
    reason              TEXT NOT NULL,
    previous_error      TEXT,
    PRIMARY KEY (delivery_id, delivery_started_at),
    FOREIGN KEY (delivery_id) REFERENCES dfe_delivery (delivery_id)
        ON DELETE CASCADE
);
'@

                $null = $resolutionCommand.ExecuteNonQuery()

                $resolutionCommand.CommandText = @'
INSERT INTO dfe_delivery_resolution (
    delivery_id,
    delivery_started_at,
    resolved_at,
    resolution_status,
    reason,
    previous_error
) SELECT
    delivery_id,
    delivery_started_at,
    @resolved_at,
    @status,
    @reason,
    delivery_error
FROM dfe_delivery
WHERE delivery_id = @delivery_id
    AND delivery_status = 'Indeterminate'
    AND delivery_started_at = @expected_started_at;
'@

                $resolutionCommand.Parameters.AddWithValue('@resolved_at', $timestamp)   | Out-Null
                $resolutionCommand.Parameters.AddWithValue('@status', $Status)           | Out-Null
                $resolutionCommand.Parameters.AddWithValue('@reason', $ResolutionReason) | Out-Null
                $resolutionCommand.Parameters.AddWithValue('@delivery_id', $DeliveryId)  | Out-Null
                $resolutionCommand.Parameters.AddWithValue(
                    '@expected_started_at',
                    $expectedStartedAtText
                ) | Out-Null

                $resolutionRows = [int]$resolutionCommand.ExecuteNonQuery()
            } finally {
                $resolutionCommand.Dispose()
            }
        }

        $command = $connection.CreateCommand()
        $command.Transaction = $transaction
        $command.CommandText = $updateSql

        $command.Parameters.AddWithValue('@status', $Status)                  | Out-Null
        $command.Parameters.AddWithValue('@updated_at', $updatedAt)           | Out-Null
        $command.Parameters.AddWithValue('@delivery_id', $DeliveryId)         | Out-Null
        $command.Parameters.AddWithValue('@expected_status', $ExpectedStatus) | Out-Null

        $expectedStartedParam = $command.Parameters.Add(
            '@expected_started_at',
            [System.Data.DbType]::String
        )

        if ($null -eq $expectedStartedAtText) {
            $expectedStartedParam.Value = [System.DBNull]::Value
        } else {
            $expectedStartedParam.Value = $expectedStartedAtText
        }

        if ($Status -in @('Sending', 'Delivered')) {
            $command.Parameters.AddWithValue(
                '@transition_at',
                $timestamp
            ) | Out-Null
        }

        if ($Status -in @('Failed', 'Indeterminate')) {
            $command.Parameters.AddWithValue(
                '@delivery_error',
                $ErrorMessage
            ) | Out-Null
        }

        $rowsAffected = [int]$command.ExecuteNonQuery()

        if ($rowsAffected -eq 0) {
            $lookupCommand = $connection.CreateCommand()
            $lookupCommand.Transaction = $transaction
            $lookupCommand.CommandText = @'
SELECT delivery_status
FROM dfe_delivery
WHERE delivery_id = @delivery_id;
'@

            $lookupCommand.Parameters.AddWithValue(
                '@delivery_id',
                $DeliveryId
            ) | Out-Null

            $currentStatus = $lookupCommand.ExecuteScalar()

            if ($null -eq $currentStatus -or $currentStatus -is [System.DBNull]) {
                $domainErrorId = 'DeliveryNotFound'

                throw [System.InvalidOperationException]::new(
                    "Delivery '$DeliveryId' does not exist."
                )
            }

            $domainErrorId = 'ConcurrentDeliveryStateChange'

            throw [System.InvalidOperationException]::new(
                "Delivery '$DeliveryId' changed from the expected state or attempt."
            )
        }

        if ($rowsAffected -ne 1) {
            throw [System.InvalidOperationException]::new(
                "Delivery state update affected $rowsAffected rows for '$DeliveryId'."
            )
        }

        if ($isResolution -and $resolutionRows -ne 1) {
            throw [System.InvalidOperationException]::new(
                "The resolution log did not record the state change for delivery '$DeliveryId'."
            )
        }

        $selectCommand = $connection.CreateCommand()
        $selectCommand.Transaction = $transaction
        $selectCommand.CommandText = @'
SELECT
    delivery_status,
    updated_at,
    delivery_started_at,
    delivered_at,
    delivery_error
FROM dfe_delivery
WHERE delivery_id = @delivery_id;
'@

        $selectCommand.Parameters.AddWithValue(
            '@delivery_id',
            $DeliveryId
        ) | Out-Null

        $reader = $selectCommand.ExecuteReader()

        try {
            if (-not $reader.Read()) {
                throw [System.InvalidOperationException]::new(
                    "Delivery '$DeliveryId' disappeared after its state was updated."
                )
            }

            $storedStartedAt = if ($reader.IsDBNull(2)) {
                $null
            } else {
                $reader.GetString(2)
            }

            $storedDeliveredAt = if ($reader.IsDBNull(3)) {
                $null
            } else {
                $reader.GetString(3)
            }

            $storedError = if ($reader.IsDBNull(4)) {
                $null
            } else {
                $reader.GetString(4)
            }

            $transitionResult = [pscustomobject]@{
                PSTypeName        = 'PipeDFe.DeliveryStateTransition'
                Cnpj              = $Cnpj
                DeliveryId        = $DeliveryId
                PreviousStatus    = $ExpectedStatus
                DeliveryStatus    = $reader.GetString(0)
                UpdatedAt         = $reader.GetString(1)
                DeliveryStartedAt = $storedStartedAt
                DeliveredAt       = $storedDeliveredAt
                DeliveryError     = $storedError
            }
        } finally {
            $reader.Dispose()
            $reader = $null
        }

        $transaction.Commit()
    } catch {
        $originalException = $_.Exception

        if ($null -ne $transaction) {
            try {
                $transaction.Rollback()
            } catch {
                # Preserve the original state update error.
            }
        }

        $errorId = if ($null -ne $domainErrorId) {
            $domainErrorId
        } else {
            'DeliveryStateUpdateFailed'
        }

        $category = if ($errorId -eq 'DeliveryNotFound') {
            [System.Management.Automation.ErrorCategory]::ObjectNotFound
        } else {
            [System.Management.Automation.ErrorCategory]::WriteError
        }

        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $originalException,
                $errorId,
                $category,
                $DeliveryId
            )
        )
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }

        if ($null -ne $command) {
            $command.Dispose()
        }

        if ($null -ne $lookupCommand) {
            $lookupCommand.Dispose()
        }

        if ($null -ne $selectCommand) {
            $selectCommand.Dispose()
        }

        if ($null -ne $transaction) {
            $transaction.Dispose()
        }

        if ($null -ne $connection) {
            $connection.Dispose()
        }
    }

    $transitionResult
}
