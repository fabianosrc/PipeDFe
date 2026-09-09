#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-PipeDFeSequenceGap.

.DESCRIPTION
All external dependencies are mocked. No filesystem or database I/O occurs.

Coverage includedes:
  - Parameter contract
  - CNPJ normalization
  - Date range resolution - no dates, StartDate only, both dates
  - EndDate without StartDate propagation
  - Empty entries - no pipeline output
  - Gap detection - results forwarded to the pipeline
  - No gaps detected - no pipeline output
  - Output contract
#>

BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Get-PipeDFeSequenceGap' {

    InModuleScope PipeDFe {

        BeforeAll {

            $Script:CnpjInput      = '12.345.678/0001-95'
            $Script:CnpjNormalized = '12345678000195'

            $Script:StartDate = '01/08/2026'
            $Script:EndDate   = '31/08/2026'

            $Script:StartIso = '2026-08-01T00:00:00+00:00'
            $Script:EndIso   = '2026-08-31T23:59:59+00:00'

            $Script:DateRange = [PSCustomObject]@{
                Start = [System.DateTimeOffset]::Parse($Script:StartIso)
                End   = [System.DateTimeOffset]::Parse($Script:EndIso)
            }

            $Script:Entry = [PSCustomObject]@{
                chave_acesso = '35260812345678000195550010000000011234567890'
                modelo       = 55
                dh_emi       = $Script:StartIso
                file_path    = 'C:\DFe\nfe.xml'
                is_proc      = $true
                ndoc         = 1
                serie        = '001'
                sha256       = 'abc123'
                indexed_at   = $Script:StartIso
            }

            $Script:Gap = [PSCustomObject]@{
                Especie = 'NFe'
                Serie   = '001'
                Inicial = 2
                Final   = 4
            }

            $Script:ResolveDateRangeMock = { return $Script:dateRange }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            BeforeAll {

                $Script:command = Get-Command -Name Get-PipeDFeSequenceGap
            }

            It 'Requires Cnpj' {
                $Script:command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |

                    ForEach-Object { $_.Mandatory | Should -BeTrue }
            }

            It 'Declares Cnpj as string' {
                $Script:command.Parameters['Cnpj'].ParameterType |
                    Should -Be ([string])
            }

            It 'Declares StartDate as optional string' {
                $Script:command.Parameters['StartDate'].ParameterType |
                    Should -Be ([string])
            }

            It 'Declares EndDate as optional string' {
                $Script:command.Parameters['EndDate'].ParameterType |
                    Should -Be ([string])
            }

            It 'Does not expose WhatIf' {
                $Script:command.Parameters.ContainsKey('WhatIf') |
                    Should -BeFalse
            }

            It 'Does not expose Confirm' {
                $Script:command.Parameters.ContainsKey('Confirm') |
                    Should -BeFalse
            }
        }
        #endregion

        #region CNPJ normalization
        Context 'CNPJ normalization' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:CnpjNormalized
                }

                Mock -CommandName Resolve-DateRange -MockWith $Script:ResolveDateRangeMock

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return @()
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    return @()
                }

                Get-PipeDFeSequenceGap -Cnpj $Script:CnpjInput
            }

            It 'Normalizes the CNPJ before any other operation' {
                $invokeParams = @{
                    CommandName     = 'ConvertTo-NormalizedCnpj'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Value -eq $Script:CnpjInput
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Passes the normalized CNPJ to Get-DFeDocumentEntry' {
                $invokeParams = @{
                    CommandName     = 'Get-DFeDocumentEntry'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj -eq $Script:CnpjNormalized
                    }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Date range resolution
        Context 'Date range resolution - no dates supplied' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:CnpjNormalized
                }

                Mock -CommandName Resolve-DateRange -MockWith $Script:ResolveDateRangeMock

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return @()
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    return @()
                }

                Get-PipeDFeSequenceGap -Cnpj $Script:CnpjInput
            }

            It 'Calls Resolve-DateRange exactly once' {
                $invokeParams = @{
                    CommandName = 'Resolve-DateRange'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Passes the resolved start to Get-DFeDocumentEntry' {
                $invokeParams = @{
                    CommandName     = 'Get-DFeDocumentEntry'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $StartDate -eq $Script:dateRange.Start.ToString('o')
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Passes the resolved end to Get-DFeDocumentEntry' {
                $invokeParams = @{
                    CommandName     = 'Get-DFeDocumentEntry'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $EndDate -eq $Script:dateRange.End.ToString('o')
                    }
                }

                Should -Invoke @invokeParams
            }
        }

        Context 'Date range resolution - StartDate only' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:CnpjNormalized
                }

                Mock -CommandName Resolve-DateRange -MockWith $Script:ResolveDateRangeMock

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return @()
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    return @()
                }

                Get-PipeDFeSequenceGap -Cnpj $Script:CnpjInput -StartDate $Script:StartDate
            }

            It 'Forwards StartDate to Resolve-DateRange' {
                $invokeParams = @{
                    CommandName     = 'Resolve-DateRange'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $StartDate -eq $Script:StartDate
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Does not forward EndDate to Resolve-DateRange' {
                $invokeParams = @{
                    CommandName     = 'Resolve-DateRange'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        -not $PSBoundParameters.ContainsKey('EndDate')
                    }
                }

                Should -Invoke @invokeParams
            }
        }

        Context 'Date range resolution - StartDate and EndDate' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:CnpjNormalized
                }

                Mock -CommandName Resolve-DateRange -MockWith $Script:ResolveDateRangeMock

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return @()
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    return @()
                }

                $sequenceGapParams = @{
                    Cnpj      = $Script:CnpjInput
                    StartDate = $Script:StartDate
                    EndDate   = $Script:EndDate
                }

                Get-PipeDFeSequenceGap @sequenceGapParams

            }

            It 'Forwards StartDate to Resolve-DateRange' {
                $invokeParams = @{
                    CommandName     = 'Resolve-DateRange'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $StartDate -eq $Script:StartDate
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Forwards EndDate to Resolve-DateRange' {
                $invokeParams = @{
                    CommandName     = 'Resolve-DateRange'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $EndDate -eq $Script:EndDate
                    }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region EndDate without StartDate
        Context 'EndDate without StartDate propagation' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:CnpjNormalized
                }

                Mock -CommandName Resolve-DateRange -MockWith {
                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.ArgumentException]::new(
                                '-StartDate is required when -EndDate is provided.'
                            ),
                            'EndDateWithoutStartDate',
                            [System.Management.Automation.ErrorCategory]::InvalidArgument,
                            $EndDate
                        )
                    )
                }

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return @()
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    return @()
                }

                $Script:exception = $null

                try {
                    Get-PipeDFeSequenceGap -Cnpj $Script:CnpjInput -EndDate $Script:EndDate
                } catch {
                    $Script:exception = $_
                }
            }

            It 'Propagates EndDateWithoutStartDate' {
                $Script:exception.FullyQualifiedErrorId |
                    Should -BeLike 'EndDateWithoutStartDate*'
            }

            It 'Does not call Get-DFeDocumentEntry' {
                $invokeParams = @{
                    CommandName = 'Get-DFeDocumentEntry'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Does not call Get-DFeSequenceGap' {
                $invokeParams = @{
                    CommandName = 'Get-DFeSequenceGap'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Empty entries
        Context 'Empty entries' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:CnpjNormalized
                }

                Mock -CommandName Resolve-DateRange -MockWith $Script:ResolveDateRangeMock

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return @()
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    return @()
                }

                $Script:Output = @(Get-PipeDFeSequenceGap -Cnpj $Script:CnpjInput)
            }

            It 'Does not call Get-DFeSequenceGap when entries are empty' {
                $invokeParams = @{
                    CommandName = 'Get-DFeSequenceGap'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Produces no pipeline output' {
                $Script:Output.Count | Should -Be 0
            }
        }
        #endregion

        #region Gap detection
        Context 'Gap detection - gaps found' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:CnpjNormalized
                }

                Mock -CommandName Resolve-DateRange -MockWith $Script:ResolveDateRangeMock

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return @($Script:Entry)
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    return $Script:Gap
                }

                $Script:Output = @(Get-PipeDFeSequenceGap -Cnpj $Script:CnpjInput)
            }

            It 'Calls Get-DFeSequenceGap with the retrieved entries' {
                $invokeParams = @{
                    CommandName     = 'Get-DFeSequenceGap'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $null -ne $Entries -and $Entries.Count -eq 1
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Emits each gap object to the pipeline' {
                $Script:Output.Count | Should -Be 1
            }

            It 'Preserves Especie' {
                $Script:Output[0].Especie | Should -Be $Script:Gap.Especie
            }

            It 'Preserves Serie' {
                $Script:Output[0].Serie | Should -Be $Script:Gap.Serie
            }

            It 'Preserves Inicial' {
                $Script:Output[0].Inicial | Should -Be $Script:Gap.Inicial
            }

            It 'Preserves Final' {
                $Script:Output[0].Final | Should -Be $Script:Gap.Final
            }
        }

        Context 'Gap detection - no gaps found' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:CnpjNormalized
                }

                Mock -CommandName Resolve-DateRange -MockWith $Script:ResolveDateRangeMock

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return @($Script:Entry)
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    return @()
                }

                $Script:Output = @(Get-PipeDFeSequenceGap -Cnpj $Script:CnpjInput)
            }

            It 'Produces no pipeline output when no gaps are detected' {
                $Script:Output.Count | Should -Be 0
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:CnpjNormalized
                }

                Mock -CommandName Resolve-DateRange -MockWith $Script:ResolveDateRangeMock

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return @($Script:Entry)
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    return $Script:Gap
                }

                $Script:Output = @(Get-PipeDFeSequenceGap -Cnpj $Script:CnpjInput)
            }

            It 'Emits PSCustomObjects' {
                $Script:Output[0] | Should -BeOfType [pscustomobject]
            }

            It 'Exposes Especie as string' {
                $Script:Output[0].Especie | Should -BeOfType [string]
            }

            It 'Exposes Serie as string' {
                $Script:Output[0].Serie | Should -BeOfType [string]
            }

            It 'Exposes Inicial as int' {
                $Script:Output[0].Inicial | Should -BeOfType [int]
            }

            It 'Exposes Final as int' {
                $Script:Output[0].Final | Should -BeOfType [int]
            }
        }
        #endregion
    }
}
