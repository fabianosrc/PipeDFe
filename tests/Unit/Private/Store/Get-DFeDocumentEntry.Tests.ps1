#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-DFeDocumentEntry.

.DESCRIPTION
Coverage includes:

- Parameter validation: mandatory, pattern, empty, null.
- No filters returns all documents without WHERE clause.
- StartDate filter adds correct SQL and parameter.
- EndDate filter adds correct SQL and parameter.
- Modelo filter adds correct SQL and parameter.
- ProcessingStatus filter adds correct SQL and parameter.
- All filters combined build the complete WHERE clause.
- Whitespace StartDate and EndDate are treated as absent.
- Date conversion error is preserved without accessing the database.
- NULL ndoc and serie are mapped to null.
- NULL processing_started_at, processed_at and processing_error are mapped to null.
- Column mapping for all thirteen output properties.
- is_proc 0 maps to false; 1 maps to true.
- No output when no rows match.
- Database connection failure converts to DocumentEntryReadFailed.
- ExecuteReader failure converts to DocumentEntryReadFailed.
- Reader, command and connection are disposed on success.
- Command and connection are disposed when ExecuteReader fails.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Test helper functions do not require ShouldProcess.'
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

Describe 'Get-DFeDocumentEntry' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Cnpj         = '12345678000199'
            $Script:DatabasePath = 'C:\PipeDFe\Index\12345678000199\data\index.db'

            $Script:StartDate = [System.DateTimeOffset]::Parse('2026-08-01T00:00:00.0000000+00:00')
            $Script:EndDate   = [System.DateTimeOffset]::Parse('2026-08-31T23:59:59.9999999+00:00')

            $Script:Row1 = @{
                chave_acesso          = '35260812345678000199550010000000011000000001'
                modelo                = 55
                dh_emi                = '2026-08-01T10:00:00.0000000+00:00'
                file_path             = 'C:\DFe\0001.xml'
                is_proc               = 1
                ndoc                  = 1
                serie                 = '001'
                sha256                = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
                indexed_at            = '2026-08-01T10:05:00.0000000+00:00'
                processing_status     = 'Processed'
                processing_started_at = '2026-08-01T10:06:00.0000000+00:00'
                processed_at          = '2026-08-01T10:07:00.0000000+00:00'
                processing_error      = $null
            }

            $Script:Row2 = @{
                chave_acesso          = '35260812345678000199550010000000021000000002'
                modelo                = 55
                dh_emi                = '2026-08-15T10:00:00.0000000+00:00'
                file_path             = 'C:\DFe\0002.xml'
                is_proc               = 0
                ndoc                  = 2
                serie                 = '001'
                sha256                = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
                indexed_at            = '2026-08-15T10:05:00.0000000+00:00'
                processing_status     = 'Failed'
                processing_started_at = '2026-08-15T10:06:00.0000000+00:00'
                processed_at          = $null
                processing_error      = 'Fiscal processing failed.'
            }

            $Script:Row3 = @{
                chave_acesso          = '35260812345678000199550010000000031000000003'
                modelo                = 65
                dh_emi                = '2026-08-20T10:00:00.0000000+00:00'
                file_path             = 'C:\DFe\0003.xml'
                is_proc               = 1
                ndoc                  = $null
                serie                 = $null
                sha256                = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC'
                indexed_at            = '2026-08-20T10:05:00.0000000+00:00'
                processing_status     = 'Indexed'
                processing_started_at = $null
                processed_at          = $null
                processing_error      = $null
            }

            function New-TestParameterCollection {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param ()

                $list = [System.Collections.Generic.List[pscustomobject]]::new()

                $collection = [pscustomobject]@{
                    _list = $list
                    Count = 0
                }

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Add'
                    Value      = {
                        param ([string]$Name, [System.Data.DbType]$DbType)
                        $param = [PSCustomObject]@{
                            ParameterName = $Name
                            DbType        = $DbType
                            Value         = $null
                        }
                        $this._list.Add($param)
                        $this.Count = $this._list.Count
                        return $param
                    }
                }

                $collection | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'GetEnumerator'
                    Value      = { return $this._list.GetEnumerator() }
                }

                $collection | Add-Member @memberParams -Force

                return $collection
            }

            function New-TestReader {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter()]
                    [hashtable[]]$Rows = @()
                )

                $reader = [PSCustomObject]@{
                    CurrentIndex = -1
                    Rows         = $Rows
                    Disposed     = $false
                }

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Read'
                    Value      = {
                        $this.CurrentIndex++
                        return $this.CurrentIndex -lt $this.Rows.Count
                    }
                }

                $reader | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'IsDBNull'
                    Value      = {
                        param ([int]$Index)
                        $row = $this.Rows[$this.CurrentIndex]

                        switch ($Index) {
                            0  { return $null -eq $row.chave_acesso          }
                            1  { return $null -eq $row.modelo                }
                            2  { return $null -eq $row.dh_emi                }
                            3  { return $null -eq $row.file_path             }
                            4  { return $null -eq $row.is_proc               }
                            5  { return $null -eq $row.ndoc                  }
                            6  { return $null -eq $row.serie                 }
                            7  { return $null -eq $row.sha256                }
                            8  { return $null -eq $row.indexed_at            }
                            9  { return $null -eq $row.processing_status     }
                            10 { return $null -eq $row.processing_started_at }
                            11 { return $null -eq $row.processed_at          }
                            12 { return $null -eq $row.processing_error      }

                            default { throw "Unexpected column index: $Index" }
                        }
                    }
                }
                $reader | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'GetString'
                    Value      = {
                        param ([int]$Index)
                        $row = $this.Rows[$this.CurrentIndex]

                        switch ($Index) {
                            0  { return [string]$row.chave_acesso          }
                            2  { return [string]$row.dh_emi                }
                            3  { return [string]$row.file_path             }
                            6  { return [string]$row.serie                 }
                            7  { return [string]$row.sha256                }
                            8  { return [string]$row.indexed_at            }
                            9  { return [string]$row.processing_status     }
                            10 { return [string]$row.processing_started_at }
                            11 { return [string]$row.processed_at          }
                            12 { return [string]$row.processing_error      }

                            default { throw "Unexpected GetString column index: $Index" }
                        }
                    }
                }

                $reader | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'GetInt32'
                    Value      = {
                        param ([int]$Index)
                        $row = $this.Rows[$this.CurrentIndex]

                        switch ($Index) {
                            1 { return [int]$row.modelo  }
                            4 { return [int]$row.is_proc }
                            5 { return [int]$row.ndoc    }

                            default { throw "Unexpected GetInt32 column index: $Index" }
                        }
                    }
                }

                $reader | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Dispose'
                    Value      = { $this.Disposed = $true }
                }

                $reader | Add-Member @memberParams -Force

                return $reader
            }

            function New-TestCommand {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    $Reader
                )

                $command = [PSCustomObject]@{
                    CommandText  = $null
                    Parameters   = (New-TestParameterCollection)
                    _Reader      = $Reader
                    Disposed     = $false
                }

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'ExecuteReader'
                    Value      = {
                        if ($this._Reader -is [scriptblock]) {
                            return & $this._Reader
                        }
                        return $this._Reader
                    }
                }

                $command | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Dispose'
                    Value      = { $this.Disposed = $true }
                }

                $command | Add-Member @memberParams -Force

                return $command
            }

            function New-TestConnection {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    $Command
                )

                $connection = [PSCustomObject]@{
                    Command  = $Command
                    Disposed = $false
                }

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'CreateCommand'
                    Value      = { return $this.Command }
                }

                $connection | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Dispose'
                    Value      = { $this.Disposed = $true }
                }

                $connection | Add-Member @memberParams -Force

                return $connection
            }

            function Get-TestParameter {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    $Command,

                    [Parameter(Mandatory)]
                    [string]$Name
                )

                @(
                    $Command.Parameters._list | Where-Object { $_.ParameterName -eq $Name }
                ) | Select-Object -First 1
            }
        }

        BeforeEach {

            $Script:Reader     = $null
            $Script:Command    = $null
            $Script:Connection = $null

            Mock -CommandName Get-StorePath -MockWith {
                param ([string]$Scope, [string]$Cnpj)
                $null = $Scope
                $null = $Cnpj
                return $Script:DatabasePath
            }

            Mock -CommandName ConvertTo-DateTimeOffset -MockWith {
                param ([string]$Value)
                switch ($Value) {
                    'start-input' { return $Script:StartDate }
                    'end-input'   { return $Script:EndDate   }

                    default       { throw "Unexpected date value: $Value" }
                }
            }
        }

        #region Parameter validation
        Context 'Parameter validation' {

            BeforeEach {

                $Script:Reader     = New-TestReader
                $Script:Command    = New-TestCommand -Reader $Script:Reader
                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }
            }

            It 'Declares Cnpj as mandatory' {
                $getCommandParams = @{
                    Name        = 'Get-DFeDocumentEntry'
                    ErrorAction = 'Stop'
                }

                $attr = (Get-Command @getCommandParams).Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $attr | Should -Not -BeNullOrEmpty
            }

            It 'Rejects an empty Cnpj' {
                { Get-DFeDocumentEntry -Cnpj [string]::Empty -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Rejects a Cnpj shorter than 14 characters' {
                { Get-DFeDocumentEntry -Cnpj '1234567800019' -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Rejects a Cnpj longer than 14 characters' {
                { Get-DFeDocumentEntry -Cnpj '123456780001999' -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Rejects a Cnpj containing unsupported characters' {
                { Get-DFeDocumentEntry -Cnpj '123456780001-9' -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Accepts an alphanumeric Cnpj' {
                {
                    Get-DFeDocumentEntry -Cnpj 'AB12CD34EF56GH' -ErrorAction Stop | Out-Null
                } | Should -Not -Throw
            }
        }
        #endregion

        #region No filters
        Context 'When no filters are provided' {

            BeforeEach {

                $Script:Reader     = New-TestReader -Rows @($Script:Row1, $Script:Row2, $Script:Row3)
                $Script:Command    = New-TestCommand -Reader $Script:Reader
                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }
            }

            It 'Returns all documents' {
                $result = @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj)

                $result | Should -HaveCount 3
                $result[0].chave_acesso | Should -Be $Script:Row1.chave_acesso
                $result[1].chave_acesso | Should -Be $Script:Row2.chave_acesso
                $result[2].chave_acesso | Should -Be $Script:Row3.chave_acesso
            }

            It 'Does not add SQL parameters' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj | Out-Null

                $Script:Command.Parameters.Count | Should -Be 0
            }

            It 'Does not add a WHERE clause' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj | Out-Null

                $Script:Command.CommandText | Should -Not -Match '(?i)\bWHERE\b'
            }

            It 'Orders results by dh_emi ascending' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj | Out-Null

                $Script:Command.CommandText | Should -Match '(?is)ORDER\s+BY\s+dh_emi\s+ASC'
            }

            It 'Resolves the index path for the requested CNPJ' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj | Out-Null

                $invokeParams = @{
                    CommandName     = 'Get-StorePath'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Scope -eq 'Index' -and $Cnpj -eq $Script:Cnpj
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Opens the database at the resolved path' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj | Out-Null

                $invokeParams = @{
                    CommandName     = 'Open-SqliteConnection'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Path -eq $Script:DatabasePath
                    }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region StartDate filter
        Context 'When StartDate is provided' {

            BeforeEach {

                $Script:Reader     = New-TestReader
                $Script:Command    = New-TestCommand -Reader $Script:Reader
                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }
            }

            It 'Converts StartDate before accessing the database' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj -StartDate 'start-input' | Out-Null

                $invokeParams = @{
                    CommandName     = 'ConvertTo-DateTimeOffset'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $Value -eq 'start-input' }
                }

                Should -Invoke @invokeParams
            }

            It 'Adds the StartDate filter to the WHERE clause' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj -StartDate 'start-input' | Out-Null

                $Script:Command.CommandText | Should -Match '(?i)WHERE\s+dh_emi\s+>=\s+@startDate'
            }

            It 'Adds StartDate as a String parameter with the correct value' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj -StartDate 'start-input' | Out-Null

                $param = Get-TestParameter -Command $Script:Command -Name '@startDate'

                $param        | Should -Not -BeNullOrEmpty
                $param.DbType | Should -Be ([System.Data.DbType]::String)
                $param.Value  | Should -Be $Script:StartDate.ToString('o')
            }
        }
        #endregion

        #region EndDate filter
        Context 'When EndDate is provided' {

            BeforeEach {

                $Script:Reader     = New-TestReader
                $Script:Command    = New-TestCommand -Reader $Script:Reader
                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }
            }

            It 'Converts EndDate before accessing the database' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj -EndDate 'end-input' | Out-Null

                $invokeParams = @{
                    CommandName     = 'ConvertTo-DateTimeOffset'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Value -eq 'end-input'
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Adds the EndDate filter to the WHERE clause' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj -EndDate 'end-input' | Out-Null

                $Script:Command.CommandText | Should -Match '(?i)WHERE\s+dh_emi\s+<=\s+@endDate'
            }

            It 'Adds EndDate as a String parameter with the correct value' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj -EndDate 'end-input' | Out-Null

                $param = Get-TestParameter -Command $Script:Command -Name '@endDate'

                $param        | Should -Not -BeNullOrEmpty
                $param.DbType | Should -Be ([System.Data.DbType]::String)
                $param.Value  | Should -Be $Script:EndDate.ToString('o')
            }
        }
        #endregion

        #region Modelo filter
        Context 'When Modelo is provided' {

            BeforeEach {

                $Script:Reader     = New-TestReader
                $Script:Command    = New-TestCommand -Reader $Script:Reader
                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }
            }

            It 'Adds the Modelo filter to the WHERE clause' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj -Modelo ([ModeloDFe]::NFe) | Out-Null

                $Script:Command.CommandText | Should -Match '(?i)WHERE\s+modelo\s*=\s*@modelo'
            }

            It 'Adds Modelo as an Int32 parameter with the correct value' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj -Modelo ([ModeloDFe]::NFe) | Out-Null

                $param = Get-TestParameter -Command $Script:Command -Name '@modelo'

                $param        | Should -Not -BeNullOrEmpty
                $param.DbType | Should -Be ([System.Data.DbType]::Int32)
                $param.Value  | Should -Be ([int][ModeloDFe]::NFe)
            }

            It 'Does not add a dh_emi filter when only Modelo is provided' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj -Modelo ([ModeloDFe]::NFe) | Out-Null

                $Script:Command.CommandText | Should -Not -Match '(?i)dh_emi\s*>='
                $Script:Command.CommandText | Should -Not -Match '(?i)dh_emi\s*<='
            }
        }
        #endregion

        #region ProcessingStatus filter
        Context 'When ProcessingStatus is provided' {

            BeforeEach {

                $Script:Reader     = New-TestReader
                $Script:Command    = New-TestCommand -Reader $Script:Reader
                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }
            }

            It 'Adds the ProcessingStatus filter to the WHERE clause' {
                $getParams = @{
                    Cnpj             = $Script:Cnpj
                    ProcessingStatus = 'Indexed'
                }

                Get-DFeDocumentEntry @getParams | Out-Null

                $Script:Command.CommandText |
                    Should -Match '(?i)WHERE\s+processing_status\s*=\s*@processingStatus'
            }

            It 'Adds ProcessingStatus as a String parameter with the correct value' {
                $getParams = @{
                    Cnpj             = $Script:Cnpj
                    ProcessingStatus = 'Failed'
                }

                Get-DFeDocumentEntry @getParams | Out-Null

                $param = Get-TestParameter -Command $Script:Command -Name '@processingStatus'

                $param        | Should -Not -BeNullOrEmpty
                $param.DbType | Should -Be ([System.Data.DbType]::String)
                $param.Value  | Should -Be 'Failed'
            }

            It 'Does not add a dh_emi filter when only ProcessingStatus is provided' {
                $getParams = @{
                    Cnpj             = $Script:Cnpj
                    ProcessingStatus = 'Indexed'
                }

                Get-DFeDocumentEntry @getParams | Out-Null

                $Script:Command.CommandText | Should -Not -Match '(?i)dh_emi\s*>='
                $Script:Command.CommandText | Should -Not -Match '(?i)dh_emi\s*<='
            }
        }
        #endregion

        #region All filters
        Context 'When all filters are provided' {

            BeforeEach {

                $Script:Reader     = New-TestReader
                $Script:Command    = New-TestCommand -Reader $Script:Reader
                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }
            }

            It 'Builds the complete WHERE clause' {
                $getSplat = @{
                    Cnpj             = $Script:Cnpj
                    StartDate        = 'start-input'
                    EndDate          = 'end-input'
                    Modelo           = ([ModeloDFe]::NFe)
                    ProcessingStatus = 'Processed'
                }

                Get-DFeDocumentEntry @getSplat | Out-Null

                $Script:Command.CommandText |
                    Should -Match (
                        '(?i)WHERE\s+dh_emi\s+>=\s+@startDate\s+AND\s+dh_emi\s+<=\s+@endDate' +
                        '\s+AND\s+modelo\s*=\s*@modelo\s+AND\s+processing_status\s*=\s*@processingStatus'
                    )
            }

            It 'Creates exactly four parameters' {
                $getSplat = @{
                    Cnpj             = $Script:Cnpj
                    StartDate        = 'start-input'
                    EndDate          = 'end-input'
                    Modelo           = ([ModeloDFe]::NFe)
                    ProcessingStatus = 'Processed'
                }

                Get-DFeDocumentEntry @getSplat | Out-Null

                $Script:Command.Parameters.Count | Should -Be 4
            }

            It 'Does not concatenate filter values into SQL' {
                $getSplat = @{
                    Cnpj             = $Script:Cnpj
                    StartDate        = 'start-input'
                    EndDate          = 'end-input'
                    Modelo           = ([ModeloDFe]::NFe)
                    ProcessingStatus = 'Processed'
                }

                Get-DFeDocumentEntry @getSplat | Out-Null

                $Script:Command.CommandText | Should -Not -Match 'start-input'
                $Script:Command.CommandText | Should -Not -Match 'end-input'
            }
        }
        #endregion

        #region Nullable processing columns
        Context 'When nullable processing columns contain NULL' {

            BeforeEach {

                $Script:Reader     = New-TestReader -Rows @($Script:Row3)
                $Script:Command    = New-TestCommand -Reader $Script:Reader
                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }
            }

            It 'Maps NULL processing_started_at to null' {
                $result = @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj)

                $result[0].processing_started_at | Should -BeNullOrEmpty
            }

            It 'Maps NULL processed_at to null' {
                $result = @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj)

                $result[0].processed_at | Should -BeNullOrEmpty
            }

            It 'Maps NULL processing_error to null' {
                $result = @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj)

                $result[0].processing_error | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Processing column mapping
        Context 'When processing columns contain values' {

            BeforeEach {

                $Script:Reader     = New-TestReader -Rows @($Script:Row2)
                $Script:Command    = New-TestCommand -Reader $Script:Reader
                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }
            }

            It 'Maps processing_status correctly' {
                $result = @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj)

                $result[0].processing_status | Should -Be $Script:Row2.processing_status
            }

            It 'Maps processing_started_at correctly' {
                $result = @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj)

                $result[0].processing_started_at | Should -Be $Script:Row2.processing_started_at
            }

            It 'Maps processing_error correctly' {
                $result = @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj)

                $result[0].processing_error | Should -Be $Script:Row2.processing_error
            }

            It 'Maps NULL processed_at to null when status is Failed' {
                $result = @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj)

                $result[0].processed_at | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Whitespace StartDate
        Context 'When StartDate is whitespace' {

            BeforeEach {

                $Script:Reader     = New-TestReader
                $Script:Command    = New-TestCommand -Reader $Script:Reader
                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }
            }

            It 'Does not convert or add a StartDate filter' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj -StartDate '   ' | Out-Null

                $invokeParams = @{
                    CommandName = 'ConvertTo-DateTimeOffset'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams

                $Script:Command.CommandText | Should -Not -Match '(?i)dh_emi\s*>='
            }
        }
        #endregion

        #region Whitespace EndDate
        Context 'When EndDate is whitespace' {

            BeforeEach {

                $Script:Reader     = New-TestReader
                $Script:Command    = New-TestCommand -Reader $Script:Reader
                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }
            }

            It 'Does not convert or add an EndDate filter' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj -EndDate '   ' | Out-Null

                $invokeParams = @{
                    CommandName = 'ConvertTo-DateTimeOffset'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams

                $Script:Command.CommandText | Should -Not -Match '(?i)dh_emi\s*<='
            }
        }
        #endregion

        #region Date conversion failure
        Context 'When date conversion fails' {

            BeforeEach {

                Mock -CommandName ConvertTo-DateTimeOffset -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.FormatException]::new('Unsupported date format.'),
                            'UnsupportedDateFormat',
                            [System.Management.Automation.ErrorCategory]::InvalidArgument,
                            'invalid-date'
                        )
                    )
                }

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    throw 'Database must not be accessed'
                }

                $Script:ErrorRecord = $null

                try {
                    $entryParams = @{
                        Cnpj        = $Script:Cnpj
                        StartDate   = 'invalid-date'
                        ErrorAction = 'Stop'
                    }

                    Get-DFeDocumentEntry @entryParams | Out-Null
                } catch {
                    $Script:ErrorRecord = $_
                }
            }

            It 'Preserves the date conversion error' {
                $Script:ErrorRecord | Should -Not -BeNullOrEmpty
                $Script:ErrorRecord.FullyQualifiedErrorId | Should -BeLike 'UnsupportedDateFormat*'
            }

            It 'Does not access the database when date conversion fails' {
                $invokeParams = @{
                    CommandName = 'Open-SqliteConnection'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Nullable columns
        Context 'When nullable columns contain NULL' {

            BeforeEach {

                $Script:Reader     = New-TestReader -Rows @($Script:Row3)
                $Script:Command    = New-TestCommand -Reader $Script:Reader
                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }
            }

            It 'Maps NULL ndoc to null' {
                $result = @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj)

                $result | Should -HaveCount 1
                $result[0].ndoc | Should -BeNullOrEmpty
            }

            It 'Maps NULL serie to null' {
                $result = @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj)

                $result | Should -HaveCount 1
                $result[0].serie | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Column mapping
        Context 'When database rows are returned' {

            BeforeEach {

                $Script:Reader     = New-TestReader -Rows @($Script:Row1, $Script:Row2)
                $Script:Command    = New-TestCommand -Reader $Script:Reader
                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }
            }

            It 'Returns one object per database row' {
                @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj) | Should -HaveCount 2
            }

            It 'Maps all thirteen columns correctly' {
                $result = @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj)

                $result[0].chave_acesso          | Should -Be $Script:Row1.chave_acesso
                $result[0].modelo                | Should -Be $Script:Row1.modelo
                $result[0].dh_emi                | Should -Be $Script:Row1.dh_emi
                $result[0].file_path             | Should -Be $Script:Row1.file_path
                $result[0].is_proc               | Should -BeTrue
                $result[0].ndoc                  | Should -Be $Script:Row1.ndoc
                $result[0].serie                 | Should -Be $Script:Row1.serie
                $result[0].sha256                | Should -Be $Script:Row1.sha256
                $result[0].indexed_at            | Should -Be $Script:Row1.indexed_at
                $result[0].processing_status     | Should -Be $Script:Row1.processing_status
                $result[0].processing_started_at | Should -Be $Script:Row1.processing_started_at
                $result[0].processed_at          | Should -Be $Script:Row1.processed_at
                $result[0].processing_error      | Should -BeNullOrEmpty
            }

            It 'Maps is_proc 0 to false' {
                $result = @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj)
                $result[1].is_proc | Should -BeFalse
            }

            It 'Maps is_proc 1 to true' {
                $result = @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj)
                $result[0].is_proc | Should -BeTrue
            }

            It 'Returns the expected property names' {
                $result = @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj)

                @($result[0].PSObject.Properties.Name) | Should -Be @(
                    'chave_acesso'
                    'modelo'
                    'dh_emi'
                    'file_path'
                    'is_proc'
                    'ndoc'
                    'serie'
                    'sha256'
                    'indexed_at'
                    'processing_status'
                    'processing_started_at'
                    'processed_at'
                    'processing_error'
                )
            }
        }
        #endregion

        #region No rows
        Context 'When no rows match' {

            BeforeEach {

                $Script:Reader     = New-TestReader
                $Script:Command    = New-TestCommand -Reader $Script:Reader
                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }
            }

            It 'Returns no output' {
                @(Get-DFeDocumentEntry -Cnpj $Script:Cnpj) | Should -HaveCount 0
            }

            It 'Does not throw' {
                { Get-DFeDocumentEntry -Cnpj $Script:Cnpj | Out-Null } | Should -Not -Throw
            }
        }
        #endregion

        #region Connection failure
        Context 'When opening the database fails' {

            BeforeEach {

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    throw [System.InvalidOperationException]::new('SQLite connection failed.')
                }

                $Script:ErrorRecord = $null

                try {
                    Get-DFeDocumentEntry -Cnpj $Script:Cnpj -ErrorAction Stop | Out-Null
                } catch {
                    $Script:ErrorRecord = $_
                }
            }

            It 'Throws DocumentEntryReadFailed' {
                $Script:ErrorRecord | Should -Not -BeNullOrEmpty
                $Script:ErrorRecord.FullyQualifiedErrorId | Should -BeLike 'DocumentEntryReadFailed*'
            }

            It 'Reports a ReadError category' {
                $Script:ErrorRecord.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::ReadError)
            }
        }
        #endregion

        #region ExecuteReader failure
        Context 'When ExecuteReader fails' {

            BeforeEach {

                $Script:Command = [PSCustomObject]@{
                    CommandText = $null
                    Parameters  = (New-TestParameterCollection)
                    Disposed    = $false
                }

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'ExecuteReader'
                    Value      = {
                        throw [System.InvalidOperationException]::new(
                            'Query execution failed.'
                        )
                    }
                }
                $Script:Command | Add-Member @memberParams -Force

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Dispose'
                    Value      = { $this.Disposed = $true }
                }
                $Script:Command | Add-Member @memberParams -Force

                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }

                $Script:ErrorRecord = $null

                try {
                    Get-DFeDocumentEntry -Cnpj $Script:Cnpj -ErrorAction Stop | Out-Null
                } catch {
                    $Script:ErrorRecord = $_
                }
            }

            It 'Throws DocumentEntryReadFailed' {
                $Script:ErrorRecord | Should -Not -BeNullOrEmpty
                $Script:ErrorRecord.FullyQualifiedErrorId | Should -BeLike 'DocumentEntryReadFailed*'
            }

            It 'Disposes the command after ExecuteReader fails' {
                $Script:Command.Disposed | Should -BeTrue
            }

            It 'Disposes the connection after ExecuteReader fails' {
                $Script:Connection.Disposed | Should -BeTrue
            }
        }
        #endregion

        #region Resource disposal
        Context 'When the reader is successfully consumed' {

            BeforeEach {

                $Script:Reader     = New-TestReader -Rows @($Script:Row1)
                $Script:Command    = New-TestCommand -Reader $Script:Reader
                $Script:Connection = New-TestConnection -Command $Script:Command

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return $Script:Connection
                }
            }

            It 'Disposes the reader' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj | Out-Null
                $Script:Reader.Disposed | Should -BeTrue
            }

            It 'Disposes the command' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj | Out-Null
                $Script:Command.Disposed | Should -BeTrue
            }

            It 'Disposes the connection' {
                Get-DFeDocumentEntry -Cnpj $Script:Cnpj | Out-Null
                $Script:Connection.Disposed | Should -BeTrue
            }
        }
        #endregion
    }
}
