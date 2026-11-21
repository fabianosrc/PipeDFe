#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for PipeDFe localized PowerShell help.

.DESCRIPTION
Validates pt-BR and en-US about topics and MAML command help against the
real public module contract. Each locale is loaded in a separate PowerShell
process to prevent culture and Get-Help cache contamination.

No internal dependencies are mocked.

Coverage includes:
  - Presence and basic format of localized about topics
  - Well-formed MAML XML and unique command topics
  - Coverage of all exported functions and their declared parameters
  - Actual Get-Help loading for both UI cultures
  - Verification of localized MAML synopses, avoiding comment-help fallback
  - Verification of localized about topics
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

Describe 'PipeDFe localized help' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            #region Paths and contracts
            $Script:HelpTestRoot = (
                Get-Item -LiteralPath $PSScriptRoot
            ).Parent.Parent.Parent.Parent.FullName

            $Script:HelpTestCultures  = @('pt-BR', 'en-US')
            $Script:HelpTestDocuments = @{}

            # InModuleScope exposes private dot-sourced functions to Get-Command.
            # The module export table is the authoritative public contract.
            $Script:HelpTestCommands = @(
                (Get-Module -Name PipeDFe).ExportedFunctions.Keys |
                    Sort-Object -Unique
            )

            $Script:HelpTestCommonParameters = @(
                'Verbose', 'Debug', 'ErrorAction', 'ErrorVariable',
                'WarningAction', 'WarningVariable',
                'InformationAction', 'InformationVariable',
                'OutVariable', 'OutBuffer', 'PipelineVariable',
                'ProgressAction', 'WhatIf', 'Confirm'
            )

            $Script:HelpTestNamespaces = @{
                Command = 'http://schemas.microsoft.com/maml/dev/command/2004/10'
                Maml    = 'http://schemas.microsoft.com/maml/2004/10'
            }

            foreach ($cultureName in $Script:HelpTestCultures) {
                $xmlPath = Join-Path -Path $Script:HelpTestRoot -ChildPath (
                    'src/{0}/PipeDFe-help.xml' -f $cultureName
                )

                if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
                    throw [System.IO.FileNotFoundException]::new(
                        "Required MAML help file not found: '$xmlPath'.",
                        $xmlPath
                    )
                }

                $document = [xml](Get-Content -LiteralPath $xmlPath -Raw -Encoding UTF8)
                $namespaceManager = [System.Xml.XmlNamespaceManager]::new(
                    $document.NameTable
                )

                $namespaceManager.AddNamespace(
                    'command',
                    $Script:HelpTestNamespaces.Command
                )

                $namespaceManager.AddNamespace(
                    'maml',
                    $Script:HelpTestNamespaces.Maml
                )

                $Script:HelpTestDocuments[$cultureName] = [PSCustomObject]@{
                    Document   = $document
                    Namespaces = $namespaceManager
                }
            }
            #endregion

            #region Isolated module package
            # Source help lives in src/<culture>. Create the actual module
            # distribution layout under TestDrive without changing the project.
            $Script:HelpTestPackageRoot = Join-Path -Path $TestDrive -ChildPath 'PipeDFe'
            [void][System.IO.Directory]::CreateDirectory($Script:HelpTestPackageRoot)

            foreach ($fileName in @('PipeDFe.psd1', 'PipeDFe.psm1')) {
                $copyParams = @{
                    LiteralPath = Join-Path -Path $Script:HelpTestRoot -ChildPath $fileName
                    Destination = $Script:HelpTestPackageRoot
                    ErrorAction = 'Stop'
                }

                Copy-Item @copyParams
            }

            foreach ($directoryName in @('src', 'lib')) {
                $sourcePath = Join-Path -Path $Script:HelpTestRoot -ChildPath $directoryName

                $copyParams = @{
                    LiteralPath = $sourcePath
                    Destination = $Script:HelpTestPackageRoot
                    Recurse = $true
                    ErrorAction = 'Stop'
                }

                Copy-Item @copyParams
            }

            foreach ($cultureName in $Script:HelpTestCultures) {
                $sourcePath = Join-Path -Path $Script:HelpTestRoot -ChildPath (
                    'src/{0}' -f $cultureName
                )

                $destinationPath = Join-Path -Path $Script:HelpTestPackageRoot -ChildPath $cultureName

                $copyParams = @{
                    LiteralPath = $sourcePath
                    Destination = $destinationPath
                    Recurse = $true
                    ErrorAction = 'Stop'
                }

                Copy-Item @copyParams
            }

            $helpTestJoinPathParams = @{
                Path        = $Script:HelpTestPackageRoot
                ChildPath   = 'PipeDFe.psd1'
            }

            $Script:HelpTestStagedManifest = Join-Path @helpTestJoinPathParams
            #endregion

            #region Locale probe
            $Script:HelpTestProbePath = Join-Path -Path $TestDrive -ChildPath (
                'Invoke-PipeDFeHelpProbe.ps1'
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

    $commands = @(
        Get-Command -Module PipeDFe -CommandType Function |
            Select-Object -ExpandProperty Name |
            Sort-Object -Unique
    )

    $commandResults = @(
        foreach ($commandName in $commands) {
            $help = Get-Help -Name $commandName -Full -ErrorAction Stop

            [PSCustomObject]@{
                Name     = $commandName
                Synopsis = [string]$help.Synopsis
            }
        }
    )

    $about = Get-Help -Name 'about_PipeDFe' -ErrorAction Stop

    $result = [PSCustomObject]@{
        Culture       = [System.Threading.Thread]::CurrentThread.CurrentUICulture.Name
        Commands      = $commandResults
        AboutName     = [string]$about.Name
        AboutSynopsis = [string]$about.Synopsis
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
                $Script:HelpTestProbePath,
                $probeSource,
                [System.Text.UTF8Encoding]::new($true)
            )

            $Script:HelpTestPowerShell = (Get-Process -Id $PID).Path
            #endregion
        }

        #region Help file structure
        Context 'Localized help files' {

            It 'Provides a MAML file for <CultureName>' -ForEach @(
                @{ CultureName = 'pt-BR' }
                @{ CultureName = 'en-US' }
            ) {
                $path = Join-Path -Path $Script:HelpTestRoot -ChildPath (
                    'src/{0}/PipeDFe-help.xml' -f $CultureName
                )

                Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
            }

            It 'Provides an about topic for <CultureName>' -ForEach @(
                @{ CultureName = 'pt-BR' }
                @{ CultureName = 'en-US' }
            ) {
                $path = Join-Path -Path $Script:HelpTestRoot -ChildPath (
                    'src/{0}/about_PipeDFe.help.txt' -f $CultureName
                )

                Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
            }

            It 'Declares the expected about topic sections for <CultureName>' -ForEach @(
                @{ CultureName = 'pt-BR' }
                @{ CultureName = 'en-US' }
            ) {
                $path = Join-Path -Path $Script:HelpTestRoot -ChildPath (
                    'src/{0}/about_PipeDFe.help.txt' -f $CultureName
                )

                $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8

                $content | Should -Match '(?m)^TOPIC\s*$'
                $content | Should -Match '(?m)^\s+about_PipeDFe\s*$'
                $content | Should -Match '(?m)^SYNOPSIS\s*$'
                $content | Should -Match '(?m)^LONG DESCRIPTION\s*$'
            }
        }
        #endregion

        #region MAML contract
        Context 'MAML command documentation' {

            It 'Documents every exported function exactly once in <CultureName>' -ForEach @(
                @{ CultureName = 'pt-BR' }
                @{ CultureName = 'en-US' }
            ) {
                $helpSet = $Script:HelpTestDocuments[$CultureName]

                $names = @(
                    $helpSet.Document.SelectNodes(
                        '/helpItems/command:command/command:details/command:name',
                        $helpSet.Namespaces
                    ) | ForEach-Object { $_.InnerText }
                )

                $names | Should -HaveCount $Script:HelpTestCommands.Count
                @($names | Sort-Object -Unique) | Should -HaveCount $names.Count

                foreach ($commandName in $Script:HelpTestCommands) {
                    $names | Should -Contain $commandName
                }
            }

            It 'Matches the public parameter contract in <CultureName>' -ForEach @(
                @{ CultureName = 'pt-BR' }
                @{ CultureName = 'en-US' }
            ) {
                $helpSet = $Script:HelpTestDocuments[$CultureName]

                foreach ($commandName in $Script:HelpTestCommands) {
                    $topic = $helpSet.Document.SelectSingleNode(
                        "/helpItems/command:command[command:details/command:name='$commandName']",
                        $helpSet.Namespaces
                    )

                    $topic | Should -Not -BeNullOrEmpty

                    $documented = @(
                        $topic.SelectNodes(
                            'command:parameters/command:parameter/maml:name',
                            $helpSet.Namespaces
                        ) | ForEach-Object { $_.InnerText } |
                            Sort-Object -Unique
                    )

                    $actual = @(
                        (Get-Command -Name $commandName -Module PipeDFe).Parameters.Keys |
                            Where-Object {
                                $_ -notin $Script:HelpTestCommonParameters
                            } |
                            Sort-Object -Unique
                    )

                    $documented | Should -HaveCount $actual.Count

                    foreach ($parameterName in $actual) {
                        $documented | Should -Contain $parameterName
                    }
                }
            }
        }
        #endregion

        #region Real PowerShell help loading
        Context 'Get-Help localization' {

            BeforeAll {
                $Script:HelpTestProbeResults = @{}

                foreach ($cultureName in $Script:HelpTestCultures) {
                    $arguments = @(
                        '-NoLogo'
                        '-NoProfile'
                        '-NonInteractive'
                        '-File'
                        $Script:HelpTestProbePath
                        '-ModulePath'
                        $Script:HelpTestStagedManifest
                        '-CultureName'
                        $cultureName
                    )

                    $output = @(
                        & $Script:HelpTestPowerShell @arguments 2>&1
                    )

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

                    $Script:HelpTestProbeResults[$cultureName] = (
                        ConvertFrom-Json -InputObject $decoded -ErrorAction Stop
                    )
                }
            }

            It 'Uses the expected UI culture for <CultureName>' -ForEach @(
                @{ CultureName = 'pt-BR' }
                @{ CultureName = 'en-US' }
            ) {
                $Script:HelpTestProbeResults[$CultureName].Culture |
                    Should -BeExactly $CultureName
            }

            It 'Loads the about_PipeDFe topic in <CultureName>' -ForEach @(
                @{ CultureName = 'pt-BR' }
                @{ CultureName = 'en-US' }
            ) {
                $result = $Script:HelpTestProbeResults[$CultureName]

                $result.AboutName | Should -BeExactly 'about_PipeDFe'
                $result.AboutSynopsis | Should -Not -BeNullOrEmpty
            }

            It 'Loads the localized MAML synopsis for each command in <CultureName>' -ForEach @(
                @{ CultureName = 'pt-BR' }
                @{ CultureName = 'en-US' }
            ) {
                $helpSet = $Script:HelpTestDocuments[$CultureName]

                foreach ($entry in $Script:HelpTestProbeResults[$CultureName].Commands) {
                    $commandName = [string]$entry.Name

                    $topic = $helpSet.Document.SelectSingleNode(
                        "/helpItems/command:command[command:details/command:name='$commandName']",
                        $helpSet.Namespaces
                    )

                    $synopsis = $topic.SelectSingleNode(
                        'command:details/maml:description/maml:para',
                        $helpSet.Namespaces
                    )

                    $synopsis | Should -Not -BeNullOrEmpty
                    $entry.Synopsis.Trim() | Should -BeExactly $synopsis.InnerText.Trim()
                }
            }
        }
        #endregion
    }
}
