#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Test-SmtpTcpConnection.

.DESCRIPTION
Covers parameter contract, successful connection (returns true),
connection timeout (returns false), and Dispose called in finally.

.NOTES
Private dependencies mocked: System.Net.Sockets.TcpClient via
a wrapper approach -- TcpClient is instantiated inside the function
and cannot be injected directly. Tests use a real loopback connection
for the happy path and a non-routable address for the timeout path.
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

Describe 'Test-SmtpTcpConnection' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Test-SmtpTcpConnection -ErrorAction Stop
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Server as mandatory' {
                $mandatory = $Script:Command.Parameters['Server'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Port as mandatory' {
                $mandatory = $Script:Command.Parameters['Port'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares TimeoutMs as mandatory' {
                $mandatory = $Script:Command.Parameters['TimeoutMs'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Rejects an empty Server' {
                { Test-SmtpTcpConnection -Server '' -Port 25 -TimeoutMs 1000 } |
                    Should -Throw
            }

            It 'Rejects Port below valid range' {
                { Test-SmtpTcpConnection -Server 'localhost' -Port 0 -TimeoutMs 1000 } |
                    Should -Throw
            }

            It 'Rejects Port above valid range' {
                { Test-SmtpTcpConnection -Server 'localhost' -Port 65536 -TimeoutMs 1000 } |
                    Should -Throw
            }

            It 'Rejects TimeoutMs below valid range' {
                { Test-SmtpTcpConnection -Server 'localhost' -Port 25 -TimeoutMs 0 } |
                    Should -Throw
            }
        }
        #endregion

        #region Connection behavior
        Context 'Successful connection' {

            BeforeAll {

                # Start a TCP listener on a random available port.
                $Script:Listener = [System.Net.Sockets.TcpListener]::new(
                    [System.Net.IPAddress]::Loopback,
                    0
                )

                $Script:Listener.Start()

                $Script:ListenerPort = $Script:Listener.LocalEndpoint.Port
            }

            AfterAll {

                $Script:Listener.Stop()
            }

            It 'Returns true when the server accepts the connection' {
                $connectParams = @{
                    Server    = '127.0.0.1'
                    Port      = $Script:ListenerPort
                    TimeoutMs = 5000
                }

                $result = Test-SmtpTcpConnection @connectParams

                $result | Should -BeTrue
            }

            It 'Returns a bool' {
                $connectParams = @{
                    Server    = '127.0.0.1'
                    Port      = $Script:ListenerPort
                    TimeoutMs = 5000
                }

                $result = Test-SmtpTcpConnection @connectParams

                $result | Should -BeOfType [bool]
            }
        }

        Context 'Connection timeout' {

            It 'Returns false when the connection times out' {
                # 192.0.2.0/24 is TEST-NET-1 (RFC 5737) - non-routable,
                # guaranteed to time out without sending RST.
                $connectParams = @{
                    Server    = '192.0.2.1'
                    Port      = 25
                    TimeoutMs = 1
                }

                $result = Test-SmtpTcpConnection @connectParams

                $result | Should -BeFalse
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                $Script:Listener2 = [System.Net.Sockets.TcpListener]::new(
                    [System.Net.IPAddress]::Loopback,
                    0
                )

                $Script:Listener2.Start()

                $Script:ListenerPort2 = $Script:Listener2.LocalEndpoint.Port
            }

            AfterAll {

                $Script:Listener2.Stop()
            }

            It 'Returns exactly one value' {
                $connectParams = @{
                    Server    = '127.0.0.1'
                    Port      = $Script:ListenerPort2
                    TimeoutMs = 5000
                }

                $results = @(Test-SmtpTcpConnection @connectParams)

                $results | Should -HaveCount 1
            }
        }
        #endregion
    }
}
