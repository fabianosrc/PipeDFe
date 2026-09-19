#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Initialize-DFeAudit.

.DESCRIPTION
Covers the error handling path for database directory creation failures.

Coverage includes:
  - AuditDirectoryCreateFailed terminating error when New-Item throws.
  - InvalidArgument category for the terminating error.
  - TargetObject is the database directory path.
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

Describe 'Initialize-DFeAudit' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        #region Database directory creation failure
        Context 'Database directory creation failure' {

            BeforeAll {

                Mock -CommandName Test-Path -MockWith {
                    return $false
                } -ParameterFilter {
                    $PathType -eq 'Container'
                }

                Mock -CommandName New-Item -MockWith {
                    throw [System.IO.IOException]::new(
                        'Simulated directory creation failure.'
                    )
                } -ParameterFilter {
                    $ItemType -eq 'Directory'
                }

                $Script:Thrown = $null

                try {
                    Initialize-DFeAudit -Cnpj 'AB12CD34EF56GH' -ErrorAction Stop
                } catch {
                    $Script:Thrown = $_
                }
            }

            It 'Throws AuditDirectoryCreateFailed' {
                $Script:Thrown | Should -Not -BeNullOrEmpty

                $Script:Thrown.FullyQualifiedErrorId |
                    Should -BeLike 'AuditDirectoryCreateFailed*'
            }

            It 'Uses WriteError category' {
                $expected = ([System.Management.Automation.ErrorCategory]::WriteError)

                $Script:Thrown.CategoryInfo.Category | Should -Be $expected
            }

            It 'Exposes the database directory as TargetObject' {
                $Script:Thrown.TargetObject | Should -Not -BeNullOrEmpty
            }
        }
        #endregion
    }
}
