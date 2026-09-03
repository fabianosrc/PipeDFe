#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-PipeSmtp.

.DESCRIPTION
Coverage includes:
  - Accepts no parameters.
  - Delegates entirely to Get-SmtpConfig.
  - Returns the object produced by Get-SmtpConfig without modification.
  - Propagates SmtpConfigNotFound when Get-SmtpConfig throws.
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

Describe 'Get-PipeSmtp' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Get-PipeSmtp

            $Script:FakeSmtp = [PSCustomObject]@{
                SchemaVersion = 1
                Server        = 'smtp.example.com'
                Port          = 587
                Ssl           = $true
                Username      = 'user@example.com'
                Password      = 'AQAAANCMnd8BFdERjHoAwE...'
                From          = [PSCustomObject]@{
                    Name    = 'Empresa'
                    Address = 'noreply@example.com'
                }
                SenderAddress = $null
                ReplyTo       = $null
                Timeout       = 30
                CreatedAt     = '2026-07-01T00:00:00.0000000+00:00'
                UpdatedAt     = '2026-07-01T00:00:00.0000000+00:00'
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares no parameters other than common parameters' {
                $ownParams = $Script:Command.Parameters.Keys |
                    Where-Object {
                        $_ -notin [System.Management.Automation.Cmdlet]::CommonParameters
                    }

                $ownParams | Should -HaveCount 0
            }
        }
        #endregion

        #region Delegation
        Context 'Delegation' {

            BeforeAll {

                Mock -CommandName Get-SmtpConfig -MockWith {
                    return $Script:FakeSmtp
                }

                $Script:Result = Get-PipeSmtp
            }

            It 'Calls Get-SmtpConfig exactly once' {
                $invokeParams = @{
                    CommandName = 'Get-SmtpConfig'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Returns the object produced by Get-SmtpConfig' {
                $Script:Result | Should -Be $Script:FakeSmtp
            }
        }
        #endregion

        #region Return contract
        Context 'Return contract' {

            BeforeAll {

                Mock -CommandName Get-SmtpConfig -MockWith {
                    return $Script:FakeSmtp
                }

                $Script:Result = Get-PipeSmtp
            }

            It 'Returns exactly one object' {
                @($Script:Result) | Should -HaveCount 1
            }

            It 'Returns an object with a Server property' {
                $Script:Result.Server | Should -Not -BeNullOrEmpty
            }

            It 'Returns an object with a Port property' {
                $Script:Result.Port | Should -BeGreaterThan 0
            }
        }
        #endregion

        #region Error propagation
        Context 'Error propagation' {

            BeforeAll {

                Mock -CommandName Get-SmtpConfig -MockWith {
                    param ()

                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.IO.FileNotFoundException]::new('smtp.json not found.'),
                            'SmtpConfigNotFound',
                            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                            $null
                        )
                    )
                }

                $Script:Exception = $null

                try {
                    Get-PipeSmtp
                } catch {
                    $Script:Exception = $_
                }
            }

            It 'Propagates SmtpConfigNotFound when Get-SmtpConfig throws' {
                $Script:Exception.FullyQualifiedErrorId |
                    Should -BeLike 'SmtpConfigNotFound*'
            }
        }
        #endregion
    }
}
