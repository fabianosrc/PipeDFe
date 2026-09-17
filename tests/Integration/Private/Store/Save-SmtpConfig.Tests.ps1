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
  - Sets UpdatedAt to null on first write.
  - Preserves CreatedAt on subsequent writes.
  - Updates UpdatedAt on subsequent writes.
  - Throws SmtpConfigInvalid when Config fails validation.
  - Produces no output.
  - Written JSON is valid and parseable.
  - Written JSON uses UTF-8 without BOM.
  - Does not leave temp files behind.
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

Describe 'Save-SmtpConfig' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $testID = [guid]::NewGuid().ToString('N')

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $joinPathParams = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = 'PipeDFe.Tests-{0}' -f $testID
            }

            $Script:TempRoot = Join-Path @joinPathParams

            New-Item -Path $Script:TempRoot -ItemType Directory -Force | Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot

            $Script:SmtpPath = Join-Path -Path (Get-StorePath -Scope Root) -ChildPath 'smtp.json'

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

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Config as mandatory' {
                $mandatory = (Get-Command Save-SmtpConfig).Parameters['Config'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
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

                $saveParams = @{
                    Config      = (New-ValidSmtpConfig)
                    ErrorAction = 'Stop'
                }

                Save-SmtpConfig @saveParams

                $contentParams = @{
                    LiteralPath = $Script:SmtpPath
                    Raw         = $true
                    Encoding    = 'UTF8'
                }

                $Script:Written = Get-Content @contentParams | ConvertFrom-Json
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

            It 'Sets UpdatedAt to null on first write' {
                $Script:Written.UpdatedAt | Should -BeNullOrEmpty
            }

            It 'Produces no output' {
                @(Save-SmtpConfig -Config (New-ValidSmtpConfig)) | Should -HaveCount 0
            }
        }
        #endregion

        #region CreatedAt preservation
        Context 'CreatedAt preservation' {

            BeforeAll {

                Save-SmtpConfig -Config (New-ValidSmtpConfig)

                $firstWriteRawParams = @{
                    LiteralPath = $Script:SmtpPath
                    Raw         = $true
                    Encoding    = 'UTF8'
                }

                $firstWriteRaw = Get-Content @firstWriteRawParams | ConvertFrom-Json

                $Script:FirstCreatedAt = [string]$firstWriteRaw.CreatedAt
                $Script:FirstUpdatedAt = [string]$firstWriteRaw.UpdatedAt

                $configWithCreatedAt           = New-ValidSmtpConfig
                $configWithCreatedAt.CreatedAt = $Script:FirstCreatedAt

                Save-SmtpConfig -Config $configWithCreatedAt

                $secondWriteRawParams = @{
                    LiteralPath = $Script:SmtpPath
                    Raw         = $true
                    Encoding    = 'UTF8'
                }

                $secondWriteRaw = Get-Content @secondWriteRawParams | ConvertFrom-Json

                $Script:SecondWriteCreatedAt = [string]$secondWriteRaw.CreatedAt
                $Script:SecondWriteUpdatedAt = [string]$secondWriteRaw.UpdatedAt
            }

            AfterAll {

                Remove-Item -LiteralPath $Script:SmtpPath -Force -ErrorAction SilentlyContinue
            }

            It 'Preserves CreatedAt on subsequent writes' {
                $Script:SecondWriteCreatedAt | Should -Be $Script:FirstCreatedAt
            }

            It 'Updates UpdatedAt on subsequent writes' {
                $firstTime  = [System.DateTimeOffset]$Script:FirstCreatedAt
                $secondTime = [System.DateTimeOffset]$Script:SecondWriteUpdatedAt

                $secondTime | Should -BeGreaterOrEqual $firstTime
            }
        }
        #endregion

        #region Corrupted existing config
        Context 'Corrupted existing config' {

            BeforeAll {

                $smtpParams = @{
                    Path      = (Get-StorePath -Scope Root)
                    ChildPath = 'smtp.json'
                }

                $smtpPath = Join-Path @smtpParams

                [System.IO.Directory]::CreateDirectory(
                    [System.IO.Path]::GetDirectoryName($smtpPath)
                ) | Out-Null

                # Write invalid JSON so ConvertFrom-Json throws when Save-SmtpConfig
                # tries to read CreatedAt from the existing file.
                [System.IO.File]::WriteAllText($smtpPath, '{ invalid json !!!')

                $Script:CorruptedThrown = $null

                try {
                    Save-SmtpConfig -Config (New-ValidSmtpConfig) -ErrorAction Stop
                } catch {
                    $Script:CorruptedThrown = $_
                }
            }

            AfterAll {

                $smtpPath = Join-Path -Path (Get-StorePath -Scope Root) -ChildPath 'smtp.json'

                Remove-Item -LiteralPath $smtpPath -Force -ErrorAction SilentlyContinue
            }

            It 'Throws when the existing smtp.json cannot be parsed' {
                $Script:CorruptedThrown | Should -Not -BeNullOrEmpty
            }

            It 'Wraps the parse error in an IOException' {
                $Script:CorruptedThrown.Exception |
                    Should -BeOfType [System.IO.IOException]
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

                $replacedParams = @{
                    LiteralPath = $Script:SmtpPath
                    Raw         = $true
                    Encoding    = 'UTF8'
                }

                $Script:Replaced = Get-Content @replacedParams | ConvertFrom-Json
            }

            AfterAll {

                Remove-Item -LiteralPath $Script:SmtpPath -Force -ErrorAction SilentlyContinue
            }

            It 'Replaces smtp.json with the new configuration' {
                $Script:Replaced.Server | Should -Be 'smtp.gmail.com'
            }

            It 'Does not leave temp files behind' {
                $rootPath = Get-StorePath -Scope Root

                $tempFileParams = @{
                    Path        = $rootPath
                    Filter      = 'smtp.*.tmp'
                    ErrorAction = 'SilentlyContinue'
                }

                $tmpFiles = Get-ChildItem @tempFileParams

                $tmpFiles | Should -HaveCount 0
            }
        }
        #endregion

        #region Validation failure
        Context 'Validation failure' {

            It 'Throws SmtpConfigInvalid when Config fails validation' {
                $invalid = [PSCustomObject]@{
                    Server        = [string]::Empty
                    Port          = 587
                    Ssl           = $true
                    Username      = [string]::Empty
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

                $Script:FirstThreeBytes = ([System.IO.File]::ReadAllBytes($Script:SmtpPath))[0..2]
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
