#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for New-DFeArchive.

.DESCRIPTION
Verifies orchestration logic using mocked dependencies.
No real ZIP files are created except where Test-Path must find them.

Coverage includes:
  - All parameters are mandatory.
  - Creates OutputPath when it does not exist.
  - Loads eventos for every document via Get-DFeEventoEntry.
  - Maps snake_case entries to PascalCase before calling Compress-DFeArchive.
  - Calls Compress-DFeArchive once per ArchiveInfo.
  - Passes the correct XmlPath, Entries, Eventos and ZipPath to Compress-DFeArchive.
  - Throws ZipNotCreated when the ZIP is absent after compression.
  - ZipNotCreated uses ResourceUnavailable category.
  - Calls Get-FileSha256 on the TempPath.
  - Copies the ZIP to DestPath with Force.
  - Returns one result object per ArchiveInfo.
  - Result object exposes TipoDFe, FileName, FileHash, TempPath, DestPath.
  - FileHash is the value returned by Get-FileSha256.
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
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

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

            # snake_case — matches Get-DFeDocumentEntry output contract.
            $Script:ValidEntries = @(
                [PSCustomObject]@{
                    chave_acesso = '1' * 44
                    modelo       = 55
                    file_path    = 'nfe.xml'
                    sha256       = 'aaa'
                    indexed_at   = '2026-08-01T00:00:00+00:00'
                }
            )

            # snake_case — matches Get-DFeEventoEntry output contract.
            $Script:FakeEvento = [PSCustomObject]@{
                chave_pai  = '1' * 44
                file_path  = 'evt.xml'
                sha256     = 'bbb'
                indexed_at = '2026-08-01T00:00:00+00:00'
            }

            $Script:Cnpj = '12345678000199'
        }

        AfterAll {

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }

        BeforeEach {

            Mock -CommandName Get-DFeEventoEntry -MockWith {
                param  (
                    [string]$Cnpj,
                    [string]$ChavePai
                )

                $null = $Cnpj
                $null = $ChavePai
                return @()
            }

            Mock -CommandName Compress-DFeArchive -MockWith {
                param (
                    [string]$XmlPath,
                    [pscustomobject[]]$Entries,
                    [pscustomobject[]]$Eventos,
                    [string]$ZipPath,
                    [System.IO.Compression.CompressionLevel]$CompressionLevel
                )

                $null = $XmlPath
                $null = $Entries
                $null = $Eventos
                $null = $CompressionLevel
                [System.IO.File]::WriteAllText($ZipPath, 'fake-zip')
            }

            Mock -CommandName Get-FileSha256 -MockWith {
                param ([string]$Path)
                $null = $Path
                return 'abc123hash'
            }

            Mock -CommandName Copy-Item -MockWith {
                param (
                    [string]$LiteralPath,
                    [string]$Destination,
                    [switch]$Force
                )

                $null = $LiteralPath
                $null = $Destination
                $null = $Force
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
                $pathParams = @{
                    Path      = $TestDrive
                    ChildPath = 'output-{0}' -f [guid]::NewGuid().ToString('N')
                }

                $newOutput  = Join-Path @pathParams

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

        #region Evento loading
        Context 'Evento loading' {

            It 'Calls Get-DFeEventoEntry once per entry' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:ValidArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $invokeParams = @{
                    CommandName = 'Get-DFeEventoEntry'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = $Script:ValidEntries.Count
                }

                Should -Invoke @invokeParams
            }

            It 'Passes the correct ChavePai to Get-DFeEventoEntry' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:ValidArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $invokeParams = @{
                    CommandName     = 'Get-DFeEventoEntry'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $ChavePai -eq ('1' * 44)
                    }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region PascalCase mapping
        Context 'PascalCase mapping' {

            BeforeEach {

                $Script:CapturedEntries = $null
                $Script:CapturedEventos = $null

                Mock -CommandName Get-DFeEventoEntry -MockWith {
                    param (
                        [string]$Cnpj,
                        [string]$ChavePai
                    )

                    $null = $Cnpj
                    $null = $ChavePai
                    return @($Script:FakeEvento)
                }

                Mock -CommandName Compress-DFeArchive -MockWith {
                    param (
                        [string]$XmlPath,
                        [pscustomobject[]]$Entries,
                        [pscustomobject[]]$Eventos,
                        [string]$ZipPath,
                        [System.IO.Compression.CompressionLevel]$CompressionLevel
                    )

                    $null = $XmlPath
                    $null = $CompressionLevel
                    $Script:CapturedEntries = $Entries
                    $Script:CapturedEventos = $Eventos

                    [System.IO.File]::WriteAllText($ZipPath, 'fake-zip')
                }
            }

            It 'Maps chave_acesso to ChaveAcesso in entries' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:ValidArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $Script:CapturedEntries[0].ChaveAcesso | Should -Be ('1' * 44)
            }

            It 'Maps modelo to Modelo in entries' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:ValidArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $Script:CapturedEntries[0].Modelo | Should -Be 55
            }

            It 'Maps file_path to FilePath in entries' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:ValidArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $Script:CapturedEntries[0].FilePath | Should -Be 'nfe.xml'
            }

            It 'Maps chave_pai to ChavePai in eventos' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:ValidArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $Script:CapturedEventos[0].ChavePai | Should -Be ('1' * 44)
            }

            It 'Maps file_path to FilePath in eventos' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:ValidArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $Script:CapturedEventos[0].FilePath | Should -Be 'evt.xml'
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

                $invokeParams = @{
                    CommandName = 'Compress-DFeArchive'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Passes XmlPath from the Company object' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:ValidArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $invokeParams = @{
                    CommandName     = 'Compress-DFeArchive'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $XmlPath -eq $Script:ValidCompany.XmlPath
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Passes TempPath as ZipPath' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:ValidArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $invokeParams = @{
                    CommandName     = 'Compress-DFeArchive'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $ZipPath -eq $Script:ValidArchiveInfo.TempPath
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Throws ZipNotCreated when ZIP is absent after compression' {
                $pathParams = @{
                    Path      = $TestDrive
                    ChildPath = 'missing-{0}.zip' -f [guid]::NewGuid().ToString('N')
                }

                $missingZip = Join-Path @pathParams

                $archiveInfo = [PSCustomObject]@{
                    TipoDFe  = 'NFe'
                    FileName = 'NFe_test.zip'
                    TempPath = $missingZip
                    DestPath = Join-Path -Path $Script:OutputPath -ChildPath 'NFe_test.zip'
                }

                Mock -CommandName Compress-DFeArchive -MockWith {
                    param (
                        [string]$XmlPath,
                        [pscustomobject[]]$Entries,
                        [pscustomobject[]]$Eventos,
                        [string]$ZipPath,
                        [System.IO.Compression.CompressionLevel]$CompressionLevel
                    )

                    $null = $XmlPath
                    $null = $Entries
                    $null = $Eventos
                    $null = $ZipPath
                    $null = $CompressionLevel
                    # Intentionally does not create the file.
                }

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
                $pathParams = @{
                    Path      = $TestDrive
                    ChildPath = 'missing-{0}.zip' -f [guid]::NewGuid().ToString('N')
                }

                $missingZip = Join-Path @pathParams

                $archiveInfo = [PSCustomObject]@{
                    TipoDFe  = 'NFe'
                    FileName = 'NFe_test.zip'
                    TempPath = $missingZip
                    DestPath = Join-Path -Path $Script:OutputPath -ChildPath 'NFe_test.zip'
                }

                Mock -CommandName Compress-DFeArchive -MockWith {
                    param (
                        [string]$XmlPath,
                        [pscustomobject[]]$Entries,
                        [pscustomobject[]]$Eventos,
                        [string]$ZipPath,
                        [System.IO.Compression.CompressionLevel]$CompressionLevel
                    )

                    $null = $XmlPath
                    $null = $Entries
                    $null = $Eventos
                    $null = $ZipPath
                    $null = $CompressionLevel
                }

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

                $thrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::ResourceUnavailable)
            }
        }
        #endregion

        #region Result object
        Context 'Result object' {

            BeforeEach {

                $Script:CopyItemCalls = [System.Collections.Generic.List[hashtable]]::new()

                Mock -CommandName Get-FileSha256 -MockWith {
                    param ([string]$Path)
                    $null = $Path
                    return 'abc123hash'
                }

                Mock -CommandName Copy-Item -MockWith {
                    param (
                        [string]$LiteralPath,
                        [string]$Destination,
                        [switch]$Force
                    )

                    $Script:CopyItemCalls.Add(
                        @{
                            LiteralPath = $LiteralPath
                            Destination = $Destination
                            Force       = [bool]$Force
                        }
                    )
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
                $Script:Results[0] |
                    Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly the documented properties' {
                $expected = @('TipoDFe', 'FileName', 'FileHash', 'TempPath', 'DestPath')

                $actual = @($Script:Results[0].PSObject.Properties.Name)
                $actual | Should -Be $expected
            }

            It 'Returns the expected result values' {
                $result = $Script:Results[0]

                $result.TipoDFe  | Should -Be $Script:ValidArchiveInfo.TipoDFe
                $result.FileName | Should -Be $Script:ValidArchiveInfo.FileName
                $result.FileHash | Should -Be 'abc123hash'
                $result.TempPath | Should -Be $Script:ValidArchiveInfo.TempPath
                $result.DestPath | Should -Be $Script:ValidArchiveInfo.DestPath
            }

            It 'Copies the ZIP from TempPath to DestPath' {
                $Script:CopyItemCalls | Should -HaveCount 1

                $Script:CopyItemCalls[0].LiteralPath | Should -Be $Script:ValidArchiveInfo.TempPath
                $Script:CopyItemCalls[0].Destination | Should -Be $Script:ValidArchiveInfo.DestPath
            }

            It 'Copies with Force' {
                $Script:CopyItemCalls[0].Force | Should -BeTrue
            }
        }
        #endregion
    }
}
