<#
.SYNOPSIS
Updates the persistent processing state of an indexed fiscal document.

.DESCRIPTION
Applies controlled processing-state transitions to a document stored in the
CNPJ-specific index database.

Allowed transitions:

    Indexed    -> Processing
    Processing -> Processed
    Processing -> Failed
    Failed     -> Processing

The current state is read inside the same transaction used by the update.
The UPDATE also includes the expected current state, preventing a stale
state decision from overwriting a concurrent state change.

All timestamps are stored as UTC ISO 8601 round-trip strings.

.PARAMETER Cnpj
14-digit normalized CNPJ identifying the company index.

.PARAMETER ChaveAcesso
44-digit fiscal access key identifying the document.

.PARAMETER Status
Target processing status.

.PARAMETER ErrorMessage
Processing error summary. Required when Status is Failed.

.OUTPUTS
None.

.EXAMPLE
PS C:\> $stateParams = @{
    Cnpj        = '12345678000199'
    ChaveAcesso = '35260912345678000199550010000000011234567890'
    Status      = 'Processing'
}

PS C:\> Set-DFeDocumentProcessingState @stateParams

.NOTES
Private dependencies:
  Open-DFeIndexConnection
#>
function Set-DFeDocumentProcessingState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'State changes are controlled by the public processing workflow.'
    )]
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
        [ValidatePattern('^(?-i)[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^\d{44}$')]
        [string]$ChaveAcesso,

        [Parameter(Mandatory)]
        [ValidateSet('Processing', 'Processed', 'Failed')]
        [string]$Status,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ErrorMessage
    )

    if ($Status -eq 'Failed' -and
        [string]::IsNullOrWhiteSpace($ErrorMessage)) {

        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'ErrorMessage is required when Status is Failed.'
                ),
                'MissingProcessingError',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Status
            )
        )
    }

    if ($Status -ne 'Failed' -and -not [string]::IsNullOrEmpty($ErrorMessage)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'ErrorMessage can only be specified when Status is Failed.'
                ),
                'UnexpectedProcessingError',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Status
            )
        )
    }

    $connection  = $null
    $transaction = $null
    $selectCmd   = $null
    $updateCmd   = $null
    $reader      = $null

    try {
        $connection  = Open-DFeIndexConnection -Cnpj $Cnpj
        $transaction = $connection.BeginTransaction()

        # Read the current state inside the same transaction.
        $selectCmd = $connection.CreateCommand()
        $selectCmd.Transaction = $transaction
        $selectCmd.CommandText = @'
SELECT processing_status
FROM dfe_document
WHERE chave_acesso = @chave_acesso;
'@

        $selectChaveParam = $selectCmd.Parameters.Add(
            '@chave_acesso',
            [System.Data.DbType]::String
        )

        $selectChaveParam.Value = $ChaveAcesso

        $reader = $selectCmd.ExecuteReader()

        try {
            if (-not $reader.Read()) {
                # Caught below and mapped to DocumentNotFound.
                throw [System.Management.Automation.RuntimeException]::new(
                    "The specified document '$ChaveAcesso' does not exist."
                )
            }

            $statusValue = $reader['processing_status']

            if ($statusValue -is [System.DBNull]) {
                # Caught below and mapped to InvalidProcessingState.
                throw [System.Management.Automation.RuntimeException]::new(
                    "The processing status of document '$ChaveAcesso' is NULL."
                )
            }

            $currentStatus = [string]$statusValue
        } finally {
            $reader.Dispose()
            $reader = $null
        }

        $selectCmd.Dispose()
        $selectCmd = $null

        # Validate the state transition.
        $transitionAllowed = switch ($currentStatus) {
            'Indexed' {
                $Status -eq 'Processing'
            }

            'Processing' {
                $Status -in @('Processed', 'Failed')
            }

            'Failed' {
                $Status -eq 'Processing'
            }

            'Processed' {
                $false
            }

            default {
                # Caught below and mapped to UnsupportedProcessingState.
                throw [System.Management.Automation.RuntimeException]::new(
                    "Document '$ChaveAcesso' has unsupported processing state '$currentStatus'."
                )
            }
        }

        if (-not $transitionAllowed) {
            # Caught below and mapped to InvalidProcessingStateTransition.
            throw [System.Management.Automation.RuntimeException]::new(
                "Invalid processing state transition from '$currentStatus' to '$Status'."
            )
        }

        # ---------------------------------------------------------------------
        # Generate exactly one UTC timestamp for this transition.
        # ---------------------------------------------------------------------
        $timestamp = [System.DateTimeOffset]::UtcNow.ToString(
            'o',
            [System.Globalization.CultureInfo]::InvariantCulture
        )

        # ---------------------------------------------------------------------
        # Build transition-specific guarded UPDATE.
        #
        # The expected current state is part of the WHERE clause so that a
        # concurrent state change made after the SELECT causes rowsAffected
        # to be 0 rather than silently overwriting the newer state.
        # ---------------------------------------------------------------------
        switch ($Status) {
            'Processing' {
                $updateSql = @'
UPDATE dfe_document
SET
    processing_status = @processing_status,
    processing_started_at = @processing_started_at,
    processed_at = NULL,
    processing_error = NULL
WHERE
    chave_acesso = @chave_acesso
    AND processing_status = @expected_status;
'@
            }

            'Processed' {
                $updateSql = @'
UPDATE dfe_document
SET
    processing_status = @processing_status,
    processed_at = @processed_at,
    processing_error = NULL
WHERE
    chave_acesso = @chave_acesso
    AND processing_status = @expected_status;
'@
            }

            'Failed' {
                $updateSql = @'
UPDATE dfe_document
SET
    processing_status = @processing_status,
    processed_at = NULL,
    processing_error = @processing_error
WHERE
    chave_acesso = @chave_acesso
    AND processing_status = @expected_status;
'@
            }
        }

        $updateCmd = $connection.CreateCommand()

        $updateCmd.Transaction = $transaction
        $updateCmd.CommandText = $updateSql

        $updateStatusParam = $updateCmd.Parameters.Add(
            '@processing_status',
            [System.Data.DbType]::String
        )

        $updateStatusParam.Value = $Status

        $updateExpectedParam = $updateCmd.Parameters.Add(
            '@expected_status',
            [System.Data.DbType]::String
        )

        $updateExpectedParam.Value = $currentStatus

        $updateChaveParam = $updateCmd.Parameters.Add(
            '@chave_acesso',
            [System.Data.DbType]::String
        )

        $updateChaveParam.Value = $ChaveAcesso

        switch ($Status) {
            'Processing' {
                $tsParam = $updateCmd.Parameters.Add(
                    '@processing_started_at',
                    [System.Data.DbType]::String
                )

                $tsParam.Value = $timestamp
            }

            'Processed' {
                $tsParam = $updateCmd.Parameters.Add(
                    '@processed_at',
                    [System.Data.DbType]::String
                )

                $tsParam.Value = $timestamp
            }

            'Failed' {
                $errParam = $updateCmd.Parameters.Add(
                    '@processing_error',
                    [System.Data.DbType]::String
                )

                $errParam.Value = $ErrorMessage
            }
        }

        $rowsAffected = $updateCmd.ExecuteNonQuery()

        if ($rowsAffected -ne 1) {
            # Caught below and mapped to ConcurrentProcessingStateChange.
            throw [System.Management.Automation.RuntimeException]::new(
                "The processing state of document '$ChaveAcesso' " +
                'changed before the update could be applied.'
            )
        }

        $transaction.Commit()

    } catch {
        $originalException = $_.Exception

        if ($null -ne $transaction) {
            try {
                $transaction.Rollback()
            } catch {
                # Rollback is best-effort; preserve the original exception.
            }
        }

        # ---------------------------------------------------------------------
        # Map domain failures to stable ErrorIds by exception type and
        # message. Using message matching here is intentional: these
        # RuntimeExceptions are thrown above with literal messages owned by
        # this function, so there is no external string dependency.
        # ---------------------------------------------------------------------
        $errorId = switch ($originalException.Message) {
            { $_ -eq "The specified document '$ChaveAcesso' does not exist." } {
                'DocumentNotFound'
            }

            { $_ -like "Invalid processing state transition from *" } {
                'InvalidProcessingStateTransition'
            }

            { $_ -like "Document '$ChaveAcesso' has unsupported processing state *" } {
                'UnsupportedProcessingState'
            }

            { $_ -eq "The processing status of document '$ChaveAcesso' is NULL." } {
                'InvalidProcessingState'
            }

            { $_ -like "The processing state of document '$ChaveAcesso' changed*" } {
                'ConcurrentProcessingStateChange'
            }

            default {
                'DocumentProcessingStateUpdateFailed'
            }
        }

        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $originalException,
                $errorId,
                [System.Management.Automation.ErrorCategory]::WriteError,
                $ChaveAcesso
            )
        )
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }

        if ($null -ne $selectCmd) {
            $selectCmd.Dispose()
        }

        if ($null -ne $updateCmd) {
            $updateCmd.Dispose()
        }

        if ($null -ne $transaction) {
            $transaction.Dispose()
        }

        if ($null -ne $connection) {
            $connection.Dispose()
        }
    }
}
