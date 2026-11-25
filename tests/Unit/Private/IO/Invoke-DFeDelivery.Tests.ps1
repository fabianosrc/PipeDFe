#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Invoke-DFeDelivery.

.DESCRIPTION
Covers the persistent delivery lifecycle orchestration.
All inner dependencies are mocked.

Coverage includes:
  - Returns a PSCustomObject with Success, EmailsSent, ErrorMessage,
    FailedAt, DeliveryId and DeliveryStatus.
  - Never throws on any failure path.
  - Returns FailedAt = Validation when Para is empty.
  - Does not call New-DFeDelivery on validation failure.
  - Returns FailedAt = Persistence when New-DFeDelivery throws.
  - Returns immediately with Success = true when status is Delivered.
  - Does not call Send-DFeNotification when status is Delivered.
  - Returns FailedAt = State when status is Indeterminate.
  - Explains the retry block and includes the stored DeliveryError when available.
  - Returns a default error when Indeterminate has no stored error.
  - Transitions Sending to Indeterminate when an orphan is found.
  - Returns FailedAt = State when orphan transition fails.
  - Returns FailedAt = State for unsupported delivery status.
  - Transitions Prepared to Sending before calling Send-DFeNotification.
  - Transitions Failed to Sending before calling Send-DFeNotification.
  - Returns FailedAt = State when transition to Sending fails.
  - Transitions to Delivered on successful notification.
  - Returns DeliveryStatus = Delivered on success.
  - Returns FailedAt = Persistence when Delivered cannot be persisted.
  - Transitions to Failed when AcceptanceUncertain is false.
  - Transitions to Indeterminate when AcceptanceUncertain is true.
  - Transitions to Indeterminate when AcceptanceUncertain is missing.
  - Returns the notification ErrorMessage on send failure.
  - Returns FailedAt = Persistence when failure state cannot be persisted.
  - Passes Archives DestPath as ZipFileDestination to Send-DFeNotification.
  - Passes Gaps to Send-DFeNotification.
  - Passes Entries to Send-DFeNotification.
  - Calls New-DFePeriodReport when IncludeMonthlyReports is set.
  - Does not call New-DFePeriodReport when IncludeMonthlyReports is absent.
  - Returns FailedAt = Reports when New-DFePeriodReport throws.
  - Passes ReportFilePaths from New-DFePeriodReport to Send-DFeNotification.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Test helpers modify isolated fixtures.'
)]

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    '',
    Justification = 'Parameter used by ConvertTo-NormalizedMailRecipient mock signature.'
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

