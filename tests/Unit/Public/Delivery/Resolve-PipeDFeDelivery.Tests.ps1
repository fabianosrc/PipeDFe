#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Resolve-PipeDFeDelivery.

.DESCRIPTION
Coverage includes acceptance, non-acceptance, attempt guards, reason
validation, missing indexes, WhatIf and propagation of transition failures.
Uses an empty temporary index file and mocked state transitions.
#>

BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName
    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'
    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Resolve-PipeDFeDelivery' -Tag 'Unit' {
    InModuleScope -ModuleName PipeDFe {
        BeforeEach {
            $indexPath = [System.IO.Path]::GetTempFileName()
            $params = @{
                Cnpj = '12.345.678/0001-95'
                DeliveryId = '0123456789abcdef0123456789abcdef'
                AttemptStartedAt = '2026-11-01T12:00:00Z'
                Outcome = 'Accepted'
                Reason = '  Provider evidence  '
                Confirm = $false
            }

            Mock Get-StorePath { $indexPath }
            Mock Set-DFeDeliveryState { [pscustomobject]@{ Status = $Status } }
        }

        AfterEach {
            [System.IO.File]::Delete($indexPath)
        }

        It 'Resolves confirmed acceptance with the exact attempt guard' {
            $result = Resolve-PipeDFeDelivery @params
            $result.Status | Should -Be 'Delivered'

            Should -Invoke Set-DFeDeliveryState -Times 1 -Exactly -ParameterFilter {
                $Cnpj -eq '12345678000195' -and
                $DeliveryId -eq '0123456789abcdef0123456789abcdef' -and
                $ExpectedStatus -eq 'Indeterminate' -and
                $ExpectedDeliveryStartedAt -eq '2026-11-01T12:00:00Z' -and
                $Status -eq 'Delivered' -and
                $ResolutionReason -eq 'Provider evidence' -and
                [string]::IsNullOrEmpty($ErrorMessage)
            }
        }

        It 'Resolves confirmed non-acceptance as Failed' {
            $params.Outcome = 'NotAccepted'
            $result = Resolve-PipeDFeDelivery @params
            $result.Status | Should -Be 'Failed'

            Should -Invoke Set-DFeDeliveryState -Times 1 -Exactly -ParameterFilter {
                $Status -eq 'Failed' -and
                $ExpectedStatus -eq 'Indeterminate' -and
                $ExpectedDeliveryStartedAt -eq '2026-11-01T12:00:00Z' -and
                $ResolutionReason -eq 'Provider evidence' -and
                $ErrorMessage -eq 'SMTP non-acceptance confirmed: Provider evidence'
            }
        }

        It 'Rejects a whitespace-only reason' {
            $params.Reason = '   '
            { Resolve-PipeDFeDelivery @params } | Should -Throw -ErrorId 'ReasonMustNotBeBlank*'
            Should -Invoke Set-DFeDeliveryState -Times 0 -Exactly
        }

        It 'Rejects a missing index' {
            [System.IO.File]::Delete($indexPath)
            { Resolve-PipeDFeDelivery @params } | Should -Throw -ErrorId 'DeliveryIndexNotFound*'
            Should -Invoke Set-DFeDeliveryState -Times 0 -Exactly
        }

        It 'Does not change state with WhatIf' {
            Resolve-PipeDFeDelivery @params -WhatIf
            Should -Invoke Set-DFeDeliveryState -Times 0 -Exactly
        }

        It 'Propagates a rejected state transition' {
            Mock Set-DFeDeliveryState { throw 'Transition rejected' }
            { Resolve-PipeDFeDelivery @params } | Should -Throw '*Transition rejected*'
            Should -Invoke Set-DFeDeliveryState -Times 1 -Exactly
        }
    }
}
