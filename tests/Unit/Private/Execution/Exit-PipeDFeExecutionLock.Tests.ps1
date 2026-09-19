#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Exit-PipeDFeExecutionLock.

.DESCRIPTION
Covers lock release contract, mutex disposal, re-acquisition after
release, and invalid lock rejection.
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

Describe 'Exit-PipeDFeExecutionLock' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:MutexName = 'Global\PipeDFe.Execution'
        }

        #region Lock release
        Context 'Lock release' {

            It 'Allows another execution to acquire the mutex after release' {
                $lock = Enter-PipeDFeExecutionLock

                Exit-PipeDFeExecutionLock -Lock $lock

                $secondLock = Enter-PipeDFeExecutionLock

                try {
                    $secondLock.Acquired | Should -BeTrue
                } finally {
                    Exit-PipeDFeExecutionLock -Lock $secondLock
                }
            }

            It 'Disposes the mutex after release' {
                $lock = Enter-PipeDFeExecutionLock

                Exit-PipeDFeExecutionLock -Lock $lock

                { $lock.Mutex.WaitOne(0) } | Should -Throw
            }

            It 'Produces no output' {
                $lock = Enter-PipeDFeExecutionLock

                $result = Exit-PipeDFeExecutionLock -Lock $lock

                $result | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Invalid lock
        Context 'Invalid lock' {

            It 'Throws LockMissingMutex when Mutex is null' {
                $invalidLock = [PSCustomObject]@{
                    PSTypeName = 'PipeDFe.ExecutionLock'
                    Name       = $Script:MutexName
                    Mutex      = $null
                    Acquired   = $true
                    Abandoned  = $false
                }

                $thrown = $null

                try {
                    Exit-PipeDFeExecutionLock -Lock $invalidLock -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown | Should -Not -BeNullOrEmpty
                $thrown.FullyQualifiedErrorId | Should -BeLike 'LockMissingMutex*'
            }

            It 'Uses InvalidArgument category for a missing Mutex' {
                $invalidLock = [PSCustomObject]@{
                    PSTypeName = 'PipeDFe.ExecutionLock'
                    Name       = $Script:MutexName
                    Mutex      = $null
                    Acquired   = $true
                    Abandoned  = $false
                }

                $thrown = $null

                try {
                    Exit-PipeDFeExecutionLock -Lock $invalidLock -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $expected = ([System.Management.Automation.ErrorCategory]::InvalidArgument)

                $thrown.CategoryInfo.Category | Should -Be $expected
            }
        }
        #endregion
    }
}
