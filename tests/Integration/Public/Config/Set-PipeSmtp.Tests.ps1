#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Set-PipeSmtp.

.DESCRIPTION
Verifies Set-PipeSmtp using real persistence in an isolated
%LOCALAPPDATA% directory.

Coverage includes:
  - First configuration creation and persistence.
  - Returned and persisted configuration values.
  - Optional SenderAddress and ReplyTo.
  - Encrypted password persistence.
  - CreatedAt creation and preservation.
  - UpdatedAt changes on subsequent writes.
  - WhatIf preventing persistence.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
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

Describe 'Set-PipeSmtp' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $testID = [guid]::NewGuid().ToString('N')

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.Tests-{0}' -f $testID
            )

            New-Item -Path $Script:TempRoot -ItemType Directory -Force | Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot

            $secureStringParams = @{
                String      = 'P@ssw0rd!'
                AsPlainText = $true
                Force       = $true
            }

            $Script:SecurePassword = ConvertTo-SecureString @secureStringParams

            $Script:BaseSplat = @{
                Server   = 'smtp.example.com'
                Port     = 587
                Ssl      = $true
                Username = 'user@example.com'
                Password = $Script:SecurePassword
                From     = 'Empresa <noreply@example.com>'
                Timeout  = 45
                Confirm  = $false
            }

            function Get-SmtpJsonPath {
                [CmdletBinding()]
                [OutputType([string])]
                param ()

                [System.IO.Path]::Combine((Get-StorePath -Scope Root), 'smtp.json')
            }

            function Remove-SmtpConfigFile {
                [CmdletBinding()]
                [OutputType([void])]
                param ()

                $removeItemParams = @{
                    LiteralPath = (Get-SmtpJsonPath)
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeItemParams
            }

            function Get-PersistedSmtpConfig {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param ()

                Get-Content -LiteralPath (Get-SmtpJsonPath) -Raw |
                    ConvertFrom-Json
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

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }

        #region First write
        Context 'First write' {

            BeforeAll {

                $Script:Result    = Set-PipeSmtp @Script:BaseSplat
                $Script:Persisted = Get-PersistedSmtpConfig
            }

            AfterAll {

                Remove-SmtpConfigFile
            }

            It 'Creates smtp.json' {
                Test-Path -LiteralPath (Get-SmtpJsonPath) | Should -BeTrue
            }

            It 'Returns exactly one PSCustomObject' {
                @($Script:Result) | Should -HaveCount 1
                $Script:Result    | Should -BeOfType [PSCustomObject]
            }

            It 'Persists the expected configuration' {
                $Script:Persisted.Server   | Should -Be 'smtp.example.com'
                $Script:Persisted.Port     | Should -Be 587
                $Script:Persisted.Ssl      | Should -BeTrue
                $Script:Persisted.Username | Should -Be 'user@example.com'
                $Script:Persisted.Timeout  | Should -Be 45
            }

            It 'Returns the expected configuration' {
                $Script:Result.Server   | Should -Be 'smtp.example.com'
                $Script:Result.Port     | Should -Be 587
                $Script:Result.Ssl      | Should -BeTrue
                $Script:Result.Username | Should -Be 'user@example.com'
                $Script:Result.Timeout  | Should -Be 45
            }

            It 'Persists the From address' {
                $Script:Persisted.From.Email | Should -Be 'noreply@example.com'
            }

            It 'Returns the From address' {
                $Script:Result.From.Email | Should -Be 'noreply@example.com'
            }

            It 'Persists null optional addresses when omitted' {
                $Script:Persisted.SenderAddress | Should -BeNullOrEmpty
                $Script:Persisted.ReplyTo       | Should -BeNullOrEmpty
            }

            It 'Returns null optional addresses when omitted' {
                $Script:Result.SenderAddress | Should -BeNullOrEmpty
                $Script:Result.ReplyTo       | Should -BeNullOrEmpty
            }

            It 'Persists an encrypted password' {
                $Script:Persisted.Password | Should -Not -BeNullOrEmpty
                $Script:Persisted.Password | Should -Not -Be 'P@ssw0rd!'
            }

            It 'Returns an encrypted password' {
                $Script:Result.Password | Should -Not -BeNullOrEmpty
                $Script:Result.Password | Should -Not -Be 'P@ssw0rd!'
            }

            It 'Sets CreatedAt on first write and leaves UpdatedAt null' {
                $Script:Result.CreatedAt | Should -Not -BeNullOrEmpty

                { [System.DateTimeOffset]::Parse($Script:Result.CreatedAt) } |
                    Should -Not -Throw

                $Script:Result.UpdatedAt | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Optional addresses
        Context 'Optional addresses' {

            BeforeAll {

                $splat = $Script:BaseSplat.Clone()
                $splat['SenderAddress'] = 'sender@example.com'
                $splat['ReplyTo']       = 'replyto@example.com'

                $Script:Result    = Set-PipeSmtp @splat
                $Script:Persisted = Get-PersistedSmtpConfig
            }

            AfterAll {

                Remove-SmtpConfigFile
            }

            It 'Persists SenderAddress' {
                $Script:Persisted.SenderAddress.Email | Should -Be 'sender@example.com'
            }

            It 'Persists ReplyTo' {
                $Script:Persisted.ReplyTo.Email | Should -Be 'replyto@example.com'
            }

            It 'Returns SenderAddress' {
                $Script:Result.SenderAddress.Email | Should -Be 'sender@example.com'
            }

            It 'Returns ReplyTo' {
                $Script:Result.ReplyTo.Email | Should -Be 'replyto@example.com'
            }
        }
        #endregion

        #region Subsequent write
        Context 'Subsequent write' {

            BeforeAll {

                $Script:First = Set-PipeSmtp @Script:BaseSplat

                Start-Sleep -Milliseconds 100

                $Script:Second = Set-PipeSmtp @Script:BaseSplat
            }

            AfterAll {

                Remove-SmtpConfigFile
            }

            It 'Preserves CreatedAt' {
                $Script:Second.CreatedAt | Should -Be $Script:First.CreatedAt
            }

            It 'Updates UpdatedAt' {
                $Script:Second.UpdatedAt | Should -Not -Be $Script:First.UpdatedAt
            }
        }
        #endregion

        #region WhatIf
        Context 'WhatIf' {

            BeforeAll {

                Remove-SmtpConfigFile

                Set-PipeSmtp @Script:BaseSplat -WhatIf | Out-Null
            }

            It 'Does not create smtp.json' {
                Test-Path -LiteralPath (Get-SmtpJsonPath) | Should -BeFalse
            }
        }
        #endregion

        #region Partial update - Port preserved when omitted
        Context 'Partial update - Port preserved when omitted' {

            BeforeAll {

                Set-PipeSmtp @Script:BaseSplat | Out-Null

                $Script:Result = Set-PipeSmtp -Server 'smtp.new.example.com' -Confirm:$false
            }

            AfterAll {

                Remove-SmtpConfigFile
            }

            It 'Preserves Port from existing configuration when omitted' {
                $Script:Result.Port | Should -Be 587
            }
        }
        #endregion

        #region Partial update - omitted parameters preserved
        Context 'Partial update - omitted parameters preserved' {

            BeforeAll {

                # Write the initial full configuration.
                Set-PipeSmtp @Script:BaseSplat | Out-Null

                # Update only the Port - all other parameters should be preserved.
                $Script:Result = Set-PipeSmtp -Port 465 -Confirm:$false
            }

            AfterAll {

                Remove-SmtpConfigFile
            }

            It 'Preserves Server from existing configuration' {
                $Script:Result.Server | Should -Be 'smtp.example.com'
            }

            It 'Updates Port to the new value' {
                $Script:Result.Port | Should -Be 465
            }

            It 'Preserves Ssl from existing configuration' {
                $Script:Result.Ssl | Should -BeTrue
            }

            It 'Preserves Username from existing configuration' {
                $Script:Result.Username | Should -Be 'user@example.com'
            }

            It 'Preserves From from existing configuration' {
                $Script:Result.From.Email | Should -Be 'noreply@example.com'
            }

            It 'Preserves Password from existing configuration' {
                $Script:Result.Password | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region Validation failure
        Context 'Validation failure on update' {

            BeforeAll {

                Mock -CommandName Test-Smtp -MockWith {
                    [PSCustomObject]@{
                        IsValid = $false
                        Errors  = @(
                            'SMTP server is invalid'
                            'SMTP configuration is incomplete'
                        )
                    }
                }

                $Script:Exception = $null

                try {
                    Set-PipeSmtp @Script:BaseSplat
                } catch {
                    $Script:Exception = $_
                }
            }

            It 'Throws SmtpConfigValidationFailed when the configuration is invalid' {
                $Script:Exception | Should -Not -BeNullOrEmpty

                $Script:Exception.FullyQualifiedErrorId |
                    Should -BeLike 'SmtpConfigValidationFailed*'
            }

            It 'Includes all validation errors in the exception message' {
                $Script:Exception.Exception.Message |
                    Should -Match 'SMTP server is invalid'

                $Script:Exception.Exception.Message |
                    Should -Match 'SMTP configuration is incomplete'
            }
        }
        #endregion
    }
}
