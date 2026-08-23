#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Add-MailRecipient.

.DESCRIPTION
Coverage includes:
  Parameter contract:
    - Collection is mandatory.
    - Recipients is mandatory.
    - Collection rejects null.

  Recipient filtering:
    - Null Recipients is accepted.
    - Empty Recipients collection is accepted.
    - Null recipient entries are skipped.
    - Null Email values are skipped.
    - Empty Email values are skipped.
    - Whitespace Email values are skipped.
    - Invalid email addresses are skipped.
    - Processing continues after invalid recipients.

  Collection mutation:
    - Valid recipients are added.
    - Multiple valid recipients are added.
    - The correct address is stored.
    - The original address is preserved.
    - No valid recipients leaves the collection unchanged.
    - The function produces no pipeline output.

  Display name handling:
    - Display name is preserved when supplied.
    - Null Name produces no display name.
    - Empty Name produces no display name.
    - Whitespace Name produces no display name.
    - UTF-8 display names are preserved.

  Warning behavior:
    - Invalid addresses emit a warning.
    - Warning contains the rejected email address.
    - Valid recipients do not emit warnings.
    - Blank Email values do not emit warnings.
#>

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that is when Context/It are executed to register the test tree.
# If the module isn't loaded at that point, InModuleScope fails before any
# BeforeAll or BeforeEach can run.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Add-MailRecipient' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Add-MailRecipient -ErrorAction Stop
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Collection as mandatory' {
                $mandatory = $Script:Command.Parameters['Collection'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Recipients as mandatory' {
                $mandatory = $Script:Command.Parameters['Recipients'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Rejects a null Collection' {
                { Add-MailRecipient -Collection $null -Recipients @() } |
                    Should -Throw
            }

            It 'Accepts a null Recipients value' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                { Add-MailRecipient -Collection $collection -Recipients $null } |
                    Should -Not -Throw
            }

            It 'Accepts an empty Recipients collection' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                { Add-MailRecipient -Collection $collection -Recipients @() } |
                    Should -Not -Throw
            }
        }
        #endregion

        #region Recipient filtering
        Context 'Recipient filtering' {

            It 'Skips a null recipient entry' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @($null)

                $collection.Count | Should -Be 0
            }

            It 'Skips a recipient with null Email' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = $null
                        Name  = $null
                    }
                )

                $collection.Count | Should -Be 0
            }

            It 'Skips a recipient with empty Email' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = ''
                        Name  = $null
                    }
                )

                $collection.Count | Should -Be 0
            }

            It 'Skips a recipient with whitespace Email' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = '   '
                        Name  = $null
                    }
                )

                $collection.Count | Should -Be 0
            }

            It 'Skips a recipient with an invalid email address' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = 'not-an-email'
                        Name  = $null
                    }
                ) 3> $null

                $collection.Count | Should -Be 0
            }

            It 'Skips an invalid recipient without throwing' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                {
                    Add-MailRecipient -Collection $collection -Recipients @(
                        [PSCustomObject]@{
                            Email = 'not-an-email'
                            Name  = $null
                        }
                    ) 3> $null
                } |
                    Should -Not -Throw
            }

            It 'Skips null entries in a mixed recipient array' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    $null
                    [PSCustomObject]@{
                        Email = 'valid@example.com'
                        Name  = $null
                    }
                    $null
                )

                $collection.Count | Should -Be 1
            }

            It 'Continues processing after an invalid recipient' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = 'invalid-email'
                        Name  = $null
                    }
                    [PSCustomObject]@{
                        Email = 'valid@example.com'
                        Name  = $null
                    }
                ) 3> $null

                $collection.Count | Should -Be 1
                $collection[0].Address | Should -Be 'valid@example.com'
            }
        }
        #endregion

        #region Collection mutation
        Context 'Collection mutation' {

            It 'Adds a valid recipient to the collection' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = 'dest@example.com'
                        Name  = $null
                    }
                )

                $collection.Count | Should -Be 1
            }

            It 'Adds all valid recipients' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = 'a@example.com'
                        Name  = $null
                    }
                    [PSCustomObject]@{
                        Email = 'b@example.com'
                        Name  = $null
                    }
                    [PSCustomObject]@{
                        Email = 'c@example.com'
                        Name  = $null
                    }
                )

                $collection.Count | Should -Be 3
            }

            It 'Stores the correct address' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = 'dest@example.com'
                        Name  = $null
                    }
                )

                $collection[0].Address | Should -Be 'dest@example.com'
            }

            It 'Preserves the address exactly' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = 'Dest@Example.COM'
                        Name  = $null
                    }
                )

                $collection[0].Address | Should -Be 'Dest@Example.COM'
            }

            It 'Leaves the collection unchanged when no valid recipients exist' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    $null
                    [PSCustomObject]@{
                        Email = $null
                        Name  = $null
                    }
                    [PSCustomObject]@{
                        Email = '   '
                        Name  = $null
                    }
                    [PSCustomObject]@{
                        Email = 'invalid-email'
                        Name  = $null
                    }
                ) 3> $null

                $collection.Count | Should -Be 0
            }

            It 'Produces no pipeline output' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                $output = Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = 'dest@example.com'
                        Name  = $null
                    }
                )

                $output | Should -BeNullOrEmpty
            }

            It 'Leaves the collection unchanged for an empty Recipients collection' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @()

                $collection.Count | Should -Be 0
            }

            It 'Leaves the collection unchanged for null Recipients' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients $null

                $collection.Count | Should -Be 0
            }
        }
        #endregion

        #region Display name handling
        Context 'Display name handling' {

            It 'Sets DisplayName when Name is provided' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = 'dest@example.com'
                        Name  = 'Destinatario'
                    }
                )

                $collection.Count          | Should -Be 1
                $collection[0].DisplayName | Should -Be 'Destinatario'
            }

            It 'Adds without DisplayName when Name is null' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = 'dest@example.com'
                        Name  = $null
                    }
                )

                $collection.Count          | Should -Be 1
                $collection[0].DisplayName | Should -BeNullOrEmpty
            }

            It 'Adds without DisplayName when Name is empty' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = 'dest@example.com'
                        Name  = ''
                    }
                )

                $collection.Count          | Should -Be 1
                $collection[0].DisplayName | Should -BeNullOrEmpty
            }

            It 'Adds without DisplayName when Name is whitespace' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = 'dest@example.com'
                        Name  = '   '
                    }
                )

                $collection.Count          | Should -Be 1
                $collection[0].DisplayName | Should -BeNullOrEmpty
            }

            It 'Preserves UTF-8 display names' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = 'dest@example.com'
                        Name  = 'João da Silva'
                    }
                )

                $collection[0].DisplayName | Should -Be 'João da Silva'
            }
        }
        #endregion

        #region Warning behavior
        Context 'Warning behavior' {

            It 'Emits a warning for an invalid email address' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()
                $warnings   = $null

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = 'invalid-email'
                        Name  = $null
                    }
                ) -WarningVariable warnings

                $warnings | Should -Not -BeNullOrEmpty
            }

            It 'Includes the rejected email address in the warning' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()
                $warnings   = $null

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = 'invalid-email'
                        Name  = $null
                    }
                ) -WarningVariable warnings

                $warnings.Message | Should -Match 'invalid-email'
            }

            It 'Does not emit a warning for a valid recipient' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()
                $warnings   = $null

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = 'valid@example.com'
                        Name  = 'Destinatario'
                    }
                ) -WarningVariable warnings

                $warnings | Should -BeNullOrEmpty
            }

            It 'Does not emit a warning for a blank Email' {
                $collection = [System.Net.Mail.MailAddressCollection]::new()
                $warnings   = $null

                Add-MailRecipient -Collection $collection -Recipients @(
                    [PSCustomObject]@{
                        Email = '   '
                        Name  = 'Destinatario'
                    }
                ) -WarningVariable warnings

                $warnings | Should -BeNullOrEmpty
            }
        }
        #endregion
    }
}
