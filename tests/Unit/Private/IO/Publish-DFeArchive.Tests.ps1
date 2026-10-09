#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Publish-DFeArchive.

.DESCRIPTION
Verifies atomic publication of validated DFe archives.

Coverage includes:
  - Parameter contract.
  - Rejects invalid SHA-256 values.
  - Creates the destination directory when absent.
  - Wraps staging copy failures as ArchiveStageCopyFailed.
  - Validates the staged SHA-256.
  - Throws ArchiveStageHashMismatch when the staged hash differs.
  - Compares SHA-256 values case-insensitively.
  - Publishes with File.Move when the destination does not exist.
  - Publishes with File.Replace when the destination already exists.
  - Preserves an existing destination when validation fails.
  - Wraps final publication failures as ArchivePublishFailed.
  - Cleans staging files after validation and publication failures.
  - Leaves the source archive unchanged after publication.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingEmptyCatchBlock',
    '',
    Justification = 'Exceptions are intentionally ignored to verify post-failure behavior.'
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

Describe 'Publish-DFeArchive' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Publish-DFeArchive -ErrorAction Stop
            $Script:FakeHash = 'a' * 64
        }

        BeforeEach {

            $testID = [guid]::NewGuid().ToString('N')

            $Script:TestRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.PublishArchive.Tests-{0}' -f $testID
            )

            $Script:SourcePath = Join-Path -Path $Script:TestRoot -ChildPath 'source.zip'

            $Script:OutputPath = Join-Path -Path $Script:TestRoot -ChildPath 'output'

            $Script:DestinationPath = Join-Path -Path $Script:OutputPath -ChildPath 'archive.zip'

            [System.IO.Directory]::CreateDirectory($Script:TestRoot) | Out-Null

            [System.IO.File]::WriteAllText($Script:SourcePath, 'new archive content')

            Mock -CommandName Get-FileSha256 -MockWith {
                $Script:FakeHash
            }
        }

        AfterEach {

            if (Test-Path -LiteralPath $Script:TestRoot) {
                $removeItemParams = @{
                    LiteralPath = $Script:TestRoot
                    Recurse     = $true
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeItemParams
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

            It 'Declares DestinationPath as mandatory' {
                $mandatory = $Script:Command.Parameters['DestinationPath'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares ExpectedHash as mandatory' {
                $mandatory = $Script:Command.Parameters['ExpectedHash'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Rejects an invalid ExpectedHash' {
                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = 'not-a-sha256'
                }

                { Publish-DFeArchive @publishParams } | Should -Throw
            }

            It 'Accepts an uppercase SHA-256 parameter' {
                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash.ToUpperInvariant()
                }

                { Publish-DFeArchive @publishParams } | Should -Not -Throw
            }
        }
        #endregion

        #region Destination preparation
        Context 'Destination preparation' {

            It 'Creates the destination directory when it does not exist' {
                Test-Path -LiteralPath $Script:OutputPath -PathType Container |
                    Should -BeFalse

                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                Publish-DFeArchive @publishParams

                Test-Path -LiteralPath $Script:OutputPath -PathType Container |
                    Should -BeTrue
            }

            It 'Throws ArchivePublishFailed when the destination directory cannot be created' {
                $blockingPath = Join-Path -Path $Script:TestRoot -ChildPath 'blocked'

                [System.IO.File]::WriteAllText($blockingPath, 'blocking file')

                $destinationPath = Join-Path -Path $blockingPath -ChildPath 'archive.zip'

                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $destinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                { Publish-DFeArchive @publishParams } |
                    Should -Throw -ErrorId 'ArchivePublishFailed*'
            }
        }
        #endregion

        #region Staging
        Context 'Staging' {

            It 'Throws ArchiveStageCopyFailed when the source does not exist' {
                $missingPath = Join-Path -Path $Script:TestRoot -ChildPath 'missing.zip'

                $publishParams = @{
                    SourcePath      = $missingPath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                { Publish-DFeArchive @publishParams } |
                    Should -Throw -ErrorId 'ArchiveStageCopyFailed*'
            }

            It 'Does not compute a hash when staging copy fails' {
                $missingPath = Join-Path -Path $Script:TestRoot -ChildPath 'missing.zip'

                $publishParams = @{
                    SourcePath      = $missingPath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                try {
                    Publish-DFeArchive @publishParams
                } catch {
                    # Expected failure. The assertion below verifies post-failure state.
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

            It 'Hashes the staged file exactly once' {
                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                Publish-DFeArchive @publishParams

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

        #region Hash validation
        Context 'Hash validation' {

            It 'Throws ArchiveStageHashMismatch when the staged hash differs' {
                Mock -CommandName Get-FileSha256 -MockWith {
                    'b' * 64
                }

                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                { Publish-DFeArchive @publishParams } |
                    Should -Throw -ErrorId 'ArchiveStageHashMismatch*'
            }

            It 'Compares the staged hash case-insensitively' {
                Mock -CommandName Get-FileSha256 -MockWith {
                    'abcdef' * 10 + 'abcd'
                }

                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = 'ABCDEF' * 10 + 'ABCD'
                }

                { Publish-DFeArchive @publishParams } | Should -Not -Throw
            }

            It 'Does not create the destination when hash validation fails' {
                Mock -CommandName Get-FileSha256 -MockWith {
                    'b' * 64
                }

                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                try {
                    Publish-DFeArchive @publishParams
                } catch {
                    # Expected failure. The assertion below verifies post-failure state.
                }

                Test-Path -LiteralPath $Script:DestinationPath -PathType Leaf |
                    Should -BeFalse
            }

            It 'Preserves an existing destination when hash validation fails' {
                [System.IO.Directory]::CreateDirectory($Script:OutputPath) | Out-Null

                [System.IO.File]::WriteAllText(
                    $Script:DestinationPath,
                    'existing archive content'
                )

                Mock -CommandName Get-FileSha256 -MockWith {
                    'b' * 64
                }

                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                try {
                    Publish-DFeArchive @publishParams
                } catch {
                    # Expected failure. The assertion below verifies post-failure state.
                }

                [System.IO.File]::ReadAllText($Script:DestinationPath) |
                    Should -BeExactly 'existing archive content'
            }
        }
        #endregion

        #region New destination publication
        Context 'New destination publication' {

            It 'Publishes the archive when the destination does not exist' {
                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                Publish-DFeArchive @publishParams

                Test-Path -LiteralPath $Script:DestinationPath -PathType Leaf |
                    Should -BeTrue

                [System.IO.File]::ReadAllText($Script:DestinationPath) |
                    Should -BeExactly 'new archive content'
            }

            It 'Leaves the source archive unchanged after publication' {
                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                Publish-DFeArchive @publishParams

                Test-Path -LiteralPath $Script:SourcePath -PathType Leaf |
                    Should -BeTrue

                [System.IO.File]::ReadAllText($Script:SourcePath) |
                    Should -BeExactly 'new archive content'
            }
        }
        #endregion

        #region Existing destination publication
        Context 'Existing destination publication' {

            BeforeEach {

                [System.IO.Directory]::CreateDirectory($Script:OutputPath) |
                    Out-Null

                [System.IO.File]::WriteAllText(
                    $Script:DestinationPath,
                    'old archive content'
                )
            }

            It 'Atomically replaces an existing destination' {
                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                Publish-DFeArchive @publishParams

                [System.IO.File]::ReadAllText($Script:DestinationPath) |
                    Should -BeExactly 'new archive content'
            }

            It 'Does not leave a backup file after replacing the destination' {
                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                Publish-DFeArchive @publishParams

                $itemParams = @{
                    LiteralPath = $Script:OutputPath
                    Filter      = '*.backup'
                }

                (Get-ChildItem @itemParams) | Should -HaveCount 0
            }
        }
        #endregion

        #region Publication failure
        Context 'Publication failure' {

            It 'Throws ArchivePublishFailed when the final move cannot complete' {
                [System.IO.Directory]::CreateDirectory(
                    $Script:DestinationPath
                ) | Out-Null

                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                { Publish-DFeArchive @publishParams } |
                    Should -Throw -ErrorId 'ArchivePublishFailed*'
            }
        }
        #endregion

        #region Staging cleanup
        Context 'Staging cleanup' {

            It 'Removes staging files after a hash mismatch' {
                Mock -CommandName Get-FileSha256 -MockWith {
                    'b' * 64
                }

                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                try {
                    Publish-DFeArchive @publishParams
                } catch {

                }

                $stageFiles = @(
                    Get-ChildItem -LiteralPath $Script:OutputPath -Filter '*.publishing'
                )

                $stageFiles | Should -HaveCount 0
            }

            It 'Removes staging files after a publication failure' {
                [System.IO.Directory]::CreateDirectory(
                    $Script:DestinationPath
                ) | Out-Null

                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                try {
                    Publish-DFeArchive @publishParams
                } catch {

                }

                $itemParams = @{
                    LiteralPath = $Script:OutputPath
                    Filter      = '*.publishing'
                }

                (Get-ChildItem @itemParams) | Should -HaveCount 0
            }

            It 'Leaves no staging files after successful publication' {
                $publishParams = @{
                    SourcePath      = $Script:SourcePath
                    DestinationPath = $Script:DestinationPath
                    ExpectedHash    = $Script:FakeHash
                }

                Publish-DFeArchive @publishParams

                $itemParams = @{
                    LiteralPath = $Script:OutputPath
                    Filter      = '*.publishing'
                }

                (Get-ChildItem @itemParams) | Should -HaveCount 0
            }
        }
        #endregion
    }
}
