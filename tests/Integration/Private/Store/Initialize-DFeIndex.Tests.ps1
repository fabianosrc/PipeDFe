#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Initialize-DFeIndex.

.DESCRIPTION
Verifies that Initialize-DFeIndex Creates and maintains the SQLite index
database according to its public contract.

The tests use a real SQLite database in an isolated temporary
%LOCALAPPDATA% directory. No production data is accessed.

Coverage includes:
- Database and directory creation.
- Return value (type and exact path).
- Complete schema structure: tables, columns, types, nullability, defaults,
  primary keys, composite keys, CHECK constraints, and index definitions.
- Schema versioning: new database born at v4, current version no-op,
  unsupported future version rejected.
- Idempotency: repeated calls, stable return value, data preservation,
  user_version preservation.
- Partial compatible schema (mid-creation crash recovery): safe by construction.
- WAL journal mode: a database-level setting persisted in the file and
  therefore part of the observable contract of this function.
- Rejection of unsupported schema versions with the correct ErrorId.
- Corrupted database file produces IndexSchemaInitFailed.
- Isolation between CNPJs.
- Parameter validation.
- Normalized NF-e fiscal schema: tables dfe_nfe, dfe_nfe_participante,
  dfe_nfe_item, dfe_nfe_item_icms, dfe_nfe_item_ipi, dfe_nfe_item_pis,
  dfe_nfe_item_cofins, dfe_nfe_item_ibscbs, dfe_nfe_total_icms,
  dfe_nfe_total_ibscbs, dfe_nfe_total_rettrib.
- Fiscal foreign key hierarchy with ON DELETE CASCADE.
- Encadeated migration: v1, v2, and v3 databases all reach v4 in a single call.

Connection-level PRAGMAs that are NOT persisted in the database file
(e.g. foreign_keys, synchronous) belong to connection configuration and
are not verified here.
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


