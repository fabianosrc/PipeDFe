<#
.SYNOPSIS
Acquires the PipeDFe global execution lock.

.DESCRIPTION
Creates or opens the PipeDFe named system mutex and attempts to acquire
ownership without waiting.

The mutex is created in the Global namespace so that PipeDFe executions
running in different Windows sessions are mutually exclusive.

A successful call returns a lock object that must be passed to
Exit-PipeDFeExecutionLock.

If another PipeDFe execution already owns the mutex, this function throws
with ErrorId LockAlreadyHeld and does not wait for the existing execution.

If the mutex was abandoned by a previous process, ownership is acquired and
the returned object indicates that an abandoned mutex was recovered.

This function does not persist lock state to the filesystem.

.OUTPUTS
PSCustomObject

.EXAMPLE
PS C:\> $lock = Enter-PipeDFeExecutionLock

.EXAMPLE
PS C:\> try {
    $lock = Enter-PipeDFeExecutionLock
    # Execute PipeDFe
} finally {
    if ($null -ne $lock) {
        Exit-PipeDFeExecutionLock -Lock $lock
    }
}

.NOTES
Private dependencies:
  None.

The caller is responsible for releasing the returned lock object.
#>
function Enter-PipeDFeExecutionLock {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseDeclaredVarsMoreThanAssignments',
        'lockHeld',
        Justification = 'Used in the catch block to distinguish LockAlreadyHeld from unexpected failures.'
    )]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ()

    $mutex     = $null
    $acquired  = $false
    $abandoned = $false
    $lockHeld  = $false

    $mutexName = 'Global\PipeDFe.Execution'

    try {
        $mutex = [System.Threading.Mutex]::new(
            $false,
            $mutexName
        )

        try {
            $acquired = $mutex.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired  = $true
            $abandoned = $true
        }



        if (-not $acquired) {
            $mutex.Dispose()
            $mutex    = $null
            $lockHeld = $true

            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        'A PipeDFe execution is already in progress.'
                    ),
                    'LockAlreadyHeld',
                    [System.Management.Automation.ErrorCategory]::ResourceBusy,
                    $mutexName
                )
            )
        }

        [PSCustomObject]@{
            PSTypeName = 'PipeDFe.ExecutionLock'
            Name       = $mutexName
            Mutex      = $mutex
            Acquired   = $true
            Abandoned  = $abandoned
        }
    } catch {
        if ($null -ne $mutex -and -not $acquired) {
            $mutex.Dispose()
        }

        # LockAlreadyHeld was already reported -- do not wrap it again.
        if ($lockHeld) {
            throw
        }

        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                'LockAcquisitionFailed',
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                $mutexName
            )
        )
    }
}
