#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Assert-DFeArchiveSource.

.DESCRIPTION
Verifies integrity validation of DFe archive source files.

Coverage includes:
  - Parameter contract.
  - Throws ArchiveSourceNotFound when source file does not exist.
  - Throws ArchiveSourceHashMissing when indexed hash is null.
  - Throws ArchiveSourceHashMissing when indexed hash is empty.
  - Throws ArchiveSourceHashMissing when indexed hash is whitespace.
  - Throws ArchiveSourceHashMismatch when current hash differs from indexed.
  - Returns no output when all checks pass.
  - Hash comparison is case-insensitive.
  - SourceKind label appears in error messages.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingEmptyCatchBlock',
    '',
    Justification = 'Intentionally ignored to verify downstream behavior.'
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

Describe 'Assert-DFeArchiveSource' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command  = Get-Command -Name Assert-DFeArchiveSource -ErrorAction Stop
            $Script:FakeHash = 'a' * 64
            $Script:FakePath = 'C:\XMLs\NFe\35260912345678000199550010000000011234567890.xml'
            $Script:FakeId   = '35260912345678000199550010000000011234567890'
        }

        AfterAll {

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }

        BeforeEach {

            Mock -CommandName Test-Path -MockWith {
                $true
            }

            Mock -CommandName Get-FileSha256 -MockWith {
                $Script:FakeHash
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares SourcePath as mandatory' {
                $mandatory = $Script:Command.Parameters['SourcePath'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares IndexedHash as mandatory' {
                $mandatory = $Script:Command.Parameters['IndexedHash'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares SourceKind as mandatory' {
                $mandatory = $Script:Command.Parameters['SourceKind'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Restricts SourceKind to document and event' {
                $validateSet = $Script:Command.Parameters['SourceKind'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ValidateSetAttribute]
                    }

                $validateSet.ValidValues | Should -Be @('document', 'event')
            }

            It 'Declares SourceId as mandatory' {
                $mandatory = $Script:Command.Parameters['SourceId'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Rejects invalid SourceKind' {
                $assertParams = @{
                    SourcePath  = $Script:FakePath
                    IndexedHash = $Script:FakeHash
                    SourceKind  = 'archive'
                    SourceId    = $Script:FakeId
                    ErrorAction = 'Stop'
                }

                { Assert-DFeArchiveSource @assertParams } | Should -Throw
            }
        }
        #endregion

        #region Source file not found
        Context 'Source file not found' {

            BeforeEach {

                Mock -CommandName Test-Path -MockWith {
                    $false
                }
            }

            It 'Throws ArchiveSourceNotFound for a document' {
                $assertParams = @{
                    SourcePath  = $Script:FakePath
                    IndexedHash = $Script:FakeHash
                    SourceKind  = 'document'
                    SourceId    = $Script:FakeId
                    ErrorAction = 'Stop'
                }

                { Assert-DFeArchiveSource @assertParams } |
                    Should -Throw -ErrorId 'ArchiveSourceNotFound*'
            }

            It 'Throws ArchiveSourceNotFound for an event' {
                $assertParams = @{
                    SourcePath  = $Script:FakePath
                    IndexedHash = $Script:FakeHash
                    SourceKind  = 'event'
                    SourceId    = $Script:FakeId
                    ErrorAction = 'Stop'
                }

                { Assert-DFeArchiveSource @assertParams } |
                    Should -Throw -ErrorId 'ArchiveSourceNotFound*'
            }

            It 'Does not compute hash when file is missing' {
                $assertParams = @{
                    SourcePath  = $Script:FakePath
                    IndexedHash = $Script:FakeHash
                    SourceKind  = 'document'
                    SourceId    = $Script:FakeId
                    ErrorAction = 'Stop'
                }

                try {
                    Assert-DFeArchiveSource @assertParams
                } catch {

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
        }
        #endregion

        #region Missing indexed hash
        Context 'Missing indexed hash' {

            It 'Throws ArchiveSourceHashMissing when IndexedHash is null' {
                $assertParams = @{
                    SourcePath  = $Script:FakePath
                    IndexedHash = $null
                    SourceKind  = 'document'
                    SourceId    = $Script:FakeId
                    ErrorAction = 'Stop'
                }

                { Assert-DFeArchiveSource @assertParams } |
                    Should -Throw -ErrorId 'ArchiveSourceHashMissing*'
            }

            It 'Throws ArchiveSourceHashMissing when IndexedHash is empty' {
                $assertParams = @{
                    SourcePath  = $Script:FakePath
                    IndexedHash = [string]::Empty
                    SourceKind  = 'document'
                    SourceId    = $Script:FakeId
                    ErrorAction = 'Stop'
                }

                { Assert-DFeArchiveSource @assertParams } |
                    Should -Throw -ErrorId 'ArchiveSourceHashMissing*'
            }

            It 'Throws ArchiveSourceHashMissing when IndexedHash is whitespace' {
                $assertParams = @{
                    SourcePath  = $Script:FakePath
                    IndexedHash = '   '
                    SourceKind  = 'document'
                    SourceId    = $Script:FakeId
                    ErrorAction = 'Stop'
                }

                { Assert-DFeArchiveSource @assertParams } |
                    Should -Throw -ErrorId 'ArchiveSourceHashMissing*'
            }

            It 'Does not compute hash when indexed hash is missing' {
                $assertParams = @{
                    SourcePath  = $Script:FakePath
                    IndexedHash = $null
                    SourceKind  = 'document'
                    SourceId    = $Script:FakeId
                    ErrorAction = 'Stop'
                }

                try {
                    Assert-DFeArchiveSource @assertParams
                } catch {

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
        }
        #endregion

        #region Hash mismatch
        Context 'Hash mismatch' {

            BeforeEach {
                Mock -CommandName Get-FileSha256 -MockWith {
                    'b' * 64
                }
            }

            It 'Throws ArchiveSourceHashMismatch when current hash differs from indexed' {
                $assertParams = @{
                    SourcePath  = $Script:FakePath
                    IndexedHash = $Script:FakeHash
                    SourceKind  = 'document'
                    SourceId    = $Script:FakeId
                    ErrorAction = 'Stop'
                }

                { Assert-DFeArchiveSource @assertParams } |
                    Should -Throw -ErrorId 'ArchiveSourceHashMismatch*'
            }
        }
        #endregion

        #region Hash comparison
        Context 'Hash comparison' {

            It 'Accepts an indexed hash in uppercase when current hash is lowercase' {
                Mock -CommandName Get-FileSha256 -MockWith { 'abcdef' * 10 + 'abcd' }

                $assertParams = @{
                    SourcePath  = $Script:FakePath
                    IndexedHash = 'ABCDEF' * 10 + 'ABCD'
                    SourceKind  = 'document'
                    SourceId    = $Script:FakeId
                    ErrorAction = 'Stop'
                }

                { Assert-DFeArchiveSource @assertParams } | Should -Not -Throw
            }
        }
        #endregion

        #region Happy path
        Context 'Happy path' {

            It 'Returns no output when all checks pass' {
                $assertParams = @{
                    SourcePath  = $Script:FakePath
                    IndexedHash = $Script:FakeHash
                    SourceKind  = 'document'
                    SourceId    = $Script:FakeId
                }

                $result = @(Assert-DFeArchiveSource @assertParams)

                $result | Should -HaveCount 0
            }

            It 'Computes hash exactly once' {
                $assertParams = @{
                    SourcePath  = $Script:FakePath
                    IndexedHash = $Script:FakeHash
                    SourceKind  = 'document'
                    SourceId    = $Script:FakeId
                }

                Assert-DFeArchiveSource @assertParams

                $shouldParams = @{
                    CommandName = 'Get-FileSha256'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region SourceKind in error messages
        Context 'SourceKind label in error messages' {

            BeforeEach {

                Mock -CommandName Test-Path -MockWith {
                    $false
                }
            }

            It 'Includes "document" in the error message for SourceKind document' {
                $assertParams = @{
                    SourcePath  = $Script:FakePath
                    IndexedHash = $Script:FakeHash
                    SourceKind  = 'document'
                    SourceId    = $Script:FakeId
                    ErrorAction = 'Stop'
                }

                $thrown = $null

                try {
                    Assert-DFeArchiveSource @assertParams
                } catch {
                    $thrown = $_
                }

                $thrown.Exception.Message | Should -BeLike '*document*'
            }

            It 'Includes "event" in the error message for SourceKind event' {
                $assertParams = @{
                    SourcePath  = $Script:FakePath
                    IndexedHash = $Script:FakeHash
                    SourceKind  = 'event'
                    SourceId    = $Script:FakeId
                    ErrorAction = 'Stop'
                }

                $thrown = $null

                try {
                    Assert-DFeArchiveSource @assertParams
                } catch {
                    $thrown = $_
                }

                $thrown.Exception.Message | Should -BeLike '*event*'
            }
        }
        #endregion
    }
}
