#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for New-SmtpSslStream.

.DESCRIPTION
Parameter contract is covered with a mock InnerStream. Full TLS handshake
behavior requires a real TLS endpoint and is covered by integration tests.
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

Describe 'New-SmtpSslStream' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name New-SmtpSslStream
            $Script:Stream  = [System.IO.MemoryStream]::new()
        }

        AfterAll {

            $Script:Stream.Dispose()
        }

        Context 'Parameter contract' {

            It 'Requires InnerStream' {
                $Script:Command.Parameters['InnerStream'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeTrue }
            }

            It 'Requires TargetHost' {
                $Script:Command.Parameters['TargetHost'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeTrue }
            }

            It 'Requires HandshakeTimeoutMs' {
                $Script:Command.Parameters['HandshakeTimeoutMs'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeTrue }
            }

            It 'Requires FailureContext' {
                $Script:Command.Parameters['FailureContext'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeTrue }
            }

            It 'Rejects HandshakeTimeoutMs 0' {
                $params = @{
                    InnerStream        = $Script:Stream
                    TargetHost         = 'smtp.example.com'
                    HandshakeTimeoutMs = 0
                    FailureContext     = 'TLS'
                }

                { New-SmtpSslStream @params } | Should -Throw
            }

            It 'Rejects empty TargetHost' {
                $params = @{
                    InnerStream        = $Script:Stream
                    TargetHost         = ''
                    HandshakeTimeoutMs = 5000
                    FailureContext     = 'TLS'
                }

                { New-SmtpSslStream @params } | Should -Throw
            }

            It 'Rejects empty FailureContext' {
                $params = @{
                    InnerStream        = $Script:Stream
                    TargetHost         = 'smtp.example.com'
                    HandshakeTimeoutMs = 5000
                    FailureContext     = ''
                }

                { New-SmtpSslStream @params } | Should -Throw
            }

            It 'Declares OutputType as SslStream' {
                $Script:Command.OutputType.Type | Should -Be ([System.Net.Security.SslStream])
            }

            It 'Does not expose WhatIf' {
                $Script:Command.Parameters.ContainsKey('WhatIf') | Should -BeFalse
            }
        }
    }
}
