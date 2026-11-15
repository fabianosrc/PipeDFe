#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Invoke-DFeNFSeXmlScan.

.DESCRIPTION
Verifies that Invoke-DFeNFSeXmlScan correctly identifies, validates, and
persists NFS-e Nacional XML files from a directory tree.

Coverage includes:
- Happy path: national invoice in a subdirectory, mixed directory (municipal
  XML and DPS XML ignored), deduplication within the same scan.
- Conflicting sources: two different XMLs sharing the same ChaveAcesso.
- Missing directory: terminating error with NFSeXmlPathNotFound.
- Source changed during import: terminating error with NFSeSourceChangedDuringImport.
#>

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $modulePath -Force -Global -ErrorAction Stop
}

Describe 'Invoke-DFeNFSeXmlScan' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA
            $Script:OriginalDataRoot     = $env:PIPEDFE_DATA_ROOT

            $env:LOCALAPPDATA = Join-Path -Path $TestDrive -ChildPath 'store'
            Remove-Item -Path 'Env:PIPEDFE_DATA_ROOT' -ErrorAction SilentlyContinue

            $Script:Cnpj    = '12345678000199'
            $Script:Key     = '35503082123456780001990000000000001261100000012345'
            $Script:NFSeXml = @"
<NFSe xmlns="http://www.sped.fazenda.gov.br/nfse" versao="1.01">
    <infNFSe Id="NFS$($Script:Key)">
        <nNFSe>9876543210123</nNFSe>
        <dhProc>2026-11-01T00:05:00-03:00</dhProc>
        <valores>
            <vLiq>98.00</vLiq>
        </valores>
        <DPS>
            <infDPS>
                <dhEmi>2026-10-31T23:58:00-03:00</dhEmi>
                <dCompet>2026-10-31</dCompet>
                <valores>
                    <vServPrest>
                        <vServ>100.00</vServ>
                    </vServPrest>
                </valores>
            </infDPS>
        </DPS>
    </infNFSe>
</NFSe>
"@
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData

            if ([string]::IsNullOrEmpty($Script:OriginalDataRoot)) {
                Remove-Item -Path 'Env:PIPEDFE_DATA_ROOT' -ErrorAction SilentlyContinue
            } else {
                $env:PIPEDFE_DATA_ROOT = $Script:OriginalDataRoot
            }
        }

        It 'Imports a national invoice in a subdirectory and does not duplicate it' {
            $xmlDir = Join-Path -Path $TestDrive -ChildPath 'mixed'
            $subDir = Join-Path -Path $xmlDir -ChildPath 'nested'

            New-Item -Path $subDir -ItemType Directory -Force | Out-Null

            $xmlPath = Join-Path -Path $subDir -ChildPath 'nota.xml'

            [System.IO.File]::WriteAllText($xmlPath, $Script:NFSeXml)

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $xmlDir -ChildPath 'municipal.xml'),
                '<NFSe xmlns="urn:municipal" />'
            )

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $xmlDir -ChildPath 'dps.xml'),
                '<DPS xmlns="http://www.sped.fazenda.gov.br/nfse" />'
            )

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $xmlDir -ChildPath 'readme.txt'),
                'ignored'
            )

            $scanParams = @{
                Cnpj    = $Script:Cnpj
                XmlPath = $xmlDir
            }

            $result = Invoke-DFeNFSeXmlScan @scanParams
            $result.FilesFound    | Should -Be 3
            $result.FilesImported | Should -Be 1
            $result.FilesIgnored  | Should -Be 2

            $copyPath = Join-Path -Path $subDir -ChildPath 'zz-copy.xml'
            [System.IO.File]::Copy($xmlPath, $copyPath)

            $repeated = Invoke-DFeNFSeXmlScan @scanParams
            $repeated.FilesImported | Should -Be 1
            $repeated.FilesIgnored  | Should -Be 3

            $connection = Open-DFeIndexConnection -Cnpj $Script:Cnpj

            try {
                $command = $connection.CreateCommand()
                try {
                    $command.CommandText = 'SELECT COUNT(*) FROM dfe_nfse;'
                    $command.ExecuteScalar() | Should -Be 1
                    $command.CommandText = @'
SELECT chave_acesso || '|' || numero || '|' || file_path || '|' || source_sha256
FROM dfe_nfse;
'@
                    $sha = Get-FileSha256 -Path $xmlPath
                    $expected = "$($Script:Key)|9876543210123|$xmlPath|$sha"
                    $command.ExecuteScalar() | Should -BeExactly $expected

                    $command.CommandText = 'SELECT COUNT(*) FROM dfe_document;'
                    $command.ExecuteScalar() | Should -Be 0
                } finally {
                    $command.Dispose()
                }
            } finally {
                $connection.Dispose()
            }
        }

        It 'Rejects conflicting sources for the same national key in one scan' {
            $xmlDir = Join-Path -Path $TestDrive -ChildPath 'conflict'

            New-Item -Path $xmlDir -ItemType Directory | Out-Null

            $first  = Join-Path -Path $xmlDir -ChildPath 'first.xml'
            $second = Join-Path -Path $xmlDir -ChildPath 'second.xml'

            [System.IO.File]::WriteAllText($first, $Script:NFSeXml)

            [System.IO.File]::WriteAllText(
                $second,
                $Script:NFSeXml.Replace('<vLiq>98.00</vLiq>', '<vLiq>97.00</vLiq>')
            )

            $scanParams = @{
                Cnpj    = $Script:Cnpj
                XmlPath = $xmlDir
            }

            { Invoke-DFeNFSeXmlScan @scanParams } |
                Should -Throw -ErrorId 'NFSeConflictingSource*'
        }

        It 'Rejects a missing configured directory' {

            $scanParams = @{
                Cnpj    = $Script:Cnpj
                XmlPath = Join-Path -Path $TestDrive -ChildPath 'missing'
            }

            { Invoke-DFeNFSeXmlScan @scanParams } |
                Should -Throw -ErrorId 'NFSeXmlPathNotFound*'
        }

        It 'Does not write a projection when its source changes during extraction' {
            $xmlDir = Join-Path -Path $TestDrive -ChildPath 'changed'

            New-Item -Path $xmlDir -ItemType Directory | Out-Null

            $xmlPath = Join-Path -Path $xmlDir -ChildPath 'nota.xml'
            [System.IO.File]::WriteAllText($xmlPath, $Script:NFSeXml)

            $Script:HashCallCount = 0

            Mock -CommandName Get-FileSha256 -MockWith {
                $Script:HashCallCount++

                if ($Script:HashCallCount -eq 1) {
                    'a' * 64
                } else {
                    'b' * 64
                }
            }

            Mock -CommandName Save-DFeNFSeFiscalData

            $scanParams = @{
                Cnpj    = $Script:Cnpj
                XmlPath = $xmlDir
            }

            { Invoke-DFeNFSeXmlScan @scanParams } |
                Should -Throw -ErrorId 'NFSeSourceChangedDuringImport*'

            $shouldParams = @{
                CommandName = 'Save-DFeNFSeFiscalData'
                ModuleName  = 'PipeDFe'
                Scope       = 'It'
                Exactly     = $true
                Times       = 0
            }

            Should -Invoke @shouldParams
        }
    }
}
