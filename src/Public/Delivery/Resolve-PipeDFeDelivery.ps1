<#
.SYNOPSIS
Records the verified SMTP outcome of an indeterminate delivery.

.DESCRIPTION
Resolves exactly the attempt identified by DeliveryId and AttemptStartedAt.
A confirmed acceptance marks the delivery as Delivered. Confirmed
non-acceptance marks it as Failed so a normal closing can retry it.
Records the reason and previous SMTP error together with the state change.

.PARAMETER Cnpj
Company CNPJ.

.PARAMETER DeliveryId
Delivery identifier shown in the blocked delivery warning.

.PARAMETER AttemptStartedAt
Exact UTC attempt timestamp shown in the warning.

.PARAMETER Outcome
Accepted if SMTP acceptance was confirmed, or NotAccepted if non-acceptance
was confirmed.

.PARAMETER Reason
Evidence supporting the decision. Do not include credentials or fiscal data.

.OUTPUTS
System.Management.Automation.PSCustomObject

.EXTERNALHELP PipeDFe-help.xml
#>
function Resolve-PipeDFeDelivery {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidatePattern('^(?-i)[0-9a-f]{32}$')]
        [string]$DeliveryId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AttemptStartedAt,

        [Parameter(Mandatory)]
        [ValidateSet('Accepted', 'NotAccepted')]
        [string]$Outcome,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason
    )

    $normalizedCnpj = ConvertTo-NormalizedCnpj -Value $Cnpj
    $reasonText     = $Reason.Trim()

    if ([string]::IsNullOrWhiteSpace($reasonText)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'Reason must not be blank.',
                    'Reason'
                ),
                'ReasonMustNotBeBlank',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Reason
            )
        )
    }

    $status = if ($Outcome -eq 'Accepted') { 'Delivered' } else { 'Failed' }

    $indexPath = Get-StorePath -Scope Index -Cnpj $normalizedCnpj

    if (-not [System.IO.File]::Exists($indexPath)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.FileNotFoundException]::new(
                    "No delivery index exists for company '$normalizedCnpj'.",
                    $indexPath
                ),
                'DeliveryIndexNotFound',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $normalizedCnpj
            )
        )
    }

    $target = "[$normalizedCnpj] delivery $DeliveryId, attempt $AttemptStartedAt"

    if (-not $PSCmdlet.ShouldProcess($target, "Resolve delivery as $status")) {
        return
    }

    $transitionParams = @{
        Cnpj                      = $normalizedCnpj
        DeliveryId                = $DeliveryId
        ExpectedStatus            = 'Indeterminate'
        ExpectedDeliveryStartedAt = $AttemptStartedAt
        Status                    = $status
        ResolutionReason          = $reasonText
    }

    if ($status -eq 'Failed') {
        $transitionParams.ErrorMessage = "SMTP non-acceptance confirmed: $reasonText"
    }

    Set-DFeDeliveryState @transitionParams
}
