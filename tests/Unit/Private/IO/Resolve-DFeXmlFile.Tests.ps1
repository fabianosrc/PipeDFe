#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Resolve-DFeXmlFile.

.DESCRIPTION
Verifies classification, deduplication, order preservation and error
handling using mocked Get-DFeXmlMetadata. No real XML files are parsed.

Coverage includes:
  - Candidates is mandatory and rejects null.
  - Classifies a bare document correctly.
  - Classifies a processed document correctly.
  - Classifies an evento correctly.
  - Classifies an inutilizacao correctly.
  - Adds files to Unresolved when Get-DFeXmlMetadata returns null.
  - Adds files to Unresolved when Get-DFeXmlMetadata throws.
  - Adds files to Unresolved when metadata is an array.
  - Adds files to Unresolved when Tipo is not a TipoXmlDFe.
  - Adds files to Unresolved when Chave is missing or empty.
  - Adds files to Unresolved when IsProc is not a bool.
  - Does not throw when a file cannot be parsed.
  - Deduplication: proc beats bare for the same Chave.
  - Deduplication: bare does not replace an existing proc.
  - Deduplication: first bare wins when no proc exists.
  - Document output preserves input order by first encounter.
  - Processes multiple files of different types correctly.
  - Output contract: all four arrays present with correct types.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
)]

