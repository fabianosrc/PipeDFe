#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for localized PipeDFe About topics.

.DESCRIPTION
Coverage includes:
  - Required topic headers and conceptual sections in pt-BR and en-US
  - A maximum of 80 characters per line
  - Discovery of each localized synopsis through Get-Help in an isolated
    process importing the real module from a temporary installation layout
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

Describe 'PipeDFe localized About topics' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:AboutTestRoot = (
                Get-Item -LiteralPath $PSScriptRoot
            ).Parent.Parent.Parent.Parent.FullName

            $Script:AboutTestCultures = @('pt-BR', 'en-US')

            $Script:AboutTestSections = @(
                'LONG DESCRIPTION'
                'COMPANY CONFIGURATION'
                'MONTHLY CLOSING'
                'ARCHIVE ORGANIZATION'
                'DELIVERY SAFETY'
                'EXAMPLES'
                'LIMITATIONS'
                'TROUBLESHOOTING'
                'SEE ALSO'
            )

            $Script:AboutTestTopics   = @{}
            $Script:AboutTestSynopses = @{}

            foreach ($cultureName in $Script:AboutTestCultures) {
                $path = Join-Path -Path $Script:AboutTestRoot -ChildPath (
                    'src/{0}/about_PipeDFe.help.txt' -f $cultureName
                )

                $lines = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop)

                $Script:AboutTestTopics[$cultureName] = $lines

                $content = $lines -join [char]10
                $match = [regex]::Match(
                    $content,
                    '(?m)^SYNOPSIS[ ]*\n((?:[ ]{4}\S[^\n]*(?:\n|$))+)'
                )

                $Script:AboutTestSynopses[$cultureName] = (
                    $match.Groups[1].Value -replace '\s+', ' '
                ).Trim()
            }

            #region Isolated module package
            # Source help lives in src/<culture>. Create the actual module
            # distribution layout under TestDrive without changing the project.
            $Script:AboutTestPackageRoot = Join-Path -Path $TestDrive -ChildPath 'PipeDFe'
            [void][System.IO.Directory]::CreateDirectory($Script:AboutTestPackageRoot)

            foreach ($fileName in @('PipeDFe.psd1', 'PipeDFe.psm1')) {
                $copyParams = @{
                    LiteralPath = Join-Path -Path $Script:AboutTestRoot -ChildPath $fileName
                    Destination = $Script:AboutTestPackageRoot
                    ErrorAction = 'Stop'
                }

                Copy-Item @copyParams
            }

            foreach ($directoryName in @('src', 'lib')) {
                $sourcePath = Join-Path -Path $Script:AboutTestRoot -ChildPath $directoryName

                $copyParams = @{
                    LiteralPath = $sourcePath
                    Destination = $Script:AboutTestPackageRoot
                    Recurse = $true
                    ErrorAction = 'Stop'
                }

                Copy-Item @copyParams
            }

            foreach ($cultureName in $Script:AboutTestCultures) {
                $sourcePath = Join-Path -Path $Script:AboutTestRoot -ChildPath (
                    'src/{0}' -f $cultureName
                )

                $destinationPath = Join-Path -Path $Script:AboutTestPackageRoot -ChildPath $cultureName

                $copyParams = @{
                    LiteralPath = $sourcePath
                    Destination = $destinationPath
                    Recurse = $true
                    ErrorAction = 'Stop'
                }

                Copy-Item @copyParams
            }

            $aboutTestJoinPathParams = @{
                Path        = $Script:AboutTestPackageRoot
                ChildPath   = 'PipeDFe.psd1'
            }

            $Script:AboutTestStagedManifest = Join-Path @aboutTestJoinPathParams
            #endregion

            #region Locale probe
            $Script:AboutTestProbePath = Join-Path -Path $TestDrive -ChildPath (
                'Invoke-PipeDFeAboutProbe.ps1'
            )

            $probeSource = @'
param (
    [Parameter(Mandatory)]
    [string]$ModulePath,

    [Parameter(Mandatory)]
    [string]$CultureName
)

$ErrorActionPreference = 'Stop'

