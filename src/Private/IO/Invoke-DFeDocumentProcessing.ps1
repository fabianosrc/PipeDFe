<#
.SYNOPSIS
Processes one indexed NF-e or NFC-e document.

.DESCRIPTION
Coordinates fiscal processing for one dfe_document entry.

The function:

  1. Validates the supplied index entry.
  2. Moves the persistent state to Processing.
  3. Verifies that the source file SHA-256 still matches the indexed SHA-256.
  4. Loads the XML securely through Import-DFeXml.
  5. Extracts the normalized NF-e/NFC-e fiscal projection.
  6. Verifies that the extracted access key and model match the indexed entry.
  7. Recomputes the source SHA-256 to detect changes during processing.
  8. Persists the fiscal projection through Save-DFeNFeFiscalData.
  9. Moves the persistent state to Processed.

If any failure occurs after the Processing state has been acquired, the
function attempts to move the document to Failed while preserving the
original processing error.

Only NF-e (55) and NFC-e (65) are supported by this processing workflow.
Unsupported models are rejected before any processing-state transition.

This function processes exactly one document. Selection, batching, retry
policy and recovery of abandoned Processing states belong to higher-level
orchestration.

.PARAMETER Cnpj
14-character normalized CNPJ identifying the company index.

.PARAMETER Entry
Document entry returned by Get-DFeDocumentEntry.

The object must expose:
  chave_acesso
  modelo
  file_path
  sha256

.OUTPUTS
None.

.NOTES
Private dependencies:
  Get-FileSha256
  Import-DFeXml
  Get-DFeNFeFiscalData
  Save-DFeNFeFiscalData
  Set-DFeDocumentProcessingState
