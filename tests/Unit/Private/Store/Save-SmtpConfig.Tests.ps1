#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Save-SmtpConfig.

.DESCRIPTION
Covers branches that require mocks or controlled input:
  - Throws when Get-StorePath returns an empty path.
  - Throws when Get-StorePath returns an invalid path.
  - Throws SmtpConfigInvalidCreatedAt for an unparseable CreatedAt string.
  - Accepts CreatedAt as a DateTimeOffset directly.
  - Accepts CreatedAt as a DateTime directly.

.NOTES
Private dependencies mocked: Get-StorePath, Test-Smtp.
Mutex and lock-timeout branches are not covered here -- they require
a separate process to hold the mutex and are not unit-testable.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
)]

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    'Scope',
    Justification = 'Required by Get-StorePath Scope'
)]

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    'InputObject',
    Justification = 'Required by Test-Smtp mock'
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

Describe 'Save-SmtpConfig' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            function New-ValidSmtpConfig {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param ()

                [PSCustomObject]@{
                    Server        = 'smtp.office365.com'
                    Port          = 587
                    Ssl           = $true
                    Username      = 'user@domain.com'
                    Password      = 'encrypted-blob'
                    From          = [PSCustomObject]@{
                        Name  = 'PipeDFe'
                        Email = 'noreply@domain.com'
                    }
                    SenderAddress = $null
                    ReplyTo       = $null
                    Timeout       = 30
                    CreatedAt     = $null
                    UpdatedAt     = $null
                }
            }
        }

        #region Empty root path
        Context 'Empty root path' {

            BeforeAll {

                Mock -CommandName Get-StorePath -MockWith {
                    param (
                        [Parameter()]
                        [string]$Scope
                    )

                    return [string]::Empty
                } -ModuleName PipeDFe

                $Script:EmptyPathThrown = $null

                try {
                    Save-SmtpConfig -Config (New-ValidSmtpConfig) -ErrorAction Stop
                } catch {
                    $Script:EmptyPathThrown = $_
                }
            }

            It 'Throws when root path is empty' {
                $Script:EmptyPathThrown | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region Invalid root path
        Context 'Invalid root path' {

            BeforeAll {

                Mock -CommandName Get-StorePath -MockWith {
                    param (
                        [Parameter()]
                        [string]$Scope
                    )

                    # Null bytes are invalid in paths on all platforms.
                    return "invalid`0path"
                } -ModuleName PipeDFe

                $Script:InvalidPathThrown = $null

                try {
                    Save-SmtpConfig -Config (New-ValidSmtpConfig) -ErrorAction Stop
                } catch {
                    $Script:InvalidPathThrown = $_
                }
            }

            It 'Throws when root path is invalid' {
                $Script:InvalidPathThrown | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region CreatedAt as DateTimeOffset
        Context 'CreatedAt as DateTimeOffset' {

            BeforeAll {

                $testID = [guid]::NewGuid().ToString('N')

                $Script:OriginalLocalAppData = $env:LOCALAPPDATA

                $Script:TempRoot = [System.IO.Path]::Combine(
                    [System.IO.Path]::GetTempPath(),
                    ('PipeDFe.Tests-{0}' -f $testID)
                )

                New-Item -Path $Script:TempRoot -ItemType Directory -Force | Out-Null

                $env:LOCALAPPDATA = $Script:TempRoot

                $config = New-ValidSmtpConfig
                $config.CreatedAt  = [System.DateTimeOffset]::UtcNow.AddDays(-1)

                Mock -CommandName Test-Smtp -MockWith {
                    param (
                        [Parameter()]
                        [pscustomobject]$InputObject
                    )

                    return [PSCustomObject]@{
                        IsValid = $true
                        Errors  = @()
                    }
                } -ModuleName PipeDFe

                Save-SmtpConfig -Config $config

                $smtpParams = @{
                    Path      = (Get-StorePath -Scope Root)
                    ChildPath = 'smtp.json'
                }

                $smtpPath = Join-Path @smtpParams

                $Script:DtoResult = Get-Content -LiteralPath $smtpPath -Raw |
                    ConvertFrom-Json
            }

            AfterAll {

                $env:LOCALAPPDATA = $Script:OriginalLocalAppData

                $removeParams = @{
                    LiteralPath = $Script:TempRoot
                    Recurse     = $true
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeParams
            }

            It 'Accepts CreatedAt as DateTimeOffset and persists it' {
                $Script:DtoResult.CreatedAt | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region CreatedAt as DateTime
        Context 'CreatedAt as DateTime' {

            BeforeAll {

                $testID = [guid]::NewGuid().ToString('N')

                $Script:OriginalLocalAppData2 = $env:LOCALAPPDATA

                $Script:TempRoot2 = [System.IO.Path]::Combine(
                    [System.IO.Path]::GetTempPath(),
                    'PipeDFe.Tests-{0}' -f $testID
                )

                New-Item -Path $Script:TempRoot2 -ItemType Directory -Force | Out-Null

                $env:LOCALAPPDATA = $Script:TempRoot2

                $config = New-ValidSmtpConfig
                $config.CreatedAt = [System.DateTime]::UtcNow.AddDays(-1)

                Mock -CommandName Test-Smtp -MockWith {
                    param (
                        [Parameter()]
                        [pscustomobject]$InputObject
                    )

                    return [PSCustomObject]@{
                        IsValid = $true
                        Errors  = @()
                    }
                } -ModuleName PipeDFe

                Save-SmtpConfig -Config $config

                $smtpParams = @{
                    Path      = (Get-StorePath -Scope Root)
                    ChildPath = 'smtp.json'
                }

                $smtpPath = Join-Path @smtpParams

                $Script:DtResult = Get-Content -LiteralPath $smtpPath -Raw |
                    ConvertFrom-Json
            }

            AfterAll {

                $env:LOCALAPPDATA = $Script:OriginalLocalAppData2

                $removeParams = @{
                    LiteralPath = $Script:TempRoot2
                    Recurse     = $true
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeParams
            }

            It 'Accepts CreatedAt as DateTime and persists it' {
                $Script:DtResult.CreatedAt | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region Invalid CreatedAt string
        Context 'Invalid CreatedAt string' {

            BeforeAll {

                $testID = [guid]::NewGuid().ToString('N')

                $Script:OriginalLocalAppData3 = $env:LOCALAPPDATA

                $Script:TempRoot3 = [System.IO.Path]::Combine(
                    [System.IO.Path]::GetTempPath(),
                    'PipeDFe.Tests-{0}' -f $testID
                )

                New-Item -Path $Script:TempRoot3 -ItemType Directory -Force | Out-Null

                $env:LOCALAPPDATA = $Script:TempRoot3

                $config = New-ValidSmtpConfig
                $config.CreatedAt = 'not-a-timestamp'

                $Script:InvalidCreatedAtThrown = $null

                try {
                    Save-SmtpConfig -Config $config -ErrorAction Stop
                } catch {
                    $Script:InvalidCreatedAtThrown = $_
                }
            }

            AfterAll {

                $env:LOCALAPPDATA = $Script:OriginalLocalAppData3

                $removeParams = @{
                    LiteralPath = $Script:TempRoot3
                    Recurse     = $true
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeParams
            }

            It 'Throws SmtpConfigInvalidCreatedAt for an unparseable CreatedAt string' {
                $Script:InvalidCreatedAtThrown | Should -Not -BeNullOrEmpty

                $Script:InvalidCreatedAtThrown.FullyQualifiedErrorId |
                    Should -BeLike 'SmtpConfigInvalidCreatedAt*'
            }

            It 'Uses InvalidData category' {
                $Script:InvalidCreatedAtThrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidData)
            }
        }
        #endregion
    }
}
