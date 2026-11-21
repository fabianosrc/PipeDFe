#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for the PipeDFe distributable module build.

.DESCRIPTION
Builds isolated versioned and PowerShell Gallery layouts without publishing.
The build validates both layouts in isolated PowerShell processes using real
module imports and localized Get-Help resolution.

Coverage includes:
  - Versioned installation and gallery directory names
  - Required MAML and about help files in both cultures
  - Inclusion of SQLite binaries and module metadata
  - SHA-256 inventory of the versioned artifact
  - Preservation of the repository's source help directories
#>

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'PipeDFe module build' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:BuildTestRoot = (
                Get-Item -LiteralPath $PSScriptRoot
            ).Parent.Parent.Parent.FullName

            $manifestPath = Join-Path -Path $Script:BuildTestRoot -ChildPath 'PipeDFe.psd1'

            $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath

            $Script:BuildTestVersion = [string]$manifest.ModuleVersion

            $Script:BuildTestArtifacts = Join-Path -Path $TestDrive -ChildPath 'artifacts'

            $Script:BuildTestVersioned = Join-Path -Path $Script:BuildTestArtifacts -ChildPath (
                'PipeDFe/{0}' -f $Script:BuildTestVersion
            )

            $Script:BuildTestGallery = Join-Path -Path $Script:BuildTestArtifacts -ChildPath (
                'PSGallery/PipeDFe'
            )

            $buildScript = Join-Path -Path $Script:BuildTestRoot -ChildPath 'tools/Invoke-Build.ps1'

            $buildParams = @{
                SkipTests    = $true
                SkipLint     = $true
                ArtifactRoot = $Script:BuildTestArtifacts
                ErrorAction = 'Stop'
            }

            # Do not recurse into the test runner. This test exercises artifact
            # assembly and its real import/help probes, not lint or Pester itself.
            & $buildScript @buildParams
        }

        #region Installation layouts
        Context 'Installation layouts' {

            It 'Creates the versioned module directory' {
                Test-Path -LiteralPath $Script:BuildTestVersioned -PathType Container |
                    Should -BeTrue
            }

            It 'Creates a module-named directory for PowerShell Gallery' {
                Test-Path -LiteralPath $Script:BuildTestGallery -PathType Container |
                    Should -BeTrue
            }

            It 'Includes the module manifest and SQLite dependencies in both layouts' {
                foreach ($basePath in @($Script:BuildTestVersioned, $Script:BuildTestGallery)) {
                    foreach ($relativePath in @(
                            'PipeDFe.psd1',
                            'PipeDFe.psm1',
                            'lib/net471/System.Data.SQLite.dll',
                            'lib/netstandard2.0/System.Data.SQLite.dll',
                            'lib/native/x86/e_sqlite3.dll',
                            'lib/native/x64/e_sqlite3.dll'
                        )
                    ) {
                        $path = Join-Path -Path $basePath -ChildPath $relativePath

                        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
                    }
                }
            }

            It 'Installs both localized help sets at module root in both layouts' {
                foreach ($basePath in @($Script:BuildTestVersioned, $Script:BuildTestGallery)) {
                    foreach ($culture in @('pt-BR', 'en-US')) {
                        foreach ($fileName in @('PipeDFe-help.xml', 'about_PipeDFe.help.txt')) {
                            $relativePath = '{0}/{1}' -f $culture, $fileName

                            $path = Join-Path -Path $basePath -ChildPath $relativePath

                            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
                        }
                    }
                }
            }

            It 'Leaves source help files in their original repository locations' {
                foreach ($culture in @('pt-BR', 'en-US')) {
                    $path = Join-Path -Path $Script:BuildTestRoot -ChildPath (
                        'src/{0}/PipeDFe-help.xml' -f $culture
                    )

                    Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
                }
            }
        }
        #endregion

        #region Artifact integrity
        Context 'Artifact integrity' {
            It 'Creates a SHA-256 inventory' {
                $inventoryPath = Join-Path -Path $Script:BuildTestVersioned -ChildPath 'hashes.json'
                Test-Path -LiteralPath $inventoryPath -PathType Leaf | Should -BeTrue
            }

            It 'Includes the localized MAML files in the inventory' {
                $inventoryPath = Join-Path -Path $Script:BuildTestVersioned -ChildPath 'hashes.json'
                $inventory = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json

                $inventory.module  | Should -BeExactly 'PipeDFe'
                $inventory.version | Should -BeExactly $Script:BuildTestVersion

                $paths = @($inventory.files | Select-Object -ExpandProperty file)
                $paths | Should -Contain 'pt-BR/PipeDFe-help.xml'
                $paths | Should -Contain 'en-US/PipeDFe-help.xml'
            }

            It 'Records the actual SHA-256 of a packaged help file' {
                $inventoryPath = Join-Path -Path $Script:BuildTestVersioned -ChildPath 'hashes.json'
                $inventory = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json

                $entry = @($inventory.files | Where-Object { $_.file -eq 'pt-BR/PipeDFe-help.xml' })
                $entry | Should -HaveCount 1

                $helpPath = Join-Path -Path $Script:BuildTestVersioned -ChildPath ('pt-BR/PipeDFe-help.xml')

                $actualHash = (Get-FileHash -LiteralPath $helpPath -Algorithm SHA256).Hash
                $entry[0].sha256 | Should -BeExactly $actualHash
            }
        }
        #endregion
    }
}
