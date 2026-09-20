#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-DFeIndexedHash.

.DESCRIPTION
Coverage includes:
  - Parameter validation: mandatory, pattern, empty, null.
  - Returns no output when the index database does not exist.
  - Does not open a connection when the database does not exist.
  - Resolves the correct index path for the requested CNPJ.
  - Returns all hashes read from SQLite.
  - Opens exactly one connection.
  - Uses the correct database path.
  - Disposes reader, command and connection on success.
  - Disposes command and connection when execution fails.
  - Converts database failures to IndexedHashesReadFailed.
  - Preserves the original exception message.
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

Describe 'Get-DFeIndexedHash' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:FakeDatabasePath = [System.IO.Path]::Combine($TestDrive, 'index.db')

            Mock -CommandName Get-StorePath -MockWith {
                param ([string]$Scope, [string]$Cnpj)
                $null = $Scope
                $null = $Cnpj
                return $Script:FakeDatabasePath
            }
        }

        #region Parameter validation
        Context 'Parameter validation' {

            BeforeEach {

                Mock -CommandName Test-Path -MockWith {
                    param ([string]$LiteralPath, [string]$PathType)
                    $null = $LiteralPath
                    $null = $PathType
                    return $false
                }
            }

            It 'Accepts a valid normalized CNPJ' {
                { Get-DFeIndexedHash -Cnpj '12345678000199' } | Should -Not -Throw
            }

            It 'Accepts an alphanumeric 14-character CNPJ' {
                { Get-DFeIndexedHash -Cnpj '12ABC3456789DE' } | Should -Not -Throw
            }

            It 'Rejects a CNPJ containing punctuation' {
                { Get-DFeIndexedHash -Cnpj '12.345.678/0001-99' } | Should -Throw
            }

            It 'Rejects a CNPJ shorter than 14 digits' {
                { Get-DFeIndexedHash -Cnpj '1234567800019' } | Should -Throw
            }

            It 'Rejects a CNPJ longer than 14 digits' {
                { Get-DFeIndexedHash -Cnpj '123456780001990' } | Should -Throw
            }

            It 'Rejects an empty CNPJ' {
                { Get-DFeIndexedHash -Cnpj '' } | Should -Throw
            }

            It 'Rejects a null CNPJ' {
                { Get-DFeIndexedHash -Cnpj $null } | Should -Throw
            }
        }
        #endregion

        #region Database does not exist
        Context 'When the index database does not exist' {

            BeforeEach {

                Mock -CommandName Test-Path -MockWith {
                    param ([string]$LiteralPath, [string]$PathType)
                    $null = $LiteralPath
                    $null = $PathType
                    return $false
                }

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                }
            }

            It 'Returns no output' {
                @(Get-DFeIndexedHash -Cnpj '12345678000199') | Should -HaveCount 0
            }

            It 'Does not open a SQLite connection' {
                Get-DFeIndexedHash -Cnpj '12345678000199' | Out-Null

                $invokeParams = @{
                    CommandName = 'Open-SqliteConnection'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Resolves the index path for the requested CNPJ' {
                Get-DFeIndexedHash -Cnpj '12345678000199' | Out-Null

                $invokeParams = @{
                    CommandName     = 'Get-StorePath'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Scope -eq 'Index' -and $Cnpj -eq '12345678000199'
                    }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Returns hashes
        Context 'When SQLite returns indexed hashes' {

            BeforeEach {

                Mock -CommandName Test-Path -MockWith {
                    param ([string]$LiteralPath, [string]$PathType)
                    $null = $LiteralPath
                    $null = $PathType
                    return $true
                }

                $Script:FakeHashes = @('AAA', 'BBB', 'CCC')
                $Script:ReadIndex  = -1

                $Script:FakeReader = [PSCustomObject]@{}

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Read'
                    Value      = {
                        $Script:ReadIndex++
                        return $Script:ReadIndex -lt $Script:FakeHashes.Count
                    }
                }
                $Script:FakeReader | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'IsDBNull'
                    Value      = {
                        param ([int]$Ordinal)
                        $null = $Ordinal
                        return $false
                    }
                }
                $Script:FakeReader | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'GetString'
                    Value      = {
                        param ([int]$Ordinal)
                        $null = $Ordinal
                        return $Script:FakeHashes[$Script:ReadIndex]
                    }
                }
                $Script:FakeReader | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Dispose'
                    Value      = {}
                }
                $Script:FakeReader | Add-Member @memberParams -Force

                $Script:FakeCommand = [PSCustomObject]@{
                    CommandText = $null
                }

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'ExecuteReader'
                    Value      = {
                        $Script:ReadIndex = -1
                        return $Script:FakeReader
                    }
                }
                $Script:FakeCommand | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Dispose'
                    Value      = {}
                }
                $Script:FakeCommand | Add-Member @memberParams -Force

                $Script:FakeConnection = [PSCustomObject]@{}

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'CreateCommand'
                    Value      = { return $Script:FakeCommand }
                }
                $Script:FakeConnection | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Dispose'
                    Value      = {}
                }
                $Script:FakeConnection | Add-Member @memberParams -Force

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:FakeConnection
                }
            }

            It 'Returns exactly three hashes' {
                @(Get-DFeIndexedHash -Cnpj '12345678000199') | Should -HaveCount 3
            }

            It 'Returns the correct hash values in order' {
                $result = @(Get-DFeIndexedHash -Cnpj '12345678000199')

                $result[0] | Should -Be 'AAA'
                $result[1] | Should -Be 'BBB'
                $result[2] | Should -Be 'CCC'
            }

            It 'Opens exactly one SQLite connection' {
                Get-DFeIndexedHash -Cnpj '12345678000199' | Out-Null

                $invokeParams = @{
                    CommandName = 'Open-SqliteConnection'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Uses the correct database path' {
                Get-DFeIndexedHash -Cnpj '12345678000199' | Out-Null

                $invokeParams = @{
                    CommandName     = 'Open-SqliteConnection'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Path -eq $Script:FakeDatabasePath
                    }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Resource disposal
        Context 'Resource disposal on success' {

            BeforeEach {

                Mock -CommandName Test-Path -MockWith {
                    param ([string]$LiteralPath, [string]$PathType)
                    $null = $LiteralPath
                    $null = $PathType
                    return $true
                }

                $Script:Disposed = @{
                    Reader     = $false
                    Command    = $false
                    Connection = $false
                }

                $Script:DisposeReader = [PSCustomObject]@{}

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Read'
                    Value      = { return $false }
                }
                $Script:DisposeReader | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'IsDBNull'
                    Value      = {
                        param ([int]$Ordinal)
                        $null = $Ordinal
                        return $false
                    }
                }
                $Script:DisposeReader | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'GetString'
                    Value      = {
                        param ([int]$Ordinal)
                        $null = $Ordinal
                        return [string]::Empty
                    }
                }
                $Script:DisposeReader | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Dispose'
                    Value      = { $Script:Disposed.Reader = $true }
                }
                $Script:DisposeReader | Add-Member @memberParams -Force

                $Script:DisposeCommand = [PSCustomObject]@{
                    CommandText = $null
                }

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'ExecuteReader'
                    Value      = { return $Script:DisposeReader }
                }
                $Script:DisposeCommand | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Dispose'
                    Value      = { $Script:Disposed.Command = $true }
                }
                $Script:DisposeCommand | Add-Member @memberParams -Force

                $Script:DisposeConnection = [PSCustomObject]@{}

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'CreateCommand'
                    Value      = { return $Script:DisposeCommand }
                }
                $Script:DisposeConnection | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Dispose'
                    Value      = { $Script:Disposed.Connection = $true }
                }
                $Script:DisposeConnection | Add-Member @memberParams -Force

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:DisposeConnection
                }
            }

            It 'Disposes the reader' {
                Get-DFeIndexedHash -Cnpj '12345678000199' | Out-Null

                $Script:Disposed.Reader | Should -BeTrue
            }

            It 'Disposes the command' {
                Get-DFeIndexedHash -Cnpj '12345678000199' | Out-Null

                $Script:Disposed.Command | Should -BeTrue
            }

            It 'Disposes the connection' {
                Get-DFeIndexedHash -Cnpj '12345678000199' | Out-Null

                $Script:Disposed.Connection | Should -BeTrue
            }
        }
        #endregion

        #region Failure handling
        Context 'When reading the database fails' {

            BeforeEach {

                Mock -CommandName Test-Path -MockWith {
                    param ([string]$LiteralPath, [string]$PathType)
                    $null = $LiteralPath
                    $null = $PathType
                    return $true
                }

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    throw [System.Exception]::new('Simulated SQLite failure')
                }

                $Script:FailException = $null

                try {
                    Get-DFeIndexedHash -Cnpj '12345678000199' | Out-Null
                } catch {
                    $Script:FailException = $_
                }
            }

            It 'Throws a terminating error' {
                $Script:FailException | Should -Not -BeNullOrEmpty
            }

            It 'Uses IndexedHashesReadFailed as the error identifier' {
                $Script:FailException.FullyQualifiedErrorId |
                    Should -BeLike 'IndexedHashesReadFailed*'
            }

            It 'Preserves the original exception message' {
                $Script:FailException.Exception.Message |
                    Should -Be 'Simulated SQLite failure'
            }
        }
        #endregion

        #region Command execution failure
        Context 'When command execution fails' {

            BeforeEach {

                Mock -CommandName Test-Path -MockWith {
                    param ([string]$LiteralPath, [string]$PathType)
                    $null = $LiteralPath
                    $null = $PathType
                    return $true
                }

                $Script:ExecDisposed = @{
                    Command    = $false
                    Connection = $false
                }

                $Script:ExecCommand = [PSCustomObject]@{
                    CommandText = $null
                }

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'ExecuteReader'
                    Value      = {
                        throw [System.InvalidOperationException]::new(
                            'Simulated ExecuteReader failure'
                        )
                    }
                }
                $Script:ExecCommand | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Dispose'
                    Value      = { $Script:ExecDisposed.Command = $true }
                }
                $Script:ExecCommand | Add-Member @memberParams -Force

                $Script:ExecConnection = [PSCustomObject]@{}

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'CreateCommand'
                    Value      = { return $Script:ExecCommand }
                }
                $Script:ExecConnection | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Dispose'
                    Value      = { $Script:ExecDisposed.Connection = $true }
                }
                $Script:ExecConnection | Add-Member @memberParams -Force

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:ExecConnection
                }

                $Script:ExecException = $null

                try {
                    Get-DFeIndexedHash -Cnpj '12345678000199' | Out-Null
                } catch {
                    $Script:ExecException = $_
                }
            }

            It 'Throws IndexedHashesReadFailed' {
                $Script:ExecException.FullyQualifiedErrorId |
                    Should -BeLike 'IndexedHashesReadFailed*'
            }

            It 'Disposes the command when execution fails' {
                $Script:ExecDisposed.Command | Should -BeTrue
            }

            It 'Disposes the connection when execution fails' {
                $Script:ExecDisposed.Connection | Should -BeTrue
            }
        }
        #endregion
    }
}
