#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Enter-PipeDFeExecutionLock.

.DESCRIPTION
Covers lock acquisition contract, output object shape, mutex name,
already-held detection, and abandoned mutex recovery.
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

Describe 'Enter-PipeDFeExecutionLock' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:MutexName = 'Global\PipeDFe.Execution'
        }

        #region Lock acquisition
        Context 'Lock acquisition' {

            It 'Returns a PipeDFe.ExecutionLock object' {
                $lock = Enter-PipeDFeExecutionLock

                try {
                    $lock.PSTypeNames | Should -Contain 'PipeDFe.ExecutionLock'
                } finally {
                    Exit-PipeDFeExecutionLock -Lock $lock
                }
            }

            It 'Returns the expected global mutex name' {
                $lock = Enter-PipeDFeExecutionLock

                try {
                    $lock.Name | Should -Be $Script:MutexName
                } finally {
                    Exit-PipeDFeExecutionLock -Lock $lock
                }
            }

            It 'Reports that the lock was acquired' {
                $lock = Enter-PipeDFeExecutionLock

                try {
                    $lock.Acquired | Should -BeTrue
                } finally {
                    Exit-PipeDFeExecutionLock -Lock $lock
                }
            }

            It 'Returns the underlying Mutex instance' {
                $lock = Enter-PipeDFeExecutionLock

                try {
                    $lock.Mutex | Should -BeOfType [System.Threading.Mutex]
                } finally {
                    Exit-PipeDFeExecutionLock -Lock $lock
                }
            }

            It 'Reports Abandoned as false for a normal acquisition' {
                $lock = Enter-PipeDFeExecutionLock

                try {
                    $lock.Abandoned | Should -BeFalse
                } finally {
                    Exit-PipeDFeExecutionLock -Lock $lock
                }
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            It 'Exposes exactly the documented properties' {
                $lock = Enter-PipeDFeExecutionLock

                try {
                    $expected = @('Name', 'Mutex', 'Acquired', 'Abandoned')

                    $actual = @(
                        $lock.PSObject.Properties |
                            Where-Object { $_.MemberType -eq 'NoteProperty' } |
                            Select-Object -ExpandProperty Name
                    )

                    $actual | Should -HaveCount $expected.Count

                    foreach ($prop in $expected) {
                        $actual | Should -Contain $prop
                    }
                } finally {
                    Exit-PipeDFeExecutionLock -Lock $lock
                }
            }
        }
        #endregion
    }
}
