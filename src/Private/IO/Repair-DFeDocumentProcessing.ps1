<#
.SYNOPSIS
Repairs abandoned document processing states.

.DESCRIPTION
Finds documents currently stored with processing_status = Processing and
moves abandoned processing attempts to Failed.

A processing attempt is considered abandoned when processing_started_at is
older than or equal to ReferenceTime minus AbandonAfter.

A Processing document whose processing_started_at value is missing or invalid
is also moved to Failed because the persistent state is inconsistent and
cannot be safely classified as an active processing attempt.

This function does not retry Failed documents. Its only responsibility is to
repair abandoned or inconsistent Processing states.

Concurrent state changes are tolerated. If another operation changes a
document after it is selected for repair, the document is left in its newer
state.

.PARAMETER Cnpj
14-character normalized CNPJ identifying the company index.

.PARAMETER AbandonAfter
Maximum allowed duration for a Processing state before it is considered
abandoned. Must be greater than zero.

.PARAMETER ReferenceTime
Reference instant used to calculate the abandonment threshold.

Defaults to UtcNow. This parameter exists primarily to make repair behavior
deterministic and testable.

.OUTPUTS
System.Management.Automation.PSCustomObject

PSTypeName:
  PipeDFe.DocumentProcessingRecoveryResult

Properties:
  ProcessingFound     - [int]
  Active              - [int]
  Recovered           - [int]
  Inconsistent        - [int]
  ConcurrentlyChanged - [int]

.EXAMPLE
PS C:\> $repairParams = @{
    Cnpj         = '12345678000199'
    AbandonAfter = [System.TimeSpan]::FromMinutes(30)
}

PS C:\> $result = Repair-DFeDocumentProcessing @repairParams

PS C:\> Write-Host "Recovered: $($result.Recovered)"

.NOTES
Private dependencies:
  Get-DFeDocumentEntry
  Set-DFeDocumentProcessingState
#>
function Repair-DFeDocumentProcessing {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^(?-i)[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateScript(
            {
                if ($_ -le [System.TimeSpan]::Zero) {
                    throw 'AbandonAfter must be greater than zero.'
                }

                $true
            }
        )]
        [System.TimeSpan]$AbandonAfter,

        [Parameter()]
        [System.DateTimeOffset]$ReferenceTime = [System.DateTimeOffset]::UtcNow
    )

    $processingEntries = @(
        Get-DFeDocumentEntry -Cnpj $Cnpj -ProcessingStatus 'Processing'
    )

    $active              = 0
    $recovered           = 0
    $inconsistent        = 0
    $concurrentlyChanged = 0

    $referenceUtc = $ReferenceTime.ToUniversalTime()
    $threshold    = $referenceUtc.Subtract($AbandonAfter)

    foreach ($entry in $processingEntries) {
        $startedAt = [System.DateTimeOffset]::MinValue
        $validStartedAt = $false

        if (-not [string]::IsNullOrWhiteSpace([string]$entry.processing_started_at)) {
            $validStartedAt = [System.DateTimeOffset]::TryParseExact(
                [string]$entry.processing_started_at,
                'o',
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$startedAt
            )
        }

        $isInconsistent = -not $validStartedAt

        if (-not $isInconsistent) {
            if ($startedAt.ToUniversalTime() -gt $threshold) {
                $active++
                continue
            }
        }

        if ($isInconsistent) {
            $inconsistent++
            $errorMessage = (
                'Processing recovery marked the document as Failed because ' +
                'processing_started_at is missing or invalid.'
            )
        } else {
            $elapsed      = $referenceUtc - $startedAt.ToUniversalTime()
            $errorMessage = (
                'Processing recovery marked the document as Failed after an ' +
                "abandoned Processing state lasting $($elapsed.ToString())."
            )
        }

        $stateParams = @{
            Cnpj         = $Cnpj
            ChaveAcesso  = [string]$entry.chave_acesso
            Status       = 'Failed'
            ErrorMessage = $errorMessage
        }

        try {
            Set-DFeDocumentProcessingState @stateParams
            $recovered++
        } catch {
            $errorId = $_.FullyQualifiedErrorId

            $stateChanged = (
                $errorId -like 'InvalidProcessingStateTransition*' -or
                $errorId -like 'ConcurrentProcessingStateChange*'
            )

            if ($stateChanged) {
                $concurrentlyChanged++
                continue
            }

            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    $_.Exception,
                    'DocumentProcessingRecoveryFailed',
                    [System.Management.Automation.ErrorCategory]::WriteError,
                    $entry.chave_acesso
                )
            )
        }
    }

    [pscustomobject]@{
        PSTypeName          = 'PipeDFe.DocumentProcessingRecoveryResult'
        ProcessingFound     = $processingEntries.Count
        Active              = $active
        Recovered           = $recovered
        Inconsistent        = $inconsistent
        ConcurrentlyChanged = $concurrentlyChanged
    }
}
