#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Repair-DFeDocumentProcessing.

.DESCRIPTION
Verifies recovery policy for documents left in Processing state.

Coverage includes:
  - Parameter contract.
  - Queries only Processing documents.
  - Recent Processing documents remain active.
  - Processing documents older than AbandonAfter are recovered to Failed.
  - Processing documents exactly at the threshold are recovered to Failed.
  - Missing processing_started_at is treated as inconsistent and recovered.
  - Invalid processing_started_at is treated as inconsistent and recovered.
  - Recovery persists an explanatory processing_error.
  - InvalidProcessingStateTransition is treated as a concurrent state change.
  - ConcurrentProcessingStateChange is treated as a concurrent state change.
  - Unexpected state update failures terminate recovery.
  - Empty result sets return zero counters.
  - ReferenceTime is normalized to UTC.
  - Result object exposes the expected recovery counters.
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
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Repair-DFeDocumentProcessing' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Repair-DFeDocumentProcessing -ErrorAction Stop

            $Script:Cnpj = '12345678000199'

            $Script:ReferenceTime = [System.DateTimeOffset]::new(
                2026, 9, 25, 12, 0, 0,
                [System.TimeSpan]::Zero
            )

            $Script:AbandonAfter = [System.TimeSpan]::FromMinutes(30)

            function New-TestEntry {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter()]
                    [string]$ChaveAcesso = '35260912345678000199550010000000011234567890',

                    [Parameter()]
                    [AllowNull()]
                    [string]$ProcessingStartedAt = '2026-09-25T11:00:00.0000000+00:00'
                )

                [pscustomobject]@{
                    chave_acesso          = $ChaveAcesso
                    processing_status     = 'Processing'
                    processing_started_at = $ProcessingStartedAt
                }
            }
        }

        BeforeEach {

            Mock -CommandName Get-DFeDocumentEntry -MockWith {
                @()
            }

            Mock -CommandName Set-DFeDocumentProcessingState
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

            It 'Declares Cnpj as string' {
                $Script:Command.Parameters['Cnpj'].ParameterType |
                    Should -Be ([string])
            }

            It 'Validates the Cnpj pattern' {
                $attribute = $Script:Command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ValidatePatternAttribute]
                    }

                $attribute.RegexPattern |
                    Should -Be '^(?-i)[A-Z0-9]{14}$'
            }

            It 'Declares AbandonAfter as mandatory' {
                $mandatory = $Script:Command.Parameters['AbandonAfter'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares AbandonAfter as TimeSpan' {
                $Script:Command.Parameters['AbandonAfter'].ParameterType |
                    Should -Be ([System.TimeSpan])
            }

            It 'Declares ReferenceTime as optional' {
                $mandatory = $Script:Command.Parameters['ReferenceTime'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -BeNullOrEmpty
            }

            It 'Declares ReferenceTime as DateTimeOffset' {
                $Script:Command.Parameters['ReferenceTime'].ParameterType |
                    Should -Be ([System.DateTimeOffset])
            }

            It 'Rejects zero AbandonAfter' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = [System.TimeSpan]::Zero
                    ReferenceTime = $Script:ReferenceTime
                }

                { Repair-DFeDocumentProcessing @recoverParams } | Should -Throw
            }

            It 'Rejects negative AbandonAfter' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = [System.TimeSpan]::FromMinutes(-1)
                    ReferenceTime = $Script:ReferenceTime
                }

                { Repair-DFeDocumentProcessing @recoverParams } | Should -Throw
            }
        }
        #endregion

        #region Processing document selection
        Context 'Processing document selection' {

            It 'Queries only Processing documents for the company' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                Repair-DFeDocumentProcessing @recoverParams | Out-Null

                $shouldParams = @{
                    CommandName     = 'Get-DFeDocumentEntry'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj -eq $Script:Cnpj -and
                        $ProcessingStatus -eq 'Processing'
                    }
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Active Processing document
        Context 'Active Processing document' {

            BeforeEach {

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    New-TestEntry -ProcessingStartedAt '2026-09-25T11:45:00.0000000+00:00'
                }
            }

            It 'Does not recover a recent Processing document' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                $result = Repair-DFeDocumentProcessing @recoverParams

                $result.Active    | Should -Be 1
                $result.Recovered | Should -Be 0

                $shouldParams = @{
                    CommandName = 'Set-DFeDocumentProcessingState'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Abandoned Processing document
        Context 'Abandoned Processing document' {

            BeforeEach {

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    New-TestEntry -ProcessingStartedAt '2026-09-25T11:00:00.0000000+00:00'
                }
            }

            It 'Moves an abandoned Processing document to Failed' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                Repair-DFeDocumentProcessing @recoverParams | Out-Null

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj -eq $Script:Cnpj -and
                        $ChaveAcesso -eq '35260912345678000199550010000000011234567890' -and
                        $Status -eq 'Failed'
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Persists an abandoned processing recovery message' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                Repair-DFeDocumentProcessing @recoverParams | Out-Null

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Status -eq 'Failed' -and
                        $ErrorMessage -like '*abandoned Processing state*'
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Reports the recovered document' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                $result = Repair-DFeDocumentProcessing @recoverParams

                $result.ProcessingFound     | Should -Be 1
                $result.Active              | Should -Be 0
                $result.Recovered           | Should -Be 1
                $result.Inconsistent        | Should -Be 0
                $result.ConcurrentlyChanged | Should -Be 0
            }
        }
        #endregion

        #region Exact abandonment threshold
        Context 'Exact abandonment threshold' {

            BeforeEach {

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    # started_at = 11:30 UTC; threshold = 12:00 - 30m = 11:30 UTC
                    # startedAtUtc -gt threshold is false, so the document is recovered
                    New-TestEntry -ProcessingStartedAt '2026-09-25T11:30:00.0000000+00:00'
                }
            }

            It 'Recovers a Processing document exactly at the threshold' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                $result = Repair-DFeDocumentProcessing @recoverParams

                $result.Recovered | Should -Be 1
                $result.Active    | Should -Be 0

                $shouldParams = @{
                    CommandName = 'Set-DFeDocumentProcessingState'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Missing processing timestamp
        Context 'Missing processing timestamp' {

            BeforeEach {

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    New-TestEntry -ProcessingStartedAt $null
                }
            }

            It 'Recovers a Processing document with no processing_started_at' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                $result = Repair-DFeDocumentProcessing @recoverParams

                $result.ProcessingFound | Should -Be 1
                $result.Inconsistent    | Should -Be 1
                $result.Recovered       | Should -Be 1
            }

            It 'Persists an inconsistent state recovery message' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                Repair-DFeDocumentProcessing @recoverParams | Out-Null

                $shouldParams = @{
                    CommandName     = 'Set-DFeDocumentProcessingState'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Status -eq 'Failed' -and
                        $ErrorMessage -like '*processing_started_at is missing or invalid*'
                    }
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Invalid processing timestamp
        Context 'Invalid processing timestamp' {

            BeforeEach {

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    New-TestEntry -ProcessingStartedAt 'not-a-date'
                }
            }

            It 'Recovers a Processing document with invalid processing_started_at' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                $result = Repair-DFeDocumentProcessing @recoverParams

                $result.Inconsistent | Should -Be 1
                $result.Recovered    | Should -Be 1
                $result.Active       | Should -Be 0
            }
        }
        #endregion

        #region Concurrent state change
        Context 'Concurrent state change' {

            BeforeEach {

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    New-TestEntry -ProcessingStartedAt '2026-09-25T11:00:00.0000000+00:00'
                }
            }

            It 'Treats InvalidProcessingStateTransition as concurrently changed' {
                Mock -CommandName Set-DFeDocumentProcessingState -MockWith {
                    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new(
                            'Invalid processing state transition.'
                        ),
                        'InvalidProcessingStateTransition',
                        [System.Management.Automation.ErrorCategory]::WriteError,
                        $null
                    )

                    throw $errorRecord
                }

                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                $result = Repair-DFeDocumentProcessing @recoverParams

                $result.Recovered           | Should -Be 0
                $result.ConcurrentlyChanged | Should -Be 1
            }

            It 'Treats ConcurrentProcessingStateChange as concurrently changed' {
                Mock -CommandName Set-DFeDocumentProcessingState -MockWith {
                    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new(
                            'Processing state changed concurrently.'
                        ),
                        'ConcurrentProcessingStateChange',
                        [System.Management.Automation.ErrorCategory]::WriteError,
                        $null
                    )

                    throw $errorRecord
                }

                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                $result = Repair-DFeDocumentProcessing @recoverParams

                $result.Recovered           | Should -Be 0
                $result.ConcurrentlyChanged | Should -Be 1
            }
        }
        #endregion

        #region Unexpected recovery failure
        Context 'Unexpected recovery failure' {

            BeforeEach {
                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    New-TestEntry -ProcessingStartedAt '2026-09-25T11:00:00.0000000+00:00'
                }

                Mock -CommandName Set-DFeDocumentProcessingState -MockWith {
                    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                        [System.IO.IOException]::new('Database write failed.'),
                        'DocumentProcessingStateUpdateFailed',
                        [System.Management.Automation.ErrorCategory]::WriteError,
                        $null
                    )

                    throw $errorRecord
                }
            }

            It 'Throws DocumentProcessingRecoveryFailed' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                    ErrorAction   = 'Stop'
                }

                { Repair-DFeDocumentProcessing @recoverParams } |
                    Should -Throw -ErrorId 'DocumentProcessingRecoveryFailed*'
            }
        }
        #endregion

        #region Multiple Processing documents
        Context 'Multiple Processing documents' {

            BeforeEach {

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    @(
                        New-TestEntry -ChaveAcesso ('1' * 44) -ProcessingStartedAt '2026-09-25T11:00:00.0000000+00:00'
                        New-TestEntry -ChaveAcesso ('2' * 44) -ProcessingStartedAt '2026-09-25T11:50:00.0000000+00:00'
                        New-TestEntry -ChaveAcesso ('3' * 44) -ProcessingStartedAt $null
                    )
                }
            }

            It 'Classifies each Processing document independently' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                $result = Repair-DFeDocumentProcessing @recoverParams

                $result.ProcessingFound | Should -Be 3
                $result.Active          | Should -Be 1
                $result.Recovered       | Should -Be 2
                $result.Inconsistent    | Should -Be 1
            }

            It 'Updates only abandoned or inconsistent documents' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                Repair-DFeDocumentProcessing @recoverParams | Out-Null

                $shouldParams = @{
                    CommandName = 'Set-DFeDocumentProcessingState'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 2
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region ReferenceTime normalization
        Context 'ReferenceTime normalization' {

            BeforeEach {

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    New-TestEntry -ProcessingStartedAt '2026-09-25T11:00:00.0000000+00:00'
                }
            }

            It 'Uses the same instant regardless of ReferenceTime offset' {
                # 09:00 BRT (-3h) = 12:00 UTC - same reference instant as $Script:ReferenceTime
                $referenceTime = [System.DateTimeOffset]::new(
                    2026, 9, 25, 9, 0, 0,
                    [System.TimeSpan]::FromHours(-3)
                )

                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $referenceTime
                }

                $result = Repair-DFeDocumentProcessing @recoverParams

                $result.Recovered | Should -Be 1
                $result.Active    | Should -Be 0
            }
        }
        #endregion

        #region No Processing documents
        Context 'No Processing documents' {

            It 'Returns zero counters' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                $result = Repair-DFeDocumentProcessing @recoverParams

                $result.ProcessingFound     | Should -Be 0
                $result.Active              | Should -Be 0
                $result.Recovered           | Should -Be 0
                $result.Inconsistent        | Should -Be 0
                $result.ConcurrentlyChanged | Should -Be 0
            }

            It 'Does not update document state' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                Repair-DFeDocumentProcessing @recoverParams | Out-Null

                $shouldParams = @{
                    CommandName = 'Set-DFeDocumentProcessingState'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Result contract
        Context 'Result contract' {

            It 'Returns one recovery result object' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                $result = @(Repair-DFeDocumentProcessing @recoverParams)

                $result | Should -HaveCount 1
            }

            It 'Returns PipeDFe.DocumentProcessingRecoveryResult' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                $result = Repair-DFeDocumentProcessing @recoverParams

                $result.PSObject.TypeNames |
                    Should -Contain 'PipeDFe.DocumentProcessingRecoveryResult'
            }

            It 'Exposes the expected properties' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                $result = Repair-DFeDocumentProcessing @recoverParams

                $propertyNames = @($result.PSObject.Properties.Name)

                $propertyNames | Should -Be @(
                    'ProcessingFound'
                    'Active'
                    'Recovered'
                    'Inconsistent'
                    'ConcurrentlyChanged'
                )
            }

            It 'Returns integer counters' {
                $recoverParams = @{
                    Cnpj          = $Script:Cnpj
                    AbandonAfter  = $Script:AbandonAfter
                    ReferenceTime = $Script:ReferenceTime
                }

                $result = Repair-DFeDocumentProcessing @recoverParams

                $result.ProcessingFound     | Should -BeOfType ([int])
                $result.Active              | Should -BeOfType ([int])
                $result.Recovered           | Should -BeOfType ([int])
                $result.Inconsistent        | Should -BeOfType ([int])
                $result.ConcurrentlyChanged | Should -BeOfType ([int])
            }
        }
        #endregion
    }
}
