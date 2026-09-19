#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for the PipeDFe global execution lock.

.DESCRIPTION
Validates cross-process behavior of the PipeDFe named mutex.

The tests intentionally use separate PowerShell processes because
System.Threading.Mutex ownership is thread-aware. This reproduces the
real execution scenario where two independent PipeDFe processes attempt
to run simultaneously.

Coverage includes:
  - LockAlreadyHeld when another process owns the mutex.
  - ResourceBusy error category when the lock is already held.
  - Non-blocking behavior when the lock is already held.

.NOTES
The mutex is handled defensively for the possibility of an
AbandonedMutexException being reported by WaitOne().

Automated coverage for the abandoned-mutex recovery path is intentionally
not included. Attempts to reproduce mutex abandonment deterministically
within the supported PowerShell test environments were not reliable and
thread-based approaches require a PowerShell runspace, making them
unsuitable for this test suite.

Cross-process contention is covered by the integration test suite.
#>

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'PipeDFe execution lock' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:MutexName = 'Global\PipeDFe.Execution'

            $Script:PowerShellExecutable = (Get-Process -Id $PID).Path

            $Script:ModuleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

            $Script:ModuleName = Join-Path -Path $Script:ModuleRoot -ChildPath 'PipeDFe.psd1'
        }

        BeforeEach {

            Start-Sleep -Milliseconds 300

            try {
                $drain = [System.Threading.Mutex]::new($false, $Script:MutexName)

                try {
                    $drainAcquired = $drain.WaitOne(500)
                } catch [System.Threading.AbandonedMutexException] {
                    $drainAcquired = $true
                }

                if ($drainAcquired) {
                    $drain.ReleaseMutex()
                }

                $drain.Dispose()
            } catch {
                $null = $_
            }
        }

        #region Lock already held by another process
        Context 'Lock already held by another process' {

            It 'Throws LockAlreadyHeld when another process owns the mutex' {
                $childScript = @'
$mutex = [System.Threading.Mutex]::new($false, '__MUTEX_NAME__')

try {
    $acquired = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $acquired = $true
}

if (-not $acquired) {
    [System.Console]::Error.WriteLine('Could not acquire mutex.')
    exit 2
}

[System.Console]::Out.WriteLine('READY')
[System.Console]::Out.Flush()

Start-Sleep -Seconds 30
'@

                $childScript = $childScript.Replace('__MUTEX_NAME__', $Script:MutexName)

                $scriptPath = Join-Path -Path $TestDrive -ChildPath 'Hold-PipeDFeExecutionLock.ps1'

                $setParams = @{
                    LiteralPath = $scriptPath
                    Value       = $childScript
                    Encoding    = 'UTF8'
                }

                Set-Content @setParams

                $startInfo                        = [System.Diagnostics.ProcessStartInfo]::new()
                $startInfo.FileName               = $Script:PowerShellExecutable
                $startInfo.Arguments              = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath
                $startInfo.UseShellExecute        = $false
                $startInfo.CreateNoWindow         = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError  = $true

                $process           = [System.Diagnostics.Process]::new()
                $process.StartInfo = $startInfo

                try {
                    $null = $process.Start()

                    $readyLine = $process.StandardOutput.ReadLine()

                    if ($readyLine -ne 'READY') {
                        $stderr = $process.StandardError.ReadToEnd()

                        if (-not $process.HasExited) {
                            $process.WaitForExit()
                        }

                        throw (
                            @(
                                'Child process did not write READY.'
                                "STDOUT: $readyLine"
                                "STDERR: $stderr"
                                "ExitCode: $($process.ExitCode)"
                            ) -join [System.Environment]::NewLine
                        )
                    }

                    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

                    $thrown = $null

                    try {
                        Enter-PipeDFeExecutionLock -ErrorAction Stop
                    } catch {
                        $thrown = $_
                    } finally {
                        $stopwatch.Stop()
                    }

                    $thrown | Should -Not -BeNullOrEmpty

                    $thrown.FullyQualifiedErrorId | Should -BeLike 'LockAlreadyHeld*'

                    $expected = ([System.Management.Automation.ErrorCategory]::ResourceBusy)

                    $thrown.CategoryInfo.Category | Should -Be $expected

                    $stopwatch.ElapsedMilliseconds | Should -BeLessThan 1000

                } finally {
                    if ($null -ne $process) {
                        if (-not $process.HasExited) {
                            $process.Kill()
                            $process.WaitForExit()
                        }

                        $process.Dispose()
                    }
                }
            }
        }
        #endregion
    }
}
