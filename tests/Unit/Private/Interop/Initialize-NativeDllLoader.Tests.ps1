#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Initialize-NativeDllLoader.

.DESCRIPTION
Verifies that Initialize-NativeDllLoader correctly configures the native DLL
search path and maintains initialization state across calls.

Coverage includes:
  - LiteralPath is mandatory.
  - LiteralPath accepts an existing directory.
  - LiteralPath rejects a path that does not exist.
  - LiteralPath rejects a file path.
  - Returns immediately when already initialized.
  - Does not modify initialization state on repeated calls.
  - Registers PipeDFe.NativeLoader on first call.
  - Does not throw when PipeDFe.NativeLoader is already registered.
  - Calls SetDefaultDllDirectories on initialization.
  - Continues when SetDefaultDllDirectories is unavailable.
  - Throws DefaultDllDirectoriesConfigFailed when SetDefaultDllDirectories fails.
  - Stores the cookie returned by AddDllDirectory.
  - Does not call SetDllDirectory when AddDllDirectory succeeds.
  - Falls back to SetDllDirectory when AddDllDirectory is unavailable.
  - Falls back to SetDllDirectory when AddDllDirectory returns Zero.
  - Does not store a cookie when SetDllDirectory fallback is used.
  - Sets NativeDllDirectoryInitialized to true when fallback succeeds.
  - Throws NativeDllDirectoryConfigFailed when SetDllDirectory fails.
  - Does not set NativeDllDirectoryInitialized to true on failure.

.NOTES
All kernel32 calls are intercepted via the private seam functions
(Invoke-NativeSetDefaultDllDirectory, Invoke-NativeAddDllDirectory,
Invoke-NativeSetDllDirectory), making every test deterministic and
independent of the host environment.
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

