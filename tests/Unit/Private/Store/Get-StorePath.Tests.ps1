<#
.SYNOPSIS
Unit tests for Get-StorePath.

.DESCRIPTION
Covers all scopes, CNPJ validation, environment variable guards,
and the guarantee that the function never touches the filesystem.
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

Describe 'Get-StorePath' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {
            $Script:OriginalLocalAppData = $env:LOCALAPPDATA
            $Script:OriginalUserProfile  = $env:USERPROFILE

            $env:LOCALAPPDATA = 'C:\FakeAppData'
            $env:USERPROFILE  = 'C:\FakeProfile'

            $Script:Cnpj = '12345678000199'
            $Script:Root = 'C:\FakeAppData\PipeDFe'
        }

        AfterAll {
            $env:LOCALAPPDATA = $Script:OriginalLocalAppData
            $env:USERPROFILE  = $Script:OriginalUserProfile

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }

        Context 'Scope - Root' {

            It 'Returns the module root under LOCALAPPDATA' {
                $result = Get-StorePath -Scope Root
                $result | Should -Be $Script:Root
            }

            It 'Does not require -Cnpj' {
                { Get-StorePath -Scope Root } | Should -Not -Throw
            }
        }

        Context 'Scope - Company' {

            It 'Returns the per-CNPJ root folder' {
                $result = Get-StorePath -Scope Company -Cnpj $Script:Cnpj
                $result | Should -Be "$($Script:Root)\$($Script:Cnpj)"
            }
        }

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

        Context 'Scope - Logs' {

            It 'Returns the per-CNPJ logs folder' {
                $result = Get-StorePath -Scope Logs -Cnpj $Script:Cnpj
                $result | Should -Be "$($Script:Root)\$($Script:Cnpj)\logs"
            }
        }

        Context 'Scope - Config' {

            It 'Returns the per-CNPJ config folder' {
                $result = Get-StorePath -Scope Config -Cnpj $Script:Cnpj
                $result | Should -Be "$($Script:Root)\$($Script:Cnpj)\config"
            }
        }

        Context 'Scope - Output' {

            It 'Returns the per-CNPJ output folder under USERPROFILE' {
                $result = Get-StorePath -Scope Output -Cnpj $Script:Cnpj
                $result | Should -Be "C:\FakeProfile\PipeDFe\$($Script:Cnpj)\output"
            }

            It 'Output is not rooted under LOCALAPPDATA' {
                $result = Get-StorePath -Scope Output -Cnpj $Script:Cnpj
                $result | Should -Not -BeLike "$($Script:Root)*"
            }
        }

        Context 'Path structure invariants' {

            It 'Index and Audit share the same data folder' {
                $index = Get-StorePath -Scope Index -Cnpj $Script:Cnpj
                $audit = Get-StorePath -Scope Audit -Cnpj $Script:Cnpj

                (Split-Path -Parent $index) | Should -Be (Split-Path -Parent $audit)
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

            It 'Throws when CNPJ has fewer than 14 digits' {
                { Get-StorePath -Scope Index -Cnpj '1234567800019' } | Should -Throw
            }

            It 'Throws when CNPJ has more than 14 digits' {
                { Get-StorePath -Scope Index -Cnpj '123456780001990' } | Should -Throw
            }

            It 'Throws when CNPJ contains non-numeric characters' {
                { Get-StorePath -Scope Index -Cnpj '1234567800019X' } | Should -Throw
            }

            It 'Throws with MissingCnpj error id when CNPJ is absent' {
                try {
                    Get-StorePath -Scope Index -ErrorAction Stop
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'MissingCnpj*'
                }
            }
        }

        Context 'Environment variable guards' {

            It 'Throws when LOCALAPPDATA is not set' {
                $saved = $env:LOCALAPPDATA

                try {
                    $env:LOCALAPPDATA = ''
                    { Get-StorePath -Scope Root } | Should -Throw
                } finally {
                    $env:LOCALAPPDATA = $saved
                }
            }

            It 'Throws when USERPROFILE is not set and Scope is Output' {
                $saved = $env:USERPROFILE

                try {
                    $env:USERPROFILE = ''
                    { Get-StorePath -Scope Output -Cnpj $Script:Cnpj } | Should -Throw
                } finally {
                    $env:USERPROFILE = $saved
                }
            }

            It 'Does not throw when USERPROFILE is not set and Scope is not Output' {
                $saved = $env:USERPROFILE

                try {
                    $env:USERPROFILE = ''
                    { Get-StorePath -Scope Index -Cnpj $Script:Cnpj } | Should -Not -Throw
                } finally {
                    $env:USERPROFILE = $saved
                }
            }
        }

        Context 'Filesystem purity' {

            It 'Does not create any directory' {
                $fakePath = Join-Path -Path (
                    [System.IO.Path]::GetTempPath()
                ) -ChildPath (
                    [System.IO.Path]::GetRandomFileName()
                )

                $saved = $env:LOCALAPPDATA

                try {
                    $env:LOCALAPPDATA = $fakePath
                    Get-StorePath -Scope Index -Cnpj $Script:Cnpj | Out-Null
                    Test-Path -LiteralPath $fakePath | Should -BeFalse
                } finally {
                    $env:LOCALAPPDATA = $saved
                }
            }

            It 'Does not create any file' {
                $fakePath = Join-Path -Path (
                    [System.IO.Path]::GetTempPath()
                ) -ChildPath (
                    [System.IO.Path]::GetRandomFileName()
                )

                $saved = $env:LOCALAPPDATA

                try {
                    $env:LOCALAPPDATA = $fakePath
                    Get-StorePath -Scope Root | Out-Null
                    Test-Path -LiteralPath $fakePath | Should -BeFalse
                } finally {
                    $env:LOCALAPPDATA = $saved
                }
            }
        }

        Context 'Output contract' {

            It 'Returns a string for every scope' -ForEach @(
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
    }
}