Describe 'Invoke-DFeDelivery' {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            $Script:ValidCompany = [PSCustomObject]@{
                NomeFantasia = 'Empresa Teste'
                RazaoSocial  = 'Empresa Teste Ltda'
                Cnpj         = '11222333000181'
                Email        = [PSCustomObject]@{
                    Para = @(
                        [PSCustomObject]@{
                            Name  = 'Dest'
                            Email = 'dest@example.com'
                        }
                    )
                    Cc   = @()
                    Cco  = @()
                }
            }

            $Script:ValidDateRange = [PSCustomObject]@{
                Start = [System.DateTimeOffset]::new(
                    2026, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero
                )
                End   = [System.DateTimeOffset]::new(
                    2026, 1, 31, 23, 59, 59, [System.TimeSpan]::Zero
                )
            }

            $Script:ValidSmtp = [PSCustomObject]@{
                Server = 'smtp.example.com'
                Port   = 587
            }

            $Script:ValidArchive = [PSCustomObject]@{
                TipoDFe  = 'NFe'
                FileName = 'NFe_11222333000181_202601.zip'
                FileHash = 'a' * 64
                DestPath = 'C:\Temp\NFe_11222333000181_202601.zip'
            }

            $Script:DeliveryId        = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4'
            $Script:DeliveryStartedAt = '2026-01-15T10:00:00.0000000+00:00'

            $Script:PreparedDelivery = [PSCustomObject]@{
                DeliveryId        = $Script:DeliveryId
                DeliveryStatus    = 'Prepared'
                DeliveryStartedAt = $null
                DeliveryError     = $null
                Recipients        = @(
                    [PSCustomObject]@{
                        RecipientType = 'To'
                        Address       = 'dest@example.com'
                    }
                )
                Archives          = @($Script:ValidArchive)
            }

            $Script:SendingState = [PSCustomObject]@{
                DeliveryId        = $Script:DeliveryId
                DeliveryStatus    = 'Sending'
                DeliveryStartedAt = $Script:DeliveryStartedAt
            }

            $Script:SuccessNotificationResult = [PSCustomObject]@{
                Success      = $true
                EmailsSent   = @('dest@example.com')
                ErrorMessage = $null
                FailedAt     = $null
            }

            $Script:ValidEntries = @(
                [PSCustomObject]@{
                    chave_acesso = '1' * 44
                    modelo       = 55
                }
            )

            $Script:BaseParams = @{
                Company   = $Script:ValidCompany
                DateRange = $Script:ValidDateRange
                Smtp      = $Script:ValidSmtp
                Gaps      = @()
                Archives  = @($Script:ValidArchive)
                Entries   = $Script:ValidEntries
            }

            Mock -CommandName ConvertTo-NormalizedMailRecipient -MockWith {
                param (
                    [Parameter()]
                    [object]$InputObject
                )

                [PSCustomObject]@{
                    Name  = 'Dest'
                    Email = 'dest@example.com'
                }
            }

            Mock -CommandName New-DFeDelivery -MockWith {
                $Script:PreparedDelivery
            }

            Mock -CommandName Set-DFeDeliveryState -MockWith {
                $Script:SendingState
            }

            Mock -CommandName Send-DFeNotification -MockWith {
                $Script:SuccessNotificationResult
            }

            Mock -CommandName New-DFePeriodReport -MockWith {
                @(
                    'C:\Reports\Resumo-CFOP.html',
                    'C:\Reports\Fechamento.xlsx'
                )
            }
        }
        #endregion

        #region Result object shape
        Context 'Result object shape' {

            It 'Returns a PSCustomObject' {
                $result = Invoke-DFeDelivery @Script:BaseParams

                $result | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly the documented properties' {
                $result = Invoke-DFeDelivery @Script:BaseParams

                $expected = @(
                    'Success'
                    'EmailsSent'
                    'ErrorMessage'
                    'FailedAt'
                    'DeliveryId'
                    'DeliveryStatus'
                )

                $actual = @($result.PSObject.Properties.Name)

                $actual | Should -Be $expected
            }
        }
        #endregion

        #region Never throws
        Context 'Never throws' {

            It 'Does not throw when New-DFeDelivery throws' {
                Mock -CommandName New-DFeDelivery -MockWith {
                    throw 'persistence error'
                }

                $scriptBlock = { Invoke-DFeDelivery @Script:BaseParams }

                $scriptBlock | Should -Not -Throw
            }

            It 'Does not throw when Send-DFeNotification returns failure' {
                Mock -CommandName Send-DFeNotification -MockWith {
                    [PSCustomObject]@{
                        Success       = $false
                        EmailsSent    = @()
                        ErrorMessage  = 'Connection refused'
                        FailedAt      = 'Send'
                        AcceptanceUncertain = $false
                    }
                }

                $scriptBlock = { Invoke-DFeDelivery @Script:BaseParams }

                $scriptBlock | Should -Not -Throw
            }

            It 'Does not throw when Set-DFeDeliveryState throws' {
                Mock -CommandName Set-DFeDeliveryState -MockWith {
                    throw 'state error'
                }

                $scriptBlock = { Invoke-DFeDelivery @Script:BaseParams }

                $scriptBlock | Should -Not -Throw
            }
        }
        #endregion

        #region Validation stage
        Context 'Validation stage' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedMailRecipient -MockWith {
                    param (
                        [Parameter()]
                        [object]$InputObject
                    )
                }

                $Script:ValidationResult = Invoke-DFeDelivery @Script:BaseParams
            }

            It 'Returns Success = false when Para is empty' {
                $Script:ValidationResult.Success | Should -BeFalse
            }

            It 'Returns FailedAt = Validation when Para is empty' {
                $Script:ValidationResult.FailedAt | Should -Be 'Validation'
            }

            It 'Returns empty EmailsSent on validation failure' {
                $Script:ValidationResult.EmailsSent | Should -HaveCount 0
            }

            It 'Returns null DeliveryId on validation failure' {
                $Script:ValidationResult.DeliveryId | Should -BeNullOrEmpty
            }

            It 'Returns null DeliveryStatus on validation failure' {
                $Script:ValidationResult.DeliveryStatus | Should -BeNullOrEmpty
            }

            It 'Does not call New-DFeDelivery on validation failure' {
                Should -Invoke -CommandName New-DFeDelivery -Times 0 -Exactly
            }

            It 'Does not call Send-DFeNotification on validation failure' {
                Should -Invoke -CommandName Send-DFeNotification -Times 0 -Exactly
            }
        }
        #endregion

        #region Persistence failure
        Context 'Persistence failure' {

            BeforeAll {

                Mock -CommandName New-DFeDelivery -MockWith {
                    throw 'index write failed'
                }

                $Script:PersistenceResult = Invoke-DFeDelivery @Script:BaseParams
            }

            It 'Returns Success = false when New-DFeDelivery throws' {
                $Script:PersistenceResult.Success | Should -BeFalse
            }

            It 'Returns FailedAt = Persistence when New-DFeDelivery throws' {
                $Script:PersistenceResult.FailedAt | Should -Be 'Persistence'
            }

            It 'Returns null DeliveryId when New-DFeDelivery throws' {
                $Script:PersistenceResult.DeliveryId | Should -BeNullOrEmpty
            }

            It 'Does not call Send-DFeNotification when New-DFeDelivery throws' {
                Should -Invoke -CommandName Send-DFeNotification -Times 0 -Exactly
            }
        }
        #endregion

        #region Delivered guard
        Context 'Delivered guard' {

            BeforeAll {

                Mock -CommandName New-DFeDelivery -MockWith {
                    [PSCustomObject]@{
                        DeliveryId        = $Script:DeliveryId
                        DeliveryStatus    = 'Delivered'
                        DeliveryStartedAt = $Script:DeliveryStartedAt
                        DeliveryError     = $null
                        Recipients        = @(
                            [PSCustomObject]@{
                                RecipientType = 'To'
                                Address       = 'dest@example.com'
                            }
                        )
                        Archives          = @($Script:ValidArchive)
                    }
                }

                $Script:DeliveredResult = Invoke-DFeDelivery @Script:BaseParams
            }

            It 'Returns Success = true for an already Delivered delivery' {
                $Script:DeliveredResult.Success | Should -BeTrue
            }

            It 'Returns DeliveryStatus = Delivered' {
                $Script:DeliveredResult.DeliveryStatus | Should -Be 'Delivered'
            }

            It 'Returns the stored To recipient addresses' {
                $Script:DeliveredResult.EmailsSent | Should -Contain 'dest@example.com'
            }

            It 'Returns null ErrorMessage' {
                $Script:DeliveredResult.ErrorMessage | Should -BeNullOrEmpty
            }

            It 'Does not call Send-DFeNotification when already Delivered' {
                Should -Invoke -CommandName Send-DFeNotification -Times 0 -Exactly
            }

            It 'Does not call Set-DFeDeliveryState when already Delivered' {
                Should -Invoke -CommandName Set-DFeDeliveryState -Times 0 -Exactly
            }
        }
        #endregion

        #region Indeterminate guard
        Context 'Indeterminate guard' {

            BeforeAll {

                Mock -CommandName New-DFeDelivery -MockWith {
                    [PSCustomObject]@{
                        DeliveryId        = $Script:DeliveryId
                        DeliveryStatus    = 'Indeterminate'
                        DeliveryStartedAt = $Script:DeliveryStartedAt
                        DeliveryError     = 'SMTP acceptance could not be determined.'
                        Recipients        = @()
                        Archives          = @($Script:ValidArchive)
                    }
                }

                $Script:IndeterminateResult = Invoke-DFeDelivery @Script:BaseParams
            }

            It 'Returns Success = false for an Indeterminate delivery' {
                $Script:IndeterminateResult.Success | Should -BeFalse
            }

            It 'Returns FailedAt = State for an Indeterminate delivery' {
                $Script:IndeterminateResult.FailedAt | Should -Be 'State'
            }

            It 'Returns DeliveryStatus = Indeterminate' {
                $Script:IndeterminateResult.DeliveryStatus | Should -Be 'Indeterminate'
            }

            It 'Explains the retry block in the error message' {
                $Script:IndeterminateResult.ErrorMessage |
                    Should -Match 'Automatic retry is blocked'
            }

            It 'Includes the previous delivery error in the message' {
                $Script:IndeterminateResult.ErrorMessage |
                    Should -Match 'SMTP acceptance could not be determined'
            }

            It 'Does not call Send-DFeNotification for an Indeterminate delivery' {
                Should -Invoke -CommandName Send-DFeNotification -Times 0 -Exactly
            }

            It 'Does not call Set-DFeDeliveryState for an Indeterminate delivery' {
                Should -Invoke -CommandName Set-DFeDeliveryState -Times 0 -Exactly
            }
        }

        Context 'Indeterminate guard with no stored error' {

            BeforeAll {

                Mock -CommandName New-DFeDelivery -MockWith {
                    [PSCustomObject]@{
                        DeliveryId        = $Script:DeliveryId
                        DeliveryStatus    = 'Indeterminate'
                        DeliveryStartedAt = $Script:DeliveryStartedAt
                        DeliveryError     = $null
                        Recipients        = @()
                        Archives          = @($Script:ValidArchive)
                    }
                }

                $Script:IndeterminateNoErrorResult = Invoke-DFeDelivery @Script:BaseParams
            }

            It 'Returns a default error message when DeliveryError is empty' {
                $Script:IndeterminateNoErrorResult.ErrorMessage |
                    Should -Match 'Automatic retry is blocked'
            }

            It 'Does not append a previous attempt section when DeliveryError is empty' {
                $Script:IndeterminateNoErrorResult.ErrorMessage |
                    Should -Not -Match 'Previous attempt error'
            }
        }
        #endregion

        #region Orphan Sending recovery
        Context 'Orphan Sending recovery' {

            BeforeAll {

                Mock -CommandName New-DFeDelivery -MockWith {
                    [PSCustomObject]@{
                        DeliveryId        = $Script:DeliveryId
                        DeliveryStatus    = 'Sending'
                        DeliveryStartedAt = $Script:DeliveryStartedAt
                        DeliveryError     = $null
                        Recipients        = @()
                        Archives          = @($Script:ValidArchive)
                    }
                }

                Mock -CommandName Set-DFeDeliveryState -MockWith {
                    [PSCustomObject]@{
                        DeliveryId     = $Script:DeliveryId
                        DeliveryStatus = 'Indeterminate'
                    }
                }

                $Script:OrphanResult = Invoke-DFeDelivery @Script:BaseParams
            }

            It 'Returns Success = false for an orphan Sending delivery' {
                $Script:OrphanResult.Success | Should -BeFalse
            }

            It 'Returns FailedAt = State for an orphan Sending delivery' {
                $Script:OrphanResult.FailedAt | Should -Be 'State'
            }

            It 'Returns DeliveryStatus = Indeterminate after orphan recovery' {
                $Script:OrphanResult.DeliveryStatus | Should -Be 'Indeterminate'
            }

            It 'Transitions the orphan to Indeterminate' {
                $assertParams = @{
                    CommandName     = 'Set-DFeDeliveryState'
                    Times           = 1
                    Exactly         = $true
                    Scope           = 'Context'
                    ParameterFilter = { $Status -eq 'Indeterminate' }
                }

                Should -Invoke @assertParams
            }

            It 'Does not call Send-DFeNotification for an orphan Sending delivery' {
                Should -Invoke -CommandName Send-DFeNotification -Times 0 -Exactly -Scope Context
            }
        }

        Context 'Orphan Sending recovery failure' {

            BeforeAll {

                Mock -CommandName New-DFeDelivery -MockWith {
                    [PSCustomObject]@{
                        DeliveryId        = $Script:DeliveryId
                        DeliveryStatus    = 'Sending'
                        DeliveryStartedAt = $Script:DeliveryStartedAt
                        DeliveryError     = $null
                        Recipients        = @()
                        Archives          = @($Script:ValidArchive)
                    }
                }

                Mock -CommandName Set-DFeDeliveryState -MockWith {
                    throw 'concurrent state change'
                }

                $Script:OrphanFailureResult = Invoke-DFeDelivery @Script:BaseParams
            }

            It 'Returns FailedAt = State when orphan transition throws' {
                $Script:OrphanFailureResult.FailedAt | Should -Be 'State'
            }

            It 'Returns DeliveryStatus = Sending when orphan transition throws' {
                $Script:OrphanFailureResult.DeliveryStatus | Should -Be 'Sending'
            }
        }
        #endregion

        #region Unsupported state guard
        Context 'Unsupported state guard' {

            BeforeAll {

                Mock -CommandName New-DFeDelivery -MockWith {
                    [PSCustomObject]@{
                        DeliveryId        = $Script:DeliveryId
                        DeliveryStatus    = 'UnknownState'
                        DeliveryStartedAt = $null
                        DeliveryError     = $null
                        Recipients        = @()
                        Archives          = @($Script:ValidArchive)
                    }
                }

                $Script:UnsupportedResult = Invoke-DFeDelivery @Script:BaseParams
            }

            It 'Returns FailedAt = State for an unsupported delivery status' {
                $Script:UnsupportedResult.FailedAt | Should -Be 'State'
            }

            It 'Returns Success = false for an unsupported delivery status' {
                $Script:UnsupportedResult.Success | Should -BeFalse
            }
        }
        #endregion

        #region Transition to Sending
        Context 'Transition to Sending' {

            It 'Transitions a Prepared delivery to Sending before notification' {
                $assertParams = @{
                    CommandName     = 'Set-DFeDeliveryState'
                    Times           = 1
                    Exactly         = $true
                    Scope           = 'It'
                    ParameterFilter = {
                        $ExpectedStatus -eq 'Prepared' -and $Status -eq 'Sending'
                    }
                }

                Invoke-DFeDelivery @Script:BaseParams | Out-Null

                Should -Invoke @assertParams
            }

            It 'Transitions a Failed delivery to Sending before notification' {
                Mock -CommandName New-DFeDelivery -MockWith {
                    [PSCustomObject]@{
                        DeliveryId        = $Script:DeliveryId
                        DeliveryStatus    = 'Failed'
                        DeliveryStartedAt = $Script:DeliveryStartedAt
                        DeliveryError     = 'Previous failure.'
                        Recipients        = @()
                        Archives          = @($Script:ValidArchive)
                    }
                }

                $assertParams = @{
                    CommandName     = 'Set-DFeDeliveryState'
                    Times           = 1
                    Exactly         = $true
                    Scope           = 'It'
                    ParameterFilter = {
                        $ExpectedStatus -eq 'Failed' -and $Status -eq 'Sending'
                    }
                }

                Invoke-DFeDelivery @Script:BaseParams | Out-Null

                Should -Invoke @assertParams
            }

            #region Transition to Sending fails
            Context 'Transition to Sending fails' {

                BeforeAll {

                    Mock -CommandName Set-DFeDeliveryState -MockWith {
                        throw 'concurrent state change'
                    }

                    $Script:ToSendingFailResult = Invoke-DFeDelivery @Script:BaseParams
                }

                It 'Returns FailedAt = State when transition to Sending fails' {
                    $Script:ToSendingFailResult.FailedAt | Should -Be 'State'
                }

                It 'Returns Success = false when transition to Sending fails' {
                    $Script:ToSendingFailResult.Success | Should -BeFalse
                }

                It 'Does not call Send-DFeNotification when transition to Sending fails' {
                    Should -Invoke -CommandName Send-DFeNotification -Times 0 -Exactly
                }
            }
        }
        #endregion

        #region Happy path
        Context 'Happy path' {

            BeforeAll {

                $Script:HappyResult = Invoke-DFeDelivery @Script:BaseParams
            }

            It 'Returns Success = true on successful delivery' {
                $Script:HappyResult.Success | Should -BeTrue
            }

            It 'Returns DeliveryStatus = Delivered on success' {
                $Script:HappyResult.DeliveryStatus | Should -Be 'Delivered'
            }

            It 'Returns the recipient addresses from Send-DFeNotification' {
                $Script:HappyResult.EmailsSent | Should -Contain 'dest@example.com'
            }

            It 'Returns null ErrorMessage on success' {
                $Script:HappyResult.ErrorMessage | Should -BeNullOrEmpty
            }

            It 'Returns null FailedAt on success' {
                $Script:HappyResult.FailedAt | Should -BeNullOrEmpty
            }

            It 'Returns the DeliveryId' {
                $Script:HappyResult.DeliveryId | Should -Be $Script:DeliveryId
            }

            It 'Transitions to Delivered after successful notification' {
                $assertParams = @{
                    CommandName     = 'Set-DFeDeliveryState'
                    Times           = 1
                    Exactly         = $true
                    Scope           = 'Context'
                    ParameterFilter = { $Status -eq 'Delivered' }
                }

                Should -Invoke @assertParams
            }
        }
        #endregion

        #region Delivered persistence failure
        Context 'Delivered persistence failure' {

            BeforeAll {

                $Script:StateCallCount = 0

                Mock -CommandName Set-DFeDeliveryState -MockWith {
                    param (
                        [Parameter()]
                        [string]$Cnpj,

                        [Parameter()]
                        [string]$DeliveryId,

                        [Parameter()]
                        [string]$ExpectedStatus,

                        [Parameter()]
                        [AllowNull()]
                        [object]$ExpectedDeliveryStartedAt,

                        [Parameter()]
                        [string]$Status,

                        [Parameter()]
                        [AllowNull()]
                        [string]$ErrorMessage
                    )

                    $Script:StateCallCount++

                    if ($Script:StateCallCount -eq 1) {
                        return $Script:SendingState
                    }

                    throw 'DB write failed'
                }

                $Script:DeliveredPersistenceResult = Invoke-DFeDelivery @Script:BaseParams
            }

            It 'Returns FailedAt = Persistence when Delivered cannot be persisted' {
                $Script:DeliveredPersistenceResult.FailedAt | Should -Be 'Persistence'
            }

            It 'Returns Success = false when Delivered cannot be persisted' {
                $Script:DeliveredPersistenceResult.Success | Should -BeFalse
            }

            It 'Returns DeliveryStatus = Sending when Delivered cannot be persisted' {
                $Script:DeliveredPersistenceResult.DeliveryStatus | Should -Be 'Sending'
            }
        }
        #endregion

        #region Send failure state transitions
        Context 'Send failure - before SMTP' {

            BeforeAll {

                Mock -CommandName Send-DFeNotification -MockWith {
                    [PSCustomObject]@{
                        Success       = $false
                        EmailsSent    = @()
                        ErrorMessage  = 'Attachment not found.'
                        FailedAt      = 'Send'
                        AcceptanceUncertain = $false
                    }
                }

                $Script:PreSendFailureResult = Invoke-DFeDelivery @Script:BaseParams
            }

            It 'Returns Success = false' {
                $Script:PreSendFailureResult.Success | Should -BeFalse
            }

            It 'Transitions to Failed when AcceptanceUncertain is false' {
                $assertParams = @{
                    CommandName     = 'Set-DFeDeliveryState'
                    Times           = 1
                    Exactly         = $true
                    Scope           = 'Context'
                    ParameterFilter = { $Status -eq 'Failed' }
                }

                Should -Invoke @assertParams
            }

            It 'Returns DeliveryStatus = Failed when AcceptanceUncertain is false' {
                $Script:PreSendFailureResult.DeliveryStatus | Should -Be 'Failed'
            }

            It 'Returns the notification ErrorMessage' {
                $Script:PreSendFailureResult.ErrorMessage |
                    Should -Be 'Attachment not found.'
            }
        }

        Context 'Send failure - after SMTP started' {

            BeforeAll {

                Mock -CommandName Send-DFeNotification -MockWith {
                    [PSCustomObject]@{
                        Success       = $false
                        EmailsSent    = @()
                        ErrorMessage  = 'Connection reset by peer.'
                        FailedAt      = 'Send'
                        AcceptanceUncertain = $true
                    }
                }

                $Script:PostSendFailureResult = Invoke-DFeDelivery @Script:BaseParams
            }

            It 'Transitions to Indeterminate when AcceptanceUncertain is true' {
                $assertParams = @{
                    CommandName     = 'Set-DFeDeliveryState'
                    Times           = 1
                    Exactly         = $true
                    Scope           = 'Context'
                    ParameterFilter = { $Status -eq 'Indeterminate' }
                }

                Should -Invoke @assertParams
            }

            It 'Returns DeliveryStatus = Indeterminate when AcceptanceUncertain is true' {
                $Script:PostSendFailureResult.DeliveryStatus | Should -Be 'Indeterminate'
            }

            It 'Returns the notification ErrorMessage' {
                $Script:PostSendFailureResult.ErrorMessage |
                    Should -Be 'Connection reset by peer.'
            }
        }

        Context 'Send failure - AcceptanceUncertain missing' {

            BeforeAll {

                Mock -CommandName Send-DFeNotification -MockWith {
                    [PSCustomObject]@{
                        Success      = $false
                        EmailsSent   = @()
                        ErrorMessage = 'Unknown failure.'
                        FailedAt     = 'Send'
                    }
                }

                $Script:CapturedStatus = $null

                Mock -CommandName Set-DFeDeliveryState -MockWith {
                    param (
                        [Parameter()]
                        [string]$Cnpj,

                        [Parameter()]
                        [string]$DeliveryId,

                        [Parameter()]
                        [string]$ExpectedStatus,

                        [Parameter()]
                        [AllowNull()]
                        [object]$ExpectedDeliveryStartedAt,

                        [Parameter()]
                        [string]$Status,

                        [Parameter()]
                        [AllowNull()]
                        [string]$ErrorMessage
                    )

                    if ($Status -eq 'Sending') {
                        return $Script:SendingState
                    }

                    $Script:CapturedStatus = $Status
                    return $Script:SendingState
                }

                Invoke-DFeDelivery @Script:BaseParams | Out-Null
            }

            It 'Transitions to Indeterminate when AcceptanceUncertain is absent' {
                $Script:CapturedStatus | Should -Be 'Indeterminate'
            }
        }

        Context 'Send failure - state persistence fails' {

            BeforeAll {

                Mock -CommandName Send-DFeNotification -MockWith {
                    [PSCustomObject]@{
                        Success       = $false
                        EmailsSent    = @()
                        ErrorMessage  = 'Connection refused.'
                        FailedAt      = 'Send'
                        AcceptanceUncertain = $false
                    }
                }

                $Script:StateCallCount = 0

                Mock -CommandName Set-DFeDeliveryState -MockWith {
                    param (
                        [Parameter()]
                        [string]$Cnpj,

                        [Parameter()]
                        [string]$DeliveryId,

                        [Parameter()]
                        [string]$ExpectedStatus,

                        [Parameter()]
                        [AllowNull()]
                        [object]$ExpectedDeliveryStartedAt,

                        [Parameter()]
                        [string]$Status,

                        [Parameter()]
                        [AllowNull()]
                        [string]$ErrorMessage
                    )

                    $Script:StateCallCount++

                    if ($Script:StateCallCount -eq 1) {
                        return $Script:SendingState
                    }

                    throw 'DB write failed'
                }

                $Script:StatePersistenceFailResult = Invoke-DFeDelivery @Script:BaseParams
            }

            It 'Returns FailedAt = Persistence when failure state cannot be persisted' {
                $Script:StatePersistenceFailResult.FailedAt |
                    Should -Be 'Persistence'
            }

            It 'Returns DeliveryStatus = Sending when failure state cannot be persisted' {
                $Script:StatePersistenceFailResult.DeliveryStatus |
                    Should -Be 'Sending'
            }
        }
        #endregion

        #region Delegation
        Context 'Delegation' {

            It 'Passes Archives DestPath as ZipFileDestination to Send-DFeNotification' {
                $assertParams = @{
                    CommandName     = 'Send-DFeNotification'
                    Times           = 1
                    Exactly         = $true
                    Scope           = 'It'
                    ParameterFilter = {
                        $ZipFileDestination -contains $Script:ValidArchive.DestPath
                    }
                }

                Invoke-DFeDelivery @Script:BaseParams | Out-Null

                Should -Invoke @assertParams
            }

            It 'Passes Gaps to Send-DFeNotification' {
                $gaps = @(
                    [PSCustomObject]@{
                        Inicial = 1
                        Final   = 3
                        Serie   = '001'
                        Especie = 'NF-e'
                    }
                )

                $gapParams = $Script:BaseParams.Clone()
                $gapParams.Gaps = $gaps

                $assertParams = @{
                    CommandName     = 'Send-DFeNotification'
                    Times           = 1
                    Exactly         = $true
                    Scope           = 'It'
                    ParameterFilter = { $Gaps.Count -eq 1 }
                }

                Invoke-DFeDelivery @gapParams | Out-Null

                Should -Invoke @assertParams
            }

            It 'Passes Entries to Send-DFeNotification' {
                $assertParams = @{
                    CommandName     = 'Send-DFeNotification'
                    Times           = 1
                    Exactly         = $true
                    Scope           = 'It'
                    ParameterFilter = { $Entries.Count -eq 1 }
                }

                Invoke-DFeDelivery @Script:BaseParams | Out-Null

                Should -Invoke @assertParams
            }
        }
        #endregion

        #region Dependency errors
        Context 'Unexpected dependency errors' {

            Context 'Recipient normalization throws' {

                BeforeAll {

                    Mock -CommandName ConvertTo-NormalizedMailRecipient -MockWith {
                        throw [System.InvalidOperationException]::new(
                            'Recipient normalization failed.'
                        )
                    }

                    $Script:NormalizationErrorResult = Invoke-DFeDelivery @Script:BaseParams
                }

                It 'Returns Validation failure when recipient normalization throws' {
                    $Script:NormalizationErrorResult.Success  | Should -BeFalse
                    $Script:NormalizationErrorResult.FailedAt | Should -Be 'Validation'
                }

                It 'Includes the normalization error message' {
                    $Script:NormalizationErrorResult.ErrorMessage |
                        Should -Match 'Recipient normalization failed'
                }

                It 'Returns null DeliveryId when normalization throws' {
                    $Script:NormalizationErrorResult.DeliveryId | Should -BeNullOrEmpty
                }

                It 'Does not call New-DFeDelivery when normalization throws' {
                    Should -Invoke -CommandName New-DFeDelivery -Times 0 -Exactly
                }

                It 'Does not call Send-DFeNotification when normalization throws' {
                    Should -Invoke -CommandName Send-DFeNotification -Times 0 -Exactly
                }
            }

            Context 'Notification unexpectedly throws' {

                BeforeAll {

                    Mock -CommandName Send-DFeNotification -MockWith {
                        throw [System.InvalidOperationException]::new(
                            'Unexpected notification failure.'
                        )
                    }

                    Mock -CommandName Set-DFeDeliveryState -MockWith {
                        if ($Status -eq 'Sending') {
                            return $Script:SendingState
                        }

                        [PSCustomObject]@{
                            DeliveryId     = $Script:DeliveryId
                            DeliveryStatus = $Status
                        }
                    }

                    $Script:UnexpectedThrowResult = Invoke-DFeDelivery @Script:BaseParams
                }

                It 'Returns Indeterminate when notification unexpectedly throws' {
                    $Script:UnexpectedThrowResult.Success        | Should -BeFalse
                    $Script:UnexpectedThrowResult.FailedAt       | Should -Be 'Send'
                    $Script:UnexpectedThrowResult.DeliveryStatus | Should -Be 'Indeterminate'
                }

                It 'Transitions to Indeterminate after an unexpected throw' {
                    $assertParams = @{
                        CommandName     = 'Set-DFeDeliveryState'
                        Times           = 1
                        Exactly         = $true
                        Scope           = 'Context'
                        ParameterFilter = {
                            $Status -eq 'Indeterminate' -and
                            $ExpectedStatus -eq 'Sending'
                        }
                    }

                    Should -Invoke @assertParams
                }
            }
        }
        #endregion

        #region IncludeMonthlyReports
        Context 'IncludeMonthlyReports' {

            Context 'Reports generated successfully' {

                BeforeAll {

                    $reportParams = $Script:BaseParams.Clone()
                    $reportParams.IncludeMonthlyReports = $true
                    $reportParams.NFSeEntries           = @()

                    $Script:ReportsResult = Invoke-DFeDelivery @reportParams
                }

                It 'Returns Success = true when reports succeed' {
                    $Script:ReportsResult.Success | Should -BeTrue
                }

                It 'Calls New-DFePeriodReport once when IncludeMonthlyReports is set' {
                    Should -Invoke -CommandName New-DFePeriodReport -Times 1 -Exactly -Scope Context
                }

                It 'Passes ReportFilePaths to Send-DFeNotification' {
                    $assertParams = @{
                        CommandName     = 'Send-DFeNotification'
                        Times           = 1
                        Exactly         = $true
                        Scope           = 'Context'
                        ParameterFilter = {
                            $ReportFilePaths -contains 'C:\Reports\Resumo-CFOP.html'
                        }
                    }

                    Should -Invoke @assertParams
                }
            }

            Context 'Reports not requested' {

                BeforeAll {

                    $Script:NoReportsResult = Invoke-DFeDelivery @Script:BaseParams
                }

                It 'Does not call New-DFePeriodReport when IncludeMonthlyReports is absent' {
                    Should -Invoke -CommandName New-DFePeriodReport -Times 0 -Exactly -Scope Context
                }

                It 'Passes empty ReportFilePaths to Send-DFeNotification' {
                    $assertParams = @{
                        CommandName     = 'Send-DFeNotification'
                        Times           = 1
                        Exactly         = $true
                        Scope           = 'Context'
                        ParameterFilter = { $ReportFilePaths.Count -eq 0 }
                    }

                    Should -Invoke @assertParams
                }
            }

            Context 'Report generation fails' {

                BeforeAll {

                    Mock -CommandName New-DFePeriodReport -MockWith {
                        throw 'XLSX export failed.'
                    }

                    $reportParams = $Script:BaseParams.Clone()
                    $reportParams.IncludeMonthlyReports = $true
                    $reportParams.NFSeEntries           = @()

                    $Script:ReportsFailResult = Invoke-DFeDelivery @reportParams
                }

                It 'Returns FailedAt = Reports when New-DFePeriodReport throws' {
                    $Script:ReportsFailResult.FailedAt | Should -Be 'Reports'
                }

                It 'Returns Success = false when report generation fails' {
                    $Script:ReportsFailResult.Success | Should -BeFalse
                }

                It 'Does not call Send-DFeNotification when report generation fails' {
                    Should -Invoke -CommandName Send-DFeNotification -Times 0 -Exactly -Scope Context
                }

                It 'Does not transition to Sending when report generation fails' {
                    $assertParams = @{
                        CommandName     = 'Set-DFeDeliveryState'
                        Times           = 0
                        Exactly         = $true
                        Scope           = 'Context'
                        ParameterFilter = { $Status -eq 'Sending' }
                    }

                    Should -Invoke @assertParams
                }
            }
        }
        #endregion
    }
}
