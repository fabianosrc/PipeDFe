<#
.SYNOPSIS
Orchestrates the persistent delivery lifecycle for a DFe notification.

.DESCRIPTION
Owns the full delivery lifecycle:

  1. Creates or retrieves the delivery record via New-DFeDelivery.
  2. Returns immediately when the delivery is already Delivered.
  3. Blocks and returns immediately when the delivery is Indeterminate.
  4. Recovers a Sending record found during startup - the global execution
     mutex held by Invoke-PipeDFe guarantees that Sending here belongs to
     an interrupted execution, not a concurrent one - and transitions it
     to Indeterminate to block automatic retry.
  5. Transitions Prepared or Failed to Sending.
  6. Delegates rendering and SMTP delivery to Send-DFeNotification.
  7. Transitions to Delivered on success, to Failed when Send-Mail was
     not yet called, or to Indeterminate when SMTP was already in progress
     and the outcome cannot be confirmed.

The distinction between Failed and Indeterminate is derived from
SendAttempted in the Send-Mail result. A missing SendAttempted property
is treated conservatively as true (indeterminate), never as safe to retry.

Never throws. All failures are returned as Success = $false with FailedAt
identifying the stage.

.PARAMETER Company
Company object with Cnpj, Email (Para, Cc, Cco), NomeFantasia, RazaoSocial.

.PARAMETER DateRange
PSCustomObject with Start and End [DateTimeOffset].

.PARAMETER Smtp
SMTP configuration object as returned by Resolve-DFeSmtp.

.PARAMETER Gaps
Sequence gaps for inclusion in the mail body. An empty collection is valid.

.PARAMETER Archives
Archive objects as returned by New-DFeArchive. Each must expose TipoDFe,
FileName, FileHash, and DestPath.

.OUTPUTS
System.Management.Automation.PSCustomObject

  Success        [bool]     Whether the delivery was confirmed as sent.
  EmailsSent     [string[]] Addresses the message was delivered to.
  ErrorMessage   [string]   Error description on failure; $null on success.
  FailedAt       [string]   Stage that failed; $null on success.
  DeliveryId     [string]   Persistent delivery identifier.
  DeliveryStatus [string]   Final delivery status after this invocation.

.NOTES
Private dependencies:
  New-DFeDelivery
  Set-DFeDeliveryState
  Send-DFeNotification
