#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Add-TypeName.

.DESCRIPTION
Verifies that Add-TypeName correctly decorates PSObjects with ETS type names
and DefaultDisplayPropertySet without modifying the object's properties.

Coverage includes:
  - InputObject is mandatory and rejects null.
  - TypeName is mandatory and rejects empty.
  - Namespace defaults to PipeDFe.
  - Assigns the correct fully-qualified ETS type name.
  - Does not assign duplicate type names on repeated calls.
  - Custom Namespace produces the correct type name.
  - DefaultDisplayProperties registers the DefaultDisplayPropertySet.
  - Replaces an existing PSStandardMembers without throwing.
  - Throws MissingDisplayProperty when a listed property does not exist.
  - Does not add null properties to the object.
  - Returns the same object instance (decorates in place).
  - Accepts pipeline input.
  - Processes multiple pipeline objects independently.
  - Output type is PSObject.
#>

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Add-TypeName' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Add-TypeName -ErrorAction Stop

            function New-TestObject {
                [CmdletBinding()]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                    'PSUseShouldProcessForStateChangingFunctions',
                    '',
                    Justification = 'ShouldProcess would add no value here.'
                )]
                param ()

                [PSCustomObject]@{
                    Cnpj        = '12345678000199'
                    RazaoSocial = 'Test Company'
                    IsActive    = $true
                }
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares InputObject as mandatory' {
                $mandatory = $Script:Command.Parameters['InputObject'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares TypeName as mandatory' {
                $mandatory = $Script:Command.Parameters['TypeName'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Rejects a null InputObject' {
                { Add-TypeName -InputObject $null -TypeName 'Company' } | Should -Throw
            }

            It 'Rejects an empty TypeName' {
                { Add-TypeName -InputObject (New-TestObject) -TypeName '' } | Should -Throw
            }

            It 'Uses PipeDFe as the default Namespace' {
                $obj = New-TestObject

                $result = Add-TypeName -InputObject $obj -TypeName 'Company'

                $result.PSObject.TypeNames[0] | Should -Be 'PipeDFe.Company'
            }
        }
        #endregion

        #region Type name assignment
        Context 'Type name assignment' {

            It 'Assigns the correct fully-qualified ETS type name' {
                $obj    = New-TestObject
                $result = Add-TypeName -InputObject $obj -TypeName 'Company'

                $result.PSObject.TypeNames | Should -Contain 'PipeDFe.Company'
            }

            It 'Inserts the type name at position 0' {
                $obj    = New-TestObject
                $result = Add-TypeName -InputObject $obj -TypeName 'Company'

                $result.PSObject.TypeNames[0] | Should -Be 'PipeDFe.Company'
            }

            It 'Uses a custom Namespace when provided' {
                $obj    = New-TestObject
                $result = Add-TypeName -InputObject $obj -TypeName 'Company' -Namespace 'Custom'

                $result.PSObject.TypeNames | Should -Contain 'Custom.Company'
            }

            It 'Does not add duplicate type names on repeated calls' {
                $obj = New-TestObject

                Add-TypeName -InputObject $obj -TypeName 'Company' | Out-Null
                Add-TypeName -InputObject $obj -TypeName 'Company' | Out-Null

                $count = @(
                    $obj.PSObject.TypeNames |
                        Where-Object { $_ -eq 'PipeDFe.Company' }
                ).Count

                $count | Should -Be 1
            }
        }
        #endregion

        #region DefaultDisplayProperties
        Context 'DefaultDisplayProperties' {

            It 'Registers the DefaultDisplayPropertySet' {
                $obj    = New-TestObject

                $typeNameParams = @{
                    InputObject              = $obj
                    TypeName                 = 'Company'
                    DefaultDisplayProperties = @('Cnpj', 'RazaoSocial')

                }

                $result = Add-TypeName @typeNameParams

                $members = $result.PSObject.Members['PSStandardMembers']
                $members | Should -Not -BeNullOrEmpty
            }

            It 'Sets the correct properties in DefaultDisplayPropertySet' {
                $obj = New-TestObject

                $typeNameParams = @{
                    InputObject              = $obj
                    TypeName                 = 'Company'
                    DefaultDisplayProperties = @('Cnpj', 'RazaoSocial')
                }

                $result = Add-TypeName @typeNameParams

                $standardMembers = $result.PSObject.Members['PSStandardMembers']

                $displaySet = $standardMembers.DefaultDisplayPropertySet
                $displaySet.ReferencedPropertyNames | Should -Be @('Cnpj', 'RazaoSocial')
            }

            It 'Replaces an existing PSStandardMembers without throwing' {
                $obj = New-TestObject

                $typeNameParams = @{
                    InputObject              = $obj
                    TypeName                 = 'Company'
                    DefaultDisplayProperties = 'Cnpj'
                }

                Add-TypeName @typeNameParams | Out-Null

                $typeNameParamsTwo = @{
                    InputObject              = $obj
                    TypeName                 = 'Company'
                    DefaultDisplayProperties = 'RazaoSocial'
                }

                { Add-TypeName @typeNameParamsTwo } | Should -Not -Throw
            }

            It 'Throws MissingDisplayProperty when a listed property does not exist' {
                $obj    = New-TestObject
                $thrown = $null

                $typeNameParams = @{
                    InputObject              = $obj
                    TypeName                 = 'Company'
                    DefaultDisplayProperties = 'NonExistentProperty'
                    ErrorAction              = 'Stop'
                }

                try {
                    Add-TypeName @typeNameParams
                } catch {
                    $thrown = $_
                }

                $thrown.FullyQualifiedErrorId | Should -BeLike 'MissingDisplayProperty*'
            }

            It 'Uses InvalidArgument category for MissingDisplayProperty' {
                $obj    = New-TestObject
                $thrown = $null

                $typeNameParams = @{
                    InputObject              = $obj
                    TypeName                 = 'Company'
                    DefaultDisplayProperties = 'NonExistentProperty'
                    ErrorAction              = 'Stop'
                }

                try {
                    Add-TypeName @typeNameParams
                } catch {
                    $thrown = $_
                }

                $thrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidArgument)
            }

            It 'Does not add null properties to the object' {
                $obj = New-TestObject

                $typeNameParams = @{
                    InputObject              = $obj
                    TypeName                 = 'Company'
                    DefaultDisplayProperties = 'NonExistentProperty'
                    ErrorAction              = 'Stop'
                }

                try {
                    Add-TypeName @typeNameParams
                } catch {
                    $null = $_
                }

                $obj.PSObject.Properties.Name | Should -Not -Contain 'NonExistentProperty'
            }
        }
        #endregion

        #region Object identity
        Context 'Object identity' {

            It 'Returns the same object instance' {
                $obj    = New-TestObject
                $result = Add-TypeName -InputObject $obj -TypeName 'Company'

                [System.Object]::ReferenceEquals($result, $obj) | Should -BeTrue
            }

            It 'Does not add unexpected properties to the object' {
                $obj      = New-TestObject
                $before   = @($obj.PSObject.Properties.Name)

                Add-TypeName -InputObject $obj -TypeName 'Company' | Out-Null

                $after = @($obj.PSObject.Properties.Name)

                $after | Should -Be $before
            }
        }
        #endregion

        #region Pipeline support
        Context 'Pipeline support' {

            It 'Accepts InputObject from the pipeline' {
                $obj    = New-TestObject
                $result = $obj | Add-TypeName -TypeName 'Company'

                $result.PSObject.TypeNames | Should -Contain 'PipeDFe.Company'
            }

            It 'Processes multiple pipeline objects independently' {
                $obj1 = New-TestObject
                $obj2 = New-TestObject

                $results = @($obj1, $obj2 | Add-TypeName -TypeName 'Company')

                $results | Should -HaveCount 2
                $results[0].PSObject.TypeNames | Should -Contain 'PipeDFe.Company'
                $results[1].PSObject.TypeNames | Should -Contain 'PipeDFe.Company'
            }
        }
        #endregion
    }
}
