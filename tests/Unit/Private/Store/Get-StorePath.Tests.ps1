#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-StorePath.

.DESCRIPTION
Covers all scopes, CNPJ validation, environment variable guards,
configured data root (PIPEDFE_DATA_ROOT), filesystem purity,
output contract, and function metadata.
#>

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

Describe 'Get-StorePath' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA
            $Script:OriginalDataRoot     = $env:PIPEDFE_DATA_ROOT

            $env:LOCALAPPDATA      = 'C:\FakeAppData'
            $env:PIPEDFE_DATA_ROOT = $null

            $Script:Cnpj = '12345678000199'
            $Script:Root = 'C:\FakeAppData\PipeDFe'
        }

        AfterAll {

            $env:LOCALAPPDATA      = $Script:OriginalLocalAppData
            $env:PIPEDFE_DATA_ROOT = $Script:OriginalDataRoot
        }

        #region Scope - Root
        Context 'Scope - Root' {

            It 'Returns the module root under LOCALAPPDATA' {
                $result = Get-StorePath -Scope Root

                $result | Should -Be $Script:Root
            }

            It 'Does not require -Cnpj' {
                { Get-StorePath -Scope Root } | Should -Not -Throw
            }
        }
        #endregion

        #region Scope - Company
        Context 'Scope - Company' {

            It 'Returns the per-CNPJ root folder' {
                $result = Get-StorePath -Scope Company -Cnpj $Script:Cnpj

                $result | Should -Be "$($Script:Root)\$($Script:Cnpj)"
            }
        }
        #endregion

        #region Scope - Index
        Context 'Scope - Index' {

            It 'Returns the full path to index.db' {
                $result = Get-StorePath -Scope Index -Cnpj $Script:Cnpj

                $result | Should -Be "$($Script:Root)\$($Script:Cnpj)\data\index.db"
            }

            It 'Path ends with index.db' {
                $result = Get-StorePath -Scope Index -Cnpj $Script:Cnpj

                $result | Should -Match 'index\.db$'
            }
        }
        #endregion

        #region Scope - Audit
        Context 'Scope - Audit' {

            It 'Returns the full path to audit.db' {
                $result = Get-StorePath -Scope Audit -Cnpj $Script:Cnpj

                $result | Should -Be "$($Script:Root)\$($Script:Cnpj)\data\audit.db"
            }

            It 'Path ends with audit.db' {
                $result = Get-StorePath -Scope Audit -Cnpj $Script:Cnpj

                $result | Should -Match 'audit\.db$'
            }
        }
        #endregion

        #region Scope - Logs
        Context 'Scope - Logs' {

            It 'Returns the per-CNPJ logs folder' {
                $result = Get-StorePath -Scope Logs -Cnpj $Script:Cnpj

                $result | Should -Be "$($Script:Root)\$($Script:Cnpj)\logs"
            }
        }
        #endregion

        #region Scope - Config
        Context 'Scope - Config' {

            It 'Returns the per-CNPJ config folder' {
                $result = Get-StorePath -Scope Config -Cnpj $Script:Cnpj

                $result | Should -Be "$($Script:Root)\$($Script:Cnpj)\config"
            }
        }
        #endregion

        #region Scope - Output
        Context 'Scope - Output' {

            It 'Returns the per-CNPJ output folder' {
                $result = Get-StorePath -Scope Output -Cnpj $Script:Cnpj

                $result | Should -Be "$($Script:Root)\$($Script:Cnpj)\output"
            }

            It 'Output is rooted under the module root' {
                $result = Get-StorePath -Scope Output -Cnpj $Script:Cnpj

                $result | Should -BeLike "$($Script:Root)*"
            }
        }
        #endregion

        #region Path structure invariants
        Context 'Path structure invariants' {

            It 'Index and Audit share the same data folder' {
                $index = Get-StorePath -Scope Index -Cnpj $Script:Cnpj
                $audit = Get-StorePath -Scope Audit -Cnpj $Script:Cnpj

                Split-Path -Parent $index | Should -Be (Split-Path -Parent $audit)
            }

            It 'Company is a prefix of Index' {
                $company = Get-StorePath -Scope Company -Cnpj $Script:Cnpj
                $index   = Get-StorePath -Scope Index   -Cnpj $Script:Cnpj

                $index | Should -BeLike "$company*"
            }

            It 'Company is a prefix of Logs' {
                $company = Get-StorePath -Scope Company -Cnpj $Script:Cnpj
                $logs    = Get-StorePath -Scope Logs    -Cnpj $Script:Cnpj

                $logs | Should -BeLike "$company*"
            }

            It 'Company is a prefix of Config' {
                $company = Get-StorePath -Scope Company -Cnpj $Script:Cnpj
                $config  = Get-StorePath -Scope Config  -Cnpj $Script:Cnpj

                $config | Should -BeLike "$company*"
            }

            It 'Root is a prefix of Company' {
                $root    = Get-StorePath -Scope Root
                $company = Get-StorePath -Scope Company -Cnpj $Script:Cnpj

                $company | Should -BeLike "$root*"
            }

            It 'Different CNPJs produce different paths for the same scope' {
                $path1 = Get-StorePath -Scope Index -Cnpj '11111111000191'
                $path2 = Get-StorePath -Scope Index -Cnpj '22222222000100'

                $path1 | Should -Not -Be $path2
            }
        }
        #endregion

        #region CNPJ validation
        Context 'CNPJ validation' {

            It 'Throws when Scope requires CNPJ but none is provided' -ForEach @(
                @{ Scope = 'Company' }
                @{ Scope = 'Index'   }
                @{ Scope = 'Audit'   }
                @{ Scope = 'Logs'    }
                @{ Scope = 'Config'  }
                @{ Scope = 'Output'  }
            ) {
                { Get-StorePath -Scope $Scope } | Should -Throw
            }

            It 'Throws when CNPJ has fewer than 14 characters' {
                { Get-StorePath -Scope Index -Cnpj '1234567800019' } | Should -Throw
            }

            It 'Throws when CNPJ has more than 14 characters' {
                { Get-StorePath -Scope Index -Cnpj '123456780001990' } | Should -Throw
            }

            It 'Throws when CNPJ contains invalid characters' {
                { Get-StorePath -Scope Index -Cnpj '12345678000!9X' } | Should -Throw
            }

            It 'Throws with MissingCnpj error id when CNPJ is absent' {
                $thrown = $null

                try {
                    Get-StorePath -Scope Index -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown.FullyQualifiedErrorId | Should -BeLike 'MissingCnpj*'
            }
        }
        #endregion

        #region Environment variable guards
        Context 'Environment variable guards' {

            BeforeEach {

                $Script:SavedLocalAppData = $env:LOCALAPPDATA
            }

            AfterEach {

                $env:LOCALAPPDATA = $Script:SavedLocalAppData
            }

            It 'Throws when LOCALAPPDATA is not set' {
                $env:LOCALAPPDATA = [string]::Empty

                { Get-StorePath -Scope Root -ErrorAction Stop } | Should -Throw
            }
        }
        #endregion

        #region Configured data root
        Context 'Configured data root' {

            BeforeEach {

                $Script:SavedDataRoot  = $env:PIPEDFE_DATA_ROOT
                $env:PIPEDFE_DATA_ROOT = 'C:\ProgramData\PipeDFe'
            }

            AfterEach {

                $env:PIPEDFE_DATA_ROOT = $Script:SavedDataRoot
            }

            It 'Uses PIPEDFE_DATA_ROOT when configured' {
                $result = Get-StorePath -Scope Index -Cnpj $Script:Cnpj

                $result | Should -Be "C:\ProgramData\PipeDFe\$($Script:Cnpj)\data\index.db"
            }

            It 'Uses the configured root for Output' {
                $result = Get-StorePath -Scope Output -Cnpj $Script:Cnpj

                $result | Should -Be "C:\ProgramData\PipeDFe\$($Script:Cnpj)\output"
            }

            It 'Returns the configured root without creating it' {
                $fakeRoot = [System.IO.Path]::Combine(
                    [System.IO.Path]::GetTempPath(),
                    [System.IO.Path]::GetRandomFileName()
                )

                $env:PIPEDFE_DATA_ROOT = $fakeRoot

                $result = Get-StorePath -Scope Root

                $result | Should -Be ([System.IO.Path]::GetFullPath($fakeRoot))

                Test-Path -LiteralPath $fakeRoot | Should -BeFalse
            }
        }

        Context 'Invalid configured data root' {

            BeforeEach {

                $Script:SavedDataRoot  = $env:PIPEDFE_DATA_ROOT
                $env:PIPEDFE_DATA_ROOT = '.\PipeDFe'
            }

            AfterEach {

                $env:PIPEDFE_DATA_ROOT = $Script:SavedDataRoot
            }

            It 'Rejects a relative configured data root' {
                { Get-StorePath -Scope Root -ErrorAction Stop } | Should -Throw
            }

            It 'Throws InvalidDataRoot for a relative path' {
                $thrown = $null

                try {
                    Get-StorePath -Scope Root -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown.FullyQualifiedErrorId | Should -BeLike 'InvalidDataRoot*'
            }
        }
        #endregion

        #region Filesystem purity
        Context 'Filesystem purity' {

            BeforeEach {

                $Script:SavedLocalAppData2 = $env:LOCALAPPDATA

                $Script:FakePath = [System.IO.Path]::Combine(
                    [System.IO.Path]::GetTempPath(),
                    [System.IO.Path]::GetRandomFileName()
                )

                $env:LOCALAPPDATA = $Script:FakePath
            }

            AfterEach {

                $env:LOCALAPPDATA = $Script:SavedLocalAppData2
            }

            It 'Does not create any directory' {
                Get-StorePath -Scope Index -Cnpj $Script:Cnpj | Out-Null

                Test-Path -LiteralPath $Script:FakePath | Should -BeFalse
            }

            It 'Does not create any file' {
                Get-StorePath -Scope Root | Out-Null

                Test-Path -LiteralPath $Script:FakePath | Should -BeFalse
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            It 'Returns a string for every scope' -ForEach @(
                @{Scope = 'Root';    Cnpj = $null            }
                @{Scope = 'Company'; Cnpj = '12345678000199' }
                @{Scope = 'Index';   Cnpj = '12345678000199' }
                @{Scope = 'Audit';   Cnpj = '12345678000199' }
                @{Scope = 'Logs';    Cnpj = '12345678000199' }
                @{Scope = 'Config';  Cnpj = '12345678000199' }
                @{Scope = 'Output';  Cnpj = '12345678000199' }
            ) {
                $params = if ($null -eq $Cnpj) {
                    @{ Scope = $Scope }
                } else {
                    @{ Scope = $Scope; Cnpj = $Cnpj }
                }

                $result = Get-StorePath @params

                $result | Should -BeOfType [string]
            }

            It 'Returns a non-empty string for every scope' -ForEach @(
                @{ Scope = 'Root';    Cnpj = $null            }
                @{ Scope = 'Company'; Cnpj = '12345678000199' }
                @{ Scope = 'Index';   Cnpj = '12345678000199' }
                @{ Scope = 'Audit';   Cnpj = '12345678000199' }
                @{ Scope = 'Logs';    Cnpj = '12345678000199' }
                @{ Scope = 'Config';  Cnpj = '12345678000199' }
                @{ Scope = 'Output';  Cnpj = '12345678000199' }
            ) {
                $params = if ($null -eq $Cnpj) {
                    @{ Scope = $Scope }
                } else {
                    @{ Scope = $Scope; Cnpj = $Cnpj }
                }

                $result = Get-StorePath @params

                $result | Should -Not -BeNullOrEmpty
            }

            It 'Returns an absolute path for every scope' -ForEach @(
                @{ Scope = 'Root';    Cnpj = $null            }
                @{ Scope = 'Company'; Cnpj = '12345678000199' }
                @{ Scope = 'Index';   Cnpj = '12345678000199' }
                @{ Scope = 'Audit';   Cnpj = '12345678000199' }
                @{ Scope = 'Logs';    Cnpj = '12345678000199' }
                @{ Scope = 'Config';  Cnpj = '12345678000199' }
                @{ Scope = 'Output';  Cnpj = '12345678000199' }
            ) {
                $params = if ($null -eq $Cnpj) {
                    @{ Scope = $Scope }
                } else {
                    @{ Scope = $Scope; Cnpj = $Cnpj }
                }

                $result = Get-StorePath @params

                [System.IO.Path]::IsPathRooted($result) | Should -BeTrue
            }

            It 'Returns the same path on repeated calls with the same arguments' {
                $first  = Get-StorePath -Scope Index -Cnpj $Script:Cnpj
                $second = Get-StorePath -Scope Index -Cnpj $Script:Cnpj

                $first | Should -Be $second
            }
        }
        #endregion

        #region Function metadata
        Context 'Function metadata' {

            It 'Declares OutputType of System.String' {
                $cmd = Get-Command -Name Get-StorePath -Module PipeDFe

                $cmd.OutputType.Name | Should -BeOfType ([System.String])
            }

            It 'Exposes CmdletBinding' {
                $cmd = Get-Command -Name Get-StorePath -Module PipeDFe

                $cmd.CmdletBinding | Should -BeTrue
            }

            It 'Exposes comment-based help with a Synopsis' {
                $help = Get-Help Get-StorePath

                $help.Synopsis | Should -Not -BeNullOrEmpty
            }
        }
        #endregion
    }
}
