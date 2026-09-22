#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Set-DFeDocumentProcessingState.

.DESCRIPTION
Tests the persistent processing state machine of a Documento record against
the real SQLite index used by PipeDFe.

Allowed transitions:
  Indexed    -> Processing
  Processing -> Processed
  Processing -> Failed
  Failed     -> Processing

Coverage includes:
  - state transitions
  - persisted state
  - processing_started_at
  - processed_at
  - processing_error
  - UTC timestamps
  - required ErrorMessage
  - unexpected ErrorMessage
  - invalid transitions
  - missing documents
  - unsupported states
  - retry behavior
  - state/data consistency
  - CNPJ isolation
  - persistence after reopening
  - concurrent state protection
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Test helper functions do not manage user-visible state.'
)]

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseSingularNouns',
    '',
    Justification = 'Metadata is an uncountable noun.'
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

Describe 'Set-DFeDocumentProcessingState' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            #region Isolated environment.
            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $testID = [guid]::NewGuid().ToString('N')

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.Set-DFeDocumentProcessingState.Tests-{0}' -f $testID
            )

            $newItemParams = @{
                Path        = $Script:TempRoot
                ItemType    = 'Directory'
                Force       = $true
                ErrorAction = 'Stop'
            }

            New-Item @newItemParams | Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot
            $Script:TestCnpj  = '12345678000199'

            Initialize-DFeIndex -Cnpj $Script:TestCnpj | Out-Null
            #endregion

            #region Test helpers
            function New-TestChave {
                [CmdletBinding()]
                [OutputType([string])]
                param ()

                $prefix = '3526091234567800019955001000000001'

                $suffix = (
                    [guid]::NewGuid().ToString('N').Substring(0, 10)
                ) -replace '[a-f]', '1'

                $chave = $prefix + $suffix

                if ($chave.Length -ne 44) {
                    throw (
                        "Generated test access key has " +
                        "$($chave.Length) digits instead of 44."
                    )
                }

                if ($chave -notmatch '^\d{44}$') {
                    throw 'Generated test access key is not numeric.'
                }

                return $chave
            }

            function New-TestDocumentFile {
                [CmdletBinding()]
                [OutputType([System.IO.FileInfo])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Name
                )

                $path = [System.IO.Path]::Combine($Script:TempRoot, $Name)

                [System.IO.File]::WriteAllText(
                    $path,
                    '<nfe>test</nfe>',
                    [System.Text.Encoding]::UTF8
                )

                Get-Item -LiteralPath $path
            }

            function New-TestDocumentMetadata {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Chave,

                    [Parameter(Mandatory)]
                    [System.IO.FileInfo]$File
                )

                [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Documento
                    Chave  = $Chave
                    Modelo = [ModeloDFe]::NFe
                    IsProc = $false
                    File   = $File
                    Ndoc   = 1
                    Serie  = '1'
                    DhEmi  = '2026-09-21T10:00:00-03:00'
                }
            }

            function Add-TestDocument {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$Chave
                )

                $file = New-TestDocumentFile -Name "$Chave-$Cnpj.xml"

                $metadata = New-TestDocumentMetadata -Chave $Chave -File $file

                Save-DFeDocumentEntry -Cnpj $Cnpj -Metadata $metadata
            }

            function Get-TestDocument {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$Chave
                )

                $databasePath = Get-StorePath -Scope 'Index' -Cnpj $Cnpj

                $connection = Open-SqliteConnection -Path $databasePath

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = @'
SELECT
    chave_acesso,
    processing_status,
    processing_started_at,
    processed_at,
    processing_error
