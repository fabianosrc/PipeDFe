#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Repair-DFeDocumentProcessingState.

.DESCRIPTION
Verifies compare-and-swap processing recovery against the real SQLite index.

Coverage includes:
  - successful Processing to Failed recovery
  - preservation of processing_started_at
  - persistence of processing_error
  - null processing_started_at recovery
  - changed processing_started_at protection
  - ABA retry protection
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Test helper functions do not manage user-visible state.'
)]

param()

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Repair-DFeDocumentProcessingState' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $testID = [guid]::NewGuid().ToString('N')

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.Repair-DFeDocumentProcessingState.Tests-{0}' -f $testID
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

            #region Test Helpers
            function New-TestChave {
                [CmdletBinding()]
                [OutputType([string])]
                param ()

                $newGuid = [guid]::NewGuid().ToString('N')

                $prefix = '3526091234567800019955001000000001'
                $suffix = $newGuid.Substring(0, 10) -replace '[a-f]', '1'
                $chave  = $prefix + $suffix

                if ($chave.Length -ne 44) {
                    throw "Generated test access key has $($chave.Length) digits instead of 44."
                }

                if ($chave -notmatch '^\d{44}$') {
                    throw 'Generated test access key is not numeric.'
                }

                $chave
            }

            function Add-TestDocument {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Chave
                )

                $filePath = [System.IO.Path]::Combine(
                    $Script:TempRoot,
                    '{0}.xml' -f $Chave
                )

                [System.IO.File]::WriteAllText(
                    $filePath,
                    '<nfe>test</nfe>',
                    [System.Text.Encoding]::UTF8
                )

                $file = Get-Item -LiteralPath $filePath

                $metadata = [pscustomobject]@{
                    Tipo   = [TipoXmlDFe]::Documento
                    Chave  = $Chave
                    Modelo = [ModeloDFe]::NFe
                    IsProc = $false
                    File   = $file
                    Ndoc   = 1
                    Serie  = '1'
                    DhEmi  = '2026-10-09T10:00:00-03:00'
                }

                Save-DFeDocumentEntry -Cnpj $Script:TestCnpj -Metadata $metadata
            }

            function Get-TestDocument {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Chave
                )

                $databasePath = Get-StorePath -Scope 'Index' -Cnpj $Script:TestCnpj
                $connection   = Open-SqliteConnection -Path $databasePath

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = @'
SELECT
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

                            $startedAt = if (
                                $reader['processing_started_at'] -is [System.DBNull]
                            ) {
                                $null
                            } else {
                                [string]$reader['processing_started_at']
                            }

                            $processedAt = if (
                                $reader['processed_at'] -is [System.DBNull]
                            ) {
                                $null
                            } else {
                                [string]$reader['processed_at']
                            }

                            $processingError = if (
                                $reader['processing_error'] -is [System.DBNull]
                            ) {
                                $null
                            } else {
                                [string]$reader['processing_error']
                            }

                            [pscustomobject]@{
                                ProcessingStatus    = [string]$reader['processing_status']
                                ProcessingStartedAt = $startedAt
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

            function Set-TestProcessingStartedAt {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Chave,

                    [Parameter()]
                    [AllowNull()]
                    [object]$ProcessingStartedAt
                )

                $databasePath = Get-StorePath -Scope 'Index' -Cnpj $Script:TestCnpj

                $connection   = Open-SqliteConnection -Path $databasePath

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = @'
UPDATE dfe_document
SET
    processing_status = 'Processing',
    processing_started_at = @processing_started_at,
    processed_at = NULL,
    processing_error = NULL
WHERE chave_acesso = @chave;
'@

                        $startedAtParam = $command.Parameters.Add(
                            '@processing_started_at',
                            [System.Data.DbType]::String
                        )

                        if ($null -eq $ProcessingStartedAt) {
                            $startedAtParam.Value = [System.DBNull]::Value
                        } else {
                            $startedAtParam.Value = [string]$ProcessingStartedAt
                        }

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

        #region Matching Processing
        Context 'Matching Processing attempt' {

            BeforeEach {

                $Script:Chave = New-TestChave

                Add-TestDocument -Chave $Script:Chave

                $processingStateParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $Script:Chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @processingStateParams

                $Script:Before = Get-TestDocument -Chave $Script:Chave
            }

            It 'Marks the observed Processing attempt as Failed' {
                $repairParams = @{
                    Cnpj                        = $Script:TestCnpj
                    ChaveAcesso                 = $Script:Chave
                    ExpectedProcessingStartedAt = $Script:Before.ProcessingStartedAt
                    ErrorMessage                = 'Abandoned processing attempt.'
                }

                Repair-DFeDocumentProcessingState @repairParams

                $after = Get-TestDocument -Chave $Script:Chave

                $after.ProcessingStatus | Should -Be 'Failed'
            }

            It 'Preserves processing_started_at' {
                $repairParams = @{
                    Cnpj                        = $Script:TestCnpj
                    ChaveAcesso                 = $Script:Chave
                    ExpectedProcessingStartedAt = $Script:Before.ProcessingStartedAt
                    ErrorMessage                = 'Abandoned processing attempt.'
                }

                Repair-DFeDocumentProcessingState @repairParams

                $after = Get-TestDocument -Chave $Script:Chave

                $after.ProcessingStartedAt | Should -Be $Script:Before.ProcessingStartedAt
            }

            It 'Persists the recovery error' {
                $repairParams = @{
                    Cnpj                        = $Script:TestCnpj
                    ChaveAcesso                 = $Script:Chave
                    ExpectedProcessingStartedAt = $Script:Before.ProcessingStartedAt
                    ErrorMessage                = 'Abandoned processing attempt.'
                }

                Repair-DFeDocumentProcessingState @repairParams

                $after = Get-TestDocument -Chave $Script:Chave

                $after.ProcessingError | Should -Be 'Abandoned processing attempt.'
            }
        }
        #endregion

        #region Null processing_started_at
        Context 'Null processing_started_at' {

            It 'Repairs the Processing attempt only when null was observed' {
                $chave = New-TestChave

                Add-TestDocument -Chave $chave
                Set-TestProcessingStartedAt -Chave $chave -ProcessingStartedAt $null

                $repairParams = @{
                    Cnpj                        = $Script:TestCnpj
                    ChaveAcesso                 = $chave
                    ExpectedProcessingStartedAt = $null
                    ErrorMessage                = 'Missing processing timestamp.'
                }

                Repair-DFeDocumentProcessingState @repairParams

                $after = Get-TestDocument -Chave $chave

                $after.ProcessingStatus    | Should -Be 'Failed'
                $after.ProcessingStartedAt | Should -BeNullOrEmpty
                $after.ProcessingError     | Should -Be 'Missing processing timestamp.'
            }
        }
        #endregion

        #region Changed Processing
        Context 'Changed Processing attempt' {

            It 'Rejects a different processing_started_at value' {
                $chave = New-TestChave

                Add-TestDocument -Chave $chave

                $observed = '2026-10-09T10:00:00.0000000+00:00'

                $current  = '2026-10-09T11:00:00.0000000+00:00'

                Set-TestProcessingStartedAt -Chave $chave -ProcessingStartedAt $current

                $repairParams = @{
                    Cnpj                        = $Script:TestCnpj
                    ChaveAcesso                 = $chave
                    ExpectedProcessingStartedAt = $observed
                    ErrorMessage                = 'Must not be persisted.'
                }

                { Repair-DFeDocumentProcessingState @repairParams } |
                    Should -Throw -ErrorId 'ConcurrentProcessingStateChange*'

                $after = Get-TestDocument -Chave $chave

                $after.ProcessingStatus    | Should -Be 'Processing'
                $after.ProcessingStartedAt | Should -Be $current
                $after.ProcessingError     | Should -BeNullOrEmpty
            }

            It 'Rejects a non-null value when null was observed' {
                $chave = New-TestChave

                Add-TestDocument -Chave $chave

                $current = '2026-10-09T11:00:00.0000000+00:00'

                Set-TestProcessingStartedAt -Chave $chave -ProcessingStartedAt $current

                $repairParams = @{
                    Cnpj                        = $Script:TestCnpj
                    ChaveAcesso                 = $chave
                    ExpectedProcessingStartedAt = $null
                    ErrorMessage                = 'Must not be persisted.'
                }

                { Repair-DFeDocumentProcessingState @repairParams } |
                    Should -Throw -ErrorId 'ConcurrentProcessingStateChange*'

                $after = Get-TestDocument -Chave $chave

                $after.ProcessingStatus    | Should -Be 'Processing'
                $after.ProcessingStartedAt | Should -Be $current
            }
        }
        #endregion

        #region ABA Processing
        Context 'ABA Processing attempt' {
            It 'Does not fail a newer Processing retry' {
                $chave = New-TestChave

                Add-TestDocument -Chave $chave

                $initial = Get-TestDocument -Chave $chave

                $initial.ProcessingStatus | Should -Be 'Indexed'

                $processingParams = @{
                    Cnpj        = $Script:TestCnpj
                    ChaveAcesso = $chave
                    Status      = 'Processing'
                }

                Set-DFeDocumentProcessingState @processingParams

                $firstAttempt = Get-TestDocument -Chave $chave

                $firstAttempt.ProcessingStatus | Should -Be 'Processing'

                $failedParams = @{
                    Cnpj         = $Script:TestCnpj
                    ChaveAcesso  = $chave
                    Status       = 'Failed'
                    ErrorMessage = 'First attempt failed.'
                }

                Set-DFeDocumentProcessingState @failedParams

                $failedAttempt = Get-TestDocument -Chave $chave

                $failedAttempt.ProcessingStatus | Should -Be 'Failed'

                Start-Sleep -Milliseconds 10

                Set-DFeDocumentProcessingState @processingParams

                $retryAttempt = Get-TestDocument -Chave $chave

                $retryAttempt.ProcessingStatus | Should -Be 'Processing'

                $retryAttempt.ProcessingStartedAt |
                    Should -Not -Be $firstAttempt.ProcessingStartedAt

                $repairParams = @{
                    Cnpj                        = $Script:TestCnpj
                    ChaveAcesso                 = $chave
                    ExpectedProcessingStartedAt = $firstAttempt.ProcessingStartedAt
                    ErrorMessage                = 'Stale recovery must not win.'
                }

                { Repair-DFeDocumentProcessingState @repairParams } |
                    Should -Throw -ErrorId 'ConcurrentProcessingStateChange*'

                $after = Get-TestDocument -Chave $chave

                $after.ProcessingStatus    | Should -Be 'Processing'
                $after.ProcessingStartedAt | Should -Be $retryAttempt.ProcessingStartedAt
                $after.ProcessingError     | Should -BeNullOrEmpty
            }
        }
        #endregion
    }
}