#>
function Invoke-DFeDelivery {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Company,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$DateRange,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Smtp,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Gaps,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [pscustomobject[]]$Archives
    )

    $cnpj = [string]$Company.Cnpj

    #region Recipient resolution
    $para = @(ConvertTo-NormalizedMailRecipient -InputObject $Company.Email.Para)

    if ($para.Count -eq 0) {
        return [PSCustomObject]@{
            Success        = $false
            EmailsSent     = @()
            ErrorMessage   = 'No primary recipient (Para) configured.'
            FailedAt       = 'Validation'
            DeliveryId     = $null
            DeliveryStatus = $null
        }
    }

    $cc  = @(ConvertTo-NormalizedMailRecipient -InputObject $Company.Email.Cc)
    $bcc = @(ConvertTo-NormalizedMailRecipient -InputObject $Company.Email.Cco)
    #endregion

    #region Create or retrieve delivery
    $delivery = $null

    try {
        $deliveryParams = @{
            Cnpj        = $cnpj
            PeriodStart = [DateTimeOffset]$DateRange.Start
            PeriodEnd   = [DateTimeOffset]$DateRange.End
            Archives    = $Archives
            To          = $para
            Cc          = $cc
            Bcc         = $bcc
        }

        $delivery = New-DFeDelivery @deliveryParams
    } catch {
        return [PSCustomObject]@{
            Success        = $false
            EmailsSent     = @()
            ErrorMessage   = $_.Exception.Message
            FailedAt       = 'Persistence'
            DeliveryId     = $null
            DeliveryStatus = $null
        }
    }
    #endregion

    #region Guard: terminal or in-flight states
    if ($delivery.DeliveryStatus -eq 'Delivered') {
        $emailsSent = @(
            $delivery.Recipients |
                Where-Object { $_.RecipientType -eq 'To' } |
                Select-Object -ExpandProperty Address
        )

        return [PSCustomObject]@{
            Success        = $true
            EmailsSent     = $emailsSent
            ErrorMessage   = $null
            FailedAt       = $null
            DeliveryId     = $delivery.DeliveryId
            DeliveryStatus = 'Delivered'
        }
    }

    if ($delivery.DeliveryStatus -eq 'Indeterminate') {
        $errorMessage = if (-not [string]::IsNullOrWhiteSpace($delivery.DeliveryError)) {
            $delivery.DeliveryError
        } else {
            'Previous SMTP attempt has an indeterminate result. Automatic retry is blocked.'
        }

        return [PSCustomObject]@{
            Success        = $false
            EmailsSent     = @()
            ErrorMessage   = $errorMessage
            FailedAt       = 'State'
            DeliveryId     = $delivery.DeliveryId
            DeliveryStatus = 'Indeterminate'
        }
    }

    if ($delivery.DeliveryStatus -eq 'Sending') {
        # Invoke-PipeDFe holds the global execution mutex. A Sending record
        # found here belongs to an interrupted execution, not a concurrent one.
        # Transition to Indeterminate to block automatic retry.
        $orphanError = (
            'A previous execution was interrupted during SMTP delivery. ' +
            'The result cannot be confirmed. Automatic retry is blocked.'
        )

        try {
            $orphanParams = @{
                Cnpj                      = $cnpj
                DeliveryId                = $delivery.DeliveryId
                ExpectedStatus            = 'Sending'
                ExpectedDeliveryStartedAt = $delivery.DeliveryStartedAt
                Status                    = 'Indeterminate'
                ErrorMessage              = $orphanError
            }

            Set-DFeDeliveryState @orphanParams | Out-Null
        } catch {
            return [PSCustomObject]@{
                Success        = $false
                EmailsSent     = @()
                ErrorMessage   = $_.Exception.Message
                FailedAt       = 'State'
                DeliveryId     = $delivery.DeliveryId
                DeliveryStatus = 'Sending'
            }
        }

        return [PSCustomObject]@{
            Success        = $false
            EmailsSent     = @()
            ErrorMessage   = $orphanError
            FailedAt       = 'State'
            DeliveryId     = $delivery.DeliveryId
            DeliveryStatus = 'Indeterminate'
        }
    }

    if ($delivery.DeliveryStatus -notin @('Prepared', 'Failed')) {
        return [PSCustomObject]@{
            Success        = $false
            EmailsSent     = @()
            ErrorMessage   = "Unsupported delivery state '$($delivery.DeliveryStatus)'."
            FailedAt       = 'State'
            DeliveryId     = $delivery.DeliveryId
            DeliveryStatus = $delivery.DeliveryStatus
        }
    }
    #endregion

    #region Transition to Sending
    $sendingState = $null

    try {
        $toSendingParams = @{
            Cnpj                      = $cnpj
            DeliveryId                = $delivery.DeliveryId
            ExpectedStatus            = $delivery.DeliveryStatus
            ExpectedDeliveryStartedAt = $delivery.DeliveryStartedAt
            Status                    = 'Sending'
        }

        $sendingState = Set-DFeDeliveryState @toSendingParams
    } catch {
        return [PSCustomObject]@{
            Success        = $false
            EmailsSent     = @()
            ErrorMessage   = $_.Exception.Message
            FailedAt       = 'State'
            DeliveryId     = $delivery.DeliveryId
            DeliveryStatus = $delivery.DeliveryStatus
        }
    }
    #endregion

    #region Send notification
    $notificationParams = @{
        Company            = $Company
        DateRange          = $DateRange
        Smtp               = $Smtp
        Gaps               = $Gaps
        ZipFileDestination = @($Archives | Select-Object -ExpandProperty DestPath)
    }

    $notificationResult = Send-DFeNotification @notificationParams
    #endregion

    #region Transition from Sending
    if ($notificationResult.Success) {
        try {
            $deliveredParams = @{
                Cnpj                      = $cnpj
                DeliveryId                = $delivery.DeliveryId
                ExpectedStatus            = 'Sending'
                ExpectedDeliveryStartedAt = $sendingState.DeliveryStartedAt
                Status                    = 'Delivered'
            }

            Set-DFeDeliveryState @deliveredParams | Out-Null
        } catch {
            # SMTP confirmed the send but Delivered could not be persisted.
            # Return failure to prevent silent data loss - the caller will
            # surface this as a warning and the delivery remains in Sending,
            # which will be recovered as Indeterminate on the next execution.
            return [PSCustomObject]@{
                Success        = $false
                EmailsSent     = @()
                ErrorMessage   = (
                    'SMTP confirmed the send, but Delivered state could not ' +
                    'be persisted: ' + $_.Exception.Message
                )
                FailedAt       = 'Persistence'
                DeliveryId     = $delivery.DeliveryId
                DeliveryStatus = 'Sending'
            }
        }

        return [PSCustomObject]@{
            Success        = $true
            EmailsSent     = @($notificationResult.EmailsSent)
            ErrorMessage   = $null
            FailedAt       = $null
            DeliveryId     = $delivery.DeliveryId
            DeliveryStatus = 'Delivered'
        }
    }

    # Determine whether SMTP was already in progress when the failure occurred.
    # A missing SendAttempted property is treated conservatively as true.
    $sendAttemptedProp = $null

    if ($null -ne $notificationResult) {
        $sendAttemptedProp = $notificationResult.PSObject.Properties['SendAttempted']
    }

    $sendAttempted = if ($null -eq $sendAttemptedProp) {
        $true
    } else {
        [bool]$sendAttemptedProp.Value
    }

    $targetStatus = if ($sendAttempted) { 'Indeterminate' } else { 'Failed' }

    $mailError = if (
        $null -ne $notificationResult -and
        -not [string]::IsNullOrWhiteSpace($notificationResult.ErrorMessage)
    ) {
        $notificationResult.ErrorMessage
    } else {
        'SMTP delivery failed without an error message.'
    }

    try {
        $failureParams = @{
            Cnpj                      = $cnpj
            DeliveryId                = $delivery.DeliveryId
            ExpectedStatus            = 'Sending'
            ExpectedDeliveryStartedAt = $sendingState.DeliveryStartedAt
            Status                    = $targetStatus
            ErrorMessage              = $mailError
        }

        Set-DFeDeliveryState @failureParams | Out-Null
    } catch {
        return [PSCustomObject]@{
            Success        = $false
            EmailsSent     = @()
            ErrorMessage   = $mailError + ' State persistence failed: ' + $_.Exception.Message
            FailedAt       = 'Persistence'
            DeliveryId     = $delivery.DeliveryId
            DeliveryStatus = 'Sending'
        }
    }

    [PSCustomObject]@{
        Success        = $false
        EmailsSent     = @()
        ErrorMessage   = $mailError
        FailedAt       = $notificationResult.FailedAt
        DeliveryId     = $delivery.DeliveryId
        DeliveryStatus = $targetStatus
    }
    #endregion
}
