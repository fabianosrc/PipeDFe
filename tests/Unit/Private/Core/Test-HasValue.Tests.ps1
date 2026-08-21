#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Test-HasValue.

.DESCRIPTION
Validates the public behavior of Test-HasValue, including:

  - Null input.
  - Empty and whitespace-only strings.
  - Non-empty strings.
  - Empty and non-empty arrays.
  - Empty and non-empty generic lists.
  - Empty and non-empty hashtables.
  - Empty and non-empty generic enumerables.
  - Zero and $false as valid values.
  - PSCustomObject instances as valid values.
  - Scalar values as valid values.
  - Explicitly passing a collection as a single argument.
  - Pipeline input.
  - One Boolean result per pipeline input.
  - Boolean output type.

The tests validate observable behavior rather than implementation details.
#>

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that is when Context/It are executed to register the test tree.
# If the module isn't loaded at that point, InModuleScope fails before any
# BeforeAll or BeforeEach can run.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $modulePath -Force -Global -ErrorAction Stop
}

Describe 'Test-HasValue' {

    InModuleScope -ModuleName PipeDFe {

        #region Null and empty values
        Context 'Null and empty values' {

            It 'Returns false for null passed explicitly' {
                Test-HasValue -InputObject $null | Should -BeFalse
            }

            It 'Returns false for null passed through the pipeline' {
                $result = @($null) | Test-HasValue

                $result | Should -BeFalse
            }

            It 'Returns false for an empty string' {
                Test-HasValue -InputObject '' | Should -BeFalse
            }

            It 'Returns false for a whitespace-only string' {
                Test-HasValue -InputObject '   ' | Should -BeFalse
            }

            It 'Returns false for a tab and newline string' {
                Test-HasValue -InputObject "`t`n" | Should -BeFalse
            }

            It 'Returns false for an empty array' {
                Test-HasValue -InputObject @() | Should -BeFalse
            }

            It 'Returns false for an empty generic list' {
                $list = [System.Collections.Generic.List[string]]::new()

                Test-HasValue -InputObject $list | Should -BeFalse
            }

            It 'Returns false for an empty hashtable' {
                Test-HasValue -InputObject @{} | Should -BeFalse
            }

            It 'Returns false for an empty generic enumerable' {
                $enumerable = [System.Linq.Enumerable]::Empty[int]()

                Test-HasValue -InputObject $enumerable | Should -BeFalse
            }
        }
        #endregion

        #region Values considered meaningful
        Context 'Values considered meaningful' {

            It 'Returns true for a non-empty string' {
                Test-HasValue -InputObject 'hello' | Should -BeTrue
            }

            It 'Returns true for a non-empty array' {
                Test-HasValue -InputObject @(1, 2, 3) | Should -BeTrue
            }

            It 'Returns true for a non-empty generic list' {
                $list = [System.Collections.Generic.List[string]]::new()
                $list.Add('value')

                Test-HasValue -InputObject $list | Should -BeTrue
            }

            It 'Returns true for a non-empty hashtable' {
                Test-HasValue -InputObject @{ Key = 'Value' } | Should -BeTrue
            }

            It 'Returns true for a non-empty generic enumerable' {
                $enumerable = [System.Linq.Enumerable]::Range(1, 3)

                Test-HasValue -InputObject $enumerable | Should -BeTrue
            }

            It 'Returns true for zero' {
                Test-HasValue -InputObject 0 | Should -BeTrue
            }

            It 'Returns true for a negative integer' {
                Test-HasValue -InputObject -1 | Should -BeTrue
            }

            It 'Returns true for a positive integer' {
                Test-HasValue -InputObject 42 | Should -BeTrue
            }

            It 'Returns true for $false' {
                Test-HasValue -InputObject $false | Should -BeTrue
            }

            It 'Returns true for $true' {
                Test-HasValue -InputObject $true | Should -BeTrue
            }

            It 'Returns true for an empty PSCustomObject' {
                $object = [PSCustomObject]@{}

                Test-HasValue -InputObject $object | Should -BeTrue
            }

            It 'Returns true for a PSCustomObject with properties' {
                $object = [PSCustomObject]@{
                    Name = 'Test'
                }

                Test-HasValue -InputObject $object | Should -BeTrue
            }
        }
        #endregion

        #region Argument semantics
        Context 'Argument semantics' {

            It 'Treats a collection passed as InputObject as a single object' {
                $result = Test-HasValue -InputObject @(1, 2, 3)

                $result | Should -BeTrue
                $result | Should -BeOfType [bool]
            }

            It 'Returns false for an empty collection passed as InputObject' {
                $result = Test-HasValue -InputObject @()

                $result | Should -BeFalse
                $result | Should -BeOfType [bool]
            }
        }
        #endregion

        #region Pipeline support
        Context 'Pipeline support' {

            It 'Returns true when a non-empty string is passed through the pipeline' {
                $result = 'hello' | Test-HasValue

                $result | Should -BeTrue
            }

            It 'Returns false when an empty string is passed through the pipeline' {
                $result = '' | Test-HasValue

                $result | Should -BeFalse
            }

            It 'Evaluates each pipeline input independently' {
                $results = @('hello', '', 0, $false, $null) | Test-HasValue

                $results | Should -HaveCount 5
                $results | Should -Be @($true, $false, $true, $true, $false)
            }

            It 'Returns one Boolean result for each pipeline input' {
                $results = @('one', 'two', 'three') | Test-HasValue

                $results | Should -HaveCount 3
                $results | ForEach-Object { $_ | Should -BeOfType [bool] }
            }

            It 'Preserves result cardinality for mixed pipeline input' {
                $inputObjects = @(
                    $null
                    ''
                    'value'
                    @()
                    @(1)
                    0
                    $false
                    [PSCustomObject]@{}
                )

                $results = $inputObjects | Test-HasValue

                $results | Should -HaveCount $inputObjects.Count
            }

            It 'Returns true for every meaningful scalar in the pipeline' {
                $results = @(0, 1, -1, $true, $false) | Test-HasValue

                $results | Should -Be @($true, $true, $true, $true, $true)
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            It 'Returns a Boolean for a string input' {
                $result = Test-HasValue -InputObject 'hello'

                $result | Should -BeOfType [bool]
            }

            It 'Returns a Boolean for a null input' {
                $result = Test-HasValue -InputObject $null

                $result | Should -BeOfType [bool]
            }

            It 'Returns a Boolean for an empty collection' {
                $result = Test-HasValue -InputObject @()

                $result | Should -BeOfType [bool]
            }

            It 'Returns only Boolean values for multiple pipeline inputs' {
                $results = @(
                    $null
                    ''
                    'hello'
                    0
                    $false
                    ,@()
                    @(1)
                    @{}
                    @{ Key = 'Value' }
                ) | Test-HasValue

                $results | Should -HaveCount 9

                foreach ($result in $results) {
                    $result | Should -BeOfType [bool]
                }
            }
        }
        #endregion
    }
}