try {
    $culture = [System.Globalization.CultureInfo]::GetCultureInfo($CultureName)

    [System.Threading.Thread]::CurrentThread.CurrentCulture = $culture
    [System.Threading.Thread]::CurrentThread.CurrentUICulture = $culture

    # Make the staged module discoverable by the PowerShell help engine.
    $moduleParent = Split-Path -Path (Split-Path -Path $ModulePath -Parent) -Parent
    $env:PSModulePath = $moduleParent + [System.IO.Path]::PathSeparator + $env:PSModulePath

    Import-Module -Name $ModulePath -Force -ErrorAction Stop

    $about = Get-Help -Name 'about_PipeDFe' -ErrorAction Stop

    $result = [PSCustomObject]@{
        Culture       = [System.Threading.Thread]::CurrentThread.CurrentUICulture.Name
        AboutName     = [string]$about.Name
        AboutText     = ($about | Out-String -Width 4096)
    }

    # Base64 prevents Windows PowerShell 5.1 console encoding from altering
    # localized characters in the JSON returned to the parent process.
    $json = ConvertTo-Json -InputObject $result -Depth 5 -Compress
    [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))

    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 1
}
'@

            [System.IO.File]::WriteAllText(
                $Script:AboutTestProbePath,
                $probeSource,
                [System.Text.UTF8Encoding]::new($true)
            )

            $Script:AboutTestPowerShell = (Get-Process -Id $PID).Path
            #endregion
        }

        #region About files
        Context 'Localized About files' {

            It 'Declares the expected headers and sections for <CultureName>' -ForEach @(
                @{ CultureName = 'pt-BR' }
                @{ CultureName = 'en-US' }
            ) {
                $lines = $Script:AboutTestTopics[$CultureName]

                $lines.Count | Should -BeGreaterThan 4
                $lines[0] | Should -BeExactly 'TOPIC'
                $lines[1] | Should -BeExactly '    about_PipeDFe'
                $lines[2] | Should -BeExactly ''
                $lines[3] | Should -BeExactly 'SYNOPSIS'
                $Script:AboutTestSynopses[$CultureName] | Should -Not -BeNullOrEmpty

                foreach ($section in $Script:AboutTestSections) {
                    $lines | Should -Contain $section
                }
            }

            It 'Keeps About topic lines within 80 characters for <CultureName>' -ForEach @(
                @{ CultureName = 'pt-BR' }
                @{ CultureName = 'en-US' }
            ) {
                $lines = $Script:AboutTestTopics[$CultureName]

                for ($index = 0; $index -lt $lines.Count; $index++) {
                    $lines[$index].Length | Should -BeLessOrEqual 80 -Because (
                        'line {0} of the {1} About topic should fit the display width' -f
                        ($index + 1), $CultureName
                    )
                }
            }
        }
        #endregion

        #region Get-Help
        Context 'Get-Help localization' {

            BeforeAll {

                $Script:AboutTestProbeResults = @{}

                foreach ($cultureName in $Script:AboutTestCultures) {
                    $arguments = @(
                        '-NoLogo'
                        '-NoProfile'
                        '-NonInteractive'
                        '-File'
                        $Script:AboutTestProbePath
                        '-ModulePath'
                        $Script:AboutTestStagedManifest
                        '-CultureName'
                        $cultureName
                    )

                    $output = @(& $Script:AboutTestPowerShell @arguments 2>&1)

                    if ($LASTEXITCODE -ne 0) {
                        throw (
                            'Help probe failed for {0}: {1}' -f
                            $cultureName,
                            ($output -join [System.Environment]::NewLine)
                        )
                    }

                    $encoded = [string]$output[-1]
                    $decoded = [System.Text.Encoding]::UTF8.GetString(
                        [Convert]::FromBase64String($encoded)
                    )

                    $Script:AboutTestProbeResults[$cultureName] = (
                        ConvertFrom-Json -InputObject $decoded -ErrorAction Stop
                    )
                }
            }

            It 'Displays the synopsis from the <CultureName> About topic' -ForEach @(
                @{ CultureName = 'pt-BR' }
                @{ CultureName = 'en-US' }
            ) {
                $result = $Script:AboutTestProbeResults[$CultureName]
                $expectedSynopsis = $Script:AboutTestSynopses[$CultureName]
                $renderedText = ([string]$result.AboutText -replace '\s+', ' ').Trim()

                $result.Culture | Should -BeExactly $CultureName
                $result.AboutName | Should -BeExactly 'about_PipeDFe'
                $expectedSynopsis | Should -Not -BeNullOrEmpty
                $renderedText.Contains($expectedSynopsis) | Should -BeTrue -Because (
                    'Get-Help should display the synopsis from the {0} topic' -f $CultureName
                )
            }
        }
        #endregion
    }
}
