#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for New-DFeArchive.

.DESCRIPTION
Verifies orchestration behavior using mocked dependencies.

Coverage includes:
  - Mandatory parameter contract.
  - OutputPath creation.
  - Event loading for every document.
  - snake_case to PascalCase mapping.
  - SHA-256 preservation in mapped objects.
  - Document grouping by ModeloDFe.
  - Event grouping by parent document.
  - One compression per ArchiveInfo.
  - Correct XmlPath, Entries, Eventos and ZipPath.
  - Unsupported archive-model errors.
  - Missing ZIP detection and error category.
  - Compressor error propagation.
  - Get-FileSha256 invocation against TempPath.
  - Publish-DFeArchive invocation.
  - Temporary ZIP cleanup on success.
  - Temporary ZIP cleanup on failure.
  - One result per successfully published ArchiveInfo.
  - Exact result contract.
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

Describe 'New-DFeArchive' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:TestID = [guid]::NewGuid().ToString('N')

            $Script:Command = Get-Command -Name New-DFeArchive -ErrorAction Stop

            $Script:OutputPath = Join-Path -Path $TestDrive -ChildPath 'output'

            $Script:XmlPath = Join-Path -Path $TestDrive -ChildPath 'xml'

            $Script:NFeTempZip = Join-Path -Path $TestDrive -ChildPath 'NFe_test.zip'

            $Script:CTeTempZip = Join-Path -Path $TestDrive -ChildPath 'CTe_test.zip'

            $Script:ValidCompany = [PSCustomObject]@{
                XmlPath    = $Script:XmlPath
                OutputPath = $Script:OutputPath
            }

            $Script:NFeKey = '1' * 44
            $Script:CTeKey = '2' * 44

            $Script:NFeArchiveInfo = [PSCustomObject]@{
                TipoDFe  = 'NFe'
                FileName = 'NFe_test.zip'
                TempPath = $Script:NFeTempZip
                DestPath = Join-Path -Path $Script:OutputPath -ChildPath 'NFe_test.zip'
            }

            $Script:CTeArchiveInfo = [PSCustomObject]@{
                TipoDFe  = 'CTe'
                FileName = 'CTe_test.zip'
                TempPath = $Script:CTeTempZip
                DestPath = Join-Path -Path $Script:OutputPath -ChildPath 'CTe_test.zip'
            }

            $Script:ValidEntries = @(
                [PSCustomObject]@{
                    chave_acesso = $Script:NFeKey
                    modelo       = 55
                    file_path    = 'nfe.xml'
                    sha256       = 'nfe-sha'
                    indexed_at   = '2026-08-01T00:00:00+00:00'
                }

                [PSCustomObject]@{
                    chave_acesso = $Script:CTeKey
                    modelo       = 57
                    file_path    = 'cte.xml'
                    sha256       = 'cte-sha'
                    indexed_at   = '2026-08-01T00:00:00+00:00'
                }
            )

            $Script:NFeEvento = [PSCustomObject]@{
                chave_pai  = $Script:NFeKey
                file_path  = 'evento-nfe.xml'
                sha256     = 'evento-nfe-sha'
                indexed_at = '2026-08-01T00:00:00+00:00'
            }

            $Script:CTeEvento = [PSCustomObject]@{
                chave_pai  = $Script:CTeKey
                file_path  = 'evento-cte.xml'
                sha256     = 'evento-cte-sha'
                indexed_at = '2026-08-01T00:00:00+00:00'
            }

            $Script:Cnpj = '12345678000199'

            $Script:FakeHash = 'a' * 64
        }

        AfterAll {

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }

        BeforeEach {

            if (Test-Path -LiteralPath $Script:NFeTempZip) {
                Remove-Item -LiteralPath $Script:NFeTempZip -Force
            }

            if (Test-Path -LiteralPath $Script:CTeTempZip) {
                Remove-Item -LiteralPath $Script:CTeTempZip -Force
            }

            $Script:CapturedCompressionCalls = @()

            Mock -CommandName Get-DFeEventoEntry -MockWith {
                if ($ChavePai -eq $Script:NFeKey) {
                    return @($Script:NFeEvento)
                }

                if ($ChavePai -eq $Script:CTeKey) {
                    return @($Script:CTeEvento)
                }

                return @()
            }

            Mock -CommandName Compress-DFeArchive -MockWith {
                $Script:CapturedCompressionCalls += [PSCustomObject]@{
                    XmlPath = $XmlPath
                    Entries = @($Entries)
                    Eventos = @($Eventos)
                    ZipPath = $ZipPath
                }

                [System.IO.File]::WriteAllText($ZipPath, 'fake-zip')
            }

            Mock -CommandName Get-FileSha256 -MockWith {
                $Script:FakeHash
            }

            Mock -CommandName Publish-DFeArchive -MockWith {

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

        #region OutputPath
        Context 'OutputPath creation' {

            It 'Creates OutputPath when it does not exist' {
                $newOutput = Join-Path -Path $TestDrive -ChildPath (
                    'output-{0}' -f $Script:TestID
                )

                $company = [PSCustomObject]@{
                    XmlPath    = $Script:XmlPath
                    OutputPath = $newOutput
                }

                $tempZip = Join-Path -Path $TestDrive -ChildPath (
                    'temp-{0}.zip' -f $Script:TestID
                )

                $archiveInfo = [PSCustomObject]@{
                    TipoDFe  = 'NFe'
                    FileName = 'NFe_test.zip'
                    TempPath = $tempZip
                    DestPath = Join-Path -Path $newOutput -ChildPath 'NFe_test.zip'
                }

                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $company
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($archiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                Test-Path -LiteralPath $newOutput -PathType Container |
                    Should -BeTrue
            }
        }
        #endregion

        #region Evento loading
        Context 'Evento loading' {

            It 'Calls Get-DFeEventoEntry once per document entry' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @(
                        $Script:NFeArchiveInfo
                        $Script:CTeArchiveInfo
                    )
                }

                New-DFeArchive @archiveParams | Out-Null

                $invokeParams = @{
                    CommandName = 'Get-DFeEventoEntry'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 2
                }

                Should -Invoke @invokeParams
            }

            It 'Passes NFe access key as ChavePai' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $invokeParams = @{
                    CommandName     = 'Get-DFeEventoEntry'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $ChavePai -eq $Script:NFeKey
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Passes the company CNPJ to Get-DFeEventoEntry' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $invokeParams = @{
                    CommandName     = 'Get-DFeEventoEntry'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj -eq $Script:Cnpj
                    }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Mapping and grouping
        Context 'Mapping and grouping' {

            It 'Maps entry fields to PascalCase' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $entry = $Script:CapturedCompressionCalls[0].Entries[0]

                $entry.ChaveAcesso | Should -Be $Script:NFeKey
                $entry.Modelo      | Should -Be 55
                $entry.FilePath    | Should -Be 'nfe.xml'
                $entry.Sha256      | Should -Be 'nfe-sha'
            }

            It 'Maps evento fields to PascalCase' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $evento = $Script:CapturedCompressionCalls[0].Eventos[0]

                $evento.ChavePai | Should -Be $Script:NFeKey
                $evento.FilePath | Should -Be 'evento-nfe.xml'
                $evento.Sha256   | Should -Be 'evento-nfe-sha'
            }

            It 'Passes only NFe documents to the NFe archive' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $entries = @($Script:CapturedCompressionCalls[0].Entries)

                $entries                | Should -HaveCount 1
                $entries[0].Modelo      | Should -Be 55
                $entries[0].ChaveAcesso | Should -Be $Script:NFeKey
            }

            It 'Passes only CTe documents to the CTe archive' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:CTeArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $entries = @($Script:CapturedCompressionCalls[0].Entries)

                $entries                | Should -HaveCount 1
                $entries[0].Modelo      | Should -Be 57
                $entries[0].ChaveAcesso | Should -Be $Script:CTeKey
            }

            It 'Passes only NFe events to the NFe archive' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $eventos = @($Script:CapturedCompressionCalls[0].Eventos)

                $eventos             | Should -HaveCount 1
                $eventos[0].ChavePai | Should -Be $Script:NFeKey
            }

            It 'Passes only CTe events to the CTe archive' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($Script:CTeArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $eventos = @($Script:CapturedCompressionCalls[0].Eventos)

                $eventos             | Should -HaveCount 1
                $eventos[0].ChavePai | Should -Be $Script:CTeKey
            }
        }
        #endregion

        #region Compression
        Context 'Compression orchestration' {

            It 'Calls Compress-DFeArchive once per ArchiveInfo' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @(
                        $Script:NFeArchiveInfo
                        $Script:CTeArchiveInfo
                    )
                }

                New-DFeArchive @archiveParams | Out-Null

                $invokeParams = @{
                    CommandName = 'Compress-DFeArchive'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 2
                }

                Should -Invoke @invokeParams
            }

            It 'Passes XmlPath from Company' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($Script:NFeArchiveInfo)
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
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $invokeParams = @{
                    CommandName     = 'Compress-DFeArchive'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $ZipPath -eq $Script:NFeArchiveInfo.TempPath
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Throws ZipNotCreated when ZIP is absent after compression' {
                $pathParams = @{
                    Path      = $TestDrive
                    ChildPath = 'missing-{0}.zip' -f $Script:TestID
                }

                $archiveInfo = [PSCustomObject]@{
                    TipoDFe  = 'NFe'
                    FileName = 'NFe_test.zip'
                    TempPath = Join-Path @pathParams
                    DestPath = Join-Path -Path $Script:OutputPath -ChildPath 'NFe_test.zip'
                }

                Mock -CommandName Compress-DFeArchive -MockWith {

                }

                $thrown = $null

                try {
                    $archiveParams = @{
                        Cnpj         = $Script:Cnpj
                        Company      = $Script:ValidCompany
                        Entries      = @($Script:ValidEntries[0])
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
                    ChildPath = 'missing-{0}.zip' -f $Script:TestID
                }

                $archiveInfo = [PSCustomObject]@{
                    TipoDFe  = 'NFe'
                    FileName = 'NFe_test.zip'
                    TempPath = Join-Path @pathParams
                    DestPath = Join-Path -Path $Script:OutputPath -ChildPath 'NFe_test.zip'
                }

                Mock -CommandName Compress-DFeArchive -MockWith {

                }

                $thrown = $null

                try {
                    $archiveParams = @{
                        Cnpj         = $Script:Cnpj
                        Company      = $Script:ValidCompany
                        Entries      = @($Script:ValidEntries[0])
                        ArchiveInfos = @($archiveInfo)
                        ErrorAction  = 'Stop'
                    }

                    New-DFeArchive @archiveParams
                } catch {
                    $thrown = $_
                }

                $expected = [System.Management.Automation.ErrorCategory]::ResourceUnavailable

                $thrown.CategoryInfo.Category | Should -Be $expected
            }
        }
        #endregion

        #region Unsupported model
        Context 'Unsupported archive model' {

            It 'Throws ArchiveModelUnsupported' {
                $tempZip = Join-Path -Path $TestDrive -ChildPath 'invalid-model.zip'

                $archiveInfo = [PSCustomObject]@{
                    TipoDFe  = 'NotARealDFe'
                    FileName = 'invalid.zip'
                    TempPath = $tempZip
                    DestPath = Join-Path -Path $Script:OutputPath -ChildPath 'invalid.zip'
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
                $thrown.FullyQualifiedErrorId | Should -BeLike 'ArchiveModelUnsupported*'
            }

            It 'Uses InvalidData category for ArchiveModelUnsupported' {
                $tempZip = Join-Path -Path $TestDrive -ChildPath 'invalid-model.zip'

                $archiveInfo = [PSCustomObject]@{
                    TipoDFe  = 'NotARealDFe'
                    FileName = 'invalid.zip'
                    TempPath = $tempZip
                    DestPath = Join-Path -Path $Script:OutputPath -ChildPath 'invalid.zip'
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

                $expected = [System.Management.Automation.ErrorCategory]::InvalidData

                $thrown.CategoryInfo.Category | Should -Be $expected
            }

            It 'Does not call Compress-DFeArchive for unsupported models' {
                $archiveInfo = [PSCustomObject]@{
                    TipoDFe  = 'NotARealDFe'
                    FileName = 'invalid.zip'
                    TempPath = Join-Path -Path $TestDrive         -ChildPath 'invalid.zip'
                    DestPath = Join-Path -Path $Script:OutputPath -ChildPath 'invalid.zip'
                }

                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @($archiveInfo)
                    ErrorAction  = 'Stop'
                }

                { New-DFeArchive @archiveParams } | Should -Throw

                $invokeParams = @{
                    CommandName = 'Compress-DFeArchive'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Hash and publication
        Context 'Hash and publication' {

            It 'Hashes the temporary ZIP' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $invokeParams = @{
                    CommandName     = 'Get-FileSha256'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Path -eq $Script:NFeArchiveInfo.TempPath
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Publishes using TempPath, DestPath and calculated hash' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $invokeParams = @{
                    CommandName     = 'Publish-DFeArchive'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $SourcePath      -eq $Script:NFeArchiveInfo.TempPath -and
                        $DestinationPath -eq $Script:NFeArchiveInfo.DestPath -and
                        $ExpectedHash    -eq $Script:FakeHash
                    }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Error propagation
        Context 'Dependency error propagation' {

            It 'Propagates Compress-DFeArchive errors unchanged' {
                Mock -CommandName Compress-DFeArchive -MockWith {
                    throw [System.IO.InvalidDataException]::new(
                        'Source hash mismatch.'
                    )
                }

                $thrown = $null

                try {
                    $archiveParams = @{
                        Cnpj         = $Script:Cnpj
                        Company      = $Script:ValidCompany
                        Entries      = @($Script:ValidEntries[0])
                        ArchiveInfos = @($Script:NFeArchiveInfo)
                        ErrorAction  = 'Stop'
                    }

                    New-DFeArchive @archiveParams
                } catch {
                    $thrown = $_
                }

                $thrown.Exception | Should -BeOfType [System.IO.InvalidDataException]
                $thrown.Exception.Message | Should -Be 'Source hash mismatch.'
            }

            It 'Propagates Publish-DFeArchive errors unchanged' {
                Mock -CommandName Publish-DFeArchive -MockWith {
                    throw [System.Management.Automation.ErrorRecord]::new(
                        [System.IO.IOException]::new('publish failed'),
                        'ArchivePublishFailed',
                        [System.Management.Automation.ErrorCategory]::WriteError,
                        $Script:NFeArchiveInfo.DestPath
                    )
                }

                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                    ErrorAction  = 'Stop'
                }

                { New-DFeArchive @archiveParams } |
                    Should -Throw -ErrorId 'ArchivePublishFailed*'
            }

            It 'Does not hash or publish when compression fails' {
                Mock -CommandName Compress-DFeArchive -MockWith {
                    throw 'compression failed'
                }

                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                    ErrorAction  = 'Stop'
                }

                { New-DFeArchive @archiveParams } | Should -Throw

                $invokeParamsOne = @{
                    CommandName = 'Get-FileSha256'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                $invokeParamsTwo = @{
                    CommandName = 'Publish-DFeArchive'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParamsOne
                Should -Invoke @invokeParamsTwo
            }
        }
        #endregion

        #region Cleanup
        Context 'Temporary ZIP cleanup' {

            It 'Removes TempPath after successful publication' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                }

                New-DFeArchive @archiveParams | Out-Null

                $pathParams = @{
                    LiteralPath = $Script:NFeArchiveInfo.TempPath
                    PathType    = 'Leaf'
                }

                Test-Path @pathParams | Should -BeFalse
            }

            It 'Removes TempPath when publication fails' {
                Mock -CommandName Publish-DFeArchive -MockWith {
                    throw 'publish failed'
                }

                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                    ErrorAction  = 'Stop'
                }

                { New-DFeArchive @archiveParams } | Should -Throw

                $pathParams = @{
                    LiteralPath = $Script:NFeArchiveInfo.TempPath
                    PathType    = 'Leaf'
                }

                Test-Path @pathParams | Should -BeFalse
            }

            It 'Removes TempPath when hashing fails' {
                Mock -CommandName Get-FileSha256 -MockWith {
                    throw 'hash failed'
                }

                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                    ErrorAction  = 'Stop'
                }

                { New-DFeArchive @archiveParams } | Should -Throw

                $pathParams = @{
                    LiteralPath = $Script:NFeArchiveInfo.TempPath
                    PathType    = 'Leaf'
                }

                Test-Path @pathParams | Should -BeFalse
            }
        }
        #endregion

        #region Result object
        Context 'Result object' {

            It 'Returns one result per ArchiveInfo' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = $Script:ValidEntries
                    ArchiveInfos = @(
                        $Script:NFeArchiveInfo
                        $Script:CTeArchiveInfo
                    )
                }

                $results = @(New-DFeArchive @archiveParams)

                $results | Should -HaveCount 2
            }

            It 'Returns PSCustomObject instances' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                }

                $result = @(New-DFeArchive @archiveParams)[0]

                $result | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly the documented properties' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                }

                $result = @(New-DFeArchive @archiveParams)[0]

                $expected = @(
                    'TipoDFe'
                    'FileName'
                    'FileHash'
                    'TempPath'
                    'DestPath'
                )

                $actual = @($result.PSObject.Properties.Name)

                $actual | Should -Be $expected
            }

            It 'Returns the expected values' {
                $archiveParams = @{
                    Cnpj         = $Script:Cnpj
                    Company      = $Script:ValidCompany
                    Entries      = @($Script:ValidEntries[0])
                    ArchiveInfos = @($Script:NFeArchiveInfo)
                }

                $result = @(New-DFeArchive @archiveParams)[0]

                $result.TipoDFe  | Should -Be $Script:NFeArchiveInfo.TipoDFe
                $result.FileName | Should -Be $Script:NFeArchiveInfo.FileName
                $result.FileHash | Should -Be $Script:FakeHash
                $result.TempPath | Should -Be $Script:NFeArchiveInfo.TempPath
                $result.DestPath | Should -Be $Script:NFeArchiveInfo.DestPath
            }
        }
        #endregion
    }
}
