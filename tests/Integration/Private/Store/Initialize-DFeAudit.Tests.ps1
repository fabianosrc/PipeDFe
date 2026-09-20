#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Initialize-DFeAudit and Save-DFeAuditEvent.

.DESCRIPTION
Verifies the PipeDFe operational audit database against a real SQLite
database in an isolated temporary LOCALAPPDATA directory.

Coverage includes:
  - Database and directory creation.
  - Return value and exact database path.
  - WAL journal mode.
  - Schema version.
  - audit_execution schema.
  - audit_event schema.
  - Foreign-key relationship.
  - Required indexes.
  - Idempotent initialization.
  - Data preservation during repeated initialization.
  - Unsupported future schema version.
  - CNPJ isolation.
  - Operational event persistence.
  - UTC timestamp persistence.
  - Nullable optional fields.
  - Foreign-key enforcement.
  - Parameter validation.
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

Describe 'Initialize-DFeAudit' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            $testID = [guid]::NewGuid().ToString('N')

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $Script:TempRootPath = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.Audit.Tests-{0}' -f $testID
            )

            $newItemParams = @{
                Path        = $Script:TempRootPath
                ItemType    = 'Directory'
                Force       = $true
                ErrorAction = 'Stop'
            }

            New-Item @newItemParams | Out-Null

            $env:LOCALAPPDATA = $Script:TempRootPath

            $Script:Cnpj = '12345678000199'
            $Script:ExecutionId = 'execution-test-001'

            function Open-TestConnection {
                [CmdletBinding()]
                [OutputType([System.Data.SQLite.SQLiteConnection])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path
                )

                $dsn = "Data Source=$Path;Version=3;"
                $connection = [System.Data.SQLite.SQLiteConnection]::new($dsn)
                $connection.Open()
                $connection
            }

            function Invoke-TestScalar {
                [CmdletBinding()]
                [OutputType([object])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$Sql,

                    [Parameter()]
                    [hashtable]$Parameters = @{}
                )

                $connection = Open-TestConnection -Path $Path

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = $Sql

                        foreach ($key in $Parameters.Keys) {
                            $command.Parameters.AddWithValue(
                                $key,
                                $Parameters[$key]
                            ) | Out-Null
                        }

                        $command.ExecuteScalar()
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }

            function Invoke-TestNonQuery {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$Sql,

                    [Parameter()]
                    [hashtable]$Parameters = @{}
                )

                $connection = Open-TestConnection -Path $Path

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = $Sql

                        foreach ($key in $Parameters.Keys) {
                            $command.Parameters.AddWithValue(
                                $key,
                                $Parameters[$key]
                            ) | Out-Null
                        }

                        $command.ExecuteNonQuery() | Out-Null
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }

            function Get-TestTableInfo {
                [CmdletBinding()]
                [OutputType([hashtable])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$TableName
                )

                $connection = Open-TestConnection -Path $Path

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = "PRAGMA table_info([$TableName]);"

                        $reader = $command.ExecuteReader()

                        try {
                            $columns = @{}

                            while ($reader.Read()) {
                                $columns[[string]$reader['name']] = [PSCustomObject]@{
                                    Name    = [string]$reader['name']
                                    Type    = [string]$reader['type']
                                    NotNull = [int]$reader['notnull']
                                    Default = $reader['dflt_value']
                                    Primary = [int]$reader['pk']
                                }
                            }

                            $columns
                        } finally {
                            $reader.Dispose()
                        }
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }

            function Get-TestObjectSql {
                [CmdletBinding()]
                [OutputType([string])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [ValidateSet('table', 'index')]
                    [string]$Type,

                    [Parameter(Mandatory)]
                    [string]$Name
                )

                $sql = 'SELECT sql FROM sqlite_master WHERE type = @type AND name = @name;'

                $result = Invoke-TestScalar -Path $Path -Sql $sql -Parameters @{
                    '@type' = $Type
                    '@name' = $Name
                }

                if ($null -eq $result -or $result -is [System.DBNull]) {
                    return $null
                }

                [string]$result
            }

            function Test-TestObjectExist {
                [CmdletBinding()]
                [OutputType([bool])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [ValidateSet('table', 'index')]
                    [string]$Type,

                    [Parameter(Mandatory)]
                    [string]$Name
                )

                $sql = 'SELECT COUNT(*) FROM sqlite_master WHERE type = @type AND name = @name;'

                $count = Invoke-TestScalar -Path $Path -Sql $sql -Parameters @{
                    '@type' = $Type
                    '@name' = $Name
                }

                [int]$count -eq 1
            }

            function Get-TestDatabasePath {
                [CmdletBinding()]
                [OutputType([string])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj
                )

                [System.IO.Path]::Combine(
                    $Script:TempRootPath,
                    'PipeDFe',
                    $Cnpj,
                    'data',
                    'audit.db'
                )
            }

            $Script:DbPath = Initialize-DFeAudit -Cnpj $Script:Cnpj
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData

            $removeItemParams = @{
                LiteralPath = $Script:TempRootPath
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            if (Test-Path -LiteralPath $Script:TempRootPath) {
                Remove-Item @removeItemParams
            }
        }
        #endregion

        #region Database creation
        Context 'Database creation' {

            It 'Creates the parent data directory' {
                $dataDirectory = [System.IO.Path]::GetDirectoryName($Script:DbPath)

                Test-Path -LiteralPath $dataDirectory -PathType Container |
                    Should -BeTrue
            }

            It 'Creates audit.db' {
                Test-Path -LiteralPath $Script:DbPath -PathType Leaf |
                    Should -BeTrue
            }

            It 'Returns a System.String' {
                $Script:DbPath | Should -BeOfType ([string])
            }

            It 'Returns the exact audit.db path' {
                $Script:DbPath | Should -Be (Get-TestDatabasePath -Cnpj $Script:Cnpj)
            }
        }
        #endregion

        #region WAL journal mode
        Context 'WAL journal mode' {

            It 'Configures the database for WAL mode' {
                $invokeParams = @{
                    Path = $Script:DbPath
                    Sql  = 'PRAGMA journal_mode;'
                }

                $journalMode = Invoke-TestScalar @invokeParams

                $journalMode.ToString().ToLowerInvariant() | Should -Be 'wal'
            }
        }
        #endregion

        #region Schema version
        Context 'Schema version' {

            It 'Sets PRAGMA user_version to 1' {
                $invokeParams = @{
                    Path = $Script:DbPath
                    Sql  = 'PRAGMA user_version;'
                }

                $version = Invoke-TestScalar @invokeParams

                [int]$version | Should -Be 1
            }
        }
        #endregion

        #region Schema tables
        Context 'Schema tables' {

            It 'Creates audit_execution' {
                $existsParams = @{
                    Path = $Script:DbPath
                    Type = 'table'
                    Name = 'audit_execution'
                }

                Test-TestObjectExist @existsParams | Should -BeTrue
            }

            It 'Creates audit_event' {
                $existsParams = @{
                    Path = $Script:DbPath
                    Type = 'table'
                    Name = 'audit_event'
                }

                Test-TestObjectExist @existsParams | Should -BeTrue
            }
        }
        #endregion

        #region audit_execution schema
        Context 'audit_execution schema' {

            BeforeAll {

                $tableInfoParams = @{
                    Path      = $Script:DbPath
                    TableName = 'audit_execution'
                }

                $Script:ExecutionColumns = Get-TestTableInfo @tableInfoParams
            }

            It 'Contains exactly the expected columns' {
                @($Script:ExecutionColumns.Keys | Sort-Object) | Should -Be @(
                    'completed_at'
                    'error_summary'
                    'execution_id'
                    'mode'
                    'module_version'
                    'requested_period'
                    'started_at'
                    'status'
                )
            }

            It 'Defines execution_id as the primary key' {
                $Script:ExecutionColumns['execution_id'].Primary | Should -Be 1
            }

            It 'Defines execution_id as TEXT NOT NULL' {
                $Script:ExecutionColumns['execution_id'].Type    | Should -Be 'TEXT'
                $Script:ExecutionColumns['execution_id'].NotNull | Should -Be 1
            }

            It 'Defines started_at as TEXT NOT NULL' {
                $Script:ExecutionColumns['started_at'].Type    | Should -Be 'TEXT'
                $Script:ExecutionColumns['started_at'].NotNull | Should -Be 1
            }

            It 'Defines completed_at as nullable TEXT' {
                $Script:ExecutionColumns['completed_at'].Type    | Should -Be 'TEXT'
                $Script:ExecutionColumns['completed_at'].NotNull | Should -Be 0
            }

            It 'Defines mode as TEXT NOT NULL' {
                $Script:ExecutionColumns['mode'].Type    | Should -Be 'TEXT'
                $Script:ExecutionColumns['mode'].NotNull | Should -Be 1
            }

            It 'Defines requested_period as nullable TEXT' {
                $Script:ExecutionColumns['requested_period'].Type    | Should -Be 'TEXT'
                $Script:ExecutionColumns['requested_period'].NotNull | Should -Be 0
            }

            It 'Defines status as TEXT NOT NULL' {
                $Script:ExecutionColumns['status'].Type    | Should -Be 'TEXT'
                $Script:ExecutionColumns['status'].NotNull | Should -Be 1
            }

            It 'Defines module_version as nullable TEXT' {
                $Script:ExecutionColumns['module_version'].Type    | Should -Be 'TEXT'
                $Script:ExecutionColumns['module_version'].NotNull | Should -Be 0
            }

            It 'Defines error_summary as nullable TEXT' {
                $Script:ExecutionColumns['error_summary'].Type    | Should -Be 'TEXT'
                $Script:ExecutionColumns['error_summary'].NotNull | Should -Be 0
            }
        }
        #endregion

        #region audit_event schema
        Context 'audit_event schema' {

            BeforeAll {

                $tableInfoParams = @{
                    Path      = $Script:DbPath
                    TableName = 'audit_event'
                }

                $Script:EventColumns = Get-TestTableInfo @tableInfoParams

                $sqlObjectParam = @{
                    Path = $Script:DbPath
                    Type = 'table'
                    Name = 'audit_event'
                }

                $Script:EventSql = Get-TestObjectSql @sqlObjectParam
            }

            It 'Contains exactly the expected columns' {
                @($Script:EventColumns.Keys | Sort-Object) | Should -Be @(
                    'company_cnpj'
                    'document_id'
                    'duration_ms'
                    'error_code'
                    'event_id'
                    'event_type'
                    'execution_id'
                    'message'
                    'status'
                    'timestamp'
                )
            }

            It 'Defines event_id as the primary key' {
                $Script:EventColumns['event_id'].Primary | Should -Be 1
            }

            It 'Defines event_id as INTEGER NOT NULL' {
                $Script:EventColumns['event_id'].Type    | Should -Be 'INTEGER'
                $Script:EventColumns['event_id'].NotNull | Should -Be 1
            }

            It 'Defines execution_id as TEXT NOT NULL' {
                $Script:EventColumns['execution_id'].Type    | Should -Be 'TEXT'
                $Script:EventColumns['execution_id'].NotNull | Should -Be 1
            }

            It 'Defines timestamp as TEXT NOT NULL' {
                $Script:EventColumns['timestamp'].Type    | Should -Be 'TEXT'
                $Script:EventColumns['timestamp'].NotNull | Should -Be 1
            }

            It 'Defines company_cnpj as TEXT NOT NULL' {
                $Script:EventColumns['company_cnpj'].Type    | Should -Be 'TEXT'
                $Script:EventColumns['company_cnpj'].NotNull | Should -Be 1
            }

            It 'Defines document_id as nullable TEXT' {
                $Script:EventColumns['document_id'].Type    | Should -Be 'TEXT'
                $Script:EventColumns['document_id'].NotNull | Should -Be 0
            }

            It 'Defines event_type as TEXT NOT NULL' {
                $Script:EventColumns['event_type'].Type    | Should -Be 'TEXT'
                $Script:EventColumns['event_type'].NotNull | Should -Be 1
            }

            It 'Defines status as TEXT NOT NULL' {
                $Script:EventColumns['status'].Type    | Should -Be 'TEXT'
                $Script:EventColumns['status'].NotNull | Should -Be 1
            }

            It 'Defines message as nullable TEXT' {
                $Script:EventColumns['message'].Type    | Should -Be 'TEXT'
                $Script:EventColumns['message'].NotNull | Should -Be 0
            }

            It 'Defines error_code as nullable TEXT' {
                $Script:EventColumns['error_code'].Type    | Should -Be 'TEXT'
                $Script:EventColumns['error_code'].NotNull | Should -Be 0
            }

            It 'Defines duration_ms as nullable INTEGER' {
                $Script:EventColumns['duration_ms'].Type    | Should -Be 'INTEGER'
                $Script:EventColumns['duration_ms'].NotNull | Should -Be 0
            }

            It 'Defines the execution foreign key' {
                $Script:EventSql | Should -Match 'FOREIGN KEY\s*\(\s*execution_id\s*\)'
            }

            It 'Defines cascade deletion for execution records' {
                $Script:EventSql | Should -Match 'ON DELETE CASCADE'
            }
        }
        #endregion

        #region Schema indexes
        Context 'Schema indexes' {

            It 'Creates ix_audit_execution_started_at' {
                $existsParams = @{
                    Path = $Script:DbPath
                    Type = 'index'
                    Name = 'ix_audit_execution_started_at'
                }

                Test-TestObjectExist @existsParams | Should -BeTrue
            }

            It 'Creates ix_audit_execution_status' {
                $existsParams = @{
                    Path = $Script:DbPath
                    Type = 'index'
                    Name = 'ix_audit_execution_status'
                }

                Test-TestObjectExist @existsParams | Should -BeTrue
            }

            It 'Creates ix_audit_event_execution_id' {
                $existsParams = @{
                    Path = $Script:DbPath
                    Type = 'index'
                    Name = 'ix_audit_event_execution_id'
                }

                Test-TestObjectExist @existsParams | Should -BeTrue
            }

            It 'Creates ix_audit_event_company_timestamp' {
                $existsParams = @{
                    Path = $Script:DbPath
                    Type = 'index'
                    Name = 'ix_audit_event_company_timestamp'
                }

                Test-TestObjectExist @existsParams | Should -BeTrue
            }

            It 'Creates ix_audit_event_document_id' {
                $existsParams = @{
                    Path = $Script:DbPath
                    Type = 'index'
                    Name = 'ix_audit_event_document_id'
                }

                Test-TestObjectExist @existsParams | Should -BeTrue
            }
        }
        #endregion

        #region Idempotency
        Context 'Idempotency' {

            BeforeAll {

                $versionParams = @{
                    Path = $Script:DbPath
                    Sql  = 'PRAGMA user_version;'
                }

                $Script:BeforeVersion = Invoke-TestScalar @versionParams

                $insertSql = @'
INSERT INTO audit_execution (
    execution_id,
    started_at,
    mode,
    status
) VALUES (
    'idempotency-test',
    '2026-01-01T00:00:00.0000000+00:00',
    'Manual',
    'Running'
);
'@

                Invoke-TestNonQuery -Path $Script:DbPath -Sql $insertSql

                $beforeCountParams = @{
                    Path = $Script:DbPath
                    Sql  = 'SELECT COUNT(*) FROM audit_execution;'
                }

                $Script:BeforeCount = Invoke-TestScalar @beforeCountParams

                Initialize-DFeAudit -Cnpj $Script:Cnpj | Out-Null

                $afterVersionParams = @{
                    Path = $Script:DbPath
                    Sql  = 'PRAGMA user_version;'
                }

                $afterCountParams = @{
                    Path = $Script:DbPath
                    Sql  = 'SELECT COUNT(*) FROM audit_execution;'
                }

                $Script:AfterVersion = Invoke-TestScalar @afterVersionParams
                $Script:AfterCount   = Invoke-TestScalar @afterCountParams
            }

            It 'Preserves the schema version' {
                [int]$Script:AfterVersion | Should -Be ([int]$Script:BeforeVersion)
            }

            It 'Preserves existing execution records' {
                [int]$Script:AfterCount | Should -Be ([int]$Script:BeforeCount)
            }
        }
        #endregion

        #region Save-DFeAuditEvent
        Context 'Save-DFeAuditEvent' {

            BeforeAll {

                $timestamp = [System.DateTimeOffset]::Parse('2026-09-19T20:00:00.0000000+00:00')

                $insertSql = @'
INSERT INTO audit_execution (
    execution_id,
    started_at,
    mode,
    requested_period,
    status,
    module_version
)
VALUES (
    @execution_id,
    @started_at,
    @mode,
    @requested_period,
    @status,
    @module_version
);
'@

                $insertParams = @{
                    Path       = $Script:DbPath
                    Sql        = $insertSql
                    Parameters = @{
                        '@execution_id'     = $Script:ExecutionId
                        '@started_at'       = $timestamp.ToString('o')
                        '@mode'             = 'Manual'
                        '@requested_period' = '2026-08'
                        '@status'           = 'Running'
                        '@module_version'   = '1.0.0-test'
                    }
                }

                Invoke-TestNonQuery @insertParams

                $saveParams = @{
                    Cnpj        = $Script:Cnpj
                    ExecutionId = $Script:ExecutionId
                    EventType   = 'DocumentIndexed'
                    Status      = 'Success'
                    Message     = 'Document indexed successfully.'
                    DocumentId  = '35260812345678000199550010000000011234567890'
                    ErrorCode   = [string]::Empty
                    DurationMs  = 125
                    Timestamp   = $timestamp
                }

                Save-DFeAuditEvent @saveParams

                $querySql = @'
SELECT
    execution_id || '|' ||
    timestamp || '|' ||
    company_cnpj || '|' ||
    COALESCE(document_id, '') || '|' ||
    event_type || '|' ||
    status || '|' ||
    COALESCE(message, '') || '|' ||
    COALESCE(error_code, '') || '|' ||
    COALESCE(duration_ms, -1)
FROM audit_event
WHERE execution_id = @execution_id
ORDER BY event_id DESC
LIMIT 1;
'@

                $invokeParams = @{
                    Path       = $Script:DbPath
                    Sql        = $querySql
                    Parameters = @{ '@execution_id' = $Script:ExecutionId }
                }

                $Script:SavedEvent = Invoke-TestScalar @invokeParams
            }

            It 'Persists the event' {
                $Script:SavedEvent | Should -Not -BeNullOrEmpty
            }

            It 'Persists the execution identifier' {
                $pattern = [regex]::Escape($Script:ExecutionId)
                $Script:SavedEvent.ToString() | Should -Match $pattern
            }

            It 'Persists the company CNPJ' {
                $pattern = [regex]::Escape($Script:Cnpj)
                $Script:SavedEvent.ToString() | Should -Match $pattern
            }

            It 'Persists the event type' {
                $Script:SavedEvent.ToString() | Should -Match 'DocumentIndexed'
            }

            It 'Persists the status' {
                $Script:SavedEvent.ToString() | Should -Match 'Success'
            }

            It 'Persists the duration' {
                $Script:SavedEvent.ToString() | Should -Match '\|125$'
            }

            It 'Persists the UTC timestamp' {
                $Script:SavedEvent.ToString() | Should -Match '2026-09-19T20:00:00'
            }

            It 'Persists a non-empty ErrorCode' {
                $saveParams = @{
                    Cnpj        = $Script:Cnpj
                    ExecutionId = $Script:ExecutionId
                    EventType   = 'TestError'
                    Status      = 'Failure'
                    ErrorCode   = 'ERR_TEST'
                }

                Save-DFeAuditEvent @saveParams

                $count = Invoke-TestScalar -Path $Script:DbPath -Sql @'
SELECT COUNT(*)
FROM audit_event
WHERE execution_id = @execution_id
AND error_code = 'ERR_TEST';
'@ -Parameters @{ '@execution_id' = $Script:ExecutionId }

                [int]$count | Should -BeGreaterThan 0
            }
        }
        #endregion

        #region Save-DFeAuditEvent optional fields
        Context 'Save-DFeAuditEvent optional fields' {

            BeforeAll {

                $Script:NullableExecutionId = 'execution-nullable-test'

                $insertSql = @'
INSERT INTO audit_execution (
    execution_id,
    started_at,
    mode,
    status
)
VALUES (
    @execution_id,
    @started_at,
    @mode,
    @status
);
'@

                $insertParams = @{
                    Path       = $Script:DbPath
                    Sql        = $insertSql
                    Parameters = @{
                        '@execution_id' = $Script:NullableExecutionId
                        '@started_at'   = [System.DateTimeOffset]::UtcNow.ToString('o')
                        '@mode'         = 'Manual'
                        '@status'       = 'Running'
                    }
                }

                Invoke-TestNonQuery @insertParams

                $saveParams = @{
                    Cnpj        = $Script:Cnpj
                    ExecutionId = $Script:NullableExecutionId
                    EventType   = 'ExecutionStarted'
                    Status      = 'Success'
                }

                Save-DFeAuditEvent @saveParams

                $querySql = @'
SELECT COUNT(*)
FROM audit_event
WHERE execution_id = @execution_id
AND document_id IS NULL
AND message IS NULL
AND error_code IS NULL
AND duration_ms IS NULL;
'@

                $invokeParams = @{
                    Path       = $Script:DbPath
                    Sql        = $querySql
                    Parameters = @{ '@execution_id' = $Script:NullableExecutionId }
                }

                $Script:NullCount = Invoke-TestScalar @invokeParams
            }

            It 'Stores omitted optional fields as NULL' {
                [int]$Script:NullCount | Should -Be 1
            }
        }
        #endregion

        #region Start-DFeAuditExecution
        Context 'Start-DFeAuditExecution' {

            BeforeAll {

                $Script:StartExecutionParams = @{
                    Cnpj            = $Script:Cnpj
                    Mode            = 'Manual'
                    RequestedPeriod = '2026-08'
                    ModuleVersion   = '0.1.0-test'
                }

                $Script:StartedExecutionId = Start-DFeAuditExecution @startExecutionParams

                $querySql = @'
SELECT
    execution_id || '|' ||
    started_at || '|' ||
    mode || '|' ||
    COALESCE(requested_period, '') || '|' ||
    status || '|' ||
    COALESCE(module_version, '')
FROM audit_execution
WHERE execution_id = @execution_id;
'@

                $invokeParams = @{
                    Path       = $Script:DbPath
                    Sql        = $querySql
                    Parameters = @{
                        '@execution_id' = $Script:StartedExecutionId
                    }
                }

                $Script:StartedExecution = Invoke-TestScalar @invokeParams
            }

            It 'Returns an execution identifier' {
                $Script:StartedExecutionId | Should -Not -BeNullOrEmpty
            }

            It 'Returns a GUID formatted without separators' {
                $Script:StartedExecutionId | Should -Match '^[0-9a-f]{32}$'
            }

            It 'Persists the execution record' {
                $Script:StartedExecution | Should -Not -BeNullOrEmpty
            }

            It 'Persists the execution identifier' {
                $pattern = [regex]::Escape($Script:StartedExecutionId)

                $Script:StartedExecution.ToString() | Should -Match $pattern
            }

            It 'Persists the mode' {
                $Script:StartedExecution.ToString() | Should -Match '\|Manual\|'
            }

            It 'Persists the requested period' {
                $Script:StartedExecution.ToString() | Should -Match '\|2026-08\|'
            }

            It 'Starts the execution with Running status' {
                $Script:StartedExecution.ToString() | Should -Match '\|Running\|'
            }

            It 'Persists the module version' {
                $Script:StartedExecution.ToString() | Should -Match '\|0\.1\.0-test$'
            }

            It 'Persists a UTC start timestamp' {
                $timestamp = $Script:StartedExecution.ToString().Split('|')[1]

                $timestamp | Should -Match '^\d{4}-\d{2}-\d{2}T'
                $timestamp | Should -Match '\+00:00$'
            }

            It 'Generates different identifiers for different executions' {
                $secondExecutionId = Start-DFeAuditExecution @Script:StartExecutionParams

                $secondExecutionId | Should -Not -Be $Script:StartedExecutionId
            }
        }
        #endregion

        #region Start-DFeAuditExecution optional fields
        Context 'Start-DFeAuditExecution optional fields' {

            BeforeAll {

                $executionParams = @{
                    Cnpj          = $Script:Cnpj
                    Mode          = 'Automatic'
                    ModuleVersion = '0.1.0-test'
                }

                $Script:NullableExecutionId = Start-DFeAuditExecution @executionParams

                $querySql = @'
SELECT COUNT(*)
FROM audit_execution
WHERE execution_id = @execution_id
AND requested_period IS NULL;
'@

                $invokeParams = @{
                    Path       = $Script:DbPath
                    Sql        = $querySql
                    Parameters = @{
                        '@execution_id' = $Script:NullableExecutionId
                    }
                }

                $Script:NullablePeriodCount = Invoke-TestScalar @invokeParams
            }

            It 'Stores an omitted requested period as NULL' {
                [int]$Script:NullablePeriodCount | Should -Be 1
            }
        }
        #endregion

        #region Start-DFeAuditExecution failure
        Context 'Start-DFeAuditExecution failure' {

            BeforeAll {

                Mock -CommandName Open-SqliteConnection -MockWith {
                    throw [System.IO.IOException]::new('Simulated connection failure.')
                }

                $Script:StartFailThrown = $null

                try {
                    $startParams = @{
                        Cnpj          = $Script:Cnpj
                        Mode          = 'Manual'
                        ModuleVersion = '0.1.0-test'
                    }

                    Start-DFeAuditExecution @startParams -ErrorAction Stop
                } catch {
                    $Script:StartFailThrown = $_
                }
            }

            It 'Throws AuditExecutionStartFailed on connection failure' {
                $Script:StartFailThrown | Should -Not -BeNullOrEmpty

                $Script:StartFailThrown.FullyQualifiedErrorId |
                    Should -BeLike 'AuditExecutionStartFailed*'
            }

            It 'Uses WriteError category' {
                $expected = ([System.Management.Automation.ErrorCategory]::WriteError)

                $Script:StartFailThrown.CategoryInfo.Category | Should -Be  $expected
            }
        }
        #endregion

        #region Complete-DFeAuditExecution
        Context 'Complete-DFeAuditExecution' {

            BeforeAll {

                $executionParams = @{
                    Cnpj            = $Script:Cnpj
                    Mode            = 'Manual'
                    RequestedPeriod = '2026-08'
                    ModuleVersion   = '0.1.0-test'
                }

                $Script:CompletionExecutionId = Start-DFeAuditExecution @executionParams

            }

            It 'Completes a running execution successfully' {
                $completeParams = @{
                    Cnpj        = $Script:Cnpj
                    ExecutionId = $Script:CompletionExecutionId
                    Status      = 'Succeeded'
                }

                Complete-DFeAuditExecution @completeParams

                $querySql = @'
SELECT
    completed_at || '|' ||
    status || '|' ||
    COALESCE(error_summary, '')
FROM audit_execution
WHERE execution_id = @execution_id;
'@

                $invokeParams = @{
                    Path       = $Script:DbPath
                    Sql        = $querySql
                    Parameters = @{
                        '@execution_id' = $Script:CompletionExecutionId
                    }
                }

                $result = Invoke-TestScalar @invokeParams

                $result.ToString() | Should -Match '\|Succeeded\|$'
            }

            It 'Persists a UTC completion timestamp' {
                $querySql = @'
SELECT completed_at
FROM audit_execution
WHERE execution_id = @execution_id;
'@

                $invokeParams = @{
                    Path       = $Script:DbPath
                    Sql        = $querySql
                    Parameters = @{
                        '@execution_id' = $Script:CompletionExecutionId
                    }
                }

                $completedAt = Invoke-TestScalar @invokeParams

                $completedAt.ToString() | Should -Match '^\d{4}-\d{2}-\d{2}T'
                $completedAt.ToString() | Should -Match '\+00:00$'
            }

            It 'Produces no output' {
                $startParams = @{
                    Cnpj          = $Script:Cnpj
                    Mode          = 'Manual'
                    ModuleVersion = '0.1.0-test'
                }

                $executionId = Start-DFeAuditExecution @startParams

                $completeParams = @{
                    Cnpj        = $Script:Cnpj
                    ExecutionId = $executionId
                    Status      = 'Succeeded'
                }

                $result = Complete-DFeAuditExecution @completeParams

                $result | Should -BeNullOrEmpty
            }

            It 'Rejects an execution identifier that does not exist' {
                $unknownExecutionId = '0123456789abcdef0123456789abcdef'

                $thrown = $null

                try {
                    $completeParams = @{
                        Cnpj        = $Script:Cnpj
                        ExecutionId = $unknownExecutionId
                        Status      = 'Succeeded'
                        ErrorAction = 'Stop'
                    }

                    Complete-DFeAuditExecution @completeParams

                } catch {
                    $thrown = $_
                }

                $thrown | Should -Not -BeNullOrEmpty
                $thrown.FullyQualifiedErrorId |
                    Should -BeLike 'AuditExecutionCompletionFailed*'
            }
        }
        #endregion

        #region Foreign-key enforcement
        Context 'Foreign-key enforcement' {

            It 'Rejects an event for an unknown execution' {
                $saveParams = @{
                    Cnpj        = $Script:Cnpj
                    ExecutionId = 'execution-does-not-exist'
                    EventType   = 'TestEvent'
                    Status      = 'Failure'
                    ErrorAction = 'Stop'
                }

                { Save-DFeAuditEvent @saveParams } |
                    Should -Throw -ErrorId 'AuditEventSaveFailed*'
            }

            It 'Does not persist the rejected event' {
                $sql = @'
SELECT COUNT(*)
FROM audit_event
WHERE execution_id = 'execution-does-not-exist';
'@

                $count = Invoke-TestScalar -Path $Script:DbPath -Sql $sql

                [int]$count | Should -Be 0
            }
        }
        #endregion

        #region CNPJ isolation
        Context 'CNPJ isolation' {

            It 'Creates an independent database for another CNPJ' {
                $otherCnpj = '98765432000100'
                $otherPath = Initialize-DFeAudit -Cnpj $otherCnpj

                $otherPath | Should -Not -Be $Script:DbPath

                Test-Path -LiteralPath $otherPath -PathType Leaf | Should -BeTrue

                $invokeParams = @{
                    Path = $otherPath
                    Sql  = 'SELECT COUNT(*) FROM audit_event;'
                }

                $count = Invoke-TestScalar @invokeParams

                [int]$count | Should -Be 0
            }
        }
        #endregion

        #region Unsupported future schema version
        Context 'Unsupported future schema version' {

            It 'Rejects an unsupported audit schema version' {
                $futureCnpj = '11111111000191'
                $futurePath = Initialize-DFeAudit -Cnpj $futureCnpj

                Invoke-TestNonQuery -Path $futurePath -Sql 'PRAGMA user_version = 99;'

                { Initialize-DFeAudit -Cnpj $futureCnpj -ErrorAction Stop } |
                    Should -Throw -ErrorId 'AuditSchemaInitFailed*'
            }
        }
        #endregion

        #region Parameter validation
        Context 'Parameter validation' {

            It 'Rejects an invalid CNPJ' {
                { Initialize-DFeAudit -Cnpj 'INVALID' } | Should -Throw
            }

            It 'Rejects a malformed CNPJ' {
                { Initialize-DFeAudit -Cnpj '123456' } | Should -Throw
            }

            It 'Rejects a missing CNPJ' {
                { Initialize-DFeAudit -Cnpj [string]::Empty } | Should -Throw
            }

            It 'Rejects an invalid Save-DFeAuditEvent CNPJ' {
                $saveParams = @{
                    Cnpj        = 'INVALID'
                    ExecutionId = 'execution-test'
                    EventType   = 'Test'
                    Status      = 'Success'
                }

                { Save-DFeAuditEvent @saveParams } | Should -Throw
            }

            It 'Rejects a missing ExecutionId' {
                $saveParams = @{
                    Cnpj        = $Script:Cnpj
                    ExecutionId = [string]::Empty
                    EventType   = 'Test'
                    Status      = 'Success'
                }

                { Save-DFeAuditEvent @saveParams } | Should -Throw
            }

            It 'Rejects a missing EventType' {
                $saveParams = @{
                    Cnpj        = $Script:Cnpj
                    ExecutionId = $Script:ExecutionId
                    EventType   = [string]::Empty
                    Status      = 'Success'
                }

                { Save-DFeAuditEvent @saveParams } | Should -Throw
            }

            It 'Rejects a missing Status' {
                $saveParams = @{
                    Cnpj        = $Script:Cnpj
                    ExecutionId = $Script:ExecutionId
                    EventType   = 'Test'
                    Status      = [string]::Empty
                }

                { Save-DFeAuditEvent @saveParams } | Should -Throw
            }

            It 'Rejects a negative duration' {
                $saveParams = @{
                    Cnpj        = $Script:Cnpj
                    ExecutionId = $Script:ExecutionId
                    EventType   = 'Test'
                    Status      = 'Success'
                    DurationMs  = -1
                }

                { Save-DFeAuditEvent @saveParams } | Should -Throw
            }

            It 'Rejects an invalid Start-DFeAuditExecution CNPJ' {
                $params = @{
                    Cnpj          = 'INVALID'
                    Mode          = 'Manual'
                    ModuleVersion = '0.1.0-test'
                }

                { Start-DFeAuditExecution @params } | Should -Throw
            }

            It 'Rejects a missing execution mode' {
                $params = @{
                    Cnpj          = $Script:Cnpj
                    Mode          = [string]::Empty
                    ModuleVersion = '0.1.0-test'
                }

                { Start-DFeAuditExecution @params } | Should -Throw
            }

            It 'Rejects a missing module version' {
                $params = @{
                    Cnpj          = $Script:Cnpj
                    Mode          = 'Manual'
                    ModuleVersion = [string]::Empty
                }

                { Start-DFeAuditExecution @params } | Should -Throw
            }

            It 'Rejects an invalid execution identifier' {
                $completeParams = @{
                    Cnpj        = $Script:Cnpj
                    ExecutionId = 'invalid'
                    Status      = 'Succeeded'
                }

                { Complete-DFeAuditExecution @completeParams } | Should -Throw
            }

            It 'Rejects an unsupported final status' {
                $completeParams = @{
                    Cnpj       =  $Script:Cnpj
                    ExecutionId=  '012345678bcdef0123456789abcdef'
                    Status     =  'Running'
                }

                { Complete-DFeAuditExecution @completeParams } | Should -Throw
            }

            It 'Rejects an invalid CNPJ' {
                $completeParams = @{
                    Cnpj        = 'INVALID'
                    ExecutionId = '0123456789abcdef0123456789abcdef'
                    Status      = 'Succeeded'
                }

                { Complete-DFeAuditExecution @completeParams } | Should -Throw
            }
        }
        #endregion

        #region Failed execution
        Context 'Failed execution' {

            It 'Completes an execution with Failed status and error information' {
                $startParams = @{
                    Cnpj          = $Script:Cnpj
                    Mode          = 'Manual'
                    ModuleVersion = '0.1.0-test'
                }

                $executionId = Start-DFeAuditExecution @startParams

                $completeParams = @{
                    Cnpj         = $Script:Cnpj
                    ExecutionId  = $executionId
                    Status       = 'Failed'
                    ErrorSummary = 'DFeDownloadFailed: Unable to download the DFe.'
                }

                Complete-DFeAuditExecution @completeParams

                $querySql = @'
SELECT
    status || '|' ||
    COALESCE(error_summary, '')
FROM audit_execution
WHERE execution_id = @execution_id;
'@

                $invokeParams = @{
                    Path       = $Script:DbPath
                    Sql        = $querySql
                    Parameters = @{ '@execution_id' = $executionId }
                }

                $result = Invoke-TestScalar @invokeParams

                $result.ToString() |
                    Should -Be 'Failed|DFeDownloadFailed: Unable to download the DFe.'
            }
        }
    }
    #endregion
}
