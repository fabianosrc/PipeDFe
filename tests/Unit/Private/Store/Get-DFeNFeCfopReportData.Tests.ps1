#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Tests error handling and resource cleanup in Get-DFeNFeCfopReportData.

.DESCRIPTION
Uses test doubles for the SQLite connection, command, and reader.

Coverage includes:
  - Cleanup in reverse acquisition order after a successful read.
  - Cleanup failure reported when the read succeeds.
  - Original read failure preserved when cleanup also fails.
  - Connection failure reported before any resources are acquired.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    '',
    Justification = 'Required by member params.'
)]

param ()

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $modulePath -Force -Global -ErrorAction Stop
}

Describe 'Get-DFeNFeCfopReportData resource handling' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {
            function New-TestCfopConnection {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                    'PSUseShouldProcessForStateChangingFunctions',
                    '',
                    Justification = 'This helper only creates in-memory test doubles.'
                )]
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [AllowEmptyCollection()]
                    [System.Collections.Generic.List[string]]$DisposeCalls
                )

                $reader = [PSCustomObject]@{
                    DisposeCalls = $DisposeCalls
                    FailRead     = $false
                    FailDispose  = $false
                }

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Read'
                    Value      = {
                        if ($this.FailRead) {
                            throw [System.InvalidOperationException]::new(
                                'Reader failed.'
                            )
                        }

                        $false
                    }
                    Force      = $true
                }

                $reader | Add-Member @memberParams

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Dispose'
                    Value      = {
                        $this.DisposeCalls.Add('Reader')

                        if ($this.FailDispose) {
                            throw [System.InvalidOperationException]::new(
                                'Reader disposal failed.'
                            )
                        }
                    }
                    Force      = $true
                }

                $reader | Add-Member @memberParams

                $parameters = [PSCustomObject]@{}

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'AddWithValue'
                    Value      = { param ([string]$Name, [string]$Value)}
                    Force      = $true
                }

                $parameters | Add-Member @memberParams

                $command = [PSCustomObject]@{
                    CommandText  = [string]::Empty
                    Parameters   = $parameters
                    Reader       = $reader
                    DisposeCalls = $DisposeCalls
                }

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'ExecuteReader'
                    Value      = { $this.Reader }
                    Force      = $true
                }

                $command | Add-Member @memberParams

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Dispose'
                    Value      = { $this.DisposeCalls.Add('Command') }
                    Force      = $true
                }

                $command | Add-Member @memberParams

                $connection = [PSCustomObject]@{
                    Command      = $command
                    DisposeCalls = $DisposeCalls
                }

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'CreateCommand'
                    Value      = { $this.Command }
                    Force      = $true
                }

                $connection | Add-Member @memberParams

                $memberParams = @{
                    MemberType = 'ScriptMethod'
                    Name       = 'Dispose'
                    Value      = { $this.DisposeCalls.Add('Connection') }
                    Force      = $true
                }

                $connection | Add-Member @memberParams
                $connection
            }
        }

        BeforeEach {

            $Script:CfopDisposeCalls = [System.Collections.Generic.List[string]]::new()

            $Script:CfopConnection = New-TestCfopConnection -DisposeCalls $Script:CfopDisposeCalls

            $Script:CfopReportParams = @{
                Cnpj      = '12345678000195'
                StartDate = [System.DateTimeOffset]::new(
                    2024, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero
                )
                EndDate   = [System.DateTimeOffset]::new(
                    2024, 1, 31, 23, 59, 59, [System.TimeSpan]::Zero
                )
            }

            Mock -CommandName Open-DFeIndexConnection -MockWith {
                $Script:CfopConnection
            }
        }

        It 'Disposes the reader, command, and connection in reverse acquisition order' {
            $reportParams = $Script:CfopReportParams

            $result = Get-DFeNFeCfopReportData @reportParams

            $result.Itens | Should -HaveCount 0
            ($Script:CfopDisposeCalls -join ',') |
                Should -BeExactly 'Reader,Command,Connection'
        }

        It 'Reports a cleanup failure and still disposes the remaining resources' {
            $Script:CfopConnection.Command.Reader.FailDispose = $true

            $reportParams = $Script:CfopReportParams
            $shouldParams = @{
                Throw           = $true
                ErrorId         = 'NFeCfopReportReadFailed*'
                ExpectedMessage = '*Reader disposal failed.*'
            }

            { Get-DFeNFeCfopReportData @reportParams } | Should @shouldParams

            ($Script:CfopDisposeCalls -join ',') |
                Should -BeExactly 'Reader,Command,Connection'
        }

        It 'Preserves the read failure when reader cleanup also fails' {
            $Script:CfopConnection.Command.Reader.FailRead    = $true
            $Script:CfopConnection.Command.Reader.FailDispose = $true

            $reportParams = $Script:CfopReportParams

            $shouldParams = @{
                Throw           = $true
                ErrorId         = 'NFeCfopReportReadFailed*'
                ExpectedMessage = '*Reader failed.*'
            }

            { Get-DFeNFeCfopReportData @reportParams } | Should @shouldParams

            ($Script:CfopDisposeCalls -join ',') |
                Should -BeExactly 'Reader,Command,Connection'
        }

        It 'Reports a connection failure without attempting to dispose unacquired resources' {
            Mock -CommandName Open-DFeIndexConnection -MockWith {
                throw [System.InvalidOperationException]::new(
                    'Connection failed.'
                )
            }

            $reportParams = $Script:CfopReportParams

            $shouldParams = @{
                Throw           = $true
                ErrorId         = 'NFeCfopReportReadFailed*'
                ExpectedMessage = '*Connection failed.*'
            }

            { Get-DFeNFeCfopReportData @reportParams } | Should @shouldParams

            $Script:CfopDisposeCalls.Count | Should -Be 0
        }
    }
}
