#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for New-TcpClientConnection.

.DESCRIPTION
Only parameter contract is covered here. Connection behavior requires
a real network endpoint and is covered by integration tests.
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

Describe 'New-TcpClientConnection' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name New-TcpClientConnection
        }

        Context 'Parameter contract' {

            It 'Requires Server' {
                $Script:Command.Parameters['Server'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeTrue }
            }

            It 'Requires Port' {
                $Script:Command.Parameters['Port'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeTrue }
            }

            It 'Requires TimeoutMs' {
                $Script:Command.Parameters['TimeoutMs'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeTrue }
            }

            It 'Rejects Port 0' {
                $params = @{
                    Server    = 'smtp.example.com'
                    Port      = 0
                    TimeoutMs = 5000
                }

                { New-TcpClientConnection @params } | Should -Throw
            }

            It 'Rejects Port 65536' {
                $params = @{
                    Server    = 'smtp.example.com'
                    Port      = 65536
                    TimeoutMs = 5000
                }

                { New-TcpClientConnection @params } | Should -Throw
            }

            It 'Rejects TimeoutMs 0' {
                $params = @{
                    Server    = 'smtp.example.com'
                    Port      = 587
                    TimeoutMs = 0
                }

                { New-TcpClientConnection @params } | Should -Throw
            }

            It 'Rejects empty Server' {
                $params = @{
                    Server    = ''
                    Port      = 587
                    TimeoutMs = 5000
                }

                { New-TcpClientConnection @params } | Should -Throw
            }

            It 'Declares OutputType as TcpClient' {
                $Script:Command.OutputType.Type | Should -Be ([System.Net.Sockets.TcpClient])
            }

            It 'Does not expose WhatIf' {
                $Script:Command.Parameters.ContainsKey('WhatIf') | Should -BeFalse
            }
        }
    }
}
