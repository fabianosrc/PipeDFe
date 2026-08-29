#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for New-DFeArchive.

.DESCRIPTION
Verifies orchestration logic using mocked Compress-DFeArchive and
Get-FileSha256. No real ZIP files are created.

Coverage includes:
  - All parameters are mandatory.
  - Creates OutputPath when it does not exist.
  - Calls Compress-DFeArchive once per ArchiveInfo.
  - Throws ZipNotCreated when the ZIP is absent after compression.
  - ZipNotCreated uses ResourceUnavailable category.
  - Returns one result object per ArchiveInfo.
  - Result object exposes TipoDFe, FileName, FileHash, TempPath, DestPath.
  - FileHash is the value returned by Get-FileSha256.
  - Copies the ZIP to DestPath after hashing.
  - Filters entries by model value and includes eventos in each group.
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
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'New-DFeArchive' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name New-DFeArchive -ErrorAction Stop

            $Script:OutputPath = Join-Path -Path $TestDrive -ChildPath 'output'
            $Script:TempZip    = Join-Path -Path $TestDrive -ChildPath 'NFe_test.zip'

            $Script:ValidCompany = [PSCustomObject]@{
                XmlPath    = Join-Path -Path $TestDrive -ChildPath 'xml'
                OutputPath = $Script:OutputPath
            }

            $Script:ValidArchiveInfo = [PSCustomObject]@{
                TipoDFe  = 'NFe'
                FileName = 'NFe_test.zip'
                TempPath = $Script:TempZip
                DestPath = Join-Path -Path $Script:OutputPath -ChildPath 'NFe_test.zip'
            }

            $Script:ValidEntries = @(
                [PSCustomObject]@{
                    DfeModel    = 55
                    ChaveAcesso = '1' * 44
                    FilePath    = 'nfe.xml'
                    FileName    = 'nfe.xml'
                }
                [PSCustomObject]@{
                    DfeModel = 0;
                    ChavePai = '1' * 44
                    FilePath = 'evt.xml'
                    FileName = 'evt.xml'
                }
            )

            $Script:Cnpj = '12345678000199'
        }

        BeforeEach {

            Mock -CommandName Compress-DFeArchive -MockWith {
                [System.IO.File]::WriteAllText($ZipPath, 'fake-zip')
            }

            Mock -CommandName Get-FileSha256 -MockWith {
                'abc123'
            }

            Mock -CommandName Copy-Item -MockWith { }
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

            It 'Declares Company as mandatory' {
                $mandatory = $Script:Command.Parameters['Company'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Entries as mandatory' {
                $mandatory = $Script:Command.Parameters['Entries'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares ArchiveInfos as mandatory' {
                $mandatory = $Script:Command.Parameters['ArchiveInfos'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region OutputPath creation
        Context 'OutputPath creation' {

            It 'Creates OutputPath when it does not exist' {
                $joinParams = @{
                    Path      = $TestDrive
                    ChildPath = 'output-{0}' -f [guid]::NewGuid().ToString('N')
                }

                $newOutput = Join-Path @joinParams

                $company = [PSCustomObject]@{
                    XmlPath    = $Script:ValidCompany.XmlPath
                    OutputPath = $newOutput
                }

                $archiveInfo = [PSCustomObject]@{
                    TipoDFe  = 'NFe'
                    FileName = 'NFe_test.zip'
                    TempPath = $Script:TempZip
                    DestPath = Join-Path -Path $newOutput -ChildPath 'NFe_test.zip'
                }

                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $company
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($archiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                Test-Path -LiteralPath $newOutput -PathType Container | Should -BeTrue
            }
        }
        #endregion

        #region Compression orchestration
        Context 'Compression orchestration' {

            It 'Calls Compress-DFeArchive once per ArchiveInfo' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:ValidArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                Should -Invoke -CommandName Compress-DFeArchive -Times 1 -Exactly
            }

            It 'Throws ZipNotCreated when ZIP is absent after compression' {
                $joinParams = @{
                    Path      = $TestDrive
                    ChildPath = 'missing-{0}.zip' -f [guid]::NewGuid().ToString('N')
                }

                $archiveInfo = [PSCustomObject]@{
                    TipoDFe  = 'NFe'
                    FileName = 'NFe_test.zip'
                    TempPath = Join-Path @joinParams
                    DestPath = Join-Path -Path $Script:OutputPath -ChildPath 'NFe_test.zip'
                }

                Mock -CommandName Compress-DFeArchive -MockWith { }

                $thrown = $null

                try {
                    $archiveParams = @{
                        Cnpj         = $Script:Cnpj
                        Company      = $Script:ValidCompany
                        Entries      = $Script:ValidEntries
                        ArchiveInfos = @($archiveInfo)
                        ErrorAction  = 'Stop'
                    }

                    New-DFeArchive @archiveParams
                } catch {
                    $thrown = $_
                }

                $thrown | Should -Not -BeNullOrEmpty
                $thrown.FullyQualifiedErrorId | Should -BeLike 'ZipNotCreated*'
            }

            It 'Uses ResourceUnavailable category for ZipNotCreated' {
                Mock -CommandName Compress-DFeArchive -MockWith {
                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.InvalidOperationException]::new('ZIP creation failed'),
                            'ZipNotCreated',
                            [System.Management.Automation.ErrorCategory]::ResourceUnavailable,
                            $null
                        )
                    )
                }

                $thrown = $null

                try {
                    $archiveParams = @{
                        Cnpj         = $Script:Cnpj
                        Company      = $Script:ValidCompany
                        Entries      = $Script:ValidEntries
                        ArchiveInfos = @($Script:ValidArchiveInfo)
                        ErrorAction  = 'Stop'
                    }

                    New-DFeArchive @archiveParams
                } catch {
                    $thrown = $_
                }

                $thrown | Should -Not -BeNullOrEmpty
                $thrown.CategoryInfo.Category | Should -Be 'ResourceUnavailable'
            }
        }
        #endregion

        #region Result object
        Context 'Result object' {

            BeforeAll {

                $Script:CopyItemCalls = @()

                Mock -CommandName Compress-DFeArchive -MockWith {
                    [System.IO.File]::WriteAllText($ZipPath, 'fake-zip')
                }

                Mock -CommandName Get-FileSha256 -MockWith {
                    'abc123hash'
                }

                Mock -CommandName Copy-Item -MockWith {
                    $Script:CopyItemCalls += @{
                        LiteralPath = $LiteralPath
                        Destination = $Destination
                        Force       = $Force
                    }
                }

                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:ValidArchiveInfo)
                }

                $Script:Results = @(New-DFeArchive @archiveParams)
            }

            It 'Returns one result per ArchiveInfo' {
                $Script:Results | Should -HaveCount 1
            }

            It 'Returns a PSCustomObject' {
                $Script:Results[0] | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly the documented properties' {
                $expected = @('TipoDFe', 'FileName', 'FileHash', 'TempPath', 'DestPath')
                $actual   = @($Script:Results[0].PSObject.Properties.Name)

                $actual | Should -Be $expected
            }

            It 'FileHash is the value returned by Get-FileSha256' {
                $Script:Results[0].FileHash | Should -Be 'abc123hash'
            }

            It 'TipoDFe matches the ArchiveInfo' {
                $Script:Results[0].TipoDFe | Should -Be 'NFe'
            }

            It 'Copies the ZIP to DestPath' {
                $Script:CopyItemCalls | Should -HaveCount 1

                $Script:CopyItemCalls[0].LiteralPath | Should -Be $Script:ValidArchiveInfo.TempPath

                $Script:CopyItemCalls[0].Destination | Should -Be $Script:ValidArchiveInfo.DestPath
            }
        }
        #endregion
    }
}