Describe 'Initialize-NativeDllLoader' {

    InModuleScope -ModuleName PipeDFe {

        BeforeEach {

            $Script:NativeDllDirectoryInitialized = $false
            $Script:NativeDllDirectoryCookie      = [System.IntPtr]::Zero
        }

        AfterAll {

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }

        Context 'Parameter validation' {

            It 'Requires LiteralPath' {
                $command = Get-Command -Name Initialize-NativeDllLoader

                $command.Parameters['LiteralPath'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } | Select-Object -ExpandProperty Mandatory |

                    Should -BeTrue
            }

            It 'Accepts an existing directory' {
                $params = @{
                    Path     = (Join-Path -Path $TestDrive -ChildPath 'native')
                    ItemType = 'Directory'
                    Force    = $true
                }

                Mock -CommandName Invoke-NativeSetDefaultDllDirectory {
                    return $true
                }

                Mock -CommandName Invoke-NativeAddDllDirectory {
                    return [System.IntPtr] 1234
                }

                { Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName } |
                    Should -Not -Throw
            }

            It 'Rejects a path that does not exist' {
                $missing = Join-Path $TestDrive 'does-not-exist'

                { Initialize-NativeDllLoader -LiteralPath $missing } |
                    Should -Throw
            }

            It 'Rejects a file path' {
                $params = @{
                    Path     = (Join-Path -Path $TestDrive -ChildPath 'native.dll')
                    ItemType = 'File'
                }

                { Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName } |
                    Should -Throw
            }
        }

        Context 'Idempotency' {

            It 'Returns immediately when already initialized' {
                $Script:NativeDllDirectoryInitialized = $true
                $Script:NativeDllDirectoryCookie      = [System.IntPtr] 1234

                $params = @{
                    Path     = (Join-Path -Path $TestDrive -ChildPath 'native')
                    ItemType = 'Directory'
                    Force    = $true
                }

                # Seams must NOT be called - defining them as throwing confirms this.
                Mock -CommandName Invoke-NativeSetDefaultDllDirectory {
                    throw 'Must not be called'
                }

                Mock -CommandName Invoke-NativeAddDllDirectory {
                    throw 'Must not be called'
                }

                Mock -CommandName Invoke-NativeSetDllDirectory {
                    throw 'Must not be called'
                }

                { Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName } |
                    Should -Not -Throw

                $Script:NativeDllDirectoryCookie      | Should -Be ([System.IntPtr] 1234)
                $Script:NativeDllDirectoryInitialized | Should -BeTrue
            }
        }

        Context 'NativeLoader type registration' {

            It 'Registers the PipeDFe.NativeLoader type on first initialization' {
                $params = @{
                    Path     = (Join-Path -Path $TestDrive -ChildPath 'native')
                    ItemType = 'Directory'
                    Force    = $true
                }

                Mock -CommandName Invoke-NativeSetDefaultDllDirectory {
                    return $true
                }

                Mock -CommandName Invoke-NativeAddDllDirectory {
                    return [System.IntPtr] 1234
                }

                Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName

                ([System.Management.Automation.PSTypeName]'PipeDFe.NativeLoader').Type |
                    Should -Not -BeNullOrEmpty
            }

            It 'Does not throw when PipeDFe.NativeLoader is already registered' {
                $params = @{
                    Path     = (Join-Path -Path $TestDrive -ChildPath 'native')
                    ItemType = 'Directory'
                    Force    = $true
                }

                Mock -CommandName Invoke-NativeSetDefaultDllDirectory {
                    return $true
                }

                Mock -CommandName Invoke-NativeAddDllDirectory {
                    return [System.IntPtr] 1234
                }

                Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName

                $Script:NativeDllDirectoryInitialized = $false

                { Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName } |
                    Should -Not -Throw
            }
        }

        Context 'SetDefaultDllDirectories' {

            It 'Calls SetDefaultDllDirectories on initialization' {
                $params = @{
                    Path     = (Join-Path -Path $TestDrive -ChildPath 'native')
                    ItemType = 'Directory'
                    Force    = $true
                }

                Mock Invoke-NativeSetDefaultDllDirectory {
                    return $true
                }

                Mock Invoke-NativeAddDllDirectory {
                    return [System.IntPtr] 1234
                }

                Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName

                Should -Invoke -CommandName Invoke-NativeSetDefaultDllDirectory -Times 1 -Exactly
            }

            It 'Continues when SetDefaultDllDirectories is unavailable' {
                $params = @{
                    Path     = (Join-Path -Path $TestDrive -ChildPath 'native')
                    ItemType = 'Directory'
                    Force    = $true
                }

                Mock -CommandName Invoke-NativeSetDefaultDllDirectory {
                    throw [System.EntryPointNotFoundException]::new()
                }

                Mock -CommandName Invoke-NativeAddDllDirectory {
                    return [System.IntPtr] 1234
                }

                { Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName } |
                    Should -Not -Throw

                $Script:NativeDllDirectoryInitialized | Should -BeTrue
            }

            It 'Throws DefaultDllDirectoriesConfigFailed when SetDefaultDllDirectories fails' {
                $params = @{
                    Path     = (Join-Path -Path $TestDrive -ChildPath 'native')
                    ItemType = 'Directory'
                    Force    = $true
                }

                Mock -CommandName Invoke-NativeSetDefaultDllDirectory {
                    return $false
                }

                { Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName } |
                    Should -Throw -ErrorId 'DefaultDllDirectoriesConfigFailed*'

                $Script:NativeDllDirectoryInitialized | Should -BeFalse
            }
        }

        Context 'AddDllDirectory' {

            It 'Stores the cookie returned by AddDllDirectory' {
                $params = @{
                    Path     = (Join-Path -Path $TestDrive -ChildPath 'native')
                    ItemType = 'Directory'
                    Force    = $true
                }

                $expectedCookie = [System.IntPtr] 1234

                Mock -CommandName Invoke-NativeSetDefaultDllDirectory {
                    return $true
                }

                Mock -CommandName Invoke-NativeAddDllDirectory {
                    return $expectedCookie
                }


                Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName

                $Script:NativeDllDirectoryCookie      | Should -Be $expectedCookie
                $Script:NativeDllDirectoryInitialized | Should -BeTrue
            }

            It 'Does not call SetDllDirectory when AddDllDirectory succeeds' {
                $params = @{
                    Path     = (Join-Path -Path $TestDrive -ChildPath 'native')
                    ItemType = 'Directory'
                    Force    = $true
                }

                Mock -CommandName Invoke-NativeSetDefaultDllDirectory {
                    return $true
                }

                Mock -CommandName Invoke-NativeAddDllDirectory {
                    return [System.IntPtr] 1234
                }

                Mock -CommandName Invoke-NativeSetDllDirectory {
                    return $true
                }

                Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName

                Should -Invoke -CommandName Invoke-NativeSetDllDirectory -Times 0 -Exactly
            }

            It 'Falls back to SetDllDirectory when AddDllDirectory is unavailable' {
                $params = @{
                    Path     = (Join-Path -Path $TestDrive -ChildPath 'native')
                    ItemType = 'Directory'
                    Force    = $true
                }

                Mock -CommandName Invoke-NativeSetDefaultDllDirectory {
                    return $true
                }

                Mock -CommandName Invoke-NativeAddDllDirectory {
                    throw [System.EntryPointNotFoundException]::new()
                }

                Mock -CommandName Invoke-NativeSetDllDirectory {
                    return $true
                }

                Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName

                Should -Invoke -CommandName Invoke-NativeSetDllDirectory -Times 1 -Exactly

                $Script:NativeDllDirectoryCookie      | Should -Be ([System.IntPtr]::Zero)
                $Script:NativeDllDirectoryInitialized | Should -BeTrue
            }

            It 'Falls back to SetDllDirectory when AddDllDirectory returns Zero' {
                $params = @{
                    Path     = (Join-Path -Path $TestDrive -ChildPath 'native')
                    ItemType = 'Directory'
                    Force    = $true
                }

                Mock -CommandName Invoke-NativeSetDefaultDllDirectory {
                    return $true
                }

                Mock -CommandName Invoke-NativeAddDllDirectory {
                    return [System.IntPtr]::Zero
                }

                Mock -CommandName Invoke-NativeSetDllDirectory {
                    return $true
                }

                Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName

                Should -Invoke -CommandName Invoke-NativeAddDllDirectory  -Times 1 -Exactly
                Should -Invoke -CommandName Invoke-NativeSetDllDirectory  -Times 1 -Exactly

                $Script:NativeDllDirectoryCookie      | Should -Be ([System.IntPtr]::Zero)
                $Script:NativeDllDirectoryInitialized | Should -BeTrue
            }
        }

        Context 'SetDllDirectory fallback' {

            It 'Does not store a cookie when SetDllDirectory fallback is used' {
                $params = @{
                    Path     = (Join-Path -Path $TestDrive -ChildPath 'native')
                    ItemType = 'Directory'
                    Force    = $true
                }

                Mock -CommandName Invoke-NativeSetDefaultDllDirectory {
                    return $true
                }

                Mock -CommandName Invoke-NativeAddDllDirectory {
                    return [System.IntPtr]::Zero
                }

                Mock -CommandName Invoke-NativeSetDllDirectory {
                    return $true
                }

                Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName

                $Script:NativeDllDirectoryCookie | Should -Be ([System.IntPtr]::Zero)
            }

            It 'Sets NativeDllDirectoryInitialized to true when fallback succeeds' {
                $params = @{
                    Path     = (Join-Path -Path $TestDrive -ChildPath 'native')
                    ItemType = 'Directory'
                    Force    = $true
                }

                Mock -CommandName Invoke-NativeSetDefaultDllDirectory {
                    return $true
                }

                Mock -CommandName Invoke-NativeAddDllDirectory {
                    return [System.IntPtr]::Zero
                }

                Mock -CommandName Invoke-NativeSetDllDirectory {
                    return $true
                }

                Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName

                $Script:NativeDllDirectoryInitialized | Should -BeTrue
            }

            It 'Throws NativeDllDirectoryConfigFailed when SetDllDirectory fails' {
                $params = @{
                    Path     = (Join-Path -Path $TestDrive -ChildPath 'native')
                    ItemType = 'Directory'
                    Force    = $true
                }

                Mock -CommandName Invoke-NativeSetDefaultDllDirectory {
                    return $true
                }

                Mock -CommandName Invoke-NativeAddDllDirectory {
                    return [System.IntPtr]::Zero
                }

                Mock -CommandName Invoke-NativeSetDllDirectory {
                    return $false
                }

                { Initialize-NativeDllLoader -LiteralPath (New-Item @params).FullName } |
                    Should -Throw -ErrorId 'NativeDllDirectoryConfigFailed*'

                $Script:NativeDllDirectoryInitialized | Should -BeFalse
                $Script:NativeDllDirectoryCookie      | Should -Be ([System.IntPtr]::Zero)
            }
        }
    }
}
