<#
.SYNOPSIS
Marks an observed Processing attempt as Failed using compare-and-swap semantics.

.DESCRIPTION
Updates a document from Processing to Failed only when the persisted
processing_started_at value still matches the value observed by the caller.

The processing status and processing_started_at value are compared in the
same atomic UPDATE. This prevents an abandoned processing recovery from
overwriting a newer Processing attempt after an ABA state sequence.

A null ExpectedProcessingStartedAt matches only a persisted NULL value.
Non-null values are compared exactly as stored.

.PARAMETER Cnpj
14-character normalized CNPJ identifying the company index.

.PARAMETER ChaveAcesso
44-digit fiscal access key identifying the document.

.PARAMETER ExpectedProcessingStartedAt
Exact processing_started_at value observed before recovery.

May be null when the observed Processing state had no timestamp.

.PARAMETER ErrorMessage
Processing recovery error persisted when the observed attempt is marked
as Failed.

.OUTPUTS
None.

.NOTES
Private dependencies:
  Open-DFeIndexConnection

Errors:
  ConcurrentProcessingStateChange
  DocumentProcessingRecoveryStateUpdateFailed
  InvalidExpectedProcessingStartedAt
  MissingProcessingRecoveryError
#>
function Repair-DFeDocumentProcessingState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'State changes are controlled by the processing recovery workflow.'
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
        [AllowNull()]
        [object]$ExpectedProcessingStartedAt,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ErrorMessage
    )

    if ($null -ne $ExpectedProcessingStartedAt -and
        $ExpectedProcessingStartedAt -isnot [string]) {

        throw [System.Management.Automation.ErrorRecord]::new(
            [System.ArgumentException]::new(
                'ExpectedProcessingStartedAt must be null or a string.'
            ),
            'InvalidExpectedProcessingStartedAt',
            [System.Management.Automation.ErrorCategory]::InvalidArgument,
            $ExpectedProcessingStartedAt
        )
    }

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.ArgumentException]::new(
                'ErrorMessage must not be null, empty, or whitespace.'
            ),
            'MissingProcessingRecoveryError',
            [System.Management.Automation.ErrorCategory]::InvalidArgument,
            $ErrorMessage
        )
    }

    $connection = $null
    $command = $null
    $rowsAffected = $null

    try {
        $connection = Open-DFeIndexConnection -Cnpj $Cnpj
        $command = $connection.CreateCommand()

        $command.CommandText = @'
UPDATE dfe_document
SET
    processing_status = 'Failed',
    processed_at = NULL,
    processing_error = @processing_error
WHERE
    chave_acesso = @chave_acesso
    AND processing_status = 'Processing'
    AND (
        (
            @expected_processing_started_at IS NULL
            AND processing_started_at IS NULL
        )
        OR processing_started_at = @expected_processing_started_at
    );
'@

        $chaveParam = $command.Parameters.Add(
            '@chave_acesso',
            [System.Data.DbType]::String
        )

        $chaveParam.Value = $ChaveAcesso

        $expectedStartedAtParam = $command.Parameters.Add(
            '@expected_processing_started_at',
            [System.Data.DbType]::String
        )

        if ($null -eq $ExpectedProcessingStartedAt) {
            $expectedStartedAtParam.Value = [System.DBNull]::Value
        } else {
            $expectedStartedAtParam.Value = [string]$ExpectedProcessingStartedAt
        }

        $errorParam = $command.Parameters.Add(
            '@processing_error',
            [System.Data.DbType]::String
        )

        $errorParam.Value = $ErrorMessage

        $rowsAffected = $command.ExecuteNonQuery()
    } catch {
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.IO.IOException]::new(
                "Failed to repair the processing state of document '$ChaveAcesso'.",
                $_.Exception
            ),
            'DocumentProcessingRecoveryStateUpdateFailed',
            [System.Management.Automation.ErrorCategory]::WriteError,
            $ChaveAcesso
        )
    } finally {
        if ($null -ne $command) {
            $command.Dispose()
        }

        if ($null -ne $connection) {
            $connection.Dispose()
        }
    }

    if ($rowsAffected -eq 0) {
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new(
                "The processing attempt of document '$ChaveAcesso' changed before recovery."
            ),
            'ConcurrentProcessingStateChange',
            [System.Management.Automation.ErrorCategory]::WriteError,
            $ChaveAcesso
        )
    }

    if ($rowsAffected -ne 1) {
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new(
                "Processing recovery affected $rowsAffected rows for document '$ChaveAcesso'."
            ),
            'DocumentProcessingRecoveryStateUpdateFailed',
            [System.Management.Automation.ErrorCategory]::WriteError,
            $ChaveAcesso
        )
    }
}
