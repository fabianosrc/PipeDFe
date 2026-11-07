#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Set-DFeDeliveryState.

.DESCRIPTION
Verifies guarded delivery lifecycle transitions against the real SQLite index.

Coverage includes:
  - Prepared to Sending.
  - Sending to Delivered, Failed and Indeterminate.
  - Failed retry to Sending.
  - Attempt timestamp monotonicity.
  - Required and unexpected error messages.
  - Invalid transitions and invalid attempt tokens.
  - Concurrent state change protection.
  - ABA retry protection.
  - Terminal Indeterminate state.
  - Missing delivery handling.
  - CNPJ isolation.
  - Persisted state readback.

No production data is accessed.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Test helpers modify isolated SQLite fixtures.'
)]

param ()


BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Set-DFeDeliveryState' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            $testID = [guid]::NewGuid().ToString('N')

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.Set-DFeDeliveryState.Tests-{0}' -f $testID
            )

            New-Item -Path $Script:TempRoot -ItemType Directory -Force |
                Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot

            $Script:TestCnpj = '12345678000199'

            $Script:PeriodStart = [DateTimeOffset]::Parse(
                '2026-11-01T00:00:00-03:00'
            )

            $Script:PeriodEnd = [DateTimeOffset]::Parse(
                '2026-11-30T23:59:59-03:00'
            )

            Initialize-DFeIndex -Cnpj $Script:TestCnpj | Out-Null

            function New-TestArchive {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Content
                )

                $fileName = 'NFe_{0}.zip' -f [guid]::NewGuid().ToString('N')

                $path = [System.IO.Path]::Combine(
                    $Script:TempRoot,
                    $fileName
                )

                [System.IO.File]::WriteAllText(
                    $path,
                    $Content,
                    [System.Text.Encoding]::UTF8
                )

                [PSCustomObject]@{
                    TipoDFe  = 'NFe'
                    FileName = $fileName
                    FileHash = Get-FileSha256 -Path $path
                    DestPath = $path
                }
            }

            function New-TestDelivery {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter()]
                    [string]$Cnpj = $Script:TestCnpj,

                    [Parameter()]
                    [string]$To = 'delivery@example.com'
                )

                $archive = New-TestArchive -Content (
                    [guid]::NewGuid().ToString('N')
                )

                $deliveryParams = @{
                    Cnpj        = $Cnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @($To)
                }

                New-DFeDelivery @deliveryParams
            }

            function New-TestSendingDelivery {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter()]
                    [string]$Cnpj = $Script:TestCnpj
                )

                $delivery = New-TestDelivery -Cnpj $Cnpj

                $transitionParams = @{
                    Cnpj                       = $Cnpj
                    DeliveryId                 = $delivery.DeliveryId
                    ExpectedStatus             = 'Prepared'
                    ExpectedDeliveryStartedAt  = $null
                    Status                     = 'Sending'
                }

                Set-DFeDeliveryState @transitionParams
            }

            function Get-TestDelivery {
                [CmdletBinding()]
                [OutputType([object])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$DeliveryId
                )

                $connection = Open-DFeIndexConnection -Cnpj $Cnpj
                $command = $null
                $reader = $null

                try {
                    $command = $connection.CreateCommand()
                    $command.CommandText = @'
SELECT
    delivery_status,
    updated_at,
    delivery_started_at,
    delivered_at,
    delivery_error
FROM dfe_delivery
WHERE delivery_id = @delivery_id;
'@

                    $command.Parameters.AddWithValue(
                        '@delivery_id',
                        $DeliveryId
                    ) | Out-Null

                    $reader = $command.ExecuteReader()

                    if (-not $reader.Read()) {
                        return $null
                    }

                    $startedAt = if ($reader.IsDBNull(2)) {
                        $null
                    } else {
                        $reader.GetString(2)
                    }

                    $deliveredAt = if ($reader.IsDBNull(3)) {
                        $null
                    } else {
                        $reader.GetString(3)
                    }

                    $deliveryError = if ($reader.IsDBNull(4)) {
                        $null
                    } else {
                        $reader.GetString(4)
                    }

                    [PSCustomObject]@{
                        DeliveryStatus    = $reader.GetString(0)
                        UpdatedAt         = $reader.GetString(1)
                        DeliveryStartedAt = $startedAt
                        DeliveredAt       = $deliveredAt
                        DeliveryError     = $deliveryError
                    }
                } finally {
                    if ($null -ne $reader) {
                        $reader.Dispose()
                    }

                    if ($null -ne $command) {
                        $command.Dispose()
                    }

                    $connection.Dispose()
                }
            }

            function Assert-TestErrorId {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [scriptblock]$ScriptBlock,

                    [Parameter(Mandatory)]
                    [string]$ErrorId
                )

                $caught = $false

                try {
                    & $ScriptBlock
                } catch {
                    $caught = $true

                    $_.FullyQualifiedErrorId | Should -BeLike "$ErrorId*"
                }

                $caught | Should -BeTrue
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
        #endregion

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares all required parameters as mandatory' {
                $command = Get-Command -Name Set-DFeDeliveryState

                $requiredNames = @(
                    'Cnpj'
                    'DeliveryId'
                    'ExpectedStatus'
                    'ExpectedDeliveryStartedAt'
                    'Status'
                )

                foreach ($name in $requiredNames) {
                    $mandatory = @(
                        $command.Parameters[$name].Attributes |
                            Where-Object {
                                $_ -is [System.Management.Automation.ParameterAttribute] -and
                                $_.Mandatory
                            }
                    )

                    $mandatory | Should -HaveCount 1
                }
            }

            It 'Declares the expected output type' {
                $command = Get-Command -Name Set-DFeDeliveryState

                $command.OutputType.Type |
                    Should -Contain ([pscustomobject])
            }
        }
        #endregion

        #region Prepared to Sending
        Context 'Prepared to Sending' {

            It 'Starts a delivery and returns its new attempt timestamp' {
                $delivery = New-TestDelivery

                $transitionParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $delivery.DeliveryId
                    ExpectedStatus            = 'Prepared'
                    ExpectedDeliveryStartedAt = $null
                    Status                    = 'Sending'
                }

                $result = Set-DFeDeliveryState @transitionParams

                $result.PSTypeNames |
                    Should -Contain 'PipeDFe.DeliveryStateTransition'

                $result.Cnpj              | Should -Be $Script:TestCnpj
                $result.DeliveryId        | Should -Be $delivery.DeliveryId
                $result.PreviousStatus    | Should -Be 'Prepared'
                $result.DeliveryStatus    | Should -Be 'Sending'
                $result.DeliveryStartedAt | Should -Not -BeNullOrEmpty
                $result.DeliveredAt       | Should -BeNullOrEmpty
                $result.DeliveryError     | Should -BeNullOrEmpty

                $timestamp = [DateTimeOffset]::ParseExact(
                    $result.DeliveryStartedAt,
                    'o',
                    [System.Globalization.CultureInfo]::InvariantCulture
                )

                $timestamp.Offset | Should -Be ([TimeSpan]::Zero)
                $result.UpdatedAt | Should -Be $result.DeliveryStartedAt
            }

            It 'Persists Sending and its attempt timestamp' {
                $result = New-TestSendingDelivery

                $readParams = @{
                    Cnpj       = $Script:TestCnpj
                    DeliveryId = $result.DeliveryId
                }

                $stored = Get-TestDelivery @readParams

                $stored.DeliveryStatus    | Should -Be 'Sending'
                $stored.DeliveryStartedAt | Should -Be $result.DeliveryStartedAt
            }

            It 'Accepts case-insensitive state input and persists canonical values' {
                $delivery = New-TestDelivery

                $transitionParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $delivery.DeliveryId
                    ExpectedStatus            = 'prepared'
                    ExpectedDeliveryStartedAt = $null
                    Status                    = 'sending'
                }

                $result = Set-DFeDeliveryState @transitionParams

                $result.PreviousStatus | Should -Be 'Prepared'
                $result.DeliveryStatus | Should -Be 'Sending'
            }
        }
        #endregion

        #region Sending terminal transitions
        Context 'Sending terminal transitions' {

            It 'Marks a Sending delivery as Delivered' {
                $sending = New-TestSendingDelivery

                $transitionParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                    Status                    = 'Delivered'
                }

                $result = Set-DFeDeliveryState @transitionParams

                $result.PreviousStatus    | Should -Be 'Sending'
                $result.DeliveryStatus    | Should -Be 'Delivered'
                $result.DeliveryStartedAt | Should -Be $sending.DeliveryStartedAt
                $result.DeliveredAt       | Should -Not -BeNullOrEmpty
                $result.DeliveryError     | Should -BeNullOrEmpty
                $result.UpdatedAt         | Should -Be $result.DeliveredAt
            }

            It 'Marks a Sending delivery as Failed and stores the error' {
                $sending = New-TestSendingDelivery

                $transitionParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                    Status                    = 'Failed'
                    ErrorMessage              = 'SMTP connection failed.'
                }

                $result = Set-DFeDeliveryState @transitionParams

                $result.DeliveryStatus    | Should -Be 'Failed'
                $result.DeliveryStartedAt | Should -Be $sending.DeliveryStartedAt
                $result.DeliveredAt       | Should -BeNullOrEmpty
                $result.DeliveryError     | Should -Be 'SMTP connection failed.'
            }

            It 'Marks a Sending delivery as Indeterminate and stores the error' {
                $sending = New-TestSendingDelivery

                $transitionParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                    Status                    = 'Indeterminate'
                    ErrorMessage              = 'SMTP acceptance could not be determined.'
                }

                $result = Set-DFeDeliveryState @transitionParams

                $result.DeliveryStatus    | Should -Be 'Indeterminate'
                $result.DeliveryStartedAt | Should -Be $sending.DeliveryStartedAt
                $result.DeliveredAt       | Should -BeNullOrEmpty
                $result.DeliveryError     |
                    Should -Be 'SMTP acceptance could not be determined.'
            }

            It 'Persists terminal transitions after reopening the database' {
                $sending = New-TestSendingDelivery

                $transitionParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                    Status                    = 'Failed'
                    ErrorMessage              = 'Persistent failure.'
                }

                Set-DFeDeliveryState @transitionParams | Out-Null

                $readParams = @{
                    Cnpj       = $Script:TestCnpj
                    DeliveryId = $sending.DeliveryId
                }

                $stored = Get-TestDelivery @readParams

                $stored.DeliveryStatus | Should -Be 'Failed'
                $stored.DeliveryError  | Should -Be 'Persistent failure.'
            }
        }
        #endregion

        #region Failed retry
        Context 'Failed retry' {

            It 'Allows a controlled retry from Failed to Sending' {
                $sending = New-TestSendingDelivery

                $failedParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                    Status                    = 'Failed'
                    ErrorMessage              = 'Temporary SMTP failure.'
                }

                $failed = Set-DFeDeliveryState @failedParams

                $retryParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Failed'
                    ExpectedDeliveryStartedAt = $failed.DeliveryStartedAt
                    Status                    = 'Sending'
                }

                $retry = Set-DFeDeliveryState @retryParams

                $retry.DeliveryStatus    | Should -Be 'Sending'
                $retry.DeliveryError     | Should -BeNullOrEmpty
                $retry.DeliveredAt       | Should -BeNullOrEmpty
                $retry.DeliveryStartedAt | Should -Not -Be $failed.DeliveryStartedAt

                $previousTimestamp = [DateTimeOffset]::Parse(
                    $failed.DeliveryStartedAt
                )

                $retryTimestamp = [DateTimeOffset]::Parse(
                    $retry.DeliveryStartedAt
                )

                $retryTimestamp | Should -BeGreaterThan $previousTimestamp
            }

            It 'Uses a new UTC attempt timestamp on retry' {
                $sending = New-TestSendingDelivery

                $failedParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                    Status                    = 'Failed'
                    ErrorMessage              = 'Retry timestamp test.'
                }

                $failed = Set-DFeDeliveryState @failedParams

                $retryParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Failed'
                    ExpectedDeliveryStartedAt = $failed.DeliveryStartedAt
                    Status                    = 'Sending'
                }

                $retry = Set-DFeDeliveryState @retryParams

                $timestamp = [DateTimeOffset]::ParseExact(
                    $retry.DeliveryStartedAt,
                    'o',
                    [System.Globalization.CultureInfo]::InvariantCulture
                )

                $timestamp.Offset | Should -Be ([TimeSpan]::Zero)
            }
        }
        #endregion

        #region Transition validation
        Context 'Transition validation' {

            It 'Rejects Prepared to Delivered' {
                $delivery = New-TestDelivery

                $params = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $delivery.DeliveryId
                    ExpectedStatus            = 'Prepared'
                    ExpectedDeliveryStartedAt = $null
                    Status                    = 'Delivered'
                }

                $assertParams = @{
                    ErrorId     = 'InvalidDeliveryStateTransition'
                    ScriptBlock = { Set-DFeDeliveryState @params }
                }

                Assert-TestErrorId @assertParams
            }

            It 'Rejects Sending to Sending' {
                $sending = New-TestSendingDelivery

                $params = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                    Status                    = 'Sending'
                }

                $assertParams = @{
                    ErrorId     = 'InvalidDeliveryStateTransition'
                    ScriptBlock = { Set-DFeDeliveryState @params }
                }

                Assert-TestErrorId @assertParams
            }

            It 'Requires an error message for Failed' {
                $sending = New-TestSendingDelivery

                $params = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                    Status                    = 'Failed'
                }

                $assertParams = @{
                    ErrorId     = 'MissingDeliveryStateError'
                    ScriptBlock = { Set-DFeDeliveryState @params }
                }

                Assert-TestErrorId @assertParams
            }

            It 'Requires an error message for Indeterminate' {
                $sending = New-TestSendingDelivery

                $params = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                    Status                    = 'Indeterminate'
                }

                $assertParams = @{
                    ErrorId     = 'MissingDeliveryStateError'
                    ScriptBlock = { Set-DFeDeliveryState @params }
                }

                Assert-TestErrorId @assertParams
            }

            It 'Rejects an error message for Delivered' {
                $sending = New-TestSendingDelivery

                $params = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                    Status                    = 'Delivered'
                    ErrorMessage              = 'Unexpected error.'
                }

                $assertParams = @{
                    ErrorId     = 'UnexpectedDeliveryStateError'
                    ScriptBlock = { Set-DFeDeliveryState @params }
                }

                Assert-TestErrorId @assertParams
            }

            It 'Rejects an error message for Sending' {
                $delivery = New-TestDelivery

                $params = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $delivery.DeliveryId
                    ExpectedStatus            = 'Prepared'
                    ExpectedDeliveryStartedAt = $null
                    Status                    = 'Sending'
                    ErrorMessage              = 'Unexpected error.'
                }

                $assertParams = @{
                    ErrorId     = 'UnexpectedDeliveryStateError'
                    ScriptBlock = { Set-DFeDeliveryState @params }
                }

                Assert-TestErrorId @assertParams
            }

            It 'Requires an attempt timestamp after Prepared' {
                $delivery = New-TestDelivery

                $params = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $delivery.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $null
                    Status                    = 'Delivered'
                }

                $assertParams = @{
                    ErrorId     = 'InvalidExpectedDeliveryStartedAt'
                    ScriptBlock = { Set-DFeDeliveryState @params }
                }

                Assert-TestErrorId @assertParams
            }

            It 'Rejects an attempt timestamp when the expected state is Prepared' {
                $delivery = New-TestDelivery

                $params = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $delivery.DeliveryId
                    ExpectedStatus            = 'Prepared'
                    ExpectedDeliveryStartedAt = '2026-11-07T12:00:00.0000000+00:00'
                    Status                    = 'Sending'
                }

                $assertParams = @{
                    ErrorId     = 'InvalidExpectedDeliveryStartedAt'
                    ScriptBlock = { Set-DFeDeliveryState @params }
                }

                Assert-TestErrorId @assertParams
            }

            It 'Rejects a malformed attempt timestamp' {
                $delivery = New-TestDelivery

                $params = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $delivery.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = 'not-a-timestamp'
                    Status                    = 'Delivered'
                }

                $assertParams = @{
                    ErrorId     = 'InvalidExpectedDeliveryStartedAt'
                    ScriptBlock = { Set-DFeDeliveryState @params }
                }

                Assert-TestErrorId @assertParams
            }

            It 'Rejects an attempt timestamp that is not UTC' {
                $delivery = New-TestDelivery

                $params = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $delivery.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = '2026-11-07T12:00:00.0000000-03:00'
                    Status                    = 'Delivered'
                }

                $assertParams = @{
                    ErrorId     = 'InvalidExpectedDeliveryStartedAt'
                    ScriptBlock = { Set-DFeDeliveryState @params }
                }

                Assert-TestErrorId @assertParams
            }

            It 'Does not modify the delivery after invalid input' {
                $delivery = New-TestDelivery

                $params = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $delivery.DeliveryId
                    ExpectedStatus            = 'Prepared'
                    ExpectedDeliveryStartedAt = $null
                    Status                    = 'Delivered'
                }

                $assertParams = @{
                    ErrorId     = 'InvalidDeliveryStateTransition'
                    ScriptBlock = { Set-DFeDeliveryState @params }
                }

                Assert-TestErrorId @assertParams

                $readParams = @{
                    Cnpj       = $Script:TestCnpj
                    DeliveryId = $delivery.DeliveryId
                }

                $stored = Get-TestDelivery @readParams

                $stored.DeliveryStatus | Should -Be 'Prepared'
                $stored.DeliveryStartedAt | Should -BeNullOrEmpty
                $stored.DeliveredAt | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Concurrent state changes
        Context 'Concurrent state changes' {

            It 'Rejects a stale Prepared state after another operation starts Sending' {
                $sending = New-TestSendingDelivery

                $staleParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Prepared'
                    ExpectedDeliveryStartedAt = $null
                    Status                    = 'Sending'
                }

                $assertParams = @{
                    ErrorId     = 'ConcurrentDeliveryStateChange'
                    ScriptBlock = { Set-DFeDeliveryState @staleParams }
                }

                Assert-TestErrorId @assertParams

                $readParams = @{
                    Cnpj       = $Script:TestCnpj
                    DeliveryId = $sending.DeliveryId
                }

                $stored = Get-TestDelivery @readParams

                $stored.DeliveryStatus    | Should -Be 'Sending'
                $stored.DeliveryStartedAt | Should -Be $sending.DeliveryStartedAt
            }

            It 'Rejects a late result from an earlier attempt after an ABA retry' {
                $firstAttempt = New-TestSendingDelivery

                $failedParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $firstAttempt.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $firstAttempt.DeliveryStartedAt
                    Status                    = 'Failed'
                    ErrorMessage              = 'First attempt failed.'
                }

                $failed = Set-DFeDeliveryState @failedParams

                $retryParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $firstAttempt.DeliveryId
                    ExpectedStatus            = 'Failed'
                    ExpectedDeliveryStartedAt = $failed.DeliveryStartedAt
                    Status                    = 'Sending'
                }

                $secondAttempt = Set-DFeDeliveryState @retryParams

                $staleCompletionParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $firstAttempt.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $firstAttempt.DeliveryStartedAt
                    Status                    = 'Delivered'
                }

                $assertParams = @{
                    ErrorId     = 'ConcurrentDeliveryStateChange'
                    ScriptBlock = { Set-DFeDeliveryState @staleCompletionParams }
                }

                Assert-TestErrorId @assertParams

                $readParams = @{
                    Cnpj       = $Script:TestCnpj
                    DeliveryId = $firstAttempt.DeliveryId
                }

                $stored = Get-TestDelivery @readParams

                $stored.DeliveryStatus    | Should -Be 'Sending'
                $stored.DeliveryStartedAt |
                    Should -Be $secondAttempt.DeliveryStartedAt

                $stored.DeliveredAt   | Should -BeNullOrEmpty
                $stored.DeliveryError | Should -BeNullOrEmpty
            }

            It 'Rejects a stale completion after the delivery has become Delivered' {
                $sending = New-TestSendingDelivery

                $completeParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                    Status                    = 'Delivered'
                }

                Set-DFeDeliveryState @completeParams | Out-Null

                $staleParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                    Status                    = 'Failed'
                    ErrorMessage              = 'Late failure.'
                }

                $assertParams = @{
                    ErrorId     = 'ConcurrentDeliveryStateChange'
                    ScriptBlock = { Set-DFeDeliveryState @staleParams }
                }

                Assert-TestErrorId @assertParams

                $readParams = @{
                    Cnpj       = $Script:TestCnpj
                    DeliveryId = $sending.DeliveryId
                }

                $stored = Get-TestDelivery @readParams

                $stored.DeliveryStatus | Should -Be 'Delivered'
                $stored.DeliveryError  | Should -BeNullOrEmpty
            }

            It 'Does not allow Indeterminate to be retried' {
                $sending = New-TestSendingDelivery

                $indeterminateParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                    Status                    = 'Indeterminate'
                    ErrorMessage              = 'Acceptance is unknown.'
                }

                Set-DFeDeliveryState @indeterminateParams | Out-Null

                $retryParams = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = $sending.DeliveryId
                    ExpectedStatus            = 'Indeterminate'
                    ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                    Status                    = 'Sending'
                }

                { Set-DFeDeliveryState @retryParams } | Should -Throw

                $readParams = @{
                    Cnpj       = $Script:TestCnpj
                    DeliveryId = $sending.DeliveryId
                }

                $stored = Get-TestDelivery @readParams

                $stored.DeliveryStatus | Should -Be 'Indeterminate'
            }
        }
        #endregion

        #region Delivery not found
        Context 'Delivery not found' {

            It 'Throws DeliveryNotFound for an unknown identifier' {
                $params = @{
                    Cnpj                      = $Script:TestCnpj
                    DeliveryId                = [guid]::NewGuid().ToString('N')
                    ExpectedStatus            = 'Prepared'
                    ExpectedDeliveryStartedAt = $null
                    Status                    = 'Sending'
                }

                Assert-TestErrorId -ErrorId 'DeliveryNotFound' -ScriptBlock {
                    Set-DFeDeliveryState @params
                }
            }
        }
        #endregion

        #region CNPJ isolation
        Context 'CNPJ isolation' {

            It 'Updates only the delivery in the supplied company index' {
                $otherCnpj = '12345678000351'

                Initialize-DFeIndex -Cnpj $otherCnpj | Out-Null

                $delivery = New-TestDelivery -Cnpj $otherCnpj

                $transitionParams = @{
                    Cnpj                      = $otherCnpj
                    DeliveryId                = $delivery.DeliveryId
                    ExpectedStatus            = 'Prepared'
                    ExpectedDeliveryStartedAt = $null
                    Status                    = 'Sending'
                }

                $result = Set-DFeDeliveryState @transitionParams

                $result.DeliveryStatus | Should -Be 'Sending'

                $otherReadParams = @{
                    Cnpj       = $otherCnpj
                    DeliveryId = $delivery.DeliveryId
                }

                $primaryReadParams = @{
                    Cnpj       = $Script:TestCnpj
                    DeliveryId = $delivery.DeliveryId
                }

                $otherStored   = Get-TestDelivery @otherReadParams
                $primaryStored = Get-TestDelivery @primaryReadParams

                $otherStored.DeliveryStatus | Should -Be 'Sending'
                $primaryStored | Should -BeNullOrEmpty
            }
        }
        #endregion
    }
}