Describe 'Initialize-DFeIndex' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $testID = [guid]::NewGuid().ToString('N')

            $Script:TempRootPath = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.Tests-{0}' -f $testID
            )

            $splatParams = @{
                Path        = $Script:TempRootPath
                ItemType    = 'Directory'
                Force       = $true
                ErrorAction = 'Stop'
            }

            New-Item @splatParams | Out-Null

            $env:LOCALAPPDATA = $Script:TempRootPath

            $Script:Cnpj = '12345678000199'

            # Helper: Open-TestConnection
            # Opens a raw SQLiteConnection to the given path.
            # Caller is responsible for Dispose().
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

            # Helper: Invoke-TestScalar
            # Executes a single-value query and Returns the scalar result.
            # Accepts optional named parameters via hashtable.
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
                            $command.Parameters.AddWithValue($key, $Parameters[$key]) | Out-Null
                        }

                        $command.ExecuteScalar()
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }

            # Helper: Invoke-TestNonQuery
            # Executes a non-query statement (INSERT, PRAGMA, DDL).
            # Accepts optional named parameters via hashtable.
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
                            $command.Parameters.AddWithValue($key, $Parameters[$key]) | Out-Null
                        }

                        $command.ExecuteNonQuery() | Out-Null
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }

            # Helper: Get-TestTableInfo
            # Returns a hashtable keyed by column name with PRAGMA table_info
            # metadata for the given table.
            #
            # NOTE: SQLite Does not support parameter binding in PRAGMA
            # statements. The table name is bracket-quoted as an identifier
            # escape. This is safe because TableName is always a hardcoded
            # literal in this test suite - never external input.
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
                                $columns[[string]$reader['name']] = [pscustomobject]@{
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

            # Helper: Get-TestObjectSql
            # Returns the CREATE SQL for a table or index from sqlite_master.
            # Uses parameterised queries (sqlite_master accepts them normally).
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

                $splatParams = @{
                    Path = $Path
                    Sql  = 'SELECT sql FROM sqlite_master WHERE type = @type AND name = @name;'
                    Parameters = @{
                        '@type' = $Type
                        '@name' = $Name
                    }
                }

                $result = Invoke-TestScalar @splatParams

                if ($null -eq $result -or $result -is [System.DBNull]) {
                    return $null
                }

                [string]$result
            }

            # Helper: Test-TestObjectExist
            # Returns $true if an object of the given type and name exists.
            # Uses parameterised queries.
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

                $splatParams = @{
                    Path = $Path
                    Sql  =  'SELECT COUNT(*) FROM sqlite_master WHERE type = @type AND name = @name;'
                    Parameters = @{
                        '@type' = $Type
                        '@name' = $Name
                    }
                }

                $count = Invoke-TestScalar @splatParams

                [int]$count -eq 1
            }

            # Helper: Get-TestDatabasePath
            # Returns the expected index.db path for a given CNPJ.
            # Must stay in sync with Get-StorePath -Scope Index.
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
                    'index.db'
                )
            }

            # Run the primary database used by most contexts.
            $Script:DbPath = Initialize-DFeIndex -Cnpj $Script:Cnpj
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

        #region Database
        Context 'Database creation' {

            It 'Creates the parent data directory' {
                $dataDirectory = [System.IO.Path]::GetDirectoryName($Script:DbPath)

                Test-Path -LiteralPath $dataDirectory -PathType Container |
                    Should -BeTrue
            }

            It 'Creates index.db' {
                Test-Path -LiteralPath $Script:DbPath -PathType Leaf |
                    Should -BeTrue
            }

            It 'Returns a System.String' {
                $Script:DbPath | Should -BeOfType ([string])
            }

            It 'Returns the exact index.db path' {
                $Script:DbPath |
                    Should -Be (Get-TestDatabasePath -Cnpj $Script:Cnpj)
            }
        }

        # WAL journal mode
        # WAL is stored in the database file itself - not a transient connection
        # setting - and is therefore visible to any subsequent connection.
        # It is part of the observable contract of Initialize-DFeIndex.
        Context 'WAL journal mode' {

            It 'Configures the database for WAL mode' {
                $sqlParams = @{
                    Path = $Script:DbPath
                    Sql  = 'PRAGMA journal_mode;'
                }

                $journalMode = Invoke-TestScalar @sqlParams
                $journalMode.ToString().ToLowerInvariant() | Should -Be 'wal'
            }
        }

        # Schema version
        Context 'Schema version' {

            It 'Sets PRAGMA user_version to 4 on a new database' {
                $sqlParams = @{
                    Path = $Script:DbPath
                    Sql  = 'PRAGMA user_version;'
                }

                $version = Invoke-TestScalar @sqlParams
                [int]$version | Should -Be 4
            }
        }

        # Schema tables
        Context 'Schema tables' {

            It 'Creates dfe_document' {
                $objParams = @{
                    Path = $Script:DbPath
                    Type = 'table'
                    Name = 'dfe_document'
                }

                Test-TestObjectExist @objParams | Should -BeTrue
            }

            It 'Creates dfe_evento' {
                $objParams = @{
                    Path = $Script:DbPath
                    Type = 'table'
                    Name = 'dfe_evento'
                }

                Test-TestObjectExist @objParams | Should -BeTrue
            }

            It 'Creates dfe_inutilizacao' {
                $objParams = @{
                    Path = $Script:DbPath
                    Type = 'table'
                    Name = 'dfe_inutilizacao'
                }

                Test-TestObjectExist @objParams | Should -BeTrue
            }
        }

        # dfe_document schema
        Context 'dfe_document schema' {

            BeforeAll {

                $sqlParams = @{
                    Path      = $Script:DbPath
                    TableName = 'dfe_document'
                }

                $Script:DocumentColumns = Get-TestTableInfo @sqlParams

                $objSqlParams = @{
                    Path = $Script:DbPath
                    Type = 'table'
                    Name = 'dfe_document'
                }

                $Script:DocumentSql = Get-TestObjectSql @objSqlParams
            }

            It 'Contains exactly the expected columns' {
                $expectedColumns = @(
                    'chave_acesso'
                    'dh_emi'
                    'file_path'
                    'indexed_at'
                    'is_proc'
                    'modelo'
                    'ndoc'
                    'serie'
                    'sha256'
                    'processing_status'
                    'processing_started_at'
                    'processed_at'
                    'processing_error'
                )

                $actualColumns = @($Script:DocumentColumns.Keys | Sort-Object)
                $expectedColumns = @($expectedColumns | Sort-Object)

                $actualColumns | Should -Be $expectedColumns
            }


            It 'Defines chave_acesso as the primary key' {
                $Script:DocumentColumns['chave_acesso'].Primary | Should -Be 1
            }

            It 'Defines chave_acesso as NOT NULL' {
                $Script:DocumentColumns['chave_acesso'].NotNull | Should -Be 1
            }

            It 'Defines modelo as INTEGER NOT NULL' {
                $Script:DocumentColumns['modelo'].Type    | Should -Be 'INTEGER'
                $Script:DocumentColumns['modelo'].NotNull | Should -Be 1
            }

            It 'Defines file_path as TEXT NOT NULL' {
                $Script:DocumentColumns['file_path'].Type    | Should -Be 'TEXT'
                $Script:DocumentColumns['file_path'].NotNull | Should -Be 1
            }

            It 'Defines is_proc as INTEGER NOT NULL with default 0' {
                $Script:DocumentColumns['is_proc'].Type    | Should -Be 'INTEGER'
                $Script:DocumentColumns['is_proc'].NotNull | Should -Be 1
                $Script:DocumentColumns['is_proc'].Default | Should -Be '0'
            }

            It 'Defines ndoc as nullable INTEGER' {
                $Script:DocumentColumns['ndoc'].Type    | Should -Be 'INTEGER'
                $Script:DocumentColumns['ndoc'].NotNull | Should -Be 0
            }

            It 'Defines serie as nullable TEXT' {
                $Script:DocumentColumns['serie'].Type    | Should -Be 'TEXT'
                $Script:DocumentColumns['serie'].NotNull | Should -Be 0
            }

            It 'Defines dh_emi as nullable TEXT' {
                $Script:DocumentColumns['dh_emi'].Type    | Should -Be 'TEXT'
                $Script:DocumentColumns['dh_emi'].NotNull | Should -Be 0
            }

            It 'Defines sha256 as TEXT NOT NULL' {
                $Script:DocumentColumns['sha256'].Type    | Should -Be 'TEXT'
                $Script:DocumentColumns['sha256'].NotNull | Should -Be 1
            }

            It 'Defines indexed_at as TEXT NOT NULL' {
                $Script:DocumentColumns['indexed_at'].Type    | Should -Be 'TEXT'
                $Script:DocumentColumns['indexed_at'].NotNull | Should -Be 1
            }

            It 'Defines the is_proc CHECK constraint' {
                $Script:DocumentSql |
                    Should -Match 'CHECK\s*\(\s*is_proc\s+IN\s*\(\s*0\s*,\s*1\s*\)\s*\)'
            }
        }

        # dfe_evento schema
        Context 'dfe_evento schema' {

            BeforeAll {

                $sqlParams = @{
                    Path      = $Script:DbPath
                    TableName = 'dfe_evento'
                }

                $Script:EventoColumns = Get-TestTableInfo @sqlParams
            }

            It 'Contains exactly the expected columns' {
                @($Script:EventoColumns.Keys | Sort-Object) |
                    Should -Be @(
                        'chave_pai'
                        'dh_emi'
                        'evento_tipo'
                        'file_path'
                        'indexed_at'
                        'sha256'
                    )
            }

            It 'Defines chave_pai as NOT NULL' {
                $Script:EventoColumns['chave_pai'].NotNull | Should -Be 1
            }

            It 'Defines file_path as NOT NULL' {
                $Script:EventoColumns['file_path'].NotNull | Should -Be 1
            }

            It 'Defines evento_tipo as nullable TEXT' {
                $Script:EventoColumns['evento_tipo'].Type    | Should -Be 'TEXT'
                $Script:EventoColumns['evento_tipo'].NotNull | Should -Be 0
            }

            It 'Defines dh_emi as nullable TEXT' {
                $Script:EventoColumns['dh_emi'].Type    | Should -Be 'TEXT'
                $Script:EventoColumns['dh_emi'].NotNull | Should -Be 0
            }

            It 'Defines sha256 as TEXT NOT NULL' {
                $Script:EventoColumns['sha256'].Type    | Should -Be 'TEXT'
                $Script:EventoColumns['sha256'].NotNull | Should -Be 1
            }

            It 'Defines indexed_at as TEXT NOT NULL' {
                $Script:EventoColumns['indexed_at'].Type    | Should -Be 'TEXT'
                $Script:EventoColumns['indexed_at'].NotNull | Should -Be 1
            }

            It 'Defines (chave_pai, file_path) as the composite primary key' {
                $Script:EventoColumns['chave_pai'].Primary | Should -Be 1
                $Script:EventoColumns['file_path'].Primary | Should -Be 2
            }
        }

        # dfe_inutilizacao schema
        Context 'dfe_inutilizacao schema' {

            BeforeAll {

                $sqlParams = @{
                    Path      = $Script:DbPath
                    TableName = 'dfe_inutilizacao'
                }

                $Script:InutilizacaoColumns = Get-TestTableInfo @sqlParams
            }

            It 'Contains exactly the expected columns' {
                @($Script:InutilizacaoColumns.Keys | Sort-Object) |
                    Should -Be @(
                        'file_path'
                        'id_inut'
                        'indexed_at'
                        'modelo'
                        'nnf_fin'
                        'nnf_ini'
                        'serie'
                        'sha256'
                    )
            }

            It 'Defines id_inut as the primary key' {
                $Script:InutilizacaoColumns['id_inut'].Primary | Should -Be 1
            }

            It 'Defines id_inut as NOT NULL' {
                $Script:InutilizacaoColumns['id_inut'].NotNull | Should -Be 1
            }

            It 'Defines modelo as INTEGER NOT NULL' {
                $Script:InutilizacaoColumns['modelo'].Type    | Should -Be 'INTEGER'
                $Script:InutilizacaoColumns['modelo'].NotNull | Should -Be 1
            }

            It 'Defines serie as TEXT NOT NULL' {
                $Script:InutilizacaoColumns['serie'].Type    | Should -Be 'TEXT'
                $Script:InutilizacaoColumns['serie'].NotNull | Should -Be 1
            }

            It 'Defines nnf_ini as INTEGER NOT NULL' {
                $Script:InutilizacaoColumns['nnf_ini'].Type    | Should -Be 'INTEGER'
                $Script:InutilizacaoColumns['nnf_ini'].NotNull | Should -Be 1
            }

            It 'Defines nnf_fin as INTEGER NOT NULL' {
                $Script:InutilizacaoColumns['nnf_fin'].Type    | Should -Be 'INTEGER'
                $Script:InutilizacaoColumns['nnf_fin'].NotNull | Should -Be 1
            }

            It 'Defines file_path as TEXT NOT NULL' {
                $Script:InutilizacaoColumns['file_path'].Type    | Should -Be 'TEXT'
                $Script:InutilizacaoColumns['file_path'].NotNull | Should -Be 1
            }

            It 'Defines sha256 as TEXT NOT NULL' {
                $Script:InutilizacaoColumns['sha256'].Type    | Should -Be 'TEXT'
                $Script:InutilizacaoColumns['sha256'].NotNull | Should -Be 1
            }

            It 'Defines indexed_at as TEXT NOT NULL' {
                $Script:InutilizacaoColumns['indexed_at'].Type    | Should -Be 'TEXT'
                $Script:InutilizacaoColumns['indexed_at'].NotNull | Should -Be 1
            }
        }

        # Index definitions
        Context 'Index definitions' {

            It 'Creates ix_dfe_document_modelo_serie' {
                $objParams = @{
                    Path = $Script:DbPath
                    Type = 'index'
                    Name = 'ix_dfe_document_modelo_serie'
                }

                Test-TestObjectExist @objParams | Should -BeTrue
            }

            It 'Creates ix_dfe_evento_chave_pai' {
                $objParams = @{
                    Path = $Script:DbPath
                    Type = 'index'
                    Name = 'ix_dfe_evento_chave_pai'
                }

                Test-TestObjectExist @objParams | Should -BeTrue
            }

            It 'Creates ix_dfe_inutilizacao_modelo_serie' {
                $objParams = @{
                    Path = $Script:DbPath
                    Type = 'index'
                    Name = 'ix_dfe_inutilizacao_modelo_serie'
                }

                Test-TestObjectExist @objParams | Should -BeTrue
            }

            It 'Indexes dfe_document by (modelo, serie)' {
                $objParams = @{
                    Path = $Script:DbPath
                    Type = 'index'
                    Name = 'ix_dfe_document_modelo_serie'
                }

                $sql = Get-TestObjectSql @objParams
                $sql | Should -Match '\bON\s+dfe_document\s*\(\s*modelo\s*,\s*serie\s*\)'
            }

            It 'Filters dfe_document index by ndoc IS NOT NULL' {
                $objParams = @{
                    Path = $Script:DbPath
                    Type = 'index'
                    Name = 'ix_dfe_document_modelo_serie'
                }

                $sql = Get-TestObjectSql @objParams
                $sql | Should -Match '\bWHERE\s+ndoc\s+IS\s+NOT\s+NULL'
            }

            It 'Indexes dfe_evento by chave_pai' {
                $objParams = @{
                    Path = $Script:DbPath
                    Type = 'index'
                    Name = 'ix_dfe_evento_chave_pai'
                }

                $sql = Get-TestObjectSql @objParams
                $sql | Should -Match '\bON\s+dfe_evento\s*\(\s*chave_pai\s*\)'
            }

            It 'Indexes dfe_inutilizacao by (modelo, serie)' {
                $objParams = @{
                    Path = $Script:DbPath
                    Type = 'index'
                    Name = 'ix_dfe_inutilizacao_modelo_serie'
                }

                $sql = Get-TestObjectSql @objParams
                $sql | Should -Match '\bON\s+dfe_inutilizacao\s*\(\s*modelo\s*,\s*serie\s*\)'
            }
        }

        # Schema constraints
        Context 'Schema constraints' {

            It 'Rejects duplicate dfe_document chave_acesso' {
                $insert = @'
INSERT INTO dfe_document (
    chave_acesso, modelo, file_path, is_proc, sha256, indexed_at
) VALUES (
    '35260812345678000199550010000000011234567890',
    55, 'C:\test.xml', 0, 'HASH1', '2026-01-01T00:00:00Z'
);
'@
                Invoke-TestNonQuery -Path $Script:DbPath -Sql $insert

                { Invoke-TestNonQuery -Path $Script:DbPath -Sql $insert } |
                    Should -Throw
            }

            It 'Rejects an invalid dfe_document is_proc value' {
                $sql = @'
INSERT INTO dfe_document (
    chave_acesso, modelo, file_path, is_proc, sha256, indexed_at
) VALUES (
    '35260812345678000199550010000000021234567890',
    55, 'C:\test.xml', 2, 'HASH2', '2026-01-01T00:00:00Z'
);
'@
                { Invoke-TestNonQuery -Path $Script:DbPath -Sql $sql } |
                    Should -Throw
            }

            It 'Rejects dfe_evento without chave_pai' {
                $sql = @'
INSERT INTO dfe_evento (
    chave_pai, file_path, sha256, indexed_at
) VALUES (
    NULL, 'C:\evento.xml', 'HASH', '2026-01-01T00:00:00Z'
);
'@
                { Invoke-TestNonQuery -Path $Script:DbPath -Sql $sql } |
                    Should -Throw
            }

            It 'Rejects duplicate dfe_evento (chave_pai, file_path)' {
                $insert = @'
INSERT INTO dfe_evento (
    chave_pai, file_path, sha256, indexed_at
) VALUES (
    '35260812345678000199550010000000011234567890',
    'C:\evento.xml', 'HASH', '2026-01-01T00:00:00Z'
);
'@
                Invoke-TestNonQuery -Path $Script:DbPath -Sql $insert

                { Invoke-TestNonQuery -Path $Script:DbPath -Sql $insert } |
                    Should -Throw
            }

            It 'Rejects dfe_inutilizacao without id_inut' {
                $sql = @'
INSERT INTO dfe_inutilizacao (
    id_inut, modelo, serie, nnf_ini, nnf_fin, file_path, sha256, indexed_at
) VALUES (
    NULL, 55, '1', 1, 10, 'C:\inut.xml', 'HASH', '2026-01-01T00:00:00Z'
);
'@
                { Invoke-TestNonQuery -Path $Script:DbPath -Sql $sql } |
                    Should -Throw
            }
        }

        # Idempotency
        Context 'Idempotency' {

            BeforeAll {

                $Script:IdempotentCnpj   = '44444444000153'
                $Script:IdempotentDbPath = Initialize-DFeIndex -Cnpj $Script:IdempotentCnpj
            }

            It 'Does not throw when called repeatedly' {
                {
                    Initialize-DFeIndex -Cnpj $Script:IdempotentCnpj
                    Initialize-DFeIndex -Cnpj $Script:IdempotentCnpj
                    Initialize-DFeIndex -Cnpj $Script:IdempotentCnpj
                } | Should -Not -Throw
            }

            It 'Returns the same path on every call' {
                $first = Initialize-DFeIndex -Cnpj $Script:IdempotentCnpj
                $second = Initialize-DFeIndex -Cnpj $Script:IdempotentCnpj

                $second | Should -Be $first
            }

            It 'Preserves existing data' {
                $insert = @'
INSERT INTO dfe_document (
    chave_acesso, modelo, file_path, is_proc, ndoc, serie,
    dh_emi, sha256, indexed_at
) VALUES (
    '35260844444444000153550010000000011234567890',
    55, 'C:\existing.xml', 0, 1, '1',
    '2026-01-01T00:00:00Z', 'EXISTING_HASH', '2026-01-01T00:00:00Z'
);
'@
                Invoke-TestNonQuery -Path $Script:IdempotentDbPath -Sql $insert

                Initialize-DFeIndex -Cnpj $Script:IdempotentCnpj | Out-Null

                $sqlParams = @{
                    Path = $Script:IdempotentDbPath
                    Sql  = 'SELECT COUNT(*) FROM dfe_document;'
                }

                $count = Invoke-TestScalar @sqlParams

                [int]$count | Should -Be 1

                $sqlHashParams = @{
                    Path  = $Script:IdempotentDbPath
                    Sql  = 'SELECT sha256 FROM dfe_document LIMIT 1;'
                }

                $hash = Invoke-TestScalar @sqlHashParams
                $hash | Should -Be 'EXISTING_HASH'
            }

            It 'Does not alter the schema version on an already-initialised database' {
                $sqlParams = @{
                    Path = $Script:IdempotentDbPath
                    Sql  = 'PRAGMA user_version;'
                }

                $version = Invoke-TestScalar @sqlParams
                [int]$version | Should -Be 4
            }
        }

        # Existing valid database (user_version = 1, schema intact)
        # Verifies that a v1 database is correctly migrated to v4 in a single call.
        Context 'Existing valid database' {

            BeforeAll {

                $Script:ExistingCnpj   = '55555555000187'
                $Script:ExistingDbPath = Get-TestDatabasePath -Cnpj $Script:ExistingCnpj

                $existingDir = [System.IO.Path]::GetDirectoryName($Script:ExistingDbPath)
                New-Item -ItemType Directory -Path $existingDir -Force -ErrorAction Stop |
                    Out-Null

                # Build a v1 schema without calling Initialize-DFeIndex,
                # so this context is independent of idempotency coverage.
                Invoke-TestNonQuery -Path $Script:ExistingDbPath -Sql @'
CREATE TABLE dfe_document (
    chave_acesso TEXT    NOT NULL PRIMARY KEY,
    modelo       INTEGER NOT NULL,
    file_path    TEXT    NOT NULL,
    is_proc      INTEGER NOT NULL DEFAULT 0 CHECK (is_proc IN (0, 1)),
    ndoc         INTEGER,
    serie        TEXT,
    dh_emi       TEXT,
    sha256       TEXT    NOT NULL,
    indexed_at   TEXT    NOT NULL
);

CREATE INDEX ix_dfe_document_modelo_serie
    ON dfe_document (modelo, serie)
    WHERE ndoc IS NOT NULL;

CREATE TABLE dfe_evento (
    chave_pai   TEXT NOT NULL,
    file_path   TEXT NOT NULL,
    evento_tipo TEXT,
    dh_emi      TEXT,
    sha256      TEXT NOT NULL,
    indexed_at  TEXT NOT NULL,
    PRIMARY KEY (chave_pai, file_path)
);

CREATE INDEX ix_dfe_evento_chave_pai
    ON dfe_evento (chave_pai);

CREATE TABLE dfe_inutilizacao (
    id_inut    TEXT    NOT NULL PRIMARY KEY,
    modelo     INTEGER NOT NULL,
    serie      TEXT    NOT NULL,
    nnf_ini    INTEGER NOT NULL,
    nnf_fin    INTEGER NOT NULL,
    file_path  TEXT    NOT NULL,
    sha256     TEXT    NOT NULL,
    indexed_at TEXT    NOT NULL
);

CREATE INDEX ix_dfe_inutilizacao_modelo_serie
    ON dfe_inutilizacao (modelo, serie);

PRAGMA user_version = 1;
'@
            }

            It 'Succeeds without throwing' {
                { Initialize-DFeIndex -Cnpj $Script:ExistingCnpj -ErrorAction Stop } |
                    Should -Not -Throw
            }

            It 'Returns the correct path' {
                $path = Initialize-DFeIndex -Cnpj $Script:ExistingCnpj
                $path | Should -Be $Script:ExistingDbPath
            }

            It 'Upgrades user_version to 4' {
                $sqlParams = @{
                    Path = $Script:ExistingDbPath
                    Sql  = 'PRAGMA user_version;'
                }

                $version = Invoke-TestScalar @sqlParams
                [int]$version | Should -Be 4
            }

            It 'leaves all core tables intact' {
                foreach ($table in @('dfe_document', 'dfe_evento', 'dfe_inutilizacao')) {
                    $objParams = @{
                        Path = $Script:ExistingDbPath
                        Type = 'table'
                        Name = $table
                    }

                    Test-TestObjectExist @objParams |
                        Should -BeTrue -Because "table '$table' must survive migration"
                }
            }

            It 'Creates the normalized fiscal tables after migration' {
                foreach ($table in @('dfe_nfe', 'dfe_nfe_item', 'dfe_nfe_total_icms')) {
                    $objParams = @{
                        Path = $Script:ExistingDbPath
                        Type = 'table'
                        Name = $table
                    }

                    Test-TestObjectExist @objParams |
                        Should -BeTrue -Because "table '$table' must be created by v1->v4 migration"
                }
            }
        }

        # Partial compatible schema (mid-creation crash recovery)
        #
        # Simulates a database left with user_version = 0 and one table already
        # created by a prior incomplete run. The existing table has the expected
        # structure, so CREATE TABLE IF NOT EXISTS is a safe no-op for it.
        #
        # This tests recovery from an interrupted first-time creation, NOT from
        # a structurally incompatible or corrupted schema. A table that already
        # exists with wrong columns would NOT be corrected by this code path.
        Context 'Partial compatible schema from interrupted creation' {

            BeforeAll {

                $Script:PartialCnpj   = '66666666000160'
                $Script:PartialDbPath = Get-TestDatabasePath -Cnpj $Script:PartialCnpj

                $partialDir = [System.IO.Path]::GetDirectoryName($Script:PartialDbPath)
                New-Item -ItemType Directory -Path $partialDir -Force -ErrorAction Stop |
                    Out-Null

                # Simulate: dfe_document created, creation crashed before
                # the remaining tables and user_version = 1 were committed.
                Invoke-TestNonQuery -Path $Script:PartialDbPath -Sql @'
CREATE TABLE dfe_document (
    chave_acesso          TEXT     NOT NULL PRIMARY KEY,
    modelo                INTEGER  NOT NULL,
    file_path             TEXT     NOT NULL,
    is_proc               INTEGER  NOT NULL DEFAULT 0 CHECK (is_proc IN (0, 1)),
    ndoc                  INTEGER,
    serie                 TEXT,
    dh_emi                TEXT,
    sha256                TEXT     NOT NULL,
    indexed_at            TEXT     NOT NULL,
    processing_status     TEXT     NOT NULL DEFAULT 'Indexed',
    processing_started_at TEXT,
    processed_at          TEXT,
    processing_error      TEXT,
    CHECK (
        processing_status IN (
            'Indexed',
            'Processing',
            'Processed',
            'Failed'
        )
    )
);
'@
                # user_version remains 0 - the transaction never committed.
            }

            It 'Recovers without throwing' {
                { Initialize-DFeIndex -Cnpj $Script:PartialCnpj -ErrorAction Stop } |
                    Should -Not -Throw
            }

            It 'Completes the schema to user_version = 4' {
                $sqlParams = @{
                    Path = $Script:PartialDbPath
                    Sql  = 'PRAGMA user_version;'
                }

                $version = Invoke-TestScalar @sqlParams
                [int]$version | Should -Be 4
            }

            It 'Creates all remaining core tables' {
                foreach ($table in @('dfe_evento', 'dfe_inutilizacao')) {
                    $objParams = @{
                        Path = $Script:PartialDbPath
                        Type = 'table'
                        Name = $table
                    }

                    Test-TestObjectExist @objParams |
                        Should -BeTrue -Because "table '$table' must be created after recovery"
                }
            }

            It 'Creates the normalized fiscal tables after recovery' {
                foreach ($table in @('dfe_nfe', 'dfe_nfe_item', 'dfe_nfe_total_icms')) {
                    $objParams = @{
                        Path = $Script:PartialDbPath
                        Type = 'table'
                        Name = $table
                    }

                    Test-TestObjectExist @objParams |
                        Should -BeTrue -Because "table '$table' must be created after recovery"
                }
            }
        }

        # Normalized NF-e fiscal tables
        Context 'Normalized NF-e fiscal tables' {

            It 'Creates the normalized NF-e fiscal tables' {
                $expectedTables = @(
                    'dfe_nfe'
                    'dfe_nfe_participante'
                    'dfe_nfe_item'
                    'dfe_nfe_item_icms'
                    'dfe_nfe_item_ipi'
                    'dfe_nfe_item_pis'
                    'dfe_nfe_item_cofins'
                    'dfe_nfe_item_ibscbs'
                    'dfe_nfe_total_icms'
                    'dfe_nfe_total_ibscbs'
                    'dfe_nfe_total_rettrib'
                )

                foreach ($tableName in $expectedTables) {
                    $objParams = @{
                        Path = $Script:DbPath
                        Type = 'table'
                        Name = $tableName
                    }

                    Test-TestObjectExist @objParams |
                        Should -BeTrue -Because "table '$tableName' must exist"
                }
            }
        }

        # dfe_nfe schema
        Context 'dfe_nfe schema' {

            BeforeAll {

                $params = @{
                    Path      = $Script:DbPath
                    TableName = 'dfe_nfe'
                }

                $Script:NFeColumns = Get-TestTableInfo @params

                $sqlParams = @{
                    Path = $Script:DbPath
                    Type = 'table'
                    Name = 'dfe_nfe'
                }

                $Script:NFeSql = Get-TestObjectSql @sqlParams
            }

            It 'Contains exactly the expected columns' {
                $expectedColumns = @(
                    'chave_acesso'
                    'schema_version'
                    'source_sha256'
                    'extracted_at'
                    'modelo'
                    'uf_emissao'
                    'natureza_operacao'
                    'serie'
                    'numero'
                    'emitido_em'
                    'saida_entrada_em'
                    'tipo_operacao'
                    'destino'
                    'municipio_fato_gerador'
                    'tipo_impressao'
                    'tipo_emissao'
                    'finalidade'
                    'ind_consumidor_final'
                    'ind_presenca'
                ) | Sort-Object

                @($Script:NFeColumns.Keys | Sort-Object) |
                    Should -Be $expectedColumns
            }

            It 'Defines chave_acesso as the primary key' {
                $Script:NFeColumns['chave_acesso'].Primary |
                    Should -Be 1
            }

            It 'Requires projection provenance' {
                $Script:NFeColumns['schema_version'].NotNull |
                    Should -Be 1

                $Script:NFeColumns['source_sha256'].NotNull |
                    Should -Be 1

                $Script:NFeColumns['extracted_at'].NotNull |
                    Should -Be 1
            }

            It 'Stores source_sha256 and extracted_at as TEXT' {
                $Script:NFeColumns['source_sha256'].Type |
                    Should -Be 'TEXT'

                $Script:NFeColumns['extracted_at'].Type |
                    Should -Be 'TEXT'
            }

            It 'Restricts modelo to NF-e and NFC-e' {
                $Script:NFeSql |
                    Should -Match (
                        'CHECK\s*\(\s*modelo\s+IN\s*' +
                        '\(\s*55\s*,\s*65\s*\)\s*\)'
                    )
            }
        }

        # dfe_nfe_participante schema
        Context 'dfe_nfe_participante schema' {

            BeforeAll {

                $params = @{
                    Path      = $Script:DbPath
                    TableName = 'dfe_nfe_participante'
                }

                $Script:ParticipanteColumns = Get-TestTableInfo @params

                $sqlParams = @{
                    Path = $Script:DbPath
                    Type = 'table'
                    Name = 'dfe_nfe_participante'
                }

                $Script:ParticipanteSql = Get-TestObjectSql @sqlParams
            }

            It 'Contains exactly the expected columns' {
                $expectedColumns = @(
                    'chave_acesso'
                    'tipo_participante'
                    'cnpj'
                    'cpf'
                    'razao_social'
                    'nome_fantasia'
                    'inscricao_estadual'
                    'ind_ie'
                    'regime_tributario'
                    'email'
                    'logradouro'
                    'numero'
                    'complemento'
                    'bairro'
                    'cod_municipio'
                    'municipio'
                    'uf'
                    'cep'
                    'cod_pais'
                    'pais'
                    'telefone'
                ) | Sort-Object

                @($Script:ParticipanteColumns.Keys | Sort-Object) |
                    Should -Be $expectedColumns
            }

            It 'Defines a composite primary key using chave_acesso and tipo_participante' {
                $Script:ParticipanteColumns['chave_acesso'].Primary |
                    Should -Be 1

                $Script:ParticipanteColumns['tipo_participante'].Primary |
                    Should -Be 2
            }

            It 'Restricts tipo_participante to Emitente and Destinatario' {
                $Script:ParticipanteSql |
                    Should -Match (
                        "CHECK\s*\(\s*tipo_participante\s+IN\s*" +
                        "\(\s*'Emitente'\s*,\s*'Destinatario'\s*\)\s*\)"
                    )
            }
        }

        # dfe_nfe_item schema
        Context 'dfe_nfe_item schema' {

            BeforeAll {

                $params = @{
                    Path      = $Script:DbPath
                    TableName = 'dfe_nfe_item'
                }

                $Script:NFeItemColumns = Get-TestTableInfo @params
            }

            It 'Defines a composite primary key using chave_acesso and n_item' {
                $Script:NFeItemColumns['chave_acesso'].Primary |
                    Should -Be 1

                $Script:NFeItemColumns['n_item'].Primary |
                    Should -Be 2
            }

            It 'Stores fiscal codes as TEXT' {
                $Script:NFeItemColumns['ncm'].Type  | Should -Be 'TEXT'
                $Script:NFeItemColumns['cfop'].Type | Should -Be 'TEXT'
            }

            It 'Stores decimal fiscal values as TEXT' {
                $decimalColumns = @(
                    'qte_comercial'
                    'vlr_unitario'
                    'vlr_produto'
                    'qte_tributavel'
                    'vlr_unitario_tributavel'
                    'vlr_frete'
                    'vlr_seguro'
                    'vlr_desconto'
                    'vlr_outras_despesas'
                )

                foreach ($columnName in $decimalColumns) {
                    $Script:NFeItemColumns[$columnName].Type |
                        Should -Be 'TEXT' -Because "column '$columnName' must be TEXT"
                }
            }
        }

        # Normalized fiscal Indexes
        Context 'Normalized fiscal Indexes' {

            It 'Creates the CFOP item index' {
                $params = @{
                    Path = $Script:DbPath
                    Type = 'index'
                    Name = 'ix_dfe_nfe_item_cfop'
                }

                Test-TestObjectExist @params |
                    Should -BeTrue
            }

            It 'Creates the NCM item index' {
                $params = @{
                    Path = $Script:DbPath
                    Type = 'index'
                    Name = 'ix_dfe_nfe_item_ncm'
                }

                Test-TestObjectExist @params |
                    Should -BeTrue
            }
        }

        # Normalized fiscal foreign keys
        Context 'Normalized fiscal foreign keys' {

            BeforeAll {

                function Get-TestForeignKey {
                    [CmdletBinding()]
                    [OutputType([pscustomobject[]])]
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
                            $command.CommandText = "PRAGMA foreign_key_list([$TableName]);"

                            $reader = $command.ExecuteReader()

                            try {
                                $result = [System.Collections.Generic.List[pscustomobject]]::new()

                                while ($reader.Read()) {
                                    $result.Add(
                                        [pscustomobject]@{
                                            Id       = [int]$reader['id']
                                            Sequence = [int]$reader['seq']
                                            Table    = [string]$reader['table']
                                            From     = [string]$reader['from']
                                            To       = [string]$reader['to']
                                            OnUpdate = [string]$reader['on_update']
                                            OnDelete = [string]$reader['on_delete']
                                        }
                                    )
                                }

                                $result.ToArray()
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
            }

            It 'Links dfe_nfe to dfe_document with delete cascade' {
                $foreignKeys = @(
                    Get-TestForeignKey -Path $Script:DbPath -TableName 'dfe_nfe'
                )

                $foreignKeys | Should -HaveCount 1

                $foreignKeys[0].Table    | Should -Be 'dfe_document'
                $foreignKeys[0].From     | Should -Be 'chave_acesso'
                $foreignKeys[0].To       | Should -Be 'chave_acesso'
                $foreignKeys[0].OnDelete | Should -Be 'CASCADE'
                $foreignKeys[0].OnUpdate | Should -Be 'NO ACTION'
            }

            It 'Links dfe_nfe_participante to dfe_nfe with delete cascade' {
                $foreignKeys = @(
                    Get-TestForeignKey -Path $Script:DbPath -TableName 'dfe_nfe_participante'
                )

                $foreignKeys | Should -HaveCount 1

                $foreignKeys[0].Table    | Should -Be 'dfe_nfe'
                $foreignKeys[0].OnDelete | Should -Be 'CASCADE'
            }

            It 'Links dfe_nfe_item to dfe_nfe with delete cascade' {
                $foreignKeys = @(
                    Get-TestForeignKey `
                        -Path $Script:DbPath `
                        -TableName 'dfe_nfe_item'
                )

                $foreignKeys | Should -HaveCount 1

                $foreignKeys[0].Table    | Should -Be 'dfe_nfe'
                $foreignKeys[0].OnDelete | Should -Be 'CASCADE'
            }

            It 'Links item tax tables to their parent item with delete cascade' {
                $taxTables = @(
                    'dfe_nfe_item_icms'
                    'dfe_nfe_item_ipi'
                    'dfe_nfe_item_pis'
                    'dfe_nfe_item_cofins'
                    'dfe_nfe_item_ibscbs'
                )

                foreach ($tableName in $taxTables) {
                    $foreignKeys = @(
                        Get-TestForeignKey -Path $Script:DbPath -TableName $tableName
                    )

                    $foreignKeys | Should -HaveCount 2 -Because "'$tableName' has a composite FK"

                    @($foreignKeys.Table | Select-Object -Unique) |
                        Should -Be @('dfe_nfe_item')

                    @($foreignKeys.OnDelete | Select-Object -Unique) |
                        Should -Be @('CASCADE')
                }
            }

            It 'Links total tables to dfe_nfe with delete cascade' {
                $totalTables = @(
                    'dfe_nfe_total_icms'
                    'dfe_nfe_total_ibscbs'
                    'dfe_nfe_total_rettrib'
                )

                foreach ($tableName in $totalTables) {
                    $foreignKeys = @(
                        Get-TestForeignKey -Path $Script:DbPath -TableName $tableName
                    )

                    $foreignKeys | Should -HaveCount 1 -Because "'$tableName' has a single FK"

                    $foreignKeys[0].Table    | Should -Be 'dfe_nfe'
                    $foreignKeys[0].OnDelete | Should -Be 'CASCADE'
                }
            }
        }

        # Normalized fiscal cascade behavior
        Context 'Normalized fiscal cascade behavior' {

            It 'Removes the complete fiscal projection when dfe_document is deleted' {
                $chave = '35260912345678000199550010000000011234567890'

                $connection = Open-TestConnection -Path $Script:DbPath

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = 'PRAGMA foreign_keys = ON;'
                        $command.ExecuteNonQuery() | Out-Null

                        $chaveParam       = $command.Parameters.Add('@chave', [System.Data.DbType]::String)
                        $chaveParam.Value = $chave

                        $command.CommandText = @'
INSERT INTO dfe_document (
    chave_acesso, modelo, file_path, is_proc, sha256, indexed_at
) VALUES (
    @chave, 55, 'C:\test\nfe.xml', 1, 'ABCDEF',
    '2026-09-23T00:00:00.0000000+00:00'
);
'@
                        $command.ExecuteNonQuery() | Out-Null

                        $command.CommandText = @'
INSERT INTO dfe_nfe (
    chave_acesso, schema_version, source_sha256, extracted_at, modelo
) VALUES (
    @chave, 1, 'ABCDEF', '2026-09-23T00:01:00.0000000+00:00', 55
);
'@
                        $command.ExecuteNonQuery() | Out-Null

                        $command.CommandText = @'
INSERT INTO dfe_nfe_item (
    chave_acesso, n_item, cod_produto, cfop, qte_comercial, vlr_produto
) VALUES (
    @chave, 1, 'TEST', '5102', '1.0000', '100.00'
);
'@
                        $command.ExecuteNonQuery() | Out-Null

                        $command.CommandText = @'
INSERT INTO dfe_nfe_item_icms (
    chave_acesso, n_item, grupo, cst, vlr_bc, pct_icms, vlr_icms
) VALUES (
    @chave, 1, 'ICMS00', '00', '100.00', '18.0000', '18.00'
);
'@
                        $command.ExecuteNonQuery() | Out-Null

                        $command.CommandText = @'
DELETE FROM dfe_document WHERE chave_acesso = @chave;
'@
                        $command.ExecuteNonQuery() | Out-Null
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }

                foreach ($tableName in @('dfe_nfe', 'dfe_nfe_item', 'dfe_nfe_item_icms')) {
                    $invokeParams = @{
                        Path       = $Script:DbPath
                        Sql        = "SELECT COUNT(*) FROM [$tableName] WHERE chave_acesso = @chave;"
                        Parameters = @{ '@chave' = $chave }

                    }

                    $count = Invoke-TestScalar @invokeParams

                    [int]$count | Should -Be 0 -Because "'$tableName' must be removed by cascade"
                }
            }
        }

        # Schema migration v3 to v4
        Context 'Schema migration v3 to v4' {

            BeforeAll {

                $Script:MigrationCnpj   = '12345678000270'
                $Script:MigrationDbPath = Get-TestDatabasePath -Cnpj $Script:MigrationCnpj

                $databaseDirectory = [System.IO.Path]::GetDirectoryName(
                    $Script:MigrationDbPath
                )

                New-Item -Path $databaseDirectory -ItemType Directory -Force |
                    Out-Null

                $connection = Open-TestConnection -Path $Script:MigrationDbPath

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = @'
CREATE TABLE dfe_document (
    chave_acesso TEXT    NOT NULL PRIMARY KEY,
    modelo       INTEGER NOT NULL,
    file_path    TEXT    NOT NULL,
    is_proc      INTEGER NOT NULL DEFAULT 0 CHECK (is_proc IN (0, 1)),
    ndoc         INTEGER,
    serie        TEXT,
    dh_emi       TEXT,
    sha256                  TEXT NOT NULL,
    indexed_at              TEXT NOT NULL,
    processing_status       TEXT NOT NULL DEFAULT 'Indexed',
    processing_started_at   TEXT,
    processed_at            TEXT,
    processing_error        TEXT
);

CREATE TABLE dfe_evento (
    chave_pai   TEXT NOT NULL,
    file_path   TEXT NOT NULL,
    evento_tipo TEXT,
    dh_emi      TEXT,
    sha256      TEXT NOT NULL,
    indexed_at  TEXT NOT NULL,
    PRIMARY KEY (chave_pai, file_path)
);

CREATE TABLE dfe_inutilizacao (
    id_inut    TEXT    NOT NULL PRIMARY KEY,
    modelo     INTEGER NOT NULL,
    serie      TEXT    NOT NULL,
    nnf_ini    INTEGER NOT NULL,
    nnf_fin    INTEGER NOT NULL,
    file_path  TEXT    NOT NULL,
    sha256     TEXT    NOT NULL,
    indexed_at TEXT    NOT NULL
);

INSERT INTO dfe_document (
    chave_acesso, modelo, file_path, is_proc, sha256, indexed_at, processing_status
) VALUES (
    '35260912345678000199550010000000011234567890',
    55, 'C:\legacy\nfe.xml', 1, 'LEGACY-SHA',
    '2026-09-22T10:00:00.0000000+00:00', 'Processed'
);

PRAGMA user_version = 3;
'@
                        $command.ExecuteNonQuery() | Out-Null
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }

                Initialize-DFeIndex -Cnpj $Script:MigrationCnpj | Out-Null
            }

            It 'Upgrades user_version to 4' {
                $invokeParams = @{
                    Path = $Script:MigrationDbPath
                    Sql  = 'PRAGMA user_version;'
                }

                $version = Invoke-TestScalar @invokeParams

                [int]$version | Should -Be 4
            }

            It 'Creates the normalized fiscal schema' {
                $objParams = @{
                    Path = $Script:MigrationDbPath
                    Type = 'table'
                    Name = 'dfe_nfe'
                }

                Test-TestObjectExist @objParams | Should -BeTrue

                $objParams['Name'] = 'dfe_nfe_item'

                Test-TestObjectExist @objParams | Should -BeTrue
            }

            It 'Preserves existing dfe_document data' {
                $sqlParams = @{
                    Path = $Script:MigrationDbPath
                    Sql  = @'
SELECT processing_status
FROM dfe_document
WHERE chave_acesso = '35260912345678000199550010000000011234567890';
'@
                }

                $status = Invoke-TestScalar @sqlParams

                [string]$status | Should -Be 'Processed'
            }

            It 'Creates the processing status index when absent from a v3 database' {
                $objParams = @{
                    Path = $Script:MigrationDbPath
                    Type = 'index'
                    Name = 'ix_dfe_document_processing_status'
                }

                Test-TestObjectExist @objParams | Should -BeTrue
            }
        }

        # Schema migration v2 to v4
        Context 'Schema migration v2 to v4' {

            BeforeAll {

                $Script:MigrationV2Cnpj   = '12345678000351'
                $Script:MigrationV2DbPath = Get-TestDatabasePath -Cnpj $Script:MigrationV2Cnpj

                $databaseDirectory = [System.IO.Path]::GetDirectoryName(
                    $Script:MigrationV2DbPath
                )

                New-Item -Path $databaseDirectory -ItemType Directory -Force |
                    Out-Null

                $connection = Open-TestConnection -Path $Script:MigrationV2DbPath

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = @'
CREATE TABLE dfe_document (
    chave_acesso TEXT    NOT NULL PRIMARY KEY,
    modelo       INTEGER NOT NULL,
    file_path    TEXT    NOT NULL,
    is_proc      INTEGER NOT NULL DEFAULT 0 CHECK (is_proc IN (0, 1)),
    ndoc         INTEGER,
    serie        TEXT,
    dh_emi       TEXT,
    sha256       TEXT NOT NULL,
    indexed_at   TEXT NOT NULL
);

CREATE TABLE dfe_evento (
    chave_pai   TEXT NOT NULL,
    file_path   TEXT NOT NULL,
    evento_tipo TEXT,
    dh_emi      TEXT,
    sha256      TEXT NOT NULL,
    indexed_at  TEXT NOT NULL,
    PRIMARY KEY (chave_pai, file_path)
);

CREATE TABLE dfe_inutilizacao (
    id_inut    TEXT    NOT NULL PRIMARY KEY,
    modelo     INTEGER NOT NULL,
    serie      TEXT    NOT NULL,
    nnf_ini    INTEGER NOT NULL,
    nnf_fin    INTEGER NOT NULL,
    file_path  TEXT    NOT NULL,
    sha256     TEXT    NOT NULL,
    indexed_at TEXT    NOT NULL
);

INSERT INTO dfe_document (
    chave_acesso, modelo, file_path, is_proc, sha256, indexed_at
) VALUES (
    '35260912345678000199550010000000021234567890',
    55, 'C:\legacy\nfe.xml', 1, 'LEGACY-SHA-V2',
    '2026-09-22T10:00:00.0000000+00:00'
);

PRAGMA user_version = 2;
'@
                        $command.ExecuteNonQuery() | Out-Null
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }

                Initialize-DFeIndex -Cnpj $Script:MigrationV2Cnpj | Out-Null
            }

            It 'Upgrades user_version to 4' {
                $sqlParams = @{
                    Path = $Script:MigrationV2DbPath
                    Sql  = 'PRAGMA user_version;'
                }

                $version = Invoke-TestScalar @sqlParams

                [int]$version | Should -Be 4
            }

            It 'Adds processing state columns' {
                $sqlParams = @{
                    Path      = $Script:MigrationV2DbPath
                    TableName = 'dfe_document'
                }

                $columns = Get-TestTableInfo @sqlParams

                $columns.ContainsKey('processing_status')     | Should -BeTrue
                $columns.ContainsKey('processing_started_at') | Should -BeTrue
                $columns.ContainsKey('processed_at')          | Should -BeTrue
                $columns.ContainsKey('processing_error')      | Should -BeTrue
            }

            It 'Creates the normalized fiscal schema' {
                $objParams = @{
                    Path = $Script:MigrationV2DbPath
                    Type = 'table'
                    Name = 'dfe_nfe'
                }

                Test-TestObjectExist @objParams | Should -BeTrue
            }

            It 'Preserves existing dfe_document data' {
                $sqlParams = @{
                    Path = $Script:MigrationV2DbPath
                    Sql  = 'SELECT COUNT(*) FROM dfe_document;'
                }

                $count = Invoke-TestScalar @sqlParams

                [int]$count | Should -Be 1
            }
        }

        # Unsupported (future) schema version
        Context 'Unsupported schema version' {

            BeforeAll {

                $Script:FutureCnpj   = '99999999000191'
                $Script:FutureDbPath = Get-TestDatabasePath -Cnpj $Script:FutureCnpj

                $futureDir = [System.IO.Path]::GetDirectoryName($Script:FutureDbPath)

                New-Item -ItemType Directory -Path $futureDir -Force -ErrorAction Stop |
                    Out-Null

                # Pre-stamp an unsupported version to simulate a database created
                # by a newer release of PipeDFe.
                $sqlParams = @{
                    Path = $Script:FutureDbPath
                    Sql  = 'PRAGMA user_version = 999;'
                }

                Invoke-TestNonQuery @sqlParams
            }

            It 'Rejects an unsupported future schema version' {
                { Initialize-DFeIndex -Cnpj $Script:FutureCnpj -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports IndexSchemaInitFailed as the ErrorId' {
                try {
                    Initialize-DFeIndex -Cnpj $Script:FutureCnpj -ErrorAction Stop
                    throw 'Expected Initialize-DFeIndex to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'IndexSchemaInitFailed*'
                }
            }

            It 'Does not silently downgrade the schema version' {
                $sqlParams = @{
                    Path =  $Script:FutureDbPath
                    Sql  = 'PRAGMA user_version;'
                }

                $version = Invoke-TestScalar @sqlParams
                [int]$version | Should -Be 999
            }
        }

        # Corrupted database
        #
        # A file whose header is not a valid SQLite magic string causes the first
        # PRAGMA executed after Open() to fail with "file is not a database".
        # That exception propagates to the outer catch in Initialize-DFeIndex
        # and is re-thrown as IndexSchemaInitFailed.
        #
        # Note: sqlite3_open() always Succeeds - it only allocates a handle.
        # The format check happens on the first real I/O operation.
        Context 'Corrupted database' {

            BeforeAll {

                $Script:CorruptedCnpj = '77777777000130'
                $Script:CorruptedDbPath = Get-TestDatabasePath -Cnpj $Script:CorruptedCnpj

                $corruptDir = [System.IO.Path]::GetDirectoryName($Script:CorruptedDbPath)

                New-Item -ItemType Directory -Path $corruptDir -Force -ErrorAction Stop |
                    Out-Null

                # Write bytes that do not match the SQLite magic header.
                # The driver Rejects this deterministically on the first I/O.
                [System.IO.File]::WriteAllBytes(
                    $Script:CorruptedDbPath,
                    [byte[]]@(0xFF, 0xFE, 0x00, 0x01, 0x02, 0x03)
                )
            }

            It 'Throws a terminating error' {
                { Initialize-DFeIndex -Cnpj $Script:CorruptedCnpj -ErrorAction Stop } |
                    Should -Throw
            }

            It 'Reports IndexSchemaInitFailed as the ErrorId' {
                try {
                    Initialize-DFeIndex -Cnpj $Script:CorruptedCnpj -ErrorAction Stop
                    throw 'Expected Initialize-DFeIndex to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'IndexSchemaInitFailed*'
                }
            }
        }
        #endregion

        #region CNPJ isolation
        Context 'CNPJ isolation' {

            BeforeAll {

                $Script:OtherCnpj   = '11111111000191'
                $Script:OtherDbPath = Initialize-DFeIndex -Cnpj $Script:OtherCnpj
            }

            It 'Creates a different database path for another CNPJ' {
                $Script:OtherDbPath | Should -Not -Be $Script:DbPath
            }

            It 'Creates an independent physical database file for each CNPJ' {
                Test-Path -LiteralPath $Script:DbPath      -PathType Leaf | Should -BeTrue
                Test-Path -LiteralPath $Script:OtherDbPath -PathType Leaf | Should -BeTrue
            }

            It 'Does not share document data between CNPJs' {
                $insert = @'
INSERT INTO dfe_document (
    chave_acesso, modelo, file_path, is_proc, sha256, indexed_at
) VALUES (
    '35260811111111000191550010000000011234567890',
    55, 'C:\company-a.xml', 0, 'COMPANY_A', '2026-01-01T00:00:00Z'
);
'@
                Invoke-TestNonQuery -Path $Script:DbPath -Sql $insert

                $sqlParams = @{
                    Path = $Script:OtherDbPath
                    Sql  = 'SELECT COUNT(*) FROM dfe_document;'
                }

                $count = Invoke-TestScalar @sqlParams
                [int]$count | Should -Be 0
            }
        }
        #endregion

        #region Parameter validation
        Context 'Parameter validation' {

            It 'Rejects a CNPJ shorter than 14 digits' {
                { Initialize-DFeIndex -Cnpj '1234567890123' } | Should -Throw
            }

            It 'Rejects a CNPJ longer than 14 digits' {
                { Initialize-DFeIndex -Cnpj '123456789012345' } | Should -Throw
            }

            It 'Rejects a CNPJ containing non-numeric characters' {
                { Initialize-DFeIndex -Cnpj '12345678000!9' } | Should -Throw
            }

            It 'Rejects an empty CNPJ' {
                { Initialize-DFeIndex -Cnpj '' } | Should -Throw
            }

            It 'Declares Cnpj as a mandatory parameter' {
                $parameter = (Get-Command -Name Initialize-DFeIndex).Parameters['Cnpj']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } | Select-Object -ExpandProperty Mandatory |

                    Should -Contain $true
            }
        }
        #endregion
    }
}
