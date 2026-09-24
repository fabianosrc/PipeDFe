#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Invoke-DFeDocumentProcessing.

.DESCRIPTION
Verifies orchestration of one indexed NF-e/NFC-e document using mocked
dependencies.

Coverage includes:

- Parameter contract.
- Entry contract validation.
- Only NF-e and NFC-e models are accepted.
- Invalid entries are rejected before persistent state changes.
- Processing state is acquired before source access.
- Source SHA-256 must match the indexed SHA-256.
- XML is loaded from the indexed file path.
- Fiscal data is extracted from the loaded XML.
- Extracted access key must match the indexed access key.
- Extracted model must match the indexed model.
- Source SHA-256 is verified again after parsing.
- Source changes during processing are detected.
- Fiscal data is persisted with the verified source hash.
- Successful processing transitions Processing -> Processed.
- Failures after Processing are persisted as Failed.
- The original processing error is preserved.
- Failure to persist Failed does not replace the original error.
- Failure to acquire Processing does not attempt a Failed transition.
- Unsupported models never enter the processing state machine.
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

Describe 'Invoke-DFeDocumentProcessing' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $getCommandParams = @{
                Name        = 'Invoke-DFeDocumentProcessing'
                ErrorAction = 'Stop'
            }

            $Script:Command = Get-Command @getCommandParams

            $Script:Cnpj = '12345678000199'

            $Script:ChaveAcesso = '35260912345678000199550010000000011234567890'

            $Script:OtherChaveAcesso = '35260912345678000199550010000000021234567891'

            $Script:SourcePath = 'C:\xml\nfe.xml'

            $Script:SourceHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

            $Script:ChangedHash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

            function New-TestEntry {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter()]
                    [string]$ChaveAcesso = $Script:ChaveAcesso,

                    [Parameter()]
                    [int]$Modelo = 55,

                    [Parameter()]
                    [string]$FilePath = $Script:SourcePath,

                    [Parameter()]
                    [string]$Sha256 = $Script:SourceHash
                )

                [pscustomobject]@{
                    chave_acesso = $ChaveAcesso
                    modelo       = $Modelo
                    file_path    = $FilePath
                    sha256       = $Sha256
                }
            }

            function New-TestFiscalData {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter()]
                    [string]$ChaveAcesso = $Script:ChaveAcesso,

                    [Parameter()]
                    [int]$Modelo = 55
                )

                [pscustomobject]@{
                    ChaveAcesso = $ChaveAcesso
                    Modelo      = [ModeloDFe]$Modelo
                }
            }
        }

        BeforeEach {

            $Script:Entry      = New-TestEntry
            $Script:FiscalData = New-TestFiscalData

            $Script:Xml = [System.Xml.XmlDocument]::new()
            $Script:Xml.LoadXml('<NFe />')

            $Script:HashCallCount = 0

            Mock -CommandName Set-DFeDocumentProcessingState -MockWith {
                param (
                    [string]$Cnpj,
                    [string]$ChaveAcesso,
                    [string]$Status,
                    [string]$ErrorMessage
                )

                $null = $Cnpj
                $null = $ChaveAcesso
                $null = $Status
                $null = $ErrorMessage
            }

            Mock -CommandName Get-FileSha256 -MockWith {
                param ([string]$Path)

                $null = $Path
                $Script:HashCallCount++

                return $Script:SourceHash
            }

            Mock -CommandName Import-DFeXml -MockWith {
                param ([string]$Path)

                $null = $Path

                return $Script:Xml
            }

            Mock -CommandName Get-DFeNFeFiscalData -MockWith {
                param ([System.Xml.XmlDocument]$Xml)

                $null = $Xml

                return $Script:FiscalData
            }

            Mock -CommandName Save-DFeNFeFiscalData -MockWith {
                param (
                    [string]$Cnpj,
                    [pscustomobject]$FiscalData,
                    [string]$SourceSha256
                )

                $null = $Cnpj
                $null = $FiscalData
                $null = $SourceSha256
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Cnpj as mandatory' {
                $mandatory = $Script:Command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Cnpj as string' {
                $Script:Command.Parameters['Cnpj'].ParameterType |
                    Should -Be ([string])
            }

            It 'Validates the Cnpj pattern' {
                $attribute = $Script:Command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ValidatePatternAttribute]
                    }

                $attribute.RegexPattern |
                    Should -Be '^(?-i)[A-Z0-9]{14}$'
            }

            It 'Declares Entry as mandatory' {
                $mandatory = $Script:Command.Parameters['Entry'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Entry as PSCustomObject' {
                $Script:Command.Parameters['Entry'].ParameterType |
                    Should -Be ([pscustomobject])
            }

            It 'Accepts Entry from the pipeline' {
                $attribute = $Script:Command.Parameters['Entry'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    }

                $attribute.ValueFromPipeline |
                    Should -BeTrue
            }
        }
        #endregion

        #region Entry validation
        Context 'Entry validation' {

            It 'Rejects an entry missing chave_acesso' {
                $entry = [pscustomobject]@{
                    modelo    = 55
                    file_path = $Script:SourcePath
                    sha256    = $Script:SourceHash
                }

                $exception = $null

                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $exception = $_
                }

                $exception.FullyQualifiedErrorId |
                    Should -BeLike 'InvalidDocumentProcessingEntry*'

                $invokeParams = @{
                    CommandName = 'Set-DFeDocumentProcessingState'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Rejects an entry missing modelo' {
                $entry = [pscustomobject]@{
                    chave_acesso = $Script:ChaveAcesso
                    file_path    = $Script:SourcePath
                    sha256       = $Script:SourceHash
                }

                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $entry
                    ErrorAction = 'Stop'
                }

                { Invoke-DFeDocumentProcessing @invokeParams } |
                    Should -Throw -ErrorId 'InvalidDocumentProcessingEntry*'

                $shouldParams = @{
                    CommandName = 'Set-DFeDocumentProcessingState'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Rejects an entry missing file_path' {
                $entry = [pscustomobject]@{
                    chave_acesso = $Script:ChaveAcesso
                    modelo       = 55
                    sha256       = $Script:SourceHash
                }

                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $entry
                    ErrorAction = 'Stop'
                }

                { Invoke-DFeDocumentProcessing @invokeParams } |
                    Should -Throw -ErrorId 'InvalidDocumentProcessingEntry*'

                $shouldParams = @{
                    CommandName = 'Set-DFeDocumentProcessingState'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Rejects an entry missing sha256' {
                $entry = [pscustomobject]@{
                    chave_acesso = $Script:ChaveAcesso
                    modelo       = 55
                    file_path    = $Script:SourcePath
                }

                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $entry
                    ErrorAction = 'Stop'
                }

                { Invoke-DFeDocumentProcessing @invokeParams } |
                    Should -Throw -ErrorId 'InvalidDocumentProcessingEntry*'

                $shouldParams = @{
                    CommandName = 'Set-DFeDocumentProcessingState'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Rejects an invalid access key before changing state' {
                $entry = New-TestEntry -ChaveAcesso '123'

                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $entry
                    ErrorAction = 'Stop'
                }

                { Invoke-DFeDocumentProcessing @invokeParams } |
                    Should -Throw -ErrorId 'InvalidDocumentProcessingAccessKey*'

                $shouldParams = @{
                    CommandName = 'Set-DFeDocumentProcessingState'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Rejects an empty file path before changing state' {
                $entry = New-TestEntry -FilePath ([string]::Empty)

                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $entry
                    ErrorAction = 'Stop'
                }

                { Invoke-DFeDocumentProcessing @invokeParams } |
                    Should -Throw -ErrorId 'InvalidDocumentProcessingPath*'

                $shouldParams = @{
                    CommandName = 'Set-DFeDocumentProcessingState'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Rejects an invalid SHA-256 before changing state' {
                $entry = New-TestEntry -Sha256 'not-a-hash'

                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $entry
                    ErrorAction = 'Stop'
                }

                { Invoke-DFeDocumentProcessing @invokeParams } |
                    Should -Throw -ErrorId 'InvalidDocumentProcessingHash*'

                $shouldParams = @{
                    CommandName = 'Set-DFeDocumentProcessingState'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Supported models
        Context 'Supported models' {

            It 'Processes NF-e model 55' {
                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = (New-TestEntry -Modelo 55)
                    ErrorAction = 'Stop'
                }

                { Invoke-DFeDocumentProcessing @invokeParams } |
                    Should -Not -Throw
            }

            It 'Processes NFC-e model 65' {
                $Script:FiscalData = New-TestFiscalData -Modelo 65

                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = (New-TestEntry -Modelo 65)
                    ErrorAction = 'Stop'
                }

                { Invoke-DFeDocumentProcessing @invokeParams } |
                    Should -Not -Throw
            }

            It 'Rejects an unsupported model before changing state' {
                $entry = New-TestEntry -Modelo 57

                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $entry
                    ErrorAction = 'Stop'
                }

                { Invoke-DFeDocumentProcessing @invokeParams } |
                    Should -Throw -ErrorId 'UnsupportedDocumentProcessingModel*'

                $shouldParams = @{
                    CommandName = 'Set-DFeDocumentProcessingState'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams

                $shouldParams = @{
                    CommandName = 'Get-FileSha256'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Successful processing
        Context 'Successful processing' {

            It 'Enters Processing before performing fiscal work' {
                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $Script:Entry
                    ErrorAction = 'Stop'
                }

                Invoke-DFeDocumentProcessing @invokeParams

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj -eq $Script:Cnpj -and
                        $ChaveAcesso -eq $Script:ChaveAcesso -and
                        $Status -eq 'Processing'
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Hashes the indexed source twice' {
                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $Script:Entry
                    ErrorAction = 'Stop'
                }

                Invoke-DFeDocumentProcessing @invokeParams

                $shouldParams = @{
                    CommandName     = 'Get-FileSha256'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 2
                    ParameterFilter = {
                        $Path -eq $Script:SourcePath
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Loads the XML from the indexed file path' {
                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $Script:Entry
                    ErrorAction = 'Stop'
                }

                Invoke-DFeDocumentProcessing @invokeParams

                $shouldParams = @{
                    CommandName     = 'Import-DFeXml'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Path -eq $Script:SourcePath
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Extracts fiscal data from the loaded XML' {
                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $Script:Entry
                    ErrorAction = 'Stop'
                }

                Invoke-DFeDocumentProcessing @invokeParams

                $shouldParams = @{
                    CommandName     = 'Get-DFeNFeFiscalData'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Xml -eq $Script:Xml
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Persists the extracted fiscal data with the verified hash' {
                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $Script:Entry
                    ErrorAction = 'Stop'
                }

                Invoke-DFeDocumentProcessing @invokeParams

                $shouldParams = @{
                    CommandName     = 'Save-DFeNFeFiscalData'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj -eq $Script:Cnpj -and
                        $FiscalData -eq $Script:FiscalData -and
                        $SourceSha256 -eq $Script:SourceHash
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Marks the document Processed after persistence' {
                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $Script:Entry
                    ErrorAction = 'Stop'
                }

                Invoke-DFeDocumentProcessing @invokeParams

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj -eq $Script:Cnpj -and
                        $ChaveAcesso -eq $Script:ChaveAcesso -and
                        $Status -eq 'Processed'
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Does not mark the document Failed on success' {
                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $Script:Entry
                    ErrorAction = 'Stop'
                }

                Invoke-DFeDocumentProcessing @invokeParams

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 0
                    ParameterFilter = {
                        $Status -eq 'Failed'
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Produces no output on success' {
                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $Script:Entry
                    ErrorAction = 'Stop'
                }

                $result = @(Invoke-DFeDocumentProcessing @invokeParams)

                $result | Should -HaveCount 0
            }
        }
        #endregion

        #region Processing state acquisition
        Context 'Processing state acquisition' {

            BeforeEach {
                Mock -CommandName Set-DFeDocumentProcessingState -MockWith {
                    param (
                        [string]$Cnpj,
                        [string]$ChaveAcesso,
                        [string]$Status,
                        [string]$ErrorMessage
                    )

                    $null = $Cnpj
                    $null = $ChaveAcesso
                    $null = $ErrorMessage

                    if ($Status -eq 'Processing') {
                        throw [System.InvalidOperationException]::new(
                            'Unable to acquire Processing state.'
                        )
                    }
                }
            }

            It 'Preserves a failure to acquire Processing' {
                $exception = $null

                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $exception = $_
                }

                $exception.Exception.Message |
                    Should -Be 'Unable to acquire Processing state.'
            }

            It 'Does not access the source when Processing cannot be acquired' {
                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName = 'Get-FileSha256'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Does not attempt Failed when Processing cannot be acquired' {
                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 0
                    ParameterFilter = {
                        $Status -eq 'Failed'
                    }
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Initial source integrity
        Context 'Initial source integrity' {

            BeforeEach {
                Mock -CommandName Get-FileSha256 -MockWith {
                    return $Script:ChangedHash
                }
            }

            It 'Throws DocumentSourceHashMismatch when source hash differs from the index' {
                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $Script:Entry
                    ErrorAction = 'Stop'
                }

                { Invoke-DFeDocumentProcessing @invokeParams } |
                    Should -Throw -ErrorId 'DocumentSourceHashMismatch*'
            }

            It 'Does not parse a source whose hash differs from the index' {
                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName = 'Import-DFeXml'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Marks the document Failed when the initial source hash differs' {
                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Status -eq 'Failed' -and
                        $ErrorMessage -like '*DocumentSourceHashMismatch*'
                    }
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region XML loading failure
        Context 'XML loading failure' {

            BeforeEach {
                Mock -CommandName Import-DFeXml -MockWith {
                    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                        [System.Xml.XmlException]::new('Malformed XML.'),
                        'InvalidXml',
                        [System.Management.Automation.ErrorCategory]::InvalidData,
                        $Script:SourcePath
                    )

                    throw $errorRecord
                }
            }

            It 'Preserves the XML loading error' {
                $exception = $null

                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $exception = $_
                }

                $exception.FullyQualifiedErrorId |
                    Should -BeLike 'InvalidXml*'
            }

            It 'Marks the document Failed with the XML loading error' {
                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Status -eq 'Failed' -and
                        $ErrorMessage -like '*InvalidXml*'
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Does not persist fiscal data after XML loading fails' {
                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName = 'Save-DFeNFeFiscalData'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Fiscal extraction failure
        Context 'Fiscal extraction failure' {

            BeforeEach {
                Mock -CommandName Get-DFeNFeFiscalData -MockWith {
                    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new(
                            'Fiscal extraction failed.'
                        ),
                        'FiscalExtractionFailed',
                        [System.Management.Automation.ErrorCategory]::InvalidData,
                        $Script:Xml
                    )

                    throw $errorRecord
                }
            }

            It 'Preserves the fiscal extraction error' {
                $exception = $null

                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $exception = $_
                }

                $exception.FullyQualifiedErrorId |
                    Should -BeLike 'FiscalExtractionFailed*'
            }

            It 'Marks the document Failed after fiscal extraction fails' {
                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Status -eq 'Failed' -and
                        $ErrorMessage -like '*FiscalExtractionFailed*'
                    }
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Source identity
        Context 'Source identity' {

            It 'Rejects fiscal data with a different access key' {
                $Script:FiscalData = New-TestFiscalData -ChaveAcesso $Script:OtherChaveAcesso

                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $Script:Entry
                    ErrorAction = 'Stop'
                }

                { Invoke-DFeDocumentProcessing @invokeParams } |
                    Should -Throw -ErrorId 'DocumentSourceAccessKeyMismatch*'
            }

            It 'Marks the document Failed when the XML access key differs' {
                $Script:FiscalData = New-TestFiscalData -ChaveAcesso $Script:OtherChaveAcesso

                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Status -eq 'Failed' -and
                        $ErrorMessage -like '*DocumentSourceAccessKeyMismatch*'
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Rejects fiscal data with a different model' {
                $Script:FiscalData = New-TestFiscalData -Modelo 65

                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $Script:Entry
                    ErrorAction = 'Stop'
                }

                { Invoke-DFeDocumentProcessing @invokeParams } |
                    Should -Throw -ErrorId 'DocumentSourceModelMismatch*'
            }

            It 'Does not persist fiscal data after identity mismatch' {
                $Script:FiscalData = New-TestFiscalData -ChaveAcesso $Script:OtherChaveAcesso

                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName = 'Save-DFeNFeFiscalData'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Source stability
        Context 'Source stability' {

            BeforeEach {
                $Script:HashCallCount = 0

                Mock -CommandName Get-FileSha256 -MockWith {
                    $Script:HashCallCount++

                    if ($Script:HashCallCount -eq 1) {
                        return $Script:SourceHash
                    }

                    return $Script:ChangedHash
                }
            }

            It 'Throws when the source changes during processing' {
                $invokeParams = @{
                    Cnpj        = $Script:Cnpj
                    Entry       = $Script:Entry
                    ErrorAction = 'Stop'
                }

                { Invoke-DFeDocumentProcessing @invokeParams } |
                    Should -Throw -ErrorId 'DocumentSourceChangedDuringProcessing*'
            }

            It 'Does not persist fiscal data when the source changes during processing' {
                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName = 'Save-DFeNFeFiscalData'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Marks the document Failed when the source changes during processing' {
                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Status -eq 'Failed' -and
                        $ErrorMessage -like '*DocumentSourceChangedDuringProcessing*'
                    }
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Fiscal persistence failure
        Context 'Fiscal persistence failure' {

            BeforeEach {
                Mock -CommandName Save-DFeNFeFiscalData -MockWith {
                    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new(
                            'Fiscal persistence failed.'
                        ),
                        'NFeFiscalDataPersistenceFailed',
                        [System.Management.Automation.ErrorCategory]::WriteError,
                        $Script:ChaveAcesso
                    )

                    throw $errorRecord
                }
            }

            It 'Preserves the fiscal persistence error' {
                $exception = $null

                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $exception = $_
                }

                $exception.FullyQualifiedErrorId |
                    Should -BeLike 'NFeFiscalDataPersistenceFailed*'
            }

            It 'Marks the document Failed when fiscal persistence fails' {
                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Status -eq 'Failed' -and
                        $ErrorMessage -like '*NFeFiscalDataPersistenceFailed*'
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Does not mark the document Processed after persistence fails' {
                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 0
                    ParameterFilter = {
                        $Status -eq 'Processed'
                    }
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Processed transition failure
        Context 'Processed transition failure' {

            BeforeEach {

                Mock -CommandName Set-DFeDocumentProcessingState -MockWith {
                    param (
                        [string]$Cnpj,
                        [string]$ChaveAcesso,
                        [string]$Status,
                        [string]$ErrorMessage
                    )

                    $null = $Cnpj
                    $null = $ChaveAcesso
                    $null = $ErrorMessage

                    if ($Status -eq 'Processed') {
                        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                            [System.InvalidOperationException]::new(
                                'Unable to persist Processed state.'
                            ),
                            'DocumentProcessingStateUpdateFailed',
                            [System.Management.Automation.ErrorCategory]::WriteError,
                            $Script:ChaveAcesso
                        )

                        throw $errorRecord
                    }
                }
            }

            It 'Preserves the Processed transition error' {
                $exception = $null

                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $exception = $_
                }

                $exception.FullyQualifiedErrorId |
                    Should -BeLike 'DocumentProcessingStateUpdateFailed*'
            }

            It 'Attempts to move the document to Failed' {
                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Status -eq 'Failed'
                    }
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Failed state persistence
        Context 'Failed state persistence' {

            BeforeEach {

                Mock -CommandName Save-DFeNFeFiscalData -MockWith {
                    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new(
                            'Original processing failure.'
                        ),
                        'OriginalProcessingFailure',
                        [System.Management.Automation.ErrorCategory]::WriteError,
                        $Script:ChaveAcesso
                    )

                    throw $errorRecord
                }

                Mock -CommandName Set-DFeDocumentProcessingState -MockWith {
                    param (
                        [string]$Cnpj,
                        [string]$ChaveAcesso,
                        [string]$Status,
                        [string]$ErrorMessage
                    )

                    $null = $Cnpj
                    $null = $ChaveAcesso
                    $null = $ErrorMessage

                    if ($Status -eq 'Failed') {
                        throw [System.InvalidOperationException]::new(
                            'Unable to persist Failed state.'
                        )
                    }
                }

                Mock -CommandName Write-Warning
            }

            It 'Preserves the original processing error when Failed cannot be persisted' {
                $exception = $null

                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $exception = $_
                }

                $exception.FullyQualifiedErrorId |
                    Should -BeLike 'OriginalProcessingFailure*'

                $exception.Exception.Message |
                    Should -Be 'Original processing failure.'
            }

            It 'Writes a warning when Failed cannot be persisted' {
                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName = 'Write-Warning'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }

            It 'Does not replace the original exception with the Failed transition exception' {
                $exception = $null

                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $exception = $_
                }

                $exception.Exception.Message |
                    Should -Not -Be 'Unable to persist Failed state.'
            }
        }
        #endregion

        #region Failure summary
        Context 'Failure summary' {

            BeforeEach {

                $Script:LongMessage = 'X' * 6000

                Mock -CommandName Save-DFeNFeFiscalData -MockWith {
                    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new(
                            $Script:LongMessage
                        ),
                        'LongProcessingFailure',
                        [System.Management.Automation.ErrorCategory]::WriteError,
                        $Script:ChaveAcesso
                    )

                    throw $errorRecord
                }
            }

            It 'Limits the persisted processing error summary to 4000 characters' {
                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Status -eq 'Failed' -and
                        $ErrorMessage.Length -eq 4000
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Includes the original ErrorId in the persisted failure summary' {
                try {
                    $invokeParams = @{
                        Cnpj        = $Script:Cnpj
                        Entry       = $Script:Entry
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeDocumentProcessing @invokeParams
                } catch {
                    $null = $_
                }

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Status -eq 'Failed' -and
                        $ErrorMessage -like '`[LongProcessingFailure*'
                    }
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Pipeline input
        Context 'Pipeline input' {

            It 'Processes an entry received from the pipeline' {
                {
                    $pipelineParams = @{
                        Cnpj        = $Script:Cnpj
                        ErrorAction = 'Stop'
                    }

                    $Script:Entry | Invoke-DFeDocumentProcessing @pipelineParams
                } | Should -Not -Throw

                $shouldParams = @{
                    CommandName = 'Save-DFeNFeFiscalData'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion
    }
}
