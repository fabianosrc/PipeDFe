#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Initialize-NativeDllLoader.

.DESCRIPTION
Verifies that Initialize-NativeDllLoader correctly configures the native
Dll search path against the real kernel32.dll APIs on Windows PowerShell 5.1.

Coverage includes:
  - Initializes without error on a real Windows environment.
  - Sets NativeDllDirectoryInitialized to true after a real call.
  - Stores a non-zero AddDllDirectory cookie after a real call.
  - Is idempotent: a second call does not throw.
  - Preserves the original initialization state and cookie on repeated calls.

All tests run against real kernel32.dll APIs.
No production data is accessed.

.NOTES
These tests are intended for Windows PowerShell 5.1.
They are skipped automatically on non-Windows platforms.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
)]

param ()

function Script:Test-WindowsPlatform {
    [OutputType([bool])]
    param ()

    [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Initialize-NativeDllLoader' -Tag 'Integration' -Skip:(-not (Test-WindowsPlatform)) {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            $testID = [guid]::NewGuid().ToString('N')

            $joinPathParams = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = 'PipeDFe.NativeDllLoader.Tests-{0}' -f $testID
            }

            $Script:TestRoot = Join-Path @joinPathParams

            $newItemParams = @{
                Path        = $Script:TestRoot
                ItemType    = 'Directory'
                Force       = $true
                ErrorAction = 'Stop'
            }

            New-Item @newItemParams | Out-Null

        }

        AfterAll {

            if ($null -ne $Script:TestRoot -and (Test-Path -LiteralPath $Script:TestRoot)) {
                $removeItemParams = @{
                    LiteralPath = $Script:TestRoot
                    Recurse     = $true
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeItemParams

            }

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }

        BeforeEach {

            $Script:NativeDllDirectoryInitialized = $false
            $Script:NativeDllDirectoryCookie      = [System.IntPtr]::Zero
        }
        #endregion

        #region Initialization
        Context 'Initialization' {

            It 'Initializes without error on Windows' {
                { Initialize-NativeDllLoader -LiteralPath $Script:TestRoot } | Should -Not -Throw
            }

            It 'Sets NativeDllDirectoryInitialized to $true after a real call' {
                Initialize-NativeDllLoader -LiteralPath $Script:TestRoot

                $Script:NativeDllDirectoryInitialized | Should -BeTrue
            }

            It 'Stores a non-zero AddDllDirectory cookie after a real call' {
                Initialize-NativeDllLoader -LiteralPath $Script:TestRoot

                $Script:NativeDllDirectoryCookie | Should -Not -Be ([System.IntPtr]::Zero)
            }

            It 'Throws when called with a non-existent path' {
                $invalidPath = Join-Path -Path $Script:TestRoot -ChildPath 'does-not-exist'

                { Initialize-NativeDllLoader -LiteralPath $invalidPath } | Should -Throw
            }
        }
        #endregion

        #region Idempotency
        Context 'Idempotency' {

            It 'Does not throw when called a second time' {
                Initialize-NativeDllLoader -LiteralPath $Script:TestRoot

                { Initialize-NativeDllLoader -LiteralPath $Script:TestRoot } | Should -Not -Throw
            }

            It 'Preserves NativeDllDirectoryInitialized as $true on repeated calls' {
                Initialize-NativeDllLoader -LiteralPath $Script:TestRoot
                Initialize-NativeDllLoader -LiteralPath $Script:TestRoot

                $Script:NativeDllDirectoryInitialized | Should -BeTrue
            }

            It 'Preserves the original AddDllDirectory cookie on repeated calls' {
                Initialize-NativeDllLoader -LiteralPath $Script:TestRoot

                $initialCookie = $Script:NativeDllDirectoryCookie

                Initialize-NativeDllLoader -LiteralPath $Script:TestRoot

                $Script:NativeDllDirectoryCookie | Should -Be $initialCookie
            }
        }
        #endregion
    }
}
