#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Invoke-DFeDelivery.

.DESCRIPTION
Verifies the persistent delivery lifecycle of Invoke-DFeDelivery against
a real SQLite index in an isolated temporary directory.

Only Send-DFeNotification is mocked. New-DFeDelivery and Set-DFeDeliveryState
run against the real database.

Coverage includes:
  - Persists Prepared to Sending to Delivered on success.
  - Returns the same DeliveryId on a duplicate call when already Delivered.
  - Does not call Send-DFeNotification a second time for a Delivered delivery.
  - Persists pre-SMTP failure as Failed and allows a controlled retry.
  - Advances the attempt timestamp on retry.
  - Clears DeliveryError after a successful retry.
  - Persists an uncertain SMTP outcome as Indeterminate.
  - Blocks a second send attempt when status is Indeterminate.
  - Recovers an interrupted Sending record to Indeterminate without SMTP.
  - Resolves confirmed SMTP outcomes and preserves the original failure in
    the resolution log.
  - Preserves the delivery under WhatIf and rejects a decision for a stale
    attempt.
  - Treats a missing AcceptanceUncertain flag as indeterminate.
  - Treats an unexpected notification exception as indeterminate.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Integration tests create isolated fixtures.'
)]

param ()

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery
    # phase, because that is when Context/It are executed to register the test
    # tree. If the module is not loaded at that point, InModuleScope fails
    # before any BeforeAll or BeforeEach ever runs.
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Invoke-DFeDelivery SQLite lifecycle' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:TestPeriodIndex = -1

            # Save both values before redirecting the test store.
            $Script:OriginalLocalAppData = $env:LOCALAPPDATA
            $Script:OriginalDataRoot     = $env:PIPEDFE_DATA_ROOT

            $testID = [guid]::NewGuid().ToString('N')

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.DeliveryLifecycle.Tests-{0}' -f $testID
            )

            New-Item -ItemType Directory -Path $Script:TempRoot -Force |
                Out-Null

            $env:LOCALAPPDATA      = $Script:TempRoot
            $env:PIPEDFE_DATA_ROOT = $null

            $Script:TestCnpj = '12345678000199'

            $Script:Company = [pscustomobject]@{
                Cnpj         = $Script:TestCnpj
                NomeFantasia = 'Empresa Teste'
                RazaoSocial  = 'Empresa Teste Ltda'
                Email        = [pscustomobject]@{
                    Para = @('dest@example.com')
                    Cc   = @()
                    Cco  = @()
                }
            }

            $Script:DateRange = [pscustomobject]@{
                Start = [System.DateTimeOffset]::Parse('2026-11-01T00:00:00-03:00')
                End   = [System.DateTimeOffset]::Parse('2026-11-30T23:59:59-03:00')
            }

            $Script:Smtp = [pscustomobject]@{
                Server = 'smtp.example.invalid'
                Port   = 587
            }

            Initialize-DFeIndex -Cnpj $Script:TestCnpj | Out-Null

            function New-LifecycleArchive {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param ()

                $fileName = 'NFe_{0}.zip' -f [guid]::NewGuid().ToString('N')
                $path     = Join-Path -Path $Script:TempRoot -ChildPath $fileName

                [System.IO.File]::WriteAllText(
                    $path,
                    [guid]::NewGuid().ToString('N')
                )

                [pscustomobject]@{
                    TipoDFe  = 'NFe'
                    FileName = $fileName
                    FileHash = Get-FileSha256 -Path $path
                    DestPath = $path
                }
            }

            function Get-LifecycleDelivery {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [pscustomobject]$Archive
                )

                $params = @{
                    Cnpj        = $Script:Company.Cnpj
                    PeriodStart = $Script:DateRange.Start
                    PeriodEnd   = $Script:DateRange.End
                    Archives    = @($Archive)
                    To          = @($Script:Company.Email.Para)
                }

                New-DFeDelivery @params
            }

            function Set-LifecycleState {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [pscustomobject]$Delivery,

                    [Parameter(Mandatory)]
                    [string]$Status,

                    [Parameter()]
                    [string]$ErrorMessage
                )

                # $Delivery must be the object returned by Set-DFeDeliveryState
                # or New-DFeDelivery. When transitioning out of Sending, pass
                # the object returned by the Sending transition so that
                # DeliveryStartedAt is populated.
                $params = @{
                    Cnpj                      = $Script:Company.Cnpj
                    DeliveryId                = $Delivery.DeliveryId
                    ExpectedStatus            = $Delivery.DeliveryStatus
                    ExpectedDeliveryStartedAt = $Delivery.DeliveryStartedAt
                    Status                    = $Status
                }

                if ($PSBoundParameters.ContainsKey('ErrorMessage')) {
                    $params.ErrorMessage = $ErrorMessage
                }

                Set-DFeDeliveryState @params
            }
        }

        BeforeEach {
            # Isolate delivery identities between tests while preserving
            # the same period for every operation within a single test.
            $Script:TestPeriodIndex++

            $periodStart = (
                [DateTimeOffset]::Parse('2026-11-01T00:00:00-03:00')
            ).AddMonths($Script:TestPeriodIndex)

            $Script:DateRange = [pscustomobject]@{
                Start = $periodStart
                End   = $periodStart.AddMonths(1).AddSeconds(-1)
            }

            $Script:Archive = New-LifecycleArchive

            $Script:Params = @{
                Company   = $Script:Company
                DateRange = $Script:DateRange
                Smtp      = $Script:Smtp
                Gaps      = @()
                Archives  = @($Script:Archive)
                Entries   = @()
            }

            Mock -CommandName Send-DFeNotification -MockWith {
                [pscustomobject]@{
                    Success             = $true
                    EmailsSent          = @('dest@example.com')
                    ErrorMessage        = $null
                    FailedAt            = $null
                    AcceptanceUncertain = $false
                }
            }
        }

        AfterAll {

            # Always restore both env vars, even when tests fail.
            $env:LOCALAPPDATA      = $Script:OriginalLocalAppData
            $env:PIPEDFE_DATA_ROOT = $Script:OriginalDataRoot

            $removeItemParams = @{
                LiteralPath = $Script:TempRoot
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeItemParams
        }

        It 'Persists Prepared to Sending to Delivered and skips duplicate SMTP send' {
            $first = Invoke-DFeDelivery @Script:Params

            $first.Success        | Should -BeTrue
            $first.DeliveryStatus | Should -Be 'Delivered'
            $first.DeliveryId     | Should -Not -BeNullOrEmpty

            $stored = Get-LifecycleDelivery -Archive $Script:Archive

            $stored.DeliveryId        | Should -Be $first.DeliveryId
            $stored.DeliveryStatus    | Should -Be 'Delivered'
            $stored.DeliveryStartedAt | Should -Not -BeNullOrEmpty
            $stored.DeliveredAt       | Should -Not -BeNullOrEmpty
            $stored.DeliveryError     | Should -BeNullOrEmpty

            $second = Invoke-DFeDelivery @Script:Params

            $second.Success    | Should -BeTrue
            $second.DeliveryId | Should -Be $first.DeliveryId

            $invokeParams = @{
                CommandName = 'Send-DFeNotification'
                Times       = 1
                Exactly     = $true
                Scope       = 'It'
                ModuleName  = 'PipeDFe'
            }

            Should -Invoke @invokeParams
        }

        It 'Persists pre-SMTP failure as Failed and allows a controlled retry' {
            Mock -CommandName Send-DFeNotification -MockWith {
                [pscustomobject]@{
                    Success             = $false
                    EmailsSent          = @()
                    ErrorMessage        = 'Attachment validation failed.'
                    FailedAt            = 'Send'
                    AcceptanceUncertain = $false
                }
            }

            $first = Invoke-DFeDelivery @Script:Params

            $first.Success        | Should -BeFalse
            $first.DeliveryStatus | Should -Be 'Failed'

            $stored = Get-LifecycleDelivery -Archive $Script:Archive

            $stored.DeliveryStatus | Should -Be 'Failed'
            $stored.DeliveryError  | Should -Be 'Attachment validation failed.'

            $previousAttempt = [System.DateTimeOffset]::Parse(
                $stored.DeliveryStartedAt
            )

            Mock -CommandName Send-DFeNotification -MockWith {
                [pscustomobject]@{
                    Success             = $true
                    EmailsSent          = @('dest@example.com')
                    ErrorMessage        = $null
                    FailedAt            = $null
                    AcceptanceUncertain = $false
                }
            }

            $second = Invoke-DFeDelivery @Script:Params

            $second.Success        | Should -BeTrue
            $second.DeliveryId     | Should -Be $first.DeliveryId
            $second.DeliveryStatus | Should -Be 'Delivered'

            $stored = Get-LifecycleDelivery -Archive $Script:Archive

            ([DateTimeOffset]::Parse(
                $stored.DeliveryStartedAt) -gt $previousAttempt
            ) | Should -BeTrue

            $stored.DeliveryError | Should -BeNullOrEmpty
        }

        It 'Persists an uncertain SMTP outcome as Indeterminate and blocks another send' {
            Mock -CommandName Send-DFeNotification -MockWith {
                [pscustomobject]@{
                    Success             = $false
                    EmailsSent          = @()
                    ErrorMessage        = 'SMTP connection closed after DATA without a final response.'
                    FailedAt            = 'Send'
                    AcceptanceUncertain = $true
                }
            }

            $first = Invoke-DFeDelivery @Script:Params

            $first.DeliveryStatus | Should -Be 'Indeterminate'

            $stored = Get-LifecycleDelivery -Archive $Script:Archive

            $stored.DeliveryStatus | Should -Be 'Indeterminate'
            $stored.DeliveryError  | Should -Match 'SMTP connection closed'

            $second = Invoke-DFeDelivery @Script:Params

            $second.Success        | Should -BeFalse
            $second.DeliveryStatus | Should -Be 'Indeterminate'
            $second.ErrorMessage   | Should -Match ([regex]::Escape($stored.DeliveryStartedAt))
            $second.ErrorMessage   | Should -Match ([regex]::Escape($stored.DeliveryId))

            $invokeParams = @{
                CommandName = 'Send-DFeNotification'
                Times       = 1
                Exactly     = $true
                Scope       = 'It'
                ModuleName  = 'PipeDFe'
            }

            Should -Invoke @invokeParams
        }

        Context 'Operator resolution of an indeterminate delivery' {

            BeforeEach {
                $prepared = Get-LifecycleDelivery -Archive $Script:Archive
                $sending  = Set-LifecycleState -Delivery $prepared -Status 'Sending'

                $indeterminateParams = @{
                    Delivery     = $sending
                    Status       = 'Indeterminate'
                    ErrorMessage = 'Final SMTP response unavailable.'
                }

                $Script:UncertainDelivery = Set-LifecycleState @indeterminateParams

                $Script:ResolutionParams = @{
                    Cnpj             = $Script:Company.Cnpj
                    DeliveryId       = $Script:UncertainDelivery.DeliveryId
                    AttemptStartedAt = $Script:UncertainDelivery.DeliveryStartedAt
                    Reason           = 'Verified against the SMTP provider logs.'
                    Confirm          = $false
                }
            }

            It 'Resolves <Outcome> as <Status> and honors that state on the next closing' -ForEach @(
                @{
                    Outcome   = 'Accepted'
                    Status    = 'Delivered'
                    SendCount = 0
                }
                @{
                    Outcome   = 'NotAccepted'
                    Status    = 'Failed'
                    SendCount = 1
                }
            ) {
                $resolution = Resolve-PipeDFeDelivery @Script:ResolutionParams -Outcome $Outcome

                $resolution.PreviousStatus    | Should -Be 'Indeterminate'
                $resolution.DeliveryStatus    | Should -Be $Status

                $resolution.DeliveryStartedAt |
                    Should -Be $Script:UncertainDelivery.DeliveryStartedAt

                Should -Invoke -CommandName Send-DFeNotification -Times 0 -Exactly -Scope It

                $next = Invoke-DFeDelivery @Script:Params

                $next.DeliveryId     | Should -Be $resolution.DeliveryId
                $next.DeliveryStatus | Should -Be 'Delivered'

                $invokeParams = @{
                    CommandName = 'Send-DFeNotification'
                    Times       = $SendCount
                    Exactly     = $true
                    Scope       = 'It'
                    ModuleName  = 'PipeDFe'
                }

                Should -Invoke @invokeParams

                $connection = Open-DFeIndexConnection -Cnpj $Script:Company.Cnpj

                try {

                    $command = $connection.CreateCommand()
                    try {
                        $command.CommandText = @'
SELECT resolution_status || '|' || reason || '|' || previous_error
FROM dfe_delivery_resolution
WHERE delivery_id = @delivery_id AND delivery_started_at = @started_at;
'@

                        $null = $command.Parameters.AddWithValue(
                            '@delivery_id',
                            $resolution.DeliveryId
                        )

                        $null = $command.Parameters.AddWithValue(
                            '@started_at',
                            $resolution.DeliveryStartedAt
                        )

                        $expected = '{0}|{1}|Final SMTP response unavailable.' -f (
                            $Status,
                            $Script:ResolutionParams.Reason
                        )

                        $command.ExecuteScalar() | Should -BeExactly $expected
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }

            It 'Leaves the attempt indeterminate under WhatIf' {
                $whatIfParams = $Script:ResolutionParams.Clone()
                $whatIfParams.Outcome = 'NotAccepted'

                Resolve-PipeDFeDelivery @whatIfParams -WhatIf

                $stored = Get-LifecycleDelivery -Archive $Script:Archive

                $stored.DeliveryStatus    | Should -Be 'Indeterminate'
                $stored.DeliveryStartedAt |
                    Should -Be $Script:UncertainDelivery.DeliveryStartedAt

                $stored.DeliveryError     | Should -Be 'Final SMTP response unavailable.'

                Should -Invoke -CommandName Send-DFeNotification -Times 0 -Exactly -Scope It
            }

            It 'Rejects a decision for an older attempt of the same delivery' {
                Resolve-PipeDFeDelivery @Script:ResolutionParams -Outcome NotAccepted |
                    Out-Null

                $failed = Get-LifecycleDelivery -Archive $Script:Archive

                $newAttempt = Set-LifecycleState -Delivery $failed -Status 'Sending'

                $staleParams = @{
                    Delivery     = $newAttempt
                    Status       = 'Indeterminate'
                    ErrorMessage = 'Second attempt was not confirmed.'
                }

                $newState = Set-LifecycleState @staleParams

                { Resolve-PipeDFeDelivery @Script:ResolutionParams -Outcome Accepted } |
                    Should -Throw -ErrorId 'ConcurrentDeliveryStateChange*'

                $stored = Get-LifecycleDelivery -Archive $Script:Archive

                $stored.DeliveryStatus    | Should -Be 'Indeterminate'
                $stored.DeliveryStartedAt | Should -Be $newState.DeliveryStartedAt
                $stored.DeliveryError     | Should -Be $newState.DeliveryError

                $invokeParams = @{
                    CommandName = 'Send-DFeNotification'
                    Times       = 0
                    Exactly     = $true
                    Scope       = 'It'
                    ModuleName  = 'PipeDFe'
                }

                Should -Invoke @invokeParams
            }
        }

        It 'Recovers an interrupted Sending record to Indeterminate without SMTP' {
            $delivery = Get-LifecycleDelivery -Archive $Script:Archive
            $sending  = Set-LifecycleState -Delivery $delivery -Status 'Sending'

            $sending.DeliveryStatus | Should -Be 'Sending'

            $result = Invoke-DFeDelivery @Script:Params

            $result.Success        | Should -BeFalse
            $result.DeliveryStatus | Should -Be 'Indeterminate'

            (Get-LifecycleDelivery -Archive $Script:Archive).DeliveryStatus |
                Should -Be 'Indeterminate'

            $invokeParams = @{
                CommandName = 'Send-DFeNotification'
                Times       = 0
                Exactly     = $true
                Scope       = 'It'
                ModuleName  = 'PipeDFe'
            }

            Should -Invoke @invokeParams
        }

        It 'Treats a missing AcceptanceUncertain flag as indeterminate' {
            Mock -CommandName Send-DFeNotification -MockWith {
                [pscustomobject]@{
                    Success      = $false
                    EmailsSent   = @()
                    ErrorMessage = 'Unknown send outcome.'
                    FailedAt     = 'Send'
                }
            }

            $result = Invoke-DFeDelivery @Script:Params

            $result.DeliveryStatus | Should -Be 'Indeterminate'

            $stored = Get-LifecycleDelivery -Archive $Script:Archive

            $stored.DeliveryStatus | Should -Be 'Indeterminate'
            $stored.DeliveryError  | Should -Be 'Unknown send outcome.'
        }

        It 'Treats an unexpected notification exception as indeterminate' {
            Mock -CommandName Send-DFeNotification -MockWith {
                throw [System.InvalidOperationException]::new(
                    'Unexpected notification failure.'
                )
            }

            $result = Invoke-DFeDelivery @Script:Params

            $result.Success        | Should -BeFalse
            $result.DeliveryStatus | Should -Be 'Indeterminate'

            (Get-LifecycleDelivery -Archive $Script:Archive).DeliveryStatus |
                Should -Be 'Indeterminate'
        }
    }
}
