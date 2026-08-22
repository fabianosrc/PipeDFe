#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Get-SmtpConfig.

.DESCRIPTION
Verifies that Get-SmtpConfig reads and validates smtp.json correctly
using real files in an isolated temporary directory.

Coverage includes:
  - Throws SmtpConfigNotFound when smtp.json does not exist.
  - SmtpConfigNotFound uses ObjectNotFound category.
  - SmtpConfigNotFound exposes the file path as TargetObject.
  - Throws SmtpConfigInvalid when the file contains invalid JSON.
  - Throws SmtpConfigInvalid when the file fails schema validation.
  - Returns a PSCustomObject for a valid configuration.
  - Preserves all documented configuration values.
  - Output contract: all documented properties are present.
  - Output contract: documented properties have the expected types.
  - Password is returned as-is without decryption.
  - Produces exactly one configuration object.
#>

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Get-SmtpConfig' {

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

            $Script:ValidConfig = [ordered]@{
                SchemaVersion = $Script:SmtpSchemaVersion
                Server        = 'smtp.office365.com'
                Port          = 587
                Ssl           = $true
                Username      = 'user@domain.com'
                Password      = 'encrypted-blob'
                From          = [ordered]@{
                    Name  = 'PipeDFe'
                    Email = 'noreply@domain.com'
                }
                SenderAddress = $null
                ReplyTo       = $null
                Timeout       = 30
                CreatedAt     = '2026-08-01T00:00:00+00:00'
                UpdatedAt     = '2026-08-01T00:00:00+00:00'
            }

            function Write-SmtpFixture {
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [object]$Content
                )

                $dir = [System.IO.Path]::GetDirectoryName($Path)

                if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                    New-Item -Path $dir -ItemType Directory -Force | Out-Null
                }

                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                $json = $Content | ConvertTo-Json -Depth 5

                [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
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

        #region File not found
        Context 'File not found' {

            BeforeAll {

                $Script:NotFoundThrown = $null

                try {
                    Get-SmtpConfig -ErrorAction Stop
                } catch {
                    $Script:NotFoundThrown = $_
                }
            }

            It 'Throws SmtpConfigNotFound when smtp.json does not exist' {
                $Script:NotFoundThrown | Should -Not -BeNullOrEmpty

                $Script:NotFoundThrown.FullyQualifiedErrorId |
                    Should -BeLike 'SmtpConfigNotFound*'
            }

            It 'Uses ObjectNotFound category' {
                $Script:NotFoundThrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::ObjectNotFound)
            }

            It 'Exposes the file path as TargetObject' {
                $Script:NotFoundThrown.TargetObject |
                    Should -Be $Script:SmtpPath
            }
        }
        #endregion

        #region Invalid JSON
        Context 'Invalid JSON' {

            BeforeAll {

                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                $dir = [System.IO.Path]::GetDirectoryName($Script:SmtpPath)

                if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                    New-Item -Path $dir -ItemType Directory -Force |  Out-Null
                }

                [System.IO.File]::WriteAllText(
                    $Script:SmtpPath,
                    'not json {{{{',
                    $utf8NoBom
                )

                $Script:InvalidJsonThrown = $null

                try {
                    Get-SmtpConfig -ErrorAction Stop
                } catch {
                    $Script:InvalidJsonThrown = $_
                }
            }

            AfterAll {

                $removeItemParams = @{
                    LiteralPath = $Script:SmtpPath
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeItemParams

            }

            It 'Throws SmtpConfigInvalid when the file contains invalid JSON' {
                $Script:InvalidJsonThrown | Should -Not -BeNullOrEmpty

                $Script:InvalidJsonThrown.FullyQualifiedErrorId |
                    Should -BeLike 'SmtpConfigInvalid*'
            }

            It 'Uses InvalidData category for invalid JSON' {
                $Script:InvalidJsonThrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidData)
            }
        }
        #endregion

        #region Schema validation failure
        Context 'Schema validation failure' {

            BeforeAll {

                $invalidConfig = [ordered]@{
                    SchemaVersion = $Script:SmtpSchemaVersion
                    Server        = ''
                    Port          = 587
                    Ssl           = $true
                    Username      = ''
                    Password      = 'blob'
                    Timeout       = 30
                }

                Write-SmtpFixture -Path $Script:SmtpPath -Content $invalidConfig

                $Script:ValidationThrown = $null

                try {
                    Get-SmtpConfig -ErrorAction Stop
                } catch {
                    $Script:ValidationThrown = $_
                }
            }

            AfterAll {

                $removeItemParams = @{
                    LiteralPath = $Script:SmtpPath
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeItemParams

            }

            It 'Throws SmtpConfigInvalid when validation fails' {
                $Script:ValidationThrown | Should -Not -BeNullOrEmpty

                $Script:ValidationThrown.FullyQualifiedErrorId |
                    Should -BeLike 'SmtpConfigInvalid*'
            }

            It 'Uses InvalidData category for schema validation failure' {
                $Script:ValidationThrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidData)
            }
        }
        #endregion

        #region Successful read
        Context 'Successful read' {

            BeforeAll {

                Write-SmtpFixture -Path $Script:SmtpPath -Content $Script:ValidConfig

                $Script:Result = @(Get-SmtpConfig)
            }

            AfterAll {

                $removeItemParams = @{
                    LiteralPath = $Script:SmtpPath
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeItemParams

            }

            It 'Returns exactly one configuration object' {
                $Script:Result | Should -HaveCount 1
            }

            It 'Returns a PSCustomObject' {
                $Script:Result[0] |
                    Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Preserves SchemaVersion' {
                $Script:Result[0].SchemaVersion | Should -Be $Script:ValidConfig.SchemaVersion
            }

            It 'Preserves Server' {
                $Script:Result[0].Server | Should -Be $Script:ValidConfig.Server
            }

            It 'Preserves Port' {
                $Script:Result[0].Port | Should -Be $Script:ValidConfig.Port
            }

            It 'Preserves Ssl' {
                $Script:Result[0].Ssl | Should -Be $Script:ValidConfig.Ssl
            }

            It 'Preserves Username' {
                $Script:Result[0].Username | Should -Be $Script:ValidConfig.Username
            }

            It 'Preserves Password without decryption' {
                $Script:Result[0].Password | Should -Be $Script:ValidConfig.Password
            }

            It 'Preserves From' {
                $Script:Result[0].From.Name  | Should -Be $Script:ValidConfig.From.Name
                $Script:Result[0].From.Email | Should -Be $Script:ValidConfig.From.Email
            }

            It 'Preserves SenderAddress' {
                $Script:Result[0].SenderAddress | Should -BeNullOrEmpty
            }

            It 'Preserves ReplyTo' {
                $Script:Result[0].ReplyTo | Should -BeNullOrEmpty
            }

            It 'Preserves Timeout' {
                $Script:Result[0].Timeout | Should -Be $Script:ValidConfig.Timeout
            }

            It 'Preserves CreatedAt' {
                $Script:Result[0].CreatedAt | Should -Be $Script:ValidConfig.CreatedAt
            }

            It 'Preserves UpdatedAt' {
                $Script:Result[0].UpdatedAt | Should -Be $Script:ValidConfig.UpdatedAt
            }

            It 'Exposes exactly the documented properties' {
                $expected = @(
                    'SchemaVersion'
                    'Server'
                    'Port'
                    'Ssl'
                    'Username'
                    'Password'
                    'From'
                    'SenderAddress'
                    'ReplyTo'
                    'Timeout'
                    'CreatedAt'
                    'UpdatedAt'
                )

                $actual = @($Script:Result[0].PSObject.Properties.Name)
                $actual | Should -Be $expected
            }

            It 'Exposes documented properties with the expected types' {
                $Script:Result[0].SchemaVersion | Should -BeOfType [int]
                $Script:Result[0].Server        | Should -BeOfType [string]
                $Script:Result[0].Port          | Should -BeOfType [int]
                $Script:Result[0].Ssl           | Should -BeOfType [bool]
                $Script:Result[0].Username      | Should -BeOfType [string]
                $Script:Result[0].Password      | Should -BeOfType [string]
                $Script:Result[0].From          | Should -BeOfType [pscustomobject]
                $Script:Result[0].Timeout       | Should -BeOfType [int]
                $Script:Result[0].CreatedAt     | Should -BeOfType [string]
                $Script:Result[0].UpdatedAt     | Should -BeOfType [string]
            }
        }
        #endregion
    }
}
