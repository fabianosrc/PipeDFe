#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Resolve-SmtpReplyTo.

.DESCRIPTION
Coverage includes:
  - Smtp is mandatory and rejects null.
  - Returns null when ReplyTo property is absent.
  - Returns null when ReplyTo property is null.
  - Returns null when ReplyTo is an empty string.
  - Returns null when ReplyTo is a whitespace-only string.
  - Returns the string when ReplyTo is a plain email string.
  - Returns the Email value when ReplyTo is an object with Email property.
  - Returns null when ReplyTo is an object with an empty Email.
  - Returns null when ReplyTo is an object with a whitespace-only Email.
  - Returns null when ReplyTo is an object with a null Email.
  - Returns null when ReplyTo is an object without an Email property.
  - Never throws for unexpected ReplyTo types.
  - Returns string or null.
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

Describe 'Resolve-SmtpReplyTo' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Resolve-SmtpReplyTo -ErrorAction Stop
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Smtp as mandatory' {
                $mandatory = $Script:Command.Parameters['Smtp'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Rejects null Smtp' {
                { Resolve-SmtpReplyTo -Smtp $null } | Should -Throw
            }
        }
        #endregion

        #region Absent and null
        Context 'Absent and null' {

            It 'Returns null when ReplyTo property is absent' {
                $smtp = [PSCustomObject]@{ Server = 'smtp.test.com' }

                $result = Resolve-SmtpReplyTo -Smtp $smtp
                $result | Should -BeNullOrEmpty
            }

            It 'Returns null when ReplyTo property is null' {
                $smtp = [PSCustomObject]@{ ReplyTo = $null }

                $result = Resolve-SmtpReplyTo -Smtp $smtp
                $result | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region String input
        Context 'String input' {

            It 'Returns null when ReplyTo is an empty string' {
                $smtp = [PSCustomObject]@{ ReplyTo = '' }

                $result = Resolve-SmtpReplyTo -Smtp $smtp

                $result | Should -BeNullOrEmpty
            }

            It 'Returns null when ReplyTo is a whitespace-only string' {
                $smtp = [PSCustomObject]@{ ReplyTo = '   ' }

                $result = Resolve-SmtpReplyTo -Smtp $smtp
                $result | Should -BeNullOrEmpty
            }

            It 'Returns the string when ReplyTo is a plain email string' {
                $smtp = [PSCustomObject]@{ ReplyTo = 'reply@domain.com' }

                $result = Resolve-SmtpReplyTo -Smtp $smtp
                $result | Should -Be 'reply@domain.com'
            }
        }
        #endregion

        #region Object input
        Context 'Object input' {

            It 'Returns the Email value when ReplyTo is an object with Email' {
                $smtp = [PSCustomObject]@{
                    ReplyTo = [PSCustomObject]@{
                        Email = 'reply@domain.com'
                    }
                }

                $result = Resolve-SmtpReplyTo -Smtp $smtp
                $result | Should -Be 'reply@domain.com'
            }

            It 'Returns null when ReplyTo is an object with an empty Email' {
                $smtp = [PSCustomObject]@{
                    ReplyTo = [PSCustomObject]@{
                        Email = ''
                    }
                }

                $result = Resolve-SmtpReplyTo -Smtp $smtp
                $result | Should -BeNullOrEmpty
            }

            It 'Returns null when ReplyTo is an object with a whitespace-only Email' {
                $smtp = [PSCustomObject]@{
                    ReplyTo = [PSCustomObject]@{
                        Email = '   '
                    }
                }

                $result = Resolve-SmtpReplyTo -Smtp $smtp
                $result | Should -BeNullOrEmpty
            }

            It 'Returns null when ReplyTo is an object with a null Email' {
                $smtp = [PSCustomObject]@{
                    ReplyTo = [PSCustomObject]@{
                        Email = $null
                    }
                }

                $result = Resolve-SmtpReplyTo -Smtp $smtp
                $result | Should -BeNullOrEmpty
            }

            It 'Returns null when ReplyTo is an object without an Email property' {
                $smtp = [PSCustomObject]@{
                    ReplyTo = [PSCustomObject]@{
                        Name = 'Reply'
                    }
                }

                $result = Resolve-SmtpReplyTo -Smtp $smtp
                $result | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Never throws
        Context 'Never throws' {

            It 'Does not throw when ReplyTo is absent' {
                $smtp = [PSCustomObject]@{ Server = 'smtp.test.com' }

                { Resolve-SmtpReplyTo -Smtp $smtp } | Should -Not -Throw
            }

            It 'Does not throw when ReplyTo is null' {
                $smtp = [PSCustomObject]@{ ReplyTo = $null }

                { Resolve-SmtpReplyTo -Smtp $smtp } | Should -Not -Throw
            }

            It 'Does not throw when ReplyTo is a boolean' {
                $smtp = [PSCustomObject]@{ ReplyTo = $true }

                { Resolve-SmtpReplyTo -Smtp $smtp } | Should -Not -Throw
            }

            It 'Does not throw when ReplyTo is an array' {
                $smtp = [PSCustomObject]@{ ReplyTo = @() }

                { Resolve-SmtpReplyTo -Smtp $smtp } | Should -Not -Throw
            }

            It 'Does not throw when ReplyTo is a hashtable' {
                $smtp = [PSCustomObject]@{ ReplyTo = @{} }

                { Resolve-SmtpReplyTo -Smtp $smtp } | Should -Not -Throw
            }

            It 'Does not throw when ReplyTo is an integer' {
                $smtp = [PSCustomObject]@{ ReplyTo = 42 }

                { Resolve-SmtpReplyTo -Smtp $smtp } | Should -Not -Throw
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            It 'Returns a string when ReplyTo is present' {
                $smtp = [PSCustomObject]@{
                    ReplyTo = 'reply@domain.com'
                }

                $result = Resolve-SmtpReplyTo -Smtp $smtp
                $result | Should -BeOfType [string]
            }

            It 'Returns null when ReplyTo is absent' {
                $smtp = [PSCustomObject]@{
                    Server = 'smtp.test.com'
                }

                $result = Resolve-SmtpReplyTo -Smtp $smtp
                $result | Should -BeNullOrEmpty
            }
        }
        #endregion
    }
}
