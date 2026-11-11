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
  - Treats a missing SendAttempted flag as indeterminate.
  - Treats an unexpected notification exception as indeterminate.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Integration tests create isolated fixtures.'
)]

param ()

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Invoke-DFeDelivery SQLite lifecycle' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:TestPeriodIndex = -1

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $testID = [guid]::NewGuid().ToString('N')

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.DeliveryLifecycle.Tests-{0}' -f $testID
            )

            New-Item -ItemType Directory -Path $Script:TempRoot -Force | Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot

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
                Start = [DateTimeOffset]::Parse('2026-11-01T00:00:00-03:00')
                End   = [DateTimeOffset]::Parse('2026-11-30T23:59:59-03:00')
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

                [System.IO.File]::WriteAllText($path, [guid]::NewGuid().ToString('N'))

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

                # $Delivery must be the object returned by Set-DFeDeliveryState or
                # New-DFeDelivery. When transitioning out of Sending, pass the object
                # returned by the Sending transition so DeliveryStartedAt is populated.
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
                    Success       = $true
                    EmailsSent    = @('dest@example.com')
                    ErrorMessage  = $null
                    FailedAt      = $null
                    SendAttempted = $true
                }
            }
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData

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

            Should -Invoke -CommandName Send-DFeNotification -Times 1 -Exactly -Scope It
        }

        It 'Persists pre-SMTP failure as Failed and allows a controlled retry' {
            Mock -CommandName Send-DFeNotification -MockWith {
                [pscustomobject]@{
                    Success       = $false
                    EmailsSent    = @()
                    ErrorMessage  = 'Attachment validation failed.'
                    FailedAt      = 'Send'
                    SendAttempted = $false
                }
            }

            $first = Invoke-DFeDelivery @Script:Params

            $first.Success        | Should -BeFalse
            $first.DeliveryStatus | Should -Be 'Failed'

            $stored = Get-LifecycleDelivery -Archive $Script:Archive

            $stored.DeliveryStatus | Should -Be 'Failed'
            $stored.DeliveryError  | Should -Be 'Attachment validation failed.'

            $previousAttempt = [DateTimeOffset]::Parse($stored.DeliveryStartedAt)

            Mock -CommandName Send-DFeNotification -MockWith {
                [pscustomobject]@{
                    Success       = $true
                    EmailsSent    = @('dest@example.com')
                    ErrorMessage  = $null
                    FailedAt      = $null
                    SendAttempted = $true
                }
            }

            $second = Invoke-DFeDelivery @Script:Params

            $second.Success        | Should -BeTrue
            $second.DeliveryId     | Should -Be $first.DeliveryId
            $second.DeliveryStatus | Should -Be 'Delivered'

            $stored = Get-LifecycleDelivery -Archive $Script:Archive

            ([DateTimeOffset]::Parse($stored.DeliveryStartedAt) -gt $previousAttempt) |
                Should -BeTrue

            $stored.DeliveryError | Should -BeNullOrEmpty
        }

        It 'Persists an uncertain SMTP outcome as Indeterminate and blocks another send' {
            Mock -CommandName Send-DFeNotification -MockWith {
                [pscustomobject]@{
                    Success       = $false
                    EmailsSent    = @()
                    ErrorMessage  = 'SMTP connection closed during send.'
                    FailedAt      = 'Send'
                    SendAttempted = $true
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

            Should -Invoke -CommandName Send-DFeNotification -Times 1 -Exactly -Scope It
        }

        It 'Recovers an interrupted Sending record to Indeterminate without SMTP' {
            $delivery = Get-LifecycleDelivery -Archive $Script:Archive
            $sending  = Set-LifecycleState -Delivery $delivery -Status 'Sending'

            $sending.DeliveryStatus | Should -Be 'Sending'

            $result = Invoke-DFeDelivery @Script:Params

            $result.Success        | Should -BeFalse
            $result.DeliveryStatus | Should -Be 'Indeterminate'

            $storedParams = @{
                Archive = $Script:Archive
            }

            (Get-LifecycleDelivery @storedParams).DeliveryStatus |
                Should -Be 'Indeterminate'

            Should -Invoke -CommandName Send-DFeNotification -Times 0 -Exactly -Scope It
        }

        It 'Treats a missing SendAttempted flag as indeterminate' {
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

            $storedParams = @{
                Archive = $Script:Archive
            }

            (Get-LifecycleDelivery @storedParams).DeliveryStatus |
                Should -Be 'Indeterminate'
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

            $storedParams = @{
                Archive = $Script:Archive
            }

            (Get-LifecycleDelivery @storedParams).DeliveryStatus |
                Should -Be 'Indeterminate'
        }
    }
}
