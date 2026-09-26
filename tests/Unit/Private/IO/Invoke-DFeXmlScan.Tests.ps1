#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Invoke-DFeXmlScan operational failure handling.

.DESCRIPTION
Verifies that Invoke-DFeXmlScan distinguishes content rejection from
operational failure.

Malformed or unrecognized XML remains isolated to the affected file and
increments FilesIgnored. Failures while reading indexed hashes, enumerating
the source tree, hashing files, or persisting metadata terminate the scan.

All private dependencies and file-system commands are mocked. No real SQLite
database or source directory is used.

Coverage includes:
  - Reads indexed hashes without suppressing failures.
  - Wraps source-tree enumeration failures with DFeXmlScanEnumerationFailed.
  - Ignores InvalidXml while continuing the scan.
  - Ignores null metadata while continuing the scan.
  - Propagates unexpected metadata extraction failures.
  - Propagates file hashing failures.
  - Propagates document persistence failures.
  - Propagates event persistence failures.
  - Propagates inutilizacao persistence failures.
  - Adds hashes only after successful persistence.
  - Returns the expected scan counters.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
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

Describe 'Invoke-DFeXmlScan' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Cnpj    = '12345678000199'
            $Script:XmlPath = 'C:\xml'

            $Script:FileOne = [pscustomobject]@{
                Name     = 'one.xml'
                FullName = 'C:\xml\one.xml'
            }

            $Script:FileTwo = [pscustomobject]@{
                Name     = 'two.xml'
                FullName = 'C:\xml\two.xml'
            }

            $Script:HashOne = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            $Script:HashTwo = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

            function New-TestMetadata {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [TipoXmlDFe]$Tipo,

                    [Parameter(Mandatory)]
                    [pscustomobject]$File
                )

                [pscustomobject]@{
                    File       = $File
                    Tipo       = $Tipo
                    Modelo     = [ModeloDFe]::NFe
                    Root       = 'NFe'
                    IsProc     = $false
                    Chave      = '35260112345678000199550010000000011234567890'
                    ChavePai   = $null
                    EventoTipo = $null
                    TpEvento   = $null
                    DescEvento = $null
                    DhEmi      = '2026-08-15T10:00:00-03:00'
                    Ndoc       = '1'
                    Serie      = '001'
                    NNFIni     = $null
                    NNFFin     = $null
                    IdInut     = $null
                    cStat      = $null
                    xMotivo    = $null
                }
            }

            function Invoke-TestScan {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param ()

                $scanParams = @{
                    Cnpj        = $Script:Cnpj
                    XmlPath     = $Script:XmlPath
                    ErrorAction = 'Stop'
                }

                Invoke-DFeXmlScan @scanParams
            }

            function New-TestErrorRecord {
                [CmdletBinding()]
                [OutputType([System.Management.Automation.ErrorRecord])]
                param (
                    [Parameter(Mandatory)]
                    [string]$ErrorId,

                    [Parameter(Mandatory)]
                    [string]$Message,

                    [Parameter()]
                    [System.Management.Automation.ErrorCategory]$Category = (
                        [System.Management.Automation.ErrorCategory]::NotSpecified
                    )
                )

                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new($Message),
                    $ErrorId,
                    $Category,
                    $null
                )
            }
        }

        BeforeEach {

            Mock -CommandName Test-Path -MockWith {
                return $true
            }

            Mock -CommandName Get-DFeIndexedHash -MockWith {

            }

            Mock -CommandName Get-ChildItem -MockWith {
                return $Script:FileOne
            }

            Mock -CommandName Get-FileSha256 -MockWith {
                return $Script:HashOne
            }

            Mock -CommandName Get-DFeXmlMetadata -MockWith {
                $metadataParams = @{
                    Tipo = [TipoXmlDFe]::Documento
                    File = $Script:FileOne
                }

                return New-TestMetadata @metadataParams
            }

            Mock -CommandName Save-DFeDocumentEntry -MockWith {

            }

            Mock -CommandName Save-DFeEventoEntry -MockWith {

            }

            Mock -CommandName Save-DFeInutilizacaoEntry -MockWith {

            }
        }

        #region Indexed hash loading
        Context 'Indexed hash loading' {

            It 'Loads indexed hashes without SilentlyContinue' {
                Invoke-TestScan | Out-Null

                $shouldParams = @{
                    CommandName     = 'Get-DFeIndexedHash'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj -eq $Script:Cnpj -and
                        $ErrorAction -ne 'SilentlyContinue'
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Propagates IndexedHashesReadFailed' {
                Mock -CommandName Get-DFeIndexedHash -MockWith {
                    $errorParams = @{
                        ErrorId = 'IndexedHashesReadFailed'
                        Message = 'Index read failed.'
                    }

                    throw New-TestErrorRecord @errorParams
                }

                { Invoke-TestScan } | Should -Throw -ErrorId 'IndexedHashesReadFailed*'
            }
        }
        #endregion

        #region Source-tree enumeration
        Context 'Source-tree enumeration' {

            It 'Requests terminating errors from Get-ChildItem' {
                Invoke-TestScan | Out-Null

                $shouldParams = @{
                    CommandName     = 'Get-ChildItem'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $LiteralPath -eq $Script:XmlPath -and
                        $Filter -eq '*.xml' -and
                        $Recurse -eq $true -and
                        $File -eq $true -and
                        $ErrorAction -eq 'Stop'
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Wraps enumeration failures with DFeXmlScanEnumerationFailed' {
                Mock -CommandName Get-ChildItem -MockWith {
                    throw [System.UnauthorizedAccessException]::new('Access denied.')
                }

                { Invoke-TestScan } |
                    Should -Throw -ErrorId 'DFeXmlScanEnumerationFailed*'
            }
        }
        #endregion

        #region Content rejection
        Context 'Content rejection' {

            It 'Counts InvalidXml as ignored and continues with the next file' {
                Mock -CommandName Get-ChildItem -MockWith {
                    return @($Script:FileOne, $Script:FileTwo)
                }

                Mock -CommandName Get-FileSha256 -MockWith {
                    if ($Path -eq $Script:FileOne.FullName) {
                        return $Script:HashOne
                    }

                    return $Script:HashTwo
                }

                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    if ($Path -eq $Script:FileOne.FullName) {
                        $errorParams = @{
                            ErrorId  = 'InvalidXml'
                            Message  = 'Malformed XML.'
                            Category = [System.Management.Automation.ErrorCategory]::InvalidData
                        }

                        throw New-TestErrorRecord @errorParams
                    }

                    $metadataParams = @{
                        Tipo = [TipoXmlDFe]::Documento
                        File = $Script:FileTwo
                    }

                    return New-TestMetadata @metadataParams
                }

                $result = Invoke-TestScan

                $result.FilesFound   | Should -Be 2
                $result.FilesIndexed | Should -Be 1
                $result.FilesSkipped | Should -Be 0
                $result.FilesIgnored | Should -Be 1

                $shouldParams = @{
                    CommandName = 'Save-DFeDocumentEntry'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }

            It 'Counts null metadata as ignored and continues with the next file' {
                Mock -CommandName Get-ChildItem -MockWith {
                    return @($Script:FileOne, $Script:FileTwo)
                }

                Mock -CommandName Get-FileSha256 -MockWith {
                    if ($Path -eq $Script:FileOne.FullName) {
                        return $Script:HashOne
                    }

                    return $Script:HashTwo
                }

                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    if ($Path -eq $Script:FileOne.FullName) {
                        return $null
                    }

                    $metadataParams = @{
                        Tipo = [TipoXmlDFe]::Documento
                        File = $Script:FileTwo
                    }

                    return New-TestMetadata @metadataParams
                }

                $result = Invoke-TestScan

                $result.FilesFound   | Should -Be 2
                $result.FilesIndexed | Should -Be 1
                $result.FilesIgnored | Should -Be 1
            }

            It 'Propagates unexpected metadata extraction failures' {
                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    $errorParams = @{
                        ErrorId = 'MetadataExtractionFailed'
                        Message = 'Unexpected parser failure.'
                    }

                    throw New-TestErrorRecord @errorParams
                }

                { Invoke-TestScan } | Should -Throw -ErrorId 'MetadataExtractionFailed*'
            }
        }
        #endregion

        #region Operational file failures
        Context 'Operational file failures' {

            It 'Propagates FileSha256Failed' {
                Mock -CommandName Get-FileSha256 -MockWith {
                    $errorParams = @{
                        ErrorId  = 'FileSha256Failed'
                        Message  = 'Hash read failed.'
                        Category = [System.Management.Automation.ErrorCategory]::ReadError
                    }

                    throw New-TestErrorRecord @errorParams
                }

                { Invoke-TestScan } | Should -Throw -ErrorId 'FileSha256Failed*'
            }

            It 'Does not attempt metadata extraction after a hash failure' {
                Mock -CommandName Get-FileSha256 -MockWith {
                    throw [System.IO.IOException]::new('Hash read failed.')
                }

                { Invoke-TestScan } | Should -Throw

                $shouldParams = @{
                    CommandName = 'Get-DFeXmlMetadata'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Persistence failures
        Context 'Persistence failures' {

            It 'Propagates document persistence failure' {
                Mock -CommandName Save-DFeDocumentEntry -MockWith {
                    $errorParams = @{
                        ErrorId  = 'DocumentEntrySaveFailed'
                        Message  = 'Document write failed.'
                        Category = [System.Management.Automation.ErrorCategory]::WriteError
                    }

                    throw New-TestErrorRecord @errorParams
                }

                { Invoke-TestScan } | Should -Throw -ErrorId 'DocumentEntrySaveFailed*'
            }

            It 'Propagates event persistence failure' {
                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    $metadataParams = @{
                        Tipo = [TipoXmlDFe]::Evento
                        File = $Script:FileOne
                    }

                    return New-TestMetadata @metadataParams
                }

                Mock -CommandName Save-DFeEventoEntry -MockWith {
                    $errorParams = @{
                        ErrorId  = 'EventoEntrySaveFailed'
                        Message  = 'Event write failed.'
                        Category = [System.Management.Automation.ErrorCategory]::WriteError
                    }

                    throw New-TestErrorRecord @errorParams
                }

                { Invoke-TestScan } | Should -Throw -ErrorId 'EventoEntrySaveFailed*'
            }

            It 'Propagates inutilizacao persistence failure' {
                Mock -CommandName Get-DFeXmlMetadata -MockWith {
                    $metadataParams = @{
                        Tipo = [TipoXmlDFe]::Inutilizacao
                        File = $Script:FileOne
                    }

                    return New-TestMetadata @metadataParams
                }

                Mock -CommandName Save-DFeInutilizacaoEntry -MockWith {
                    $errorParams = @{
                        ErrorId  = 'InutilizacaoEntrySaveFailed'
                        Message  = 'Inutilizacao write failed.'
                        Category = [System.Management.Automation.ErrorCategory]::WriteError
                    }

                    throw New-TestErrorRecord @errorParams
                }

                { Invoke-TestScan } |
                    Should -Throw -ErrorId 'InutilizacaoEntrySaveFailed*'
            }
        }
        #endregion

        #region Hash lifecycle
        Context 'Hash lifecycle' {

            It 'Skips a file whose hash was already indexed' {
                Mock -CommandName Get-DFeIndexedHash -MockWith {
                    return $Script:HashOne
                }

                $result = Invoke-TestScan

                $result.FilesFound   | Should -Be 1
                $result.FilesIndexed | Should -Be 0
                $result.FilesSkipped | Should -Be 1
                $result.FilesIgnored | Should -Be 0

                $metadataShouldParams = @{
                    CommandName = 'Get-DFeXmlMetadata'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @metadataShouldParams
            }

            It 'Adds a new hash only after successful persistence' {
                Mock -CommandName Get-ChildItem -MockWith {
                    return @($Script:FileOne, $Script:FileTwo)
                }

                Mock -CommandName Get-FileSha256 -MockWith {
                    return $Script:HashOne
                }

                $result = Invoke-TestScan

                $result.FilesFound   | Should -Be 2
                $result.FilesIndexed | Should -Be 1
                $result.FilesSkipped | Should -Be 1

                $shouldParams = @{
                    CommandName = 'Save-DFeDocumentEntry'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }

            It 'Does not mark a failed save hash as indexed during the scan' {
                Mock -CommandName Get-ChildItem -MockWith {
                    return @($Script:FileOne, $Script:FileTwo)
                }

                Mock -CommandName Get-FileSha256 -MockWith {
                    return $Script:HashOne
                }

                Mock -CommandName Save-DFeDocumentEntry -MockWith {
                    throw [System.IO.IOException]::new('Write failed.')
                }

                { Invoke-TestScan } | Should -Throw

                $shouldParams = @{
                    CommandName = 'Save-DFeDocumentEntry'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Result contract
        Context 'Result contract' {

            It 'Returns zero counts when no XML files are found' {
                Mock -CommandName Get-ChildItem

                $result = Invoke-TestScan

                $result.FilesFound   | Should -Be 0
                $result.FilesIndexed | Should -Be 0
                $result.FilesSkipped | Should -Be 0
                $result.FilesIgnored | Should -Be 0
            }

            It 'Returns integer counters' {
                $result = Invoke-TestScan

                $result.FilesFound   | Should -BeOfType ([int])
                $result.FilesIndexed | Should -BeOfType ([int])
                $result.FilesSkipped | Should -BeOfType ([int])
                $result.FilesIgnored | Should -BeOfType ([int])
            }
        }
        #region
    }
}
