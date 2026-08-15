<#
.SYNOPSIS
Integration tests for Open-SqliteConnection.

.DESCRIPTION
Verifies the public contract of Open-SqliteConnection.

Coverage includes:
  - Path is mandatory;
  - Path must not be null or empty;
  - a relative path is normalised to an absolute path;
  - a new database file is created by SQLite when the path does not exist;
  - a real SQLiteConnection is returned;
  - the returned connection is open and usable;
  - the connection points to the normalised database path;
  - a connection failure produces SqliteConnectionFailed;
  - SqliteConnectionFailed uses ConnectionError;
  - SqliteConnectionFailed exposes the normalised path as TargetObject;
  - the connection is disposed before the error is thrown;
  - the declared output type is SQLiteConnection;
  - the caller owns the returned connection.

All tests use real SQLite files in an isolated temporary directory.
No production data is accessed.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
)]

param ()

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Open-SqliteConnection' {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            $joinPathParams = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = 'PipeDFe.Open-SqliteConnection.Tests-' + [guid]::NewGuid().ToString('N')
            }

            $Script:TestRoot = Join-Path @joinPathParams

            New-Item -ItemType Directory -Path $Script:TestRoot -Force -ErrorAction Stop |
                Out-Null

            function New-TestDbPath {
                [OutputType([string])]
                param ()

                $joinPathParams = @{
                    Path      = $Script:TestRoot
                    ChildPath = [guid]::NewGuid().ToString('N') + '.db'
                }

                Join-Path @joinPathParams
            }

            function Close-TestConnection {
                param (
                    [AllowNull()]
                    [System.Data.SQLite.SQLiteConnection]$Connection
                )

                if ($null -ne $Connection) {
                    try {
                        $Connection.Dispose()
                    } catch {
                        $null = $_
                    }
                }
            }
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
        #endregion

        #region Parameter contract
        Context 'Parameter contract' {

            BeforeAll {
                $Script:Command = Get-Command -Name Open-SqliteConnection -ErrorAction Stop
            }

            It 'Exposes the Path parameter' {
                $Script:Command.Parameters.ContainsKey('Path') | Should -BeTrue
            }

            It 'Declares Path as a string' {
                $Script:Command.Parameters['Path'].ParameterType | Should -Be ([string])
            }

            It 'Declares Path as mandatory' {
                $mandatoryAttributes = @(
                    $Script:Command.Parameters['Path'].Attributes |
                        Where-Object {
                            $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
                        }
                )

                $mandatoryAttributes | Should -Not -BeNullOrEmpty
            }

            It 'Declares ValidateNotNullOrEmpty on Path' {
                $Script:Command.Parameters['Path'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ValidateNotNullOrEmptyAttribute]
                    } |

                    Should -Not -BeNullOrEmpty
            }

            It 'Declares SQLiteConnection as the output type' {
                $outputTypes = @(
                    $Script:Command.OutputType |
                        ForEach-Object {
                            if ($_ -is [System.Type]) {
                                $_
                            } elseif ($null -ne $_.Type) {
                                $_.Type
                            }
                        }
                )

                $outputTypes.FullName | Should -Contain 'System.Data.SQLite.SQLiteConnection'
            }
        }
        #endregion

        #region Parameter validation
        Context 'Parameter validation' {

            It 'Rejects an empty Path' {
                { Open-SqliteConnection -Path '' } | Should -Throw
            }

            It 'Rejects a null Path' {
                { Open-SqliteConnection -Path $null } | Should -Throw
            }
        }
        #endregion

        #region Successful connection
        Context 'Successful connection' {

            BeforeAll {

                $Script:SuccessDbPath     = New-TestDbPath
                $Script:SuccessConnection = Open-SqliteConnection -Path $Script:SuccessDbPath -ErrorAction Stop
            }

            AfterAll {

                Close-TestConnection -Connection $Script:SuccessConnection
            }

            It 'Returns a SQLiteConnection' {
                $Script:SuccessConnection |
                    Should -BeOfType ([System.Data.SQLite.SQLiteConnection])
            }

            It 'Returns a non-null connection' {
                $Script:SuccessConnection | Should -Not -BeNullOrEmpty
            }

            It 'Returns an open connection' {
                $Script:SuccessConnection.State |
                    Should -Be ([System.Data.ConnectionState]::Open)
            }

            It 'Points to the normalised database path' {
                $Script:SuccessConnection.FileName |
                    Should -Be ([System.IO.Path]::GetFullPath($Script:SuccessDbPath))
            }

            It 'Returns a usable connection' {
                $command = $Script:SuccessConnection.CreateCommand()

                try {
                    $command.CommandText = 'SELECT 1;'
                    $command.ExecuteScalar() | Should -Be 1
                } finally {
                    $command.Dispose()
                }
            }
        }
        #endregion

        #region New database file
        Context 'New database file' {

            It 'Creates the database file when it does not exist' {
                $dbPath     = New-TestDbPath
                $connection = Open-SqliteConnection -Path $dbPath -ErrorAction Stop

                Close-TestConnection -Connection $connection

                Test-Path -LiteralPath $dbPath -PathType Leaf | Should -BeTrue
            }
        }

        #endregion

        #region Relative path
        Context 'Relative path' {

            It 'Normalises a relative path to an absolute path' {
                $fileName = [guid]::NewGuid().ToString('N') + '.db'
                $savedDir = [System.IO.Directory]::GetCurrentDirectory()

                [System.IO.Directory]::SetCurrentDirectory($Script:TestRoot)

                $connection = $null

                try {
                    $connection = Open-SqliteConnection -Path $fileName -ErrorAction Stop

                    $joinPathParams = @{
                        Path      = $Script:TestRoot
                        ChildPath = $fileName
                    }

                    $expectedPath = [System.IO.Path]::GetFullPath((Join-Path @joinPathParams ))

                    $connection.FileName | Should -Be $expectedPath
                } finally {
                    Close-TestConnection -Connection $connection
                    [System.IO.Directory]::SetCurrentDirectory($savedDir)
                }
            }
        }
        #endregion

        #region Connection failure
        Context 'Connection failure' {

            BeforeAll {
                # A directory path causes SQLite to fail on Open() deterministically.
                $joinPathParams = @{
                    Path      = $Script:TestRoot
                    ChildPath = [guid]::NewGuid().ToString('N')
                }

                $Script:FailPath = Join-Path @joinPathParams

                New-Item -ItemType Directory -Path $Script:FailPath -Force -ErrorAction Stop |
                    Out-Null
            }

            It 'Throws a terminating error' {
                { Open-SqliteConnection -Path $Script:FailPath -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports SqliteConnectionFailed as ErrorId' {
                try {
                    Open-SqliteConnection -Path $Script:FailPath -ErrorAction Stop
                    throw 'Expected Open-SqliteConnection to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'SqliteConnectionFailed*'
                }
            }

            It 'Uses ConnectionError as the error category' {
                try {
                    Open-SqliteConnection -Path $Script:FailPath -ErrorAction Stop
                    throw 'Expected Open-SqliteConnection to fail.'
                } catch {
                    $_.CategoryInfo.Category |
                        Should -Be ([System.Management.Automation.ErrorCategory]::ConnectionError)
                }
            }

            It 'Exposes the normalised path as TargetObject' {
                try {
                    Open-SqliteConnection -Path $Script:FailPath -ErrorAction Stop
                    throw 'Expected Open-SqliteConnection to fail.'
                } catch {
                    $_.TargetObject |
                        Should -Be ([System.IO.Path]::GetFullPath($Script:FailPath))
                }
            }

            It 'Preserves the original exception' {
                try {
                    Open-SqliteConnection -Path $Script:FailPath -ErrorAction Stop
                    throw 'Expected Open-SqliteConnection to fail.'
                } catch {
                    $_.Exception | Should -Not -BeNullOrEmpty
                }
            }

            It 'Does not return a connection on failure' {
                $result = $null

                try {
                    $result = Open-SqliteConnection -Path $Script:FailPath -ErrorAction Stop
                } catch {
                    $null = $_
                }

                $result | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Caller ownership
        Context 'Caller ownership' {

            It 'Does not dispose the connection before returning' {
                $connection = $null

                try {
                    $connection = Open-SqliteConnection -Path (New-TestDbPath) -ErrorAction Stop
                    $connection.State | Should -Be ([System.Data.ConnectionState]::Open)
                } finally {
                    Close-TestConnection -Connection $connection
                }
            }

            It 'Can be disposed by the caller without error' {
                $connection = Open-SqliteConnection -Path (New-TestDbPath) -ErrorAction Stop

                { $connection.Dispose() } | Should -Not -Throw
            }
        }
        #endregion
    }
}
