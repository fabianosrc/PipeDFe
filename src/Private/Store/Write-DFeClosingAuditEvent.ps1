<#
.SYNOPSIS
Records an operational closing event without changing the closing outcome.

.PARAMETER Cnpj
Company CNPJ for the audit database.

.PARAMETER ExecutionId
Existing audit execution ID. An empty value disables event persistence.

.PARAMETER EventType
Stage or milestone in the closing workflow.

.PARAMETER Status
Recorded outcome of the event.

.PARAMETER Message
Optional operational summary without payloads or credentials.
#>
function Write-DFeClosingAuditEvent {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [string]$Cnpj,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ExecutionId,

        [Parameter(Mandatory)]
        [string]$EventType,

        [Parameter(Mandatory)]
        [string]$Status,

        [Parameter()]
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        return
    }

    try {
        Save-DFeAuditEvent @PSBoundParameters -ErrorAction Stop
    } catch {
        Write-Warning -Message "[$Cnpj] Could not record audit event '$EventType' for execution '$ExecutionId'." -WarningAction Continue
    }
}
