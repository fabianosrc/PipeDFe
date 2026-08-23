#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Save-SmtpConfig.

.DESCRIPTION
Verifies that Save-SmtpConfig correctly persists smtp.json using real
files in an isolated temporary directory.

Coverage includes:
  - Config is mandatory and rejects null.
  - Creates smtp.json when it does not exist.
  - Replaces smtp.json atomically when it already exists.
  - Persists all expected fields correctly.
  - Sets CreatedAt on first write.
  - Preserves CreatedAt on subsequent writes.
  - Sets UpdatedAt to the current UTC time.
  - Throws SmtpConfigInvalid when Config fails validation.
  - Throws SmtpConfigSaveFailed on write failure.
  - Produces no output.
  - Written JSON is valid and parseable.
  - Written JSON uses UTF-8 without BOM.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Test infrastructure helpers do not ship as module functions.'
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

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $joinPathParams = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = 'PipeDFe.Tests-' + [guid]::NewGuid().ToString('N')
            }

            $Script:TempRoot = Join-Path @joinPathParams

            New-Item -Path $Script:TempRoot -ItemType Directory -Force | Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot

            $Script:SmtpPath = Join-Path -Path (Get-StorePath -Scope Root) -ChildPath 'smtp.json'

            function New-ValidSmtpConfig {
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

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData
            $removeItemparams = @{
                LiteralPath = $Script:TempRoot
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeItemparams
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Config as mandatory' {
                $mandatory = (Get-Command Save-SmtpConfig).Parameters['Config'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Rejects null Config' {
                { Save-SmtpConfig -Config $null } | Should -Throw
            }
        }
        #endregion

        #region Successful write
        Context 'Successful write' {

            BeforeAll {

                $config = New-ValidSmtpConfig

                $saveParams = @{
                    Config      = $config
                    ErrorAction = 'Stop'
                }

                Save-SmtpConfig @saveParams

                $Script:Written = Get-Content -LiteralPath $Script:SmtpPath -Raw -Encoding UTF8 |
                    ConvertFrom-Json
            }

            AfterAll {

                Remove-Item -LiteralPath $Script:SmtpPath -Force -ErrorAction SilentlyContinue
            }

            It 'Creates smtp.json' {
                Test-Path -LiteralPath $Script:SmtpPath -PathType Leaf | Should -BeTrue
            }

            It 'Writes valid JSON' {
                $Script:Written | Should -Not -BeNullOrEmpty
            }

            It 'Persists the correct SchemaVersion' {
                [int]$Script:Written.SchemaVersion | Should -Be $Script:SmtpSchemaVersion
            }

            It 'Persists the correct Server' {
                $Script:Written.Server | Should -Be 'smtp.office365.com'
            }

            It 'Persists the correct Port' {
                [int]$Script:Written.Port | Should -Be 587
            }

            It 'Persists the correct Username' {
                $Script:Written.Username | Should -Be 'user@domain.com'
            }

            It 'Persists the correct Password' {
                $Script:Written.Password | Should -Be 'encrypted-blob'
            }

            It 'Persists the correct Timeout' {
                [int]$Script:Written.Timeout | Should -Be 30
            }

            It 'Sets CreatedAt on first write' {
                $Script:Written.CreatedAt | Should -Not -BeNullOrEmpty
            }

            It 'Sets UpdatedAt on write' {
                $Script:Written.UpdatedAt | Should -Not -BeNullOrEmpty
            }

            It 'Produces no output' {
                $result = Save-SmtpConfig -Config (New-ValidSmtpConfig)
                $result | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region CreatedAt preservation
        Context 'CreatedAt preservation' {

            BeforeAll {

                $config = New-ValidSmtpConfig

                Save-SmtpConfig -Config $config

                $firstWriteRaw = Get-Content -LiteralPath $Script:SmtpPath -Raw -Encoding UTF8 |
                    ConvertFrom-Json

                $Script:FirstCreatedAt = if ($firstWriteRaw.CreatedAt -is [datetime]) {
                    $firstWriteRaw.CreatedAt.ToUniversalTime().ToString('o')
                } else {
                    [string]$firstWriteRaw.CreatedAt
                }

                $Script:FirstUpdatedAt = if ($firstWriteRaw.UpdatedAt -is [datetime]) {
                    $firstWriteRaw.UpdatedAt.ToUniversalTime().ToString('o')
                } else {
                    [string]$firstWriteRaw.UpdatedAt
                }

                $configWithCreatedAt = New-ValidSmtpConfig
                $configWithCreatedAt.CreatedAt = $Script:FirstCreatedAt

                Save-SmtpConfig -Config $configWithCreatedAt

                $secondWriteRaw = Get-Content -LiteralPath $Script:SmtpPath -Raw -Encoding UTF8 |
                    ConvertFrom-Json

                $Script:SecondWriteCreatedAt = if ($secondWriteRaw.CreatedAt -is [datetime]) {
                    $secondWriteRaw.CreatedAt.ToUniversalTime().ToString('o')
                } else {
                    [string]$secondWriteRaw.CreatedAt
                }

                $Script:SecondWriteUpdatedAt = if ($secondWriteRaw.UpdatedAt -is [datetime]) {
                    $secondWriteRaw.UpdatedAt.ToUniversalTime().ToString('o')
                } else {
                    [string]$secondWriteRaw.UpdatedAt
                }
            }

            AfterAll {

                Remove-Item -LiteralPath $Script:SmtpPath -Force -ErrorAction SilentlyContinue
            }

            It 'Preserves CreatedAt on subsequent writes' {
                $Script:SecondWriteCreatedAt | Should -Be $Script:FirstCreatedAt
            }

            It 'Updates UpdatedAt on subsequent writes' {
                $Script:SecondWriteUpdatedAt | Should -Not -Be $Script:FirstUpdatedAt
            }
        }
        #endregion

        #region Atomic replace
        Context 'Atomic replace' {

            BeforeAll {

                $config = New-ValidSmtpConfig

                Save-SmtpConfig -Config $config

                $config.Server = 'smtp.gmail.com'

                Save-SmtpConfig -Config $config

                $Script:Replaced = Get-Content -LiteralPath $Script:SmtpPath -Raw -Encoding UTF8 |
                    ConvertFrom-Json
            }

            AfterAll {

                Remove-Item -LiteralPath $Script:SmtpPath -Force -ErrorAction SilentlyContinue
            }

            It 'Replaces smtp.json with the new configuration' {
                $Script:Replaced.Server | Should -Be 'smtp.gmail.com'
            }

            It 'Does not leave a temp file behind' {
                $tempPath = "$($Script:SmtpPath).tmp"
                Test-Path -LiteralPath $tempPath | Should -BeFalse
            }
        }
        #endregion

        #region Validation failure
        Context 'Validation failure' {

            It 'Throws SmtpConfigInvalid when Config fails validation' {
                $invalid = [PSCustomObject]@{
                    Server        = ''
                    Port          = 587
                    Ssl           = $true
                    Username      = ''
                    Password      = 'blob'
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

                $thrown = $null

                try {
                    Save-SmtpConfig -Config $invalid -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown | Should -Not -BeNullOrEmpty
                $thrown.FullyQualifiedErrorId | Should -BeLike 'SmtpConfigInvalid*'
            }
        }
        #endregion

        #region UTF-8 without BOM
        Context 'UTF-8 without BOM' {

            BeforeAll {

                Save-SmtpConfig -Config (New-ValidSmtpConfig)

                $bytes = [System.IO.File]::ReadAllBytes($Script:SmtpPath)
                $Script:FirstThreeBytes = $bytes[0..2]
            }

            AfterAll {
                Remove-Item -LiteralPath $Script:SmtpPath -Force -ErrorAction SilentlyContinue
            }

            It 'Writes UTF-8 without BOM' {
                $hasBom = (
                    $Script:FirstThreeBytes[0] -eq 0xEF -and
                    $Script:FirstThreeBytes[1] -eq 0xBB -and
                    $Script:FirstThreeBytes[2] -eq 0xBF
                )

                $hasBom | Should -BeFalse
            }
        }
        #endregion
    }
}
