#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-DFeSequenceGap

.DESCRIPTION
Coverage includes:
  - Empty and null input contracts.
  - Contiguous sequences.
  - Single-entry sequences.
  - Duplicate ndoc values.
  - Single and multiple gaps.
  - Multiple series.
  - Multiple models.
  - Isolation between modelo and serie.
  - Unordered input.
  - Null, empty, and whitespace-only fields.
  - Supported DFe models.
  - Unsupported and excluded models.
  - Leading sequence numbers.
  - Return type and property contracts.
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

Describe 'Get-DFeSequenceGap' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            function New-TestDFeEntry {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [int]$Modelo,

                    [Parameter(Mandatory)]
                    [AllowNull()]
                    [object]$Ndoc,

                    [Parameter(Mandatory)]
                    [AllowNull()]
                    [AllowEmptyString()]
                    [string]$Serie
                )

                [PSCustomObject]@{
                    ChaveDFe = [guid]::NewGuid().ToString('N')
                    Modelo   = $Modelo
                    Ndoc     = $Ndoc
                    Serie    = $Serie
                }
            }
        }

        Context 'Empty input' {

            It 'Returns no output when Entries is empty' {
                $result = @(Get-DFeSequenceGap -Entries @())
                $result | Should -HaveCount 0
            }

            It 'Rejects null Entries' {
                { Get-DFeSequenceGap -Entries $null } | Should -Throw
            }
        }

        Context 'Contiguous sequence' {

            It 'Returns no output when the sequence is contiguous' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 2 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)
                $result | Should -HaveCount 0
            }

            It 'Returns no output for a single entry' {
                $entries = @(New-TestDFeEntry -Modelo 55 -Ndoc 42 -Serie '001')
                $result  = @(Get-DFeSequenceGap -Entries $entries)
                $result | Should -HaveCount 0
            }

            It 'Returns no output when entries have duplicate ndoc values' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 2 -Serie '001'
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)
                $result | Should -HaveCount 0
            }

            It 'Returns no output when the first observed ndoc is greater than one' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 5 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 6 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 7 -Serie '001'
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)
                $result | Should -HaveCount 0
            }
        }

        Context 'Single gap' {

            BeforeAll {

                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 2 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 5 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 6 -Serie '001'
                )

                $Script:Result = @(Get-DFeSequenceGap -Entries $entries)
            }

            It 'Returns exactly one gap' {
                $Script:Result | Should -HaveCount 1
            }

            It 'Returns the correct Inicial' {
                $Script:Result[0].Inicial | Should -Be 3
            }

            It 'Returns the correct Final' {
                $Script:Result[0].Final | Should -Be 4
            }

            It 'Returns the correct Especie' {
                $Script:Result[0].Especie | Should -Be 'NFe'
            }

            It 'Returns the correct Serie' {
                $Script:Result[0].Serie | Should -Be '001'
            }
        }

        Context 'Multiple gaps in the same serie' {

            BeforeAll {

                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 7 -Serie '001'
                )

                $Script:Result = @(Get-DFeSequenceGap -Entries $entries)
            }

            It 'Returns exactly two gaps' {
                $Script:Result | Should -HaveCount 2
            }

            It 'Returns the first gap correctly' {
                $Script:Result[0].Inicial | Should -Be 2
                $Script:Result[0].Final   | Should -Be 2
            }

            It 'Returns the second gap correctly' {
                $Script:Result[1].Inicial | Should -Be 4
                $Script:Result[1].Final   | Should -Be 6
            }
        }

        Context 'Multiple series' {

            BeforeAll {

                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '002'
                    New-TestDFeEntry -Modelo 55 -Ndoc 2 -Serie '002'
                )

                $Script:Result = @(Get-DFeSequenceGap -Entries $entries)
            }

            It 'Returns exactly one gap' {
                $Script:Result | Should -HaveCount 1
            }

            It 'Returns the gap only in serie 001' {
                $Script:Result[0].Serie   | Should -Be '001'
                $Script:Result[0].Inicial | Should -Be 2
                $Script:Result[0].Final   | Should -Be 2
            }
        }

        Context 'Modelo and serie isolation' {

            BeforeAll {

                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'

                    New-TestDFeEntry -Modelo 65 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 65 -Ndoc 2 -Serie '001'

                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '002'
                    New-TestDFeEntry -Modelo 55 -Ndoc 2 -Serie '002'
                )

                $Script:Result = @(Get-DFeSequenceGap -Entries $entries)
            }

            It 'Returns only the gap belonging to the correct modelo and serie' {
                $Script:Result | Should -HaveCount 1

                $Script:Result[0].Especie | Should -Be 'NFe'
                $Script:Result[0].Serie   | Should -Be '001'
                $Script:Result[0].Inicial | Should -Be 2
                $Script:Result[0].Final   | Should -Be 2
            }
        }

        Context 'Unordered input' {

            It 'Detects gaps regardless of input order' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 5 -Serie '001'
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)
                $result | Should -HaveCount 2

                $result[0].Inicial | Should -Be 2
                $result[0].Final   | Should -Be 2

                $result[1].Inicial | Should -Be 4
                $result[1].Final   | Should -Be 4
            }
        }

        Context 'Excluded entries' {

            It 'Excludes entries with null ndoc' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc $null -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)
                $result | Should -HaveCount 1

                $result[0].Inicial | Should -Be 2
                $result[0].Final   | Should -Be 2
            }

            It 'Excludes entries with null serie' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie $null
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie $null
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)
                $result | Should -HaveCount 0
            }

            It 'Excludes entries with empty serie' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie ''
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie ''
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)
                $result | Should -HaveCount 0
            }

            It 'Excludes entries with whitespace-only serie' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '   '
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie "`t"
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)
                $result | Should -HaveCount 0
            }

            It 'Excludes unsupported models' {
                $entries = @(
                    New-TestDFeEntry -Modelo 99 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 99 -Ndoc 3 -Serie '001'
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)
                $result | Should -HaveCount 0
            }

            It 'Excludes NFS-e from gap analysis' {
                $entries = @(
                    New-TestDFeEntry -Modelo 67 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 67 -Ndoc 3 -Serie '001'
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)
                $result | Should -HaveCount 0
            }
        }

        Context 'Supported models' {

            It 'Analyzes NF-e (55)' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)

                $result | Should -HaveCount 1
                $result[0].Especie | Should -Be 'NFe'
            }

            It 'Analyzes NFC-e (65)' {
                $entries = @(
                    New-TestDFeEntry -Modelo 65 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 65 -Ndoc 3 -Serie '001'
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)

                $result | Should -HaveCount 1
                $result[0].Especie | Should -Be 'NFCe'
            }

            It 'Analyzes NFCom (62)' {
                $entries = @(
                    New-TestDFeEntry -Modelo 62 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 62 -Ndoc 3 -Serie '001'
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)

                $result | Should -HaveCount 1
                $result[0].Especie | Should -Be 'NFCom'
            }

            It 'Analyzes CT-e (57)' {
                $entries = @(
                    New-TestDFeEntry -Modelo 57 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 57 -Ndoc 3 -Serie '001'
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)

                $result | Should -HaveCount 1
                $result[0].Especie | Should -Be 'CTe'
            }

            It 'Analyzes MDF-e (58)' {
                $entries = @(
                    New-TestDFeEntry -Modelo 58 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 58 -Ndoc 3 -Serie '001'
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)

                $result | Should -HaveCount 1
                $result[0].Especie | Should -Be 'MDFe'
            }
        }

        Context 'Return contract' {

            BeforeAll {

                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                )

                $Script:Result = @(Get-DFeSequenceGap -Entries $entries)
            }

            It 'Returns exactly one object' {
                $Script:Result | Should -HaveCount 1
            }

            It 'Returns a PSCustomObject' {
                $Script:Result[0] | Should -BeOfType ([PSCustomObject])
            }

            It 'Returns exactly the documented properties' {
                $props = @($Script:Result[0].PSObject.Properties.Name)

                $props | Should -HaveCount 5
                $props | Should -Contain 'Tipo'
                $props | Should -Contain 'Especie'
                $props | Should -Contain 'Serie'
                $props | Should -Contain 'Inicial'
                $props | Should -Contain 'Final'
            }

            It 'Returns Tipo as string' {
                $Script:Result[0].Tipo | Should -BeOfType ([string])
            }

            It 'Returns Especie as string' {
                $Script:Result[0].Especie | Should -BeOfType ([string])
            }

            It 'Returns Serie as string' {
                $Script:Result[0].Serie | Should -BeOfType ([string])
            }

            It 'Returns Inicial as int' {
                $Script:Result[0].Inicial | Should -BeOfType ([int])
            }

            It 'Returns Final as int' {
                $Script:Result[0].Final | Should -BeOfType ([int])
            }
        }

        Context 'CoveredRanges omitted or empty' {

            It 'Classifies all gaps as Faltante when CoveredRanges is not supplied' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                )

                $result = @(Get-DFeSequenceGap -Entries $entries)

                $result | Should -HaveCount 1
                $result[0].Tipo | Should -Be 'Faltante'
            }

            It 'Classifies all gaps as Faltante when CoveredRanges is empty' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                )

                $result = @(Get-DFeSequenceGap -Entries $entries -CoveredRanges @())

                $result | Should -HaveCount 1
                $result[0].Tipo | Should -Be 'Faltante'
            }
        }

        Context 'CoveredRanges - Inutilizada classification' {

            BeforeAll {

                function New-TestCoveredRange {
                    [CmdletBinding()]
                    [OutputType([pscustomobject])]
                    param (
                        [Parameter(Mandatory)]
                        [int]$Modelo,

                        [Parameter(Mandatory)]
                        [string]$Serie,

                        [Parameter(Mandatory)]
                        [int]$NnfIni,

                        [Parameter(Mandatory)]
                        [int]$NnfFin
                    )

                    [PSCustomObject]@{
                        modelo  = $Modelo
                        serie   = $Serie
                        nnf_ini = $NnfIni
                        nnf_fin = $NnfFin
                    }
                }
            }

            It 'Classifies a gap as Inutilizada when fully covered' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                )

                $covered = @(
                    New-TestCoveredRange -Modelo 55 -Serie '001' -NnfIni 2 -NnfFin 2
                )

                $result = @(Get-DFeSequenceGap -Entries $entries -CoveredRanges $covered)

                $result | Should -HaveCount 1
                $result[0].Tipo    | Should -Be 'Inutilizada'
                $result[0].Inicial | Should -Be 2
                $result[0].Final   | Should -Be 2
            }

            It 'Splits a gap into Faltante and Inutilizada when partially covered' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 5 -Serie '001'
                )

                # Numbers 2, 3, 4 are missing. Only 3 is covered.
                $covered = @(
                    New-TestCoveredRange -Modelo 55 -Serie '001' -NnfIni 3 -NnfFin 3
                )

                $result = @(Get-DFeSequenceGap -Entries $entries -CoveredRanges $covered)

                $result | Should -HaveCount 3

                $result[0].Tipo    | Should -Be 'Faltante'
                $result[0].Inicial | Should -Be 2
                $result[0].Final   | Should -Be 2

                $result[1].Tipo    | Should -Be 'Inutilizada'
                $result[1].Inicial | Should -Be 3
                $result[1].Final   | Should -Be 3

                $result[2].Tipo    | Should -Be 'Faltante'
                $result[2].Inicial | Should -Be 4
                $result[2].Final   | Should -Be 4
            }

            It 'Merges contiguous Inutilizada numbers into a single range' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 5 -Serie '001'
                )

                $covered = @(
                    New-TestCoveredRange -Modelo 55 -Serie '001' -NnfIni 2 -NnfFin 4
                )

                $result = @(Get-DFeSequenceGap -Entries $entries -CoveredRanges $covered)

                $result | Should -HaveCount 1
                $result[0].Tipo    | Should -Be 'Inutilizada'
                $result[0].Inicial | Should -Be 2
                $result[0].Final   | Should -Be 4
            }

            It 'Ignores CoveredRanges entries for a different modelo' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                )

                $covered = @(
                    New-TestCoveredRange -Modelo 65 -Serie '001' -NnfIni 2 -NnfFin 2
                )

                $result = @(Get-DFeSequenceGap -Entries $entries -CoveredRanges $covered)

                $result | Should -HaveCount 1
                $result[0].Tipo | Should -Be 'Faltante'
            }

            It 'Ignores CoveredRanges entries for a different serie' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                )

                $covered = @(
                    New-TestCoveredRange -Modelo 55 -Serie '002' -NnfIni 2 -NnfFin 2
                )

                $result = @(Get-DFeSequenceGap -Entries $entries -CoveredRanges $covered)

                $result | Should -HaveCount 1
                $result[0].Tipo | Should -Be 'Faltante'
            }

            It 'Silently skips CoveredRanges entries with null modelo' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                )

                $covered = @(
                    [PSCustomObject]@{
                        modelo  = $null
                        serie   = '001'
                        nnf_ini = 2
                        nnf_fin = 2
                    }
                )

                $result = @(Get-DFeSequenceGap -Entries $entries -CoveredRanges $covered)

                $result | Should -HaveCount 1
                $result[0].Tipo | Should -Be 'Faltante'
            }

            It 'Silently skips CoveredRanges entries with null serie' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                )

                $covered = @(
                    [PSCustomObject]@{
                        modelo  = 55
                        serie   = $null
                        nnf_ini = 2
                        nnf_fin = 2
                    }
                )

                $result = @(Get-DFeSequenceGap -Entries $entries -CoveredRanges $covered)

                $result | Should -HaveCount 1
                $result[0].Tipo | Should -Be 'Faltante'
            }

            It 'Silently skips CoveredRanges entries with null nnf_ini' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                )

                $covered = @(
                    [PSCustomObject]@{
                        modelo  = 55
                        serie   = '001'
                        nnf_ini = $null
                        nnf_fin = 2
                    }
                )

                $result = @(Get-DFeSequenceGap -Entries $entries -CoveredRanges $covered)

                $result | Should -HaveCount 1
                $result[0].Tipo | Should -Be 'Faltante'
            }

            It 'Silently skips CoveredRanges entries with null nnf_fin' {
                $entries = @(
                    New-TestDFeEntry -Modelo 55 -Ndoc 1 -Serie '001'
                    New-TestDFeEntry -Modelo 55 -Ndoc 3 -Serie '001'
                )

                $covered = @(
                    [PSCustomObject]@{
                        modelo  = 55
                        serie   = '001'
                        nnf_ini = 2
                        nnf_fin = $null
                    }
                )

                $result = @(Get-DFeSequenceGap -Entries $entries -CoveredRanges $covered)

                $result | Should -HaveCount 1
                $result[0].Tipo | Should -Be 'Faltante'
            }
        }
    }
}
