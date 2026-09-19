<#
.SYNOPSIS
Releases the PipeDFe global execution lock.

.DESCRIPTION
Releases ownership of a PipeDFe execution mutex previously acquired by
Enter-PipeDFeExecutionLock and disposes the underlying Mutex object.

The lock must be released by the same thread that acquired it.

.PARAMETER Lock
The lock object returned by Enter-PipeDFeExecutionLock.

.EXAMPLE
PS C:\> $lock = Enter-PipeDFeExecutionLock

PS C:\> try {
    # Execute PipeDFe
} finally {
    Exit-PipeDFeExecutionLock -Lock $lock
}

.OUTPUTS
None.

.NOTES
Private dependencies:
  Enter-PipeDFeExecutionLock
#>
function Exit-PipeDFeExecutionLock {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Lock
    )

    $mutex = $Lock.Mutex

    if ($null -eq $mutex) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'The supplied execution lock does not contain a Mutex.'
                ),
                'LockMissingMutex',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Lock
            )
        )
    }

    try {
        $mutex.ReleaseMutex()
    } catch [System.ApplicationException] {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    'The PipeDFe execution lock could not be released ' +
                    'because the current thread does not own the mutex.',
                    $_.Exception
                ),
                'LockReleaseNotOwner',
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                $Lock
            )
        )
    } finally {
        $mutex.Dispose()
    }
}
