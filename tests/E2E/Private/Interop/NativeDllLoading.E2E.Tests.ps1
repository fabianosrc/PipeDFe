#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
E2E tests for native Dll loading.

.DESCRIPTION
Verifies that Initialize-NativeDllLoader correctly configures the native
Dll search path required by the SQLite provider.

The test exercises the complete production chain against real Windows APIs
and the real native SQLite runtime:

Initialize-NativeDllLoader
  -> kernel32.dll
  -> e_sqlite3.dll
  -> System.Data.SQLite
  -> SQLiteConnection.Open()
  -> SELECT 1

Coverage includes:
  - Resolves the expected architecture-specific native directory.
  - Initializes the native Dll loader successfully.
  - Marks NativeDllDirectoryInitialized as true.
  - Stores the AddDllDirectory cookie when the modern API is available.
  - Opens a real SQLite database connection.
  - Verifies that the connection reaches the Open state.
  - Executes a real SQL query successfully.
  - Creates all test database files under an isolated temporary directory.

No mocks are used. All calls hit the real Windows APIs and the real SQLite
native runtime.

.NOTES
These tests are skipped on non-Windows platforms.

Requires the native SQLite runtime to be present at:
  lib/native/x64/e_sqlite3.dll

  or:

  lib/native/x86/e_sqlite3.dll

depending on the current process architecture.
#>

function script:Test-WindowsPlatform {
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

Describe 'Native Dll loading' -Tag 'E2E' -Skip:(-not (Test-WindowsPlatform)) {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            $testID = [guid]::NewGuid().ToString('N')

            $Script:ModuleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

            $arch = if ([System.Environment]::Is64BitProcess) {
                'x64'
            } else {
                'x86'
            }

            $Script:NativePath = Join-Path -Path $Script:ModuleRoot -ChildPath "lib\native\$arch"

            $Script:NativeDllPath = Join-Path -Path $Script:NativePath -ChildPath 'e_sqlite3.dll'

            $rootParam = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = ('PipeDFe.E2E.NativeDllLoading-{0}' -f $testID)
            }

            $Script:TestRoot = Join-Path @rootParam

            New-Item -ItemType Directory -Path $Script:TestRoot -Force -ErrorAction Stop | Out-Null

            if (-not (Test-Path -LiteralPath $Script:NativePath -PathType Container)) {
                throw ('Native SQLite directory was not found: {0}' -f $Script:NativePath)
            }

            if (-not (Test-Path -LiteralPath $Script:NativeDllPath -PathType Leaf)) {
                throw ('Native SQLite runtime was not found: {0}' -f $Script:NativeDllPath)
            }

            $Script:NativeDllDirectoryInitialized = $false
            $Script:NativeDllDirectoryCookie      = [System.IntPtr]::Zero

            Initialize-NativeDllLoader -LiteralPath $Script:NativePath -ErrorAction Stop
        }

        AfterAll {

            if ($null -ne $Script:TestRoot -and (Test-Path -LiteralPath $Script:TestRoot)) {
                Remove-Item -LiteralPath $Script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
            }

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }
        #endregion

        #region Native Dll resolution
        Context 'Native Dll resolution' {

            It 'Uses the native directory matching the current process architecture' {
                $expectedArch = if ([System.Environment]::Is64BitProcess) {
                    'x64'
                } else {
                    'x86'
                }

                $expectedPath = @{
                    Path      = $Script:ModuleRoot
                    ChildPath = "lib\native\$expectedArch"
                }

                $Script:NativePath | Should -Be (Join-Path @expectedPath)
            }

            It 'Contains the native SQLite runtime required by the provider' {
                Test-Path -LiteralPath $Script:NativeDllPath -PathType Leaf | Should -BeTrue
            }

            It 'Initializes the native Dll loader successfully' {
                $Script:NativeDllDirectoryInitialized | Should -BeTrue
            }

            It 'Registers the native directory with AddDllDirectory' {
                $Script:NativeDllDirectoryCookie | Should -Not -Be ([System.IntPtr]::Zero)
            }
        }
        #endregion

        #region SQLite connection
        Context 'SQLite connection after native initialization' {

            It 'Opens and executes a query through the native SQLite provider' {
                $database = @{
                    Path      = $Script:TestRoot
                    ChildPath = ('{0}.db' -f [guid]::NewGuid().ToString('N'))
                }

                $connection = $null
                $command    = $null

                try {
                    { Open-SqliteConnection -Path (Join-Path @database) -ErrorAction Stop } | Should -Not -Throw

                    $connection = Open-SqliteConnection -Path (Join-Path @database) -ErrorAction Stop

                    $connection | Should -Not -BeNullOrEmpty

                    $connection.State | Should -Be ([System.Data.ConnectionState]::Open)

                    $command = $connection.CreateCommand()
                    $command.CommandText = 'SELECT 1;'

                    $command.ExecuteScalar() | Should -Be 1
                } finally {
                    if ($null -ne $command) {
                        $command.Dispose()
                    }

                    if ($null -ne $connection) {
                        $connection.Dispose()
                    }
                }
            }

            It 'Creates the SQLite database in the isolated test directory' {
                $database = @{
                    Path      = $Script:TestRoot
                    ChildPath = ('{0}.db' -f [guid]::NewGuid().ToString('N'))
                }

                $connection = $null

                try {
                    $connection = Open-SqliteConnection -Path (Join-Path @database) -ErrorAction Stop

                    $connection.State | Should -Be ([System.Data.ConnectionState]::Open)
                } finally {
                    if ($null -ne $connection) {
                        $connection.Dispose()
                    }
                }

                Test-Path -LiteralPath (Join-Path @database) -PathType Leaf | Should -BeTrue
            }
        }
        #endregion
    }
}
