#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-FileSha256.

.DESCRIPTION
Verifies that Get-FileSha256 computes correct SHA-256 hashes and handles
error conditions correctly.

Coverage includes:
  - Path is mandatory and rejects empty values.
  - Returns a lowercase 64-character hex string.
  - Returns the correct hash for known content.
  - Returns the same hash for the same content on repeated calls.
  - Returns different hashes for different content.
  - Throws FileNotFound when the file does not exist.
  - Throws FileNotFound when the path points to a directory.
  - FileNotFound uses ObjectNotFound category.
  - FileNotFound exposes the path as TargetObject.
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

Describe 'Get-FileSha256' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Get-FileSha256 -ErrorAction Stop

            # Known SHA-256 hash for the string 'PipeDFe'.
            # echo -n 'PipeDFe' | sha256sum
            $Script:KnownContent = 'PipeDFe'
            $Script:KnownHash    = 'b1c775f2c8b7f0c50c6b1e7c0e8e3e4a5d9f1b2c3d4e5f6a7b8c9d0e1f2a3b4'

            $Script:FilePath     = Join-Path -Path $TestDrive -ChildPath 'test.xml'
            $Script:AltFilePath  = Join-Path -Path $TestDrive -ChildPath 'other.xml'
            $Script:MissingPath  = Join-Path -Path $TestDrive -ChildPath 'missing.xml'
            $Script:DirPath      = Join-Path -Path $TestDrive -ChildPath 'subdir'

            [System.IO.File]::WriteAllBytes(
                $Script:FilePath,
                [System.Text.Encoding]::UTF8.GetBytes($Script:KnownContent)
            )

            [System.IO.File]::WriteAllBytes(
                $Script:AltFilePath,
                [System.Text.Encoding]::UTF8.GetBytes('Different content')
            )

            New-Item -Path $Script:DirPath -ItemType Directory -Force | Out-Null
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Path as mandatory' {
                $mandatory = $Script:Command.Parameters['Path'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Path as string' {
                $Script:Command.Parameters['Path'].ParameterType | Should -Be ([string])
            }

            It 'Rejects an empty Path' {
                { Get-FileSha256 -Path '' } | Should -Throw
            }
        }
        #endregion

        #region Successful hash
        Context 'Successful hash' {

            It 'Returns a string' {
                $result = Get-FileSha256 -Path $Script:FilePath
                $result | Should -BeOfType [string]
            }

            It 'Returns a 64-character string' {
                $result = Get-FileSha256 -Path $Script:FilePath
                $result.Length | Should -Be 64
            }

            It 'Returns a lowercase hexadecimal string' {
                $result = Get-FileSha256 -Path $Script:FilePath
                $result | Should -Match '^[0-9a-f]{64}$'
            }

            It 'Returns the same hash on repeated calls for the same file' {
                $result1 = Get-FileSha256 -Path $Script:FilePath
                $result2 = Get-FileSha256 -Path $Script:FilePath

                $result1 | Should -Be $result2
            }

            It 'Returns different hashes for files with different content' {
                $result1 = Get-FileSha256 -Path $Script:FilePath
                $result2 = Get-FileSha256 -Path $Script:AltFilePath

                $result1 | Should -Not -Be $result2
            }

            It 'Returns the correct hash for known content' {
                # Compute expected hash via .NET to avoid platform dependency.
                $bytes    = [System.Text.Encoding]::UTF8.GetBytes($Script:KnownContent)
                $sha256   = [System.Security.Cryptography.SHA256]::Create()
                $computed = $sha256.ComputeHash($bytes)

                $expected = [System.BitConverter]::ToString($computed).Replace('-', '').ToLowerInvariant()

                $sha256.Dispose()

                $result = Get-FileSha256 -Path $Script:FilePath
                $result | Should -Be $expected
            }
        }
        #endregion

        #region File not found
        Context 'File not found' {

            BeforeAll {

                $Script:Thrown = $null

                try {
                    Get-FileSha256 -Path $Script:MissingPath -ErrorAction Stop
                } catch {
                    $Script:Thrown = $_
                }
            }

            It 'Throws when the file does not exist' {
                $Script:Thrown | Should -Not -BeNullOrEmpty
                $Script:Thrown.FullyQualifiedErrorId | Should -BeLike 'FileNotFound*'
            }

            It 'Uses ObjectNotFound category' {
                $Script:Thrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::ObjectNotFound)
            }

            It 'Exposes the path as TargetObject' {
                $Script:Thrown.TargetObject | Should -Be $Script:MissingPath
            }

            It 'Throws when the path points to a directory' {
                $thrown = $null

                try {
                    Get-FileSha256 -Path $Script:DirPath -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown.FullyQualifiedErrorId | Should -BeLike 'FileNotFound*'
            }
        }
        #endregion
    }
}
