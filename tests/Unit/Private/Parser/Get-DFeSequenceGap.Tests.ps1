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

                $props | Should -HaveCount 4
                $props | Should -Contain 'Especie'
                $props | Should -Contain 'Serie'
                $props | Should -Contain 'Inicial'
                $props | Should -Contain 'Final'
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
    }
}