#>
function Invoke-DFeDocumentProcessing {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^(?-i)[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNull()]
        [pscustomobject]$Entry
    )

    process {
        # Validate the entry contract before changing persistent state.
        foreach ($propertyName in @(
                'chave_acesso', 'modelo', 'file_path', 'sha256')
        ) {
            if ($null -eq $Entry.PSObject.Properties[$propertyName]) {
                $PSCmdlet.ThrowTerminatingError(
                    [System.Management.Automation.ErrorRecord]::new(
                        [System.ArgumentException]::new(
                            "Entry is missing required property '$propertyName'."
                        ),
                        'InvalidDocumentProcessingEntry',
                        [System.Management.Automation.ErrorCategory]::InvalidArgument,
                        $Entry
                    )
                )
            }
        }

        $chaveAcesso = [string]$Entry.chave_acesso
        $filePath    = [string]$Entry.file_path
        $indexedHash = [string]$Entry.sha256

        if ($chaveAcesso -notmatch '^\d{44}$') {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'Entry.chave_acesso must contain exactly 44 digits.'
                    ),
                    'InvalidDocumentProcessingAccessKey',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Entry
                )
            )
        }

        $modelo = 0

        try {
            $modelo = [int]$Entry.modelo
        } catch {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'Entry.modelo must contain a valid fiscal model.'
                    ),
                    'InvalidDocumentProcessingModel',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Entry
                )
            )
        }

        if ($modelo -notin @(55, 65)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.NotSupportedException]::new(
                        "Fiscal model '$modelo' is not supported by " +
                        'the NF-e/NFC-e processing workflow.'
                    ),
                    'UnsupportedDocumentProcessingModel',
                    [System.Management.Automation.ErrorCategory]::NotImplemented,
                    $Entry
                )
            )
        }

        if ([string]::IsNullOrWhiteSpace($filePath)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'Entry.file_path must not be null or empty.'
                    ),
                    'InvalidDocumentProcessingPath',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Entry
                )
            )
        }

        if ($indexedHash -notmatch '^(?i)[a-f0-9]{64}$') {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'Entry.sha256 must contain a valid SHA-256 hash.'
                    ),
                    'InvalidDocumentProcessingHash',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Entry
                )
            )
        }

        # Set-DFeDocumentProcessingState is the authority for deciding whether
        # the current persistent state may transition to Processing.
        $stateParams = @{
            Cnpj        = $Cnpj
            ChaveAcesso = $chaveAcesso
            Status      = 'Processing'
        }

        Set-DFeDocumentProcessingState @stateParams

        # The Processing state has been committed. Any failure from this point
        # must attempt to transition the document to Failed.
        $processingStarted = $true

        try {
            # Verify the physical source before parsing.
            $sourceHashBefore = Get-FileSha256 -Path $filePath

            if (-not $sourceHashBefore.Equals($indexedHash,
                    [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.InvalidDataException]::new(
                        "Source file SHA-256 does not match the indexed " +
                        "SHA-256 for document '$chaveAcesso'."
                    ),
                    'DocumentSourceHashMismatch',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $filePath
                )
            }

            $xml = Import-DFeXml -Path $filePath

            $fiscalData = Get-DFeNFeFiscalData -Xml $xml

            # The indexed document identity remains authoritative for deciding
            # which record is being processed. A path pointing to another valid
            # XML must never cause that other document to be persisted while the
            # original entry is marked Processed.
            if ($fiscalData.ChaveAcesso -ne $chaveAcesso) {
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.InvalidDataException]::new(
                        "The XML access key '$($fiscalData.ChaveAcesso)' " +
                        "does not match indexed document '$chaveAcesso'."
                    ),
                    'DocumentSourceAccessKeyMismatch',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $filePath
                )
            }

            if ([int]$fiscalData.Modelo -ne $modelo) {
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.InvalidDataException]::new(
                        "The XML fiscal model '$([int]$fiscalData.Modelo)' " +
                        "does not match indexed model '$modelo'."
                    ),
                    'DocumentSourceModelMismatch',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $filePath
                )
            }

            # Hash again after parsing. If the source changed while it was being
            # consumed, the extracted fiscal projection must not be persisted.
            $sourceHashAfter = Get-FileSha256 -Path $filePath

            if (-not $sourceHashAfter.Equals($sourceHashBefore,
                    [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.InvalidDataException]::new(
                        "Source file changed while document " +
                        "'$chaveAcesso' was being processed."
                    ),
                    'DocumentSourceChangedDuringProcessing',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $filePath
                )
            }

            $saveParams = @{
                Cnpj         = $Cnpj
                FiscalData   = $fiscalData
                SourceSha256 = $sourceHashAfter
            }

            Save-DFeNFeFiscalData @saveParams

            $stateParams = @{
                Cnpj        = $Cnpj
                ChaveAcesso = $chaveAcesso
                Status      = 'Processed'
            }

            Set-DFeDocumentProcessingState @stateParams

        } catch {
            $processingError = $_

            if ($processingStarted) {
                $errorSummary = '[{0}] {1}' -f (
                    $processingError.FullyQualifiedErrorId,
                    $processingError.Exception.Message
                )

                # Keep the persistent failure summary bounded. The original
                # ErrorRecord remains the authoritative error returned to the
                # caller.
                if ($errorSummary.Length -gt 4000) {
                    $errorSummary = $errorSummary.Substring(0, 4000)
                }

                try {
                    $failedStateParams = @{
                        Cnpj         = $Cnpj
                        ChaveAcesso  = $chaveAcesso
                        Status       = 'Failed'
                        ErrorMessage = $errorSummary
                    }

                    Set-DFeDocumentProcessingState @failedStateParams
                } catch {
                    # Failure to persist Failed must not hide the processing
                    # exception that caused it. Recovery/logging will handle
                    # documents that remain in Processing.
                    Write-Warning (
                        "Failed to persist processing failure state for " +
                        "document '$chaveAcesso': $($_.Exception.Message)"
                    )
                }
            }

            $PSCmdlet.ThrowTerminatingError($processingError)
        }
    }
}