FROM dfe_document
WHERE chave_acesso = @chave;
'@

                        $parameter = $command.Parameters.Add(
                            '@chave',
                            [System.Data.DbType]::String
                        )

                        $parameter.Value = $Chave

                        $reader = $command.ExecuteReader()

                        try {
                            if (-not $reader.Read()) {
                                return $null
                            }

                            $processingStartedAt = if ($reader['processing_started_at'] -is [System.DBNull]) {
                                $null
                            } else {
                                [string]$reader['processing_started_at']
                            }

                            $processedAt = if ($reader['processed_at'] -is [System.DBNull]) {
                                $null
                            } else {
                                [string]$reader['processed_at']
                            }

                            $processingError = if ($reader['processing_error'] -is [System.DBNull]) {
                                $null
                            } else {
                                [string]$reader['processing_error']
                            }

                            [PSCustomObject]@{
                                ChaveAcesso         = [string]$reader['chave_acesso']
                                ProcessingStatus    = [string]$reader['processing_status']
                                ProcessingStartedAt = $processingStartedAt
                                ProcessedAt         = $processedAt
                                ProcessingError     = $processingError
                            }
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

            function Set-TestDocumentRawStatus {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$Chave,

                    [Parameter(Mandatory)]
                    [string]$Status
                )

                $databasePath = Get-StorePath -Scope 'Index' -Cnpj $Cnpj

                $connection = Open-SqliteConnection -Path $databasePath

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = @'
UPDATE dfe_document
SET processing_status = @status
WHERE chave_acesso = @chave;
'@

                        $statusParam = $command.Parameters.Add(
                            '@status',
                            [System.Data.DbType]::String
                        )

                        $statusParam.Value = $Status

                        $chaveParam = $command.Parameters.Add(
                            '@chave',
                            [System.Data.DbType]::String
                        )

                        $chaveParam.Value = $Chave

                        $command.ExecuteNonQuery() | Out-Null
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }
            #endregion
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData
            $removeItemParams = @{
                LiteralPath = $Script:TempRoot
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeItemParams
        }

        #region Indexed -> Processing
        Context 'Indexed -> Processing' {

            BeforeEach {

                $Script:Chave = New-TestChave

                Add-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave
            }

            It 'Changes the state to Processing' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $document.ProcessingStatus | Should -Be 'Processing'
            }

            It 'Sets processing_started_at' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $document.ProcessingStartedAt | Should -Not -BeNullOrEmpty
            }

            It 'Does not set processed_at' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $document.ProcessedAt | Should -BeNullOrEmpty
            }

            It 'Does not set processing_error' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $document.ProcessingError | Should -BeNullOrEmpty
            }

            It 'Stores processing_started_at as UTC' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $timestamp = [System.DateTimeOffset]::Parse($document.ProcessingStartedAt)

                $timestamp.Offset | Should -Be ([timespan]::Zero)
            }
        }
        #endregion

        #region Processing -> Processed
        Context 'Processing -> Processed' {

            BeforeEach {

                $Script:Chave = New-TestChave

                Add-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams
            }

            It 'Changes the state to Processed' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processed'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $document.ProcessingStatus | Should -Be 'Processed'
            }

            It 'Preserves processing_started_at' {
                $before = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processed'
                }

                Set-DFeDocumentProcessingState @setParams

                $after = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $after.ProcessingStartedAt | Should -Be $before.ProcessingStartedAt
            }

            It 'Sets processed_at' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processed'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $document.ProcessedAt | Should -Not -BeNullOrEmpty
            }

            It 'Stores processed_at as UTC' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processed'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $timestamp = [System.DateTimeOffset]::Parse($document.ProcessedAt)

                $timestamp.Offset | Should -Be ([timespan]::Zero)
            }

            It 'Does not persist an error' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processed'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $document.ProcessingError | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Processing -> Failed
        Context 'Processing -> Failed' {

            BeforeEach {

                $Script:Chave = New-TestChave

                Add-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams
            }

            It 'Changes the state to Failed' {
                $setParams = @{
                    Cnpj         = $Script:TestCnpj
                    ChaveAcesso  = $Script:Chave
                    Status       = 'Failed'
                    ErrorMessage = 'Falha durante o processamento.'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $document.ProcessingStatus | Should -Be 'Failed'
            }

            It 'Persists ErrorMessage' {
                $errorMessage = 'Falha durante o processamento.'

                $setParams = @{
                    Cnpj         = $Script:TestCnpj
                    ChaveAcesso  = $Script:Chave
                    Status       = 'Failed'
                    ErrorMessage = $errorMessage
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $document.ProcessingError | Should -Be $errorMessage
            }

            It 'Preserves processing_started_at' {
                $before = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $setParams = @{
                    Cnpj         = $Script:TestCnpj
                    ChaveAcesso  = $Script:Chave
                    Status       = 'Failed'
                    ErrorMessage = 'Falha.'
                }

                Set-DFeDocumentProcessingState @setParams

                $after = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $after.ProcessingStartedAt | Should -Be $before.ProcessingStartedAt
            }

            It 'Does not set processed_at' {
                $setParams = @{
                    Cnpj         = $Script:TestCnpj
                    ChaveAcesso  = $Script:Chave
                    Status       = 'Failed'
                    ErrorMessage = 'Falha.'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $document.ProcessedAt | Should -BeNullOrEmpty
            }

            It 'Requires ErrorMessage' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Failed'
                }

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'MissingProcessingError*'
            }

            It 'Rejects an empty ErrorMessage' {
                $setParams = @{
                    Cnpj         = $Script:TestCnpj
                    ChaveAcesso  = $Script:Chave
                    Status       = 'Failed'
                    ErrorMessage = [string]::Empty
                }

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'MissingProcessingError*'
            }

            It 'Rejects a whitespace-only ErrorMessage' {
                $setParams = @{
                    Cnpj         = $Script:TestCnpj
                    ChaveAcesso  = $Script:Chave
                    Status       = 'Failed'
                    ErrorMessage = '   '
                }

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'MissingProcessingError*'
            }

            It 'Does not modify the document when ErrorMessage is invalid' {
                $before = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Failed'
                }

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'MissingProcessingError*'

                $after = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $after.ProcessingStatus    | Should -Be $before.ProcessingStatus
                $after.ProcessingStartedAt | Should -Be $before.ProcessingStartedAt
                $after.ProcessedAt         | Should -Be $before.ProcessedAt
                $after.ProcessingError     | Should -Be $before.ProcessingError
            }
        }
        #endregion

        #region Failed -> Processing
        Context 'Failed -> Processing' {

            BeforeEach {

                $Script:Chave = New-TestChave

                Add-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $setParams = @{
                    Cnpj         = $Script:TestCnpj
                    ChaveAcesso  = $Script:Chave
                    Status       = 'Failed'
                    ErrorMessage = 'Primeira tentativa falhou.'
                }

                Set-DFeDocumentProcessingState @setParams
            }

            It 'Allows a retry' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $document.ProcessingStatus | Should -Be 'Processing'
            }

            It 'Clears the previous error' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $document.ProcessingError | Should -BeNullOrEmpty
            }

            It 'Creates a new processing_started_at timestamp' {
                $before = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                # Ensures the retry timestamp is strictly after the first attempt's
                # processing_started_at even on low-resolution system clocks.
                Start-Sleep -Milliseconds 10

                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $after = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $beforeTimestamp = [System.DateTimeOffset]::Parse($before.ProcessingStartedAt)
                $afterTimestamp  = [System.DateTimeOffset]::Parse($after.ProcessingStartedAt)

                $afterTimestamp | Should -BeGreaterThan $beforeTimestamp
            }

            It 'Does not leave processed_at populated' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $document.ProcessedAt | Should -BeNullOrEmpty
            }

            It 'Stores the retry timestamp as UTC' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $timestamp = [System.DateTimeOffset]::Parse($document.ProcessingStartedAt)

                $timestamp.Offset | Should -Be ([timespan]::Zero)
            }
        }
        #endregion

        #region Unexpected ErrorMessage
        Context 'Unexpected ErrorMessage' {

            BeforeEach {

                $Script:Chave = New-TestChave

                Add-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave
            }

            It 'Rejects ErrorMessage for Processing' {
                $setParams = @{
                    Cnpj         = $Script:TestCnpj
                    ChaveAcesso  = $Script:Chave
                    Status       = 'Processing'
                    ErrorMessage = 'Erro.'
                }

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'UnexpectedProcessingError*'
            }

            It 'Rejects ErrorMessage for Processed' {
                $setParams = @{
                    Cnpj         = $Script:TestCnpj
                    ChaveAcesso  = $Script:Chave
                    Status       = 'Processed'
                    ErrorMessage = 'Erro.'
                }

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'UnexpectedProcessingError*'
            }

            It 'Does not modify the document' {
                $before = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $setParams = @{
                    Cnpj         = $Script:TestCnpj
                    ChaveAcesso  = $Script:Chave
                    Status       = 'Processing'
                    ErrorMessage = 'Erro.'
                }

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'UnexpectedProcessingError*'

                $after = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $after.ProcessingStatus    | Should -Be $before.ProcessingStatus
                $after.ProcessingStartedAt | Should -Be $before.ProcessingStartedAt
                $after.ProcessedAt         | Should -Be $before.ProcessedAt
                $after.ProcessingError     | Should -Be $before.ProcessingError
            }
        }
        #endregion

        #region Invalid transitions
        Context 'Invalid transitions' {

            BeforeEach {

                $Script:Chave = New-TestChave

                Add-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave
            }

            It 'Rejects Indexed -> Processed' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processed'
                }

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'InvalidProcessingStateTransition*'
            }

            It 'Rejects Indexed -> Failed' {
                $setParams = @{
                    Cnpj         = $Script:TestCnpj
                    ChaveAcesso  = $Script:Chave
                    Status       = 'Failed'
                    ErrorMessage = 'Erro.'
                }

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'InvalidProcessingStateTransition*'
            }

            It 'Rejects Indexed -> Indexed' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Indexed'
                }

                { Set-DFeDocumentProcessingState @setParams } | Should -Throw
            }

            It 'Rejects Processing -> Processing' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'InvalidProcessingStateTransition*'
            }

            It 'Rejects Processed -> Processing' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $setParams['Status'] = 'Processed'

                Set-DFeDocumentProcessingState @setParams

                $setParams['Status'] = 'Processing'

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'InvalidProcessingStateTransition*'
            }

            It 'Rejects Processed -> Failed' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $setParams['Status'] = 'Processed'

                Set-DFeDocumentProcessingState @setParams

                $setParams['Status']       = 'Failed'
                $setParams['ErrorMessage'] = 'Erro.'

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'InvalidProcessingStateTransition*'
            }

            It 'Rejects Failed -> Processed' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $setParams['Status']       = 'Failed'
                $setParams['ErrorMessage'] = 'Erro.'

                Set-DFeDocumentProcessingState @setParams

                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processed'
                }

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'InvalidProcessingStateTransition*'
            }

            It 'Does not modify the document after an invalid transition' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $before = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                { Set-DFeDocumentProcessingState @setParams } | Should -Throw

                $after = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $after.ProcessingStatus    | Should -Be $before.ProcessingStatus
                $after.ProcessingStartedAt | Should -Be $before.ProcessingStartedAt
                $after.ProcessedAt         | Should -Be $before.ProcessedAt
                $after.ProcessingError     | Should -Be $before.ProcessingError
            }
        }
        #endregion

        #region Document not found
        Context 'Document not found' {

            It 'Throws DocumentNotFound' {
                $missingChave = New-TestChave

                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $missingChave
                    Status      = 'Processing'
                }

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'DocumentNotFound*'
            }
        }
        #endregion

        #region CNPJ isolation
        Context 'CNPJ isolation' {

            It 'Does not affect a document in another company index' {
                $otherCnpj   = '98765432000188'
                $sharedChave = New-TestChave

                Initialize-DFeIndex -Cnpj $otherCnpj | Out-Null

                Add-TestDocument -Cnpj $Script:TestCnpj -Chave $sharedChave
                Add-TestDocument -Cnpj $otherCnpj       -Chave $sharedChave

                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $sharedChave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $otherDocument = Get-TestDocument -Cnpj $otherCnpj -Chave $sharedChave

                $otherDocument.ProcessingStatus    | Should -Be 'Indexed'
                $otherDocument.ProcessingStartedAt | Should -BeNullOrEmpty
                $otherDocument.ProcessedAt         | Should -BeNullOrEmpty
                $otherDocument.ProcessingError     | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region State persistence
        Context 'State persistence' {

            BeforeEach {

                $Script:Chave = New-TestChave

                Add-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave
            }

            It 'Persists Processing after reopening the database' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $firstRead  = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave
                $secondRead = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $secondRead.ProcessingStatus    | Should -Be $firstRead.ProcessingStatus
                $secondRead.ProcessingStartedAt | Should -Be $firstRead.ProcessingStartedAt
            }

            It 'Persists Processed after reopening the database' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $setParams['Status'] = 'Processed'

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $document.ProcessingStatus    | Should -Be 'Processed'
                $document.ProcessedAt         | Should -Not -BeNullOrEmpty
                $document.ProcessingStartedAt | Should -Not -BeNullOrEmpty
            }

            It 'Persists Failed and its error after reopening the database' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $setParams['Status']       = 'Failed'
                $setParams['ErrorMessage'] = 'Falha persistida.'

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $document.ProcessingStatus    | Should -Be 'Failed'
                $document.ProcessingError     | Should -Be 'Falha persistida.'
                $document.ProcessingStartedAt | Should -Not -BeNullOrEmpty
                $document.ProcessedAt         | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Timestamp semantics
        Context 'Timestamp semantics' {

            BeforeEach {

                $Script:Chave = New-TestChave

                Add-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave
            }

            It 'Stores Processing timestamp using ISO 8601 round-trip format' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                {
                    [System.DateTimeOffset]::ParseExact(
                        $document.ProcessingStartedAt,
                        'o',
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )
                } | Should -Not -Throw
            }

            It 'Stores Processed timestamp using ISO 8601 round-trip format' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $setParams['Status'] = 'Processed'

                Set-DFeDocumentProcessingState @setParams

                $document = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                {
                    [System.DateTimeOffset]::ParseExact(
                        $document.ProcessedAt,
                        'o',
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )
                } | Should -Not -Throw
            }
        }
        #endregion

        #region Terminal state
        Context 'Processed is terminal' {

            BeforeEach {

                $Script:Chave = New-TestChave

                Add-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @setParams

                $setParams['Status'] = 'Processed'

                Set-DFeDocumentProcessingState @setParams
            }

            It 'Cannot be changed back to Processing' {
                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'InvalidProcessingStateTransition*'
            }

            It 'Cannot be changed to Failed' {
                $setParams = @{
                    Cnpj         = $Script:TestCnpj
                    ChaveAcesso  = $Script:Chave
                    Status       = 'Failed'
                    ErrorMessage = 'Erro posterior.'
                }

                { Set-DFeDocumentProcessingState @setParams } |
                    Should -Throw -ErrorId 'InvalidProcessingStateTransition*'
            }

            It 'Preserves all terminal-state data after rejected transitions' {
                $before = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $setParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                { Set-DFeDocumentProcessingState @setParams } | Should -Throw

                $after = Get-TestDocument -Cnpj $Script:TestCnpj -Chave $Script:Chave

                $after.ProcessingStatus    | Should -Be $before.ProcessingStatus
                $after.ProcessingStartedAt | Should -Be $before.ProcessingStartedAt
                $after.ProcessedAt         | Should -Be $before.ProcessedAt
                $after.ProcessingError     | Should -Be $before.ProcessingError
            }
        }
        #endregion
    }
}