param()

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Resolve-DFeXmlFile' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {
            $Script:Command = Get-Command -Name Resolve-DFeXmlFile -ErrorAction Stop

            $Script:Chave1 = '35260112345678000199550010000000011234567890'
            $Script:Chave2 = '35260112345678000199550010000000021234567890'

            function New-FakeFile {
                [CmdletBinding()]
                [OutputType([System.IO.FileInfo])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Name
                )

                $path = Join-Path -Path $TestDrive -ChildPath $Name
                [System.IO.File]::WriteAllText($path, '<xml/>')
                [System.IO.FileInfo]::new($path)
            }

            function New-DocumentMeta {
                [CmdletBinding()]
                [OutputType([System.Management.Automation.PSCustomObject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Chave,

                    [Parameter()]
                    [bool]$IsProc = $false,

                    [Parameter()]
                    [System.IO.FileInfo]$File = $null
                )

                [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Documento
                    Chave  = $Chave
                    IsProc = $IsProc
                    File   = $File
                }
            }

            function New-EventoMeta {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$ChavePai,

                    [Parameter()]
                    [System.IO.FileInfo]$File = $null
                )

                [PSCustomObject]@{
                    Tipo     = [TipoXmlDFe]::Evento
                    ChavePai = $ChavePai
                    File     = $File
                }
            }

            function New-InutilizacaoMeta {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$IdInut,

                    [Parameter()]
                    [System.IO.FileInfo]$File = $null
                )

                [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Inutilizacao
                    IdInut = $IdInut
                    File   = $File
                }
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Candidates as mandatory' {
                $mandatory = $Script:Command.Parameters['Candidates'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Rejects null Candidates' {
                { Resolve-DFeXmlFile -Candidates $null } | Should -Throw
            }
        }
        #endregion

        #region Single file classification
        Context 'Single file classification' {

            It 'Classifies a bare document correctly' {
                $file = New-FakeFile -Name 'nfe.xml'
                $meta = New-DocumentMeta -Chave $Script:Chave1 -IsProc $false -File $file

                Mock -CommandName Get-DFeXmlMetadata -MockWith { $meta }

                $result = Resolve-DFeXmlFile -Candidates @($file)

                $result.Documents     | Should -HaveCount 1
                $result.Events        | Should -HaveCount 0
                $result.Inutilizacoes | Should -HaveCount 0
                $result.Unresolved    | Should -HaveCount 0
            }

            It 'Classifies a processed document correctly' {
                $file = New-FakeFile -Name 'nfeProc.xml'
                $meta = New-DocumentMeta -Chave $Script:Chave1 -IsProc $true -File $file

                Mock -CommandName Get-DFeXmlMetadata -MockWith { $meta }

                $result = Resolve-DFeXmlFile -Candidates @($file)

                $result.Documents[0].IsProc | Should -BeTrue
            }

            It 'Classifies an evento correctly' {
                $file = New-FakeFile -Name 'evento.xml'
                $meta = New-EventoMeta -ChavePai $Script:Chave1 -File $file

                Mock -CommandName Get-DFeXmlMetadata -MockWith { $meta }

                $result = Resolve-DFeXmlFile -Candidates @($file)

                $result.Events        | Should -HaveCount 1
                $result.Documents     | Should -HaveCount 0
                $result.Inutilizacoes | Should -HaveCount 0
                $result.Unresolved    | Should -HaveCount 0
            }

            It 'Classifies an inutilizacao correctly' {
                $file = New-FakeFile -Name 'inut.xml'
                $meta = New-InutilizacaoMeta -IdInut 'INUT001' -File $file

                Mock -CommandName Get-DFeXmlMetadata -MockWith { $meta }

                $result = Resolve-DFeXmlFile -Candidates @($file)

                $result.Inutilizacoes | Should -HaveCount 1
                $result.Documents     | Should -HaveCount 0
                $result.Events        | Should -HaveCount 0
                $result.Unresolved    | Should -HaveCount 0
            }
        }
        #endregion

        #region Unresolved files
        Context 'Unresolved files' {

            It 'Adds a file to Unresolved when Get-DFeXmlMetadata returns null' {
                $file = New-FakeFile -Name 'unknown.xml'

                Mock -CommandName Get-DFeXmlMetadata -MockWith { $null }

                $result = Resolve-DFeXmlFile -Candidates @($file)

                $result.Unresolved | Should -HaveCount 1
                $result.Unresolved[0].Name | Should -Be 'unknown.xml'
            }

            It 'Adds a file to Unresolved when Get-DFeXmlMetadata throws' {
                $file = New-FakeFile -Name 'malformed.xml'

                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    throw [System.Xml.XmlException]::new('Malformed XML.')
                }

                $result = Resolve-DFeXmlFile -Candidates @($file)

                $result.Unresolved | Should -HaveCount 1
            }

            It 'Does not throw when a file cannot be parsed' {
                $file = New-FakeFile -Name 'bad.xml'

                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    throw [System.Exception]::new('Parse error.')
                }

                { Resolve-DFeXmlFile -Candidates @($file) } | Should -Not -Throw
            }

            It 'Adds a file to Unresolved when metadata is an array' {
                $file = New-FakeFile -Name 'multi.xml'
                $meta = New-DocumentMeta -Chave $Script:Chave1 -File $file

                Mock -CommandName Get-DFeXmlMetadata -MockWith { @($meta, $meta) }

                $result = Resolve-DFeXmlFile -Candidates @($file)

                $result.Unresolved | Should -HaveCount 1
            }

            It 'Adds a file to Unresolved when Tipo is not a TipoXmlDFe' {
                $file = New-FakeFile -Name 'badtype.xml'

                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    [PSCustomObject]@{ Tipo = 'invalid' }
                }

                $result = Resolve-DFeXmlFile -Candidates @($file)

                $result.Unresolved | Should -HaveCount 1
            }

            It 'Adds a file to Unresolved when Chave is missing' {
                $file = New-FakeFile -Name 'nochave.xml'

                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        IsProc = $false
                    }
                }

                $result = Resolve-DFeXmlFile -Candidates @($file)

                $result.Unresolved | Should -HaveCount 1
            }

            It 'Adds a file to Unresolved when IsProc is not a bool' {
                $file = New-FakeFile -Name 'badproc.xml'

                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Chave  = $Script:Chave1
                        IsProc = 'yes'
                    }
                }

                $result = Resolve-DFeXmlFile -Candidates @($file)

                $result.Unresolved | Should -HaveCount 1
            }
        }
        #endregion

        #region Deduplication
        Context 'Deduplication' {

            It 'Proc beats bare for the same Chave' {
                $fileBare = New-FakeFile -Name 'dedup-bare.xml'
                $fileProc = New-FakeFile -Name 'dedup-proc.xml'

                $metaBare = New-DocumentMeta -Chave $Script:Chave1 -IsProc $false -File $fileBare
                $metaProc = New-DocumentMeta -Chave $Script:Chave1 -IsProc $true  -File $fileProc

                $Script:DedupCallCount = 0

                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    $Script:DedupCallCount++
                    if ($Script:DedupCallCount -eq 1) { $metaBare } else { $metaProc }
                }

                $result = Resolve-DFeXmlFile -Candidates @($fileBare, $fileProc)

                $result.Documents | Should -HaveCount 1
                $result.Documents[0].IsProc | Should -BeTrue
            }

            It 'Bare does not replace an existing proc' {
                $fileProc = New-FakeFile -Name 'dedup2-proc.xml'
                $fileBare = New-FakeFile -Name 'dedup2-bare.xml'

                $metaProc = New-DocumentMeta -Chave $Script:Chave1 -IsProc $true  -File $fileProc
                $metaBare = New-DocumentMeta -Chave $Script:Chave1 -IsProc $false -File $fileBare

                $Script:DedupCallCount = 0

                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    $Script:DedupCallCount++

                    if ($Script:DedupCallCount -eq 1) {
                        $metaProc
                    } else {
                        $metaBare
                    }
                }

                $result = Resolve-DFeXmlFile -Candidates @($fileProc, $fileBare)

                $result.Documents | Should -HaveCount 1
                $result.Documents[0].IsProc | Should -BeTrue
            }

            It 'First bare wins when no proc exists' {
                $fileFirst  = New-FakeFile -Name 'dedup3-first.xml'
                $fileSecond = New-FakeFile -Name 'dedup3-second.xml'

                $metaFirst  = New-DocumentMeta -Chave $Script:Chave1 -IsProc $false -File $fileFirst
                $metaSecond = New-DocumentMeta -Chave $Script:Chave1 -IsProc $false -File $fileSecond

                $Script:DedupCallCount = 0

                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    $Script:DedupCallCount++

                    if ($Script:DedupCallCount -eq 1) {
                        $metaFirst
                    } else {
                        $metaSecond
                    }
                }

                $result = Resolve-DFeXmlFile -Candidates @($fileFirst, $fileSecond)

                $result.Documents | Should -HaveCount 1
                $result.Documents[0].File.Name | Should -Be 'dedup3-first.xml'
            }
        }
        #endregion

        #region Order preservation
        Context 'Order preservation' {

            It 'Preserves input order by first encounter' {
                $file1 = New-FakeFile -Name 'order-1.xml'
                $file2 = New-FakeFile -Name 'order-2.xml'

                $meta1 = New-DocumentMeta -Chave $Script:Chave1 -IsProc $false -File $file1
                $meta2 = New-DocumentMeta -Chave $Script:Chave2 -IsProc $false -File $file2

                $Script:OrderCallCount = 0

                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    $Script:OrderCallCount++

                    if ($Script:OrderCallCount -eq 1) {
                        $meta1
                    } else {
                        $meta2
                    }
                }

                $result = Resolve-DFeXmlFile -Candidates @($file1, $file2)

                $result.Documents[0].File.Name | Should -Be 'order-1.xml'
                $result.Documents[1].File.Name | Should -Be 'order-2.xml'
            }

            It 'Proc replacement retains original position' {
                $file1    = New-FakeFile -Name 'order-pos-bare.xml'
                $file2    = New-FakeFile -Name 'order-pos-other.xml'
                $fileProc = New-FakeFile -Name 'order-pos-proc.xml'

                $meta1    = New-DocumentMeta -Chave $Script:Chave1 -IsProc $false -File $file1
                $meta2    = New-DocumentMeta -Chave $Script:Chave2 -IsProc $false -File $file2
                $metaProc = New-DocumentMeta -Chave $Script:Chave1 -IsProc $true  -File $fileProc

                $Script:PosCallCount = 0

                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    $Script:PosCallCount++

                    switch ($Script:PosCallCount) {
                        1 { $meta1    }
                        2 { $meta2    }
                        3 { $metaProc }
                    }
                }

                $result = Resolve-DFeXmlFile -Candidates @($file1, $file2, $fileProc)

                $result.Documents | Should -HaveCount 2
                $result.Documents[0].Chave | Should -Be $Script:Chave1
                $result.Documents[0].IsProc | Should -BeTrue
                $result.Documents[1].Chave | Should -Be $Script:Chave2
            }
        }
        #endregion

        #region Mixed classification
        Context 'Mixed classification' {

            It 'Processes multiple files of different types correctly' {
                $fileDoc  = New-FakeFile -Name 'mixed-doc.xml'
                $fileEvt  = New-FakeFile -Name 'mixed-evt.xml'
                $fileInut = New-FakeFile -Name 'mixed-inut.xml'
                $fileUnk  = New-FakeFile -Name 'mixed-unk.xml'

                $metaDoc  = New-DocumentMeta    -Chave    $Script:Chave1 -File $fileDoc
                $metaEvt  = New-EventoMeta      -ChavePai $Script:Chave1 -File $fileEvt
                $metaInut = New-InutilizacaoMeta -IdInut  'INUT001'      -File $fileInut

                $Script:MixedCallCount = 0

                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    $Script:MixedCallCount++

                    switch ($Script:MixedCallCount) {
                        1 { $metaDoc  }
                        2 { $metaEvt  }
                        3 { $metaInut }
                        4 { $null     }
                    }
                }

                $candidates = @($fileDoc, $fileEvt, $fileInut, $fileUnk)
                $result     = Resolve-DFeXmlFile -Candidates $candidates

                $result.Documents     | Should -HaveCount 1
                $result.Events        | Should -HaveCount 1
                $result.Inutilizacoes | Should -HaveCount 1
                $result.Unresolved    | Should -HaveCount 1
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {
                $file = New-FakeFile -Name 'contract.xml'
                $meta = New-DocumentMeta -Chave $Script:Chave1 -File $file

                Mock -CommandName Get-DFeXmlMetadata -MockWith { $meta }

                $Script:Sample = Resolve-DFeXmlFile -Candidates @($file)
            }

            It 'Returns a PSCustomObject' {
                $Script:Sample | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly the documented properties' {
                $expected = @('Documents', 'Events', 'Inutilizacoes', 'Unresolved')
                $actual   = @($Script:Sample.PSObject.Properties.Name)

                $actual | Should -Be $expected
            }

            It 'Documents is an array' {
                @($Script:Sample.Documents).GetType().IsArray | Should -BeTrue
            }

            It 'Events is an array' {
                @($Script:Sample.Events).GetType().IsArray | Should -BeTrue
            }

            It 'Inutilizacoes is an array' {
                @($Script:Sample.Inutilizacoes).GetType().IsArray | Should -BeTrue
            }

            It 'Unresolved is an array' {
                @($Script:Sample.Unresolved).GetType().IsArray | Should -BeTrue
            }
        }
        #endregion
    }
}
