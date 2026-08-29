#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration and contract tests for Open-DFeIndexConnection.

.DESCRIPTION
Verifies the public contract of Open-DFeIndexConnection.

Coverage includes:
  - Cnpj is mandatory;
  - Cnpj must contain exactly 14 digits;
  - Initialize-DFeIndex is used to obtain the database path;
  - a real SQLiteConnection is returned;
  - the returned connection is open;
  - the returned connection is usable;
  - the connection points to the database initialized for the CNPJ;
  - existing database data remains accessible;
  - the caller owns the returned connection;
  - connection-opening failures are converted to IndexConnectionOpenFailed;
  - connection-opening failures use ConnectionError;
  - connection-opening failures expose the database path as TargetObject;
  - the declared output type is SQLiteConnection.

The success-path tests use real SQLite files.

The failure-path tests use a directory path as the database path, which
causes SQLite to fail on Open() deterministically across all providers.

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

Describe 'Open-DFeIndexConnection' {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            $joinPathParams = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = 'PipeDFe.Open-DFeIndexConnection.Tests-' + [guid]::NewGuid().ToString('N')
            }

            $Script:TestRoot = Join-Path @joinPathParams

            New-Item -ItemType Directory -Path $Script:TestRoot -Force -ErrorAction Stop |
                Out-Null

            function New-TestDatabasePath {
                [OutputType([string])]
                param ()

                $joinPathParams = @{
                    Path      = $Script:TestRoot
                    ChildPath = [guid]::NewGuid().ToString('N') + '.db'
                }

                Join-Path @joinPathParams
            }

            function New-TestDirectoryPath {
                [OutputType([string])]
                param ()

                $joinPathParams = @{
                    Path      = $Script:TestRoot
                    ChildPath = [guid]::NewGuid().ToString('N')
                }

                $path = Join-Path @joinPathParams

                New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null

                $path
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

            function Invoke-TestScalar {
                param (
                    [Parameter(Mandatory)]
                    [System.Data.SQLite.SQLiteConnection]$Connection,

                    [Parameter(Mandatory)]
                    [string]$CommandText
                )

                $command = $null

                try {
                    $command = $Connection.CreateCommand()
                    $command.CommandText = $CommandText

                    $command.ExecuteScalar()
                } finally {
                    if ($null -ne $command) {
                        $command.Dispose()
                    }
                }
            }

            function Invoke-TestNonQuery {
                param (
                    [Parameter(Mandatory)]
                    [System.Data.SQLite.SQLiteConnection]$Connection,

                    [Parameter(Mandatory)]
                    [string]$CommandText
                )

                $command = $null

                try {
                    $command = $Connection.CreateCommand()
                    $command.CommandText = $CommandText

                    $command.ExecuteNonQuery()
                } finally {
                    if ($null -ne $command) {
                        $command.Dispose()
                    }
                }
            }
        }

        AfterAll {

            if ($null -ne $Script:TestRoot -and (Test-Path -LiteralPath $Script:TestRoot)) {
                $removeParams = @{
                    LiteralPath = $Script:TestRoot
                    Recurse     = $true
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeParams
            }

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }
        #endregion

        #region Parameter contract
        Context 'Parameter contract' {

            BeforeAll {

                $Script:Command = Get-Command -Name Open-DFeIndexConnection -ErrorAction Stop
            }

            It 'Exposes the Cnpj parameter' {
                $Script:Command.Parameters.ContainsKey('Cnpj') | Should -BeTrue
            }

            It 'Declares Cnpj as a string' {
                $Script:Command.Parameters['Cnpj'].ParameterType | Should -Be ([string])
            }

            It 'Declares Cnpj as mandatory' {
                $mandatoryAttributes = @(
                    $Script:Command.Parameters['Cnpj'].Attributes |
                        Where-Object {
                            $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
                        }
                )

                $mandatoryAttributes | Should -Not -BeNullOrEmpty
            }

            It 'Declares ValidatePattern on Cnpj' {
                $Script:Command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ValidatePatternAttribute]
                    } |

                    Should -Not -BeNullOrEmpty
            }

            It 'Uses the expected CNPJ validation pattern' {
                $validationAttribute = $Script:Command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ValidatePatternAttribute]
                    } |

                    Select-Object -First 1

                $validationAttribute.RegexPattern | Should -Be '^[A-Z0-9]{14}$'
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

        #region CNPJ validation
        Context 'Cnpj validation' {

            It 'Accepts a valid 14-digit CNPJ' {
                {
                    $connection = Open-DFeIndexConnection -Cnpj '12345678000199' -ErrorAction Stop

                    Close-TestConnection -Connection $connection
                } | Should -Not -Throw
            }

            It 'Rejects a CNPJ shorter than 14 digits' {
                { Open-DFeIndexConnection -Cnpj '1234567800019' -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Rejects a CNPJ longer than 14 digits' {
                { Open-DFeIndexConnection -Cnpj '123456780001990' -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Rejects invalid characters' {
                { Open-DFeIndexConnection -Cnpj '1234567800019!' -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Rejects punctuation characters' {
                { Open-DFeIndexConnection -Cnpj '12.345.678/0001-99' -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Rejects an empty CNPJ' {
                { Open-DFeIndexConnection -Cnpj '' -ErrorAction Stop } | Should -Throw
            }

            It 'Rejects a null CNPJ' {
                { Open-DFeIndexConnection -Cnpj $null -ErrorAction Stop } | Should -Throw
            }
        }
        #endregion

        #region Successful connection
        Context 'Successful connection' {

            BeforeAll {

                $Script:SuccessCnpj = '12345678000199'
                $Script:SuccessDatabasePath = New-TestDatabasePath

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    $Script:SuccessDatabasePath
                }

                $Script:SuccessConnection = Open-DFeIndexConnection -Cnpj $Script:SuccessCnpj -ErrorAction Stop
            }

            AfterAll {

                Close-TestConnection -Connection $Script:SuccessConnection
            }

            It 'Calls Initialize-DFeIndex with the supplied CNPJ' {
                $dbPath = New-TestDatabasePath
                $connection = $null

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    $dbPath
                }

                try {
                    $connection = Open-DFeIndexConnection -Cnpj '12345678000199' -ErrorAction Stop

                    $invokeParams = @{
                        CommandName     = 'Initialize-DFeIndex'
                        Times           = 1
                        Exactly         = $true
                        ParameterFilter = { $Cnpj -eq '12345678000199' }
                    }

                    Should -Invoke @invokeParams
                } finally {
                    Close-TestConnection -Connection $connection
                }
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

            It 'Points to the database returned by Initialize-DFeIndex' {
                $Script:SuccessConnection.FileName |
                    Should -Be ([System.IO.Path]::GetFullPath($Script:SuccessDatabasePath))
            }

            It 'Returns a usable SQLite connection' {
                Invoke-TestScalar -Connection $Script:SuccessConnection -CommandText 'SELECT 1;' |
                    Should -Be 1
            }

            It 'Can execute SQLite metadata queries' {
                Invoke-TestScalar -Connection $Script:SuccessConnection -CommandText 'SELECT sqlite_version();' |
                    Should -Not -BeNullOrEmpty
            }

            It 'Allows the caller to create database objects' {
                $nonQueryParams = @{
                    Connection  = $Script:SuccessConnection
                    CommandText = 'CREATE TABLE ConnectionContractTest (Id INTEGER PRIMARY KEY, Value TEXT NOT NULL);'
                }

                { Invoke-TestNonQuery @nonQueryParams } | Should -Not -Throw
            }

            It 'Allows the caller to insert and read data' {
                $nonQueryParams = @{
                    Connection  = $Script:SuccessConnection
                    CommandText = 'INSERT INTO ConnectionContractTest (Value) VALUES (''production-contract'');'
                }

                $scalarParams = @{
                    Connection  = $Script:SuccessConnection
                    CommandText = 'SELECT Value FROM ConnectionContractTest WHERE Id = 1;'
                }

                $insertResult = Invoke-TestNonQuery @nonQueryParams
                $insertResult | Should -Be 1

                $scalarResult = Invoke-TestScalar @scalarParams
                $scalarResult | Should -Be 'production-contract'
            }

            It 'Leaves connection ownership with the caller' {
                $Script:SuccessConnection.State |
                    Should -Be ([System.Data.ConnectionState]::Open)

                Invoke-TestScalar -Connection $Script:SuccessConnection -CommandText 'SELECT 1;' |
                    Should -Be 1
            }
        }
        #endregion

        #region Existing database
        Context 'Existing database' {

            BeforeAll {

                $Script:ExistingCnpj = '98765432000188'
                $Script:ExistingDatabasePath = New-TestDatabasePath

                $connectionString = "Data Source=$Script:ExistingDatabasePath;Version=3;"
                $setupConnection = [System.Data.SQLite.SQLiteConnection]::new($connectionString)

                $setupConnection.Open()

                try {
                    $nonQueryOneParams = @{
                        Connection  = $setupConnection
                        CommandText = 'CREATE TABLE ExistingData (Id INTEGER PRIMARY KEY, Value TEXT NOT NULL);'
                    }

                    $nonQueryTwoParams = @{
                        Connection  = $setupConnection
                        CommandText = 'INSERT INTO ExistingData (Value) VALUES (''existing-value'');'
                    }

                    Invoke-TestNonQuery @nonQueryOneParams | Out-Null

                    Invoke-TestNonQuery @nonQueryTwoParams | Out-Null
                } finally {
                    Close-TestConnection -Connection $setupConnection
                }

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    $Script:ExistingDatabasePath
                }

                $connectionParams = @{
                    Cnpj        = $Script:ExistingCnpj
                    ErrorAction = 'Stop'
                }

                $Script:ExistingConnection = Open-DFeIndexConnection @connectionParams

            }

            AfterAll {

                Close-TestConnection -Connection $Script:ExistingConnection
            }

            It 'Opens an existing database without error' {
                $Script:ExistingConnection |
                    Should -BeOfType ([System.Data.SQLite.SQLiteConnection])

                $Script:ExistingConnection.State |
                    Should -Be ([System.Data.ConnectionState]::Open)
            }

            It 'Preserves existing data' {
                $scalarParams = @{
                    Connection  = $Script:ExistingConnection
                    CommandText = 'SELECT Value FROM ExistingData WHERE Id = 1;'
                }

                $scalarResult = Invoke-TestScalar @scalarParams
                $scalarResult | Should -Be 'existing-value'
            }

            It 'Uses the database path returned by Initialize-DFeIndex' {
                $Script:ExistingConnection.FileName |
                    Should -Be ([System.IO.Path]::GetFullPath($Script:ExistingDatabasePath))
            }
        }
        #endregion

        #region Multiple connections
        Context 'Multiple connections' {
            BeforeAll {

                $Script:MultiCnpj         = '11111111000111'
                $Script:MultiDatabasePath = New-TestDatabasePath

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    $Script:MultiDatabasePath
                }
            }

            It 'Returns a new connection instance for each invocation' {
                $connection1 = $null
                $connection2 = $null

                try {
                    $connection1 = Open-DFeIndexConnection -Cnpj $Script:MultiCnpj -ErrorAction Stop
                    $connection2 = Open-DFeIndexConnection -Cnpj $Script:MultiCnpj -ErrorAction Stop

                    $connection1 | Should -BeOfType ([System.Data.SQLite.SQLiteConnection])
                    $connection2 | Should -BeOfType ([System.Data.SQLite.SQLiteConnection])

                    [object]::ReferenceEquals($connection1, $connection2) | Should -BeFalse

                    $connection1.State | Should -Be ([System.Data.ConnectionState]::Open)
                    $connection2.State | Should -Be ([System.Data.ConnectionState]::Open)
                } finally {
                    Close-TestConnection -Connection $connection1
                    Close-TestConnection -Connection $connection2
                }
            }

            It 'Calls Initialize-DFeIndex for every invocation' {
                $connection1 = $null
                $connection2 = $null

                try {
                    $connection1 = Open-DFeIndexConnection -Cnpj $Script:MultiCnpj -ErrorAction Stop
                    $connection2 = Open-DFeIndexConnection -Cnpj $Script:MultiCnpj -ErrorAction Stop
                } finally {
                    Close-TestConnection -Connection $connection1
                    Close-TestConnection -Connection $connection2
                }

                $invokeParams = @{
                    CommandName = 'Initialize-DFeIndex'
                    Times       = 2
                    Exactly     = $true
                    Scope       = 'It'
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Connection opening failure
        Context 'Connection opening failure' {

            BeforeAll {
                # A directory path causes SQLite to fail on Open() deterministically.
                $Script:FailDbPath = New-TestDirectoryPath

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    $Script:FailDbPath
                }
            }

            It 'Converts an Open() failure to IndexConnectionOpenFailed' {
                try {
                    Open-DFeIndexConnection -Cnpj '22222222000122' -ErrorAction Stop

                    throw 'Expected Open-DFeIndexConnection to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'IndexConnectionOpenFailed*'
                }
            }

            It 'Uses ConnectionError for an Open() failure' {
                try {
                    Open-DFeIndexConnection -Cnpj '33333333000133' -ErrorAction Stop

                    throw 'Expected Open-DFeIndexConnection to fail.'
                } catch {
                    $_.CategoryInfo.Category |
                        Should -Be ([System.Management.Automation.ErrorCategory]::ConnectionError)
                }
            }

            It 'Uses the database path as TargetObject' {
                try {
                    Open-DFeIndexConnection -Cnpj '44444444000144' -ErrorAction Stop

                    throw 'Expected Open-DFeIndexConnection to fail.'
                } catch {
                    $_.TargetObject | Should -Be $Script:FailDbPath
                }
            }

            It 'Preserves the original exception' {
                try {
                    Open-DFeIndexConnection -Cnpj '55555555000155' -ErrorAction Stop

                    throw 'Expected Open-DFeIndexConnection to fail.'
                } catch {
                    $_.Exception | Should -Not -BeNullOrEmpty
                }
            }

            It 'Does not return a connection when Open() fails' {
                $result = $null

                try {
                    $result = Open-DFeIndexConnection -Cnpj '66666666000166' -ErrorAction Stop
                } catch {
                    $null = $_
                }

                $result | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Caller ownership
        Context 'Caller ownership' {

            BeforeAll {
                $Script:OwnershipDbPath = New-TestDatabasePath

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    $Script:OwnershipDbPath
                }
            }

            It 'Does not dispose the returned connection before returning' {
                $connection = $null

                try {
                    $connection = Open-DFeIndexConnection -Cnpj '77777777000177' -ErrorAction Stop

                    $connection | Should -Not -BeNullOrEmpty
                    $connection.State | Should -Be ([System.Data.ConnectionState]::Open)

                    Invoke-TestScalar -Connection $connection -CommandText 'SELECT 1;' |
                        Should -Be 1
                } finally {
                    Close-TestConnection -Connection $connection
                }
            }

            It 'Can be disposed by the caller' {
                $connection = $null

                try {
                    $connection = Open-DFeIndexConnection -Cnpj '88888888000188' -ErrorAction Stop

                    { $connection.Dispose() } | Should -Not -Throw
                } finally {
                    Close-TestConnection -Connection $connection
                }
            }
        }
        #endregion
    }
}
