#Requires -Version 5.1

<#
.SYNOPSIS
Validates a staged PipeDFe module package before distribution.

.DESCRIPTION
Performs structural, manifest, version, and localized-help validation.

The module is imported in a separate PowerShell process for each supported
UI culture. This verifies that the staged package works independently of
development-source paths and the current PowerShell session.

The validation checks:
- Required package files and directories.
- Manifest validity and module identity.
- Package directory and manifest version alignment.
- XML well-formedness and MAML structure.
- One localized help topic for every exported function.
- Localized command help through PowerShell's Get-Help engine.
- Localized about_PipeDFe documentation.

.PARAMETER ModulePath
Directory containing the staged PipeDFe.psd1 manifest.

.EXAMPLE
PS C:\> .\tools\Test-BuildArtifact.ps1 -ModulePath '.\output\PipeDFe\0.1.0'

.EXAMPLE
PS C:\> .\tools\Test-BuildArtifact.ps1 -ModulePath '.\output\PSGallery\PipeDFe'

.NOTES
Compatible with Windows PowerShell 5.1.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost',
    '',
    Justification = 'This is a maintainer-facing artifact validation script.'
)]
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ModulePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Constants
$cultures = @('pt-BR', 'en-US')

$requiredFiles = @(
    'PipeDFe.psd1'
    'PipeDFe.psm1'
    'src/Types/PipeDFe.Types.ps1xml'
    'src/Format/PipeDFe.Format.ps1xml'
    'lib/net471/System.Data.SQLite.dll'
    'lib/netstandard2.0/System.Data.SQLite.dll'
    'lib/native/x86/e_sqlite3.dll'
    'lib/native/x64/e_sqlite3.dll'
    'pt-BR/PipeDFe-help.xml'
    'pt-BR/about_PipeDFe.help.txt'
    'en-US/PipeDFe-help.xml'
    'en-US/about_PipeDFe.help.txt'
)
#endregion

#region Helper functions
function Read-XmlDocument {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $settings = [System.Xml.XmlReaderSettings]::new()

    # Help XML must not resolve external entities or load DTDs.
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null

    $reader = $null
    $document = [System.Xml.XmlDocument]::new()

    $document.XmlResolver = $null

    try {
        $reader = [System.Xml.XmlReader]::Create($Path, $settings)
        $document.Load($reader)

        return $document
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }
}

function Get-MamlCommandTopic {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.Xml.XmlDocument]$Document
    )

    $namespaces = [System.Xml.XmlNamespaceManager]::new(
        $Document.NameTable
    )

    $namespaces.AddNamespace(
        'command',
        'http://schemas.microsoft.com/maml/dev/command/2004/10'
    )

    $namespaces.AddNamespace(
        'maml',
        'http://schemas.microsoft.com/maml/2004/10'
    )

    $topics = @(
        $Document.SelectNodes(
            '/helpItems/command:command',
            $namespaces
        )
    )

    if ($topics.Count -eq 0) {
        throw 'MAML document does not contain any command topics.'
    }

    $topicNames = @{}

    foreach ($topic in $topics) {
        $nameNode = $topic.SelectSingleNode(
            'command:details/command:name',
            $namespaces
        )

        if ($null -eq $nameNode) {
            throw 'MAML command topic is missing its command name.'
        }

        $commandName = $nameNode.InnerText.Trim()

        if ([string]::IsNullOrWhiteSpace($commandName)) {
            throw 'MAML command topic contains an empty command name.'
        }

        if ($topicNames.ContainsKey($commandName)) {
            throw "Duplicate MAML command topic: '$commandName'."
        }

        $synopsis = $topic.SelectSingleNode(
            'command:details/maml:description/maml:para',
            $namespaces
        )

        if ($null -eq $synopsis -or [string]::IsNullOrWhiteSpace($synopsis.InnerText)) {
            throw "MAML topic '$commandName' has no synopsis."
        }

        $topicNames[$commandName] = $topic
    }

    return $topicNames
}
#endregion

#region Resolve package
if (-not (Test-Path -LiteralPath $ModulePath -PathType Container)) {
    throw "Module directory not found: '$ModulePath'."
}

$moduleDirectory = (Resolve-Path -LiteralPath $ModulePath -ErrorAction Stop).Path

$manifestPath = Join-Path -Path $moduleDirectory -ChildPath 'PipeDFe.psd1'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Module manifest not found: '$manifestPath'."
}

Write-Host "Validating PipeDFe artifact: $moduleDirectory"
#endregion

#region Validate required files
foreach ($relativePath in $requiredFiles) {
    $filePath = Join-Path -Path $moduleDirectory -ChildPath $relativePath

    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "Required build artifact file is missing: '$filePath'."
    }
}
#endregion

#region Validate manifest and package version
$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath

$expectedVersion = [string]$manifest.ModuleVersion

if ([string]::IsNullOrWhiteSpace($expectedVersion)) {
    throw 'ModuleVersion must be defined in PipeDFe.psd1.'
}

try {
    $parsedVersion = [version]$expectedVersion
} catch {
    throw "Invalid ModuleVersion in PipeDFe.psd1: '$expectedVersion'."
}

$expectedVersion = $parsedVersion.ToString()

if ($manifest.RootModule -ne 'PipeDFe.psm1') {
    throw "Unexpected RootModule in manifest: '$($manifest.RootModule)'."
}

if ($manifest.ModuleVersion -ne $expectedVersion) {
    throw 'Manifest ModuleVersion is not a valid normalized version.'
}

$folderName = Split-Path -Path $moduleDirectory -Leaf

if ($folderName -cne $expectedVersion -and $folderName -cne 'PipeDFe') {
    throw (
        "Package directory '$folderName' does not match manifest version " +
        "'$expectedVersion' or the expected Gallery directory name 'PipeDFe'."
    )
}
#endregion

#region Validate localized help XML
foreach ($cultureName in $cultures) {
    $xmlPath = Join-Path -Path $moduleDirectory -ChildPath (
        '{0}/PipeDFe-help.xml' -f $cultureName
    )

    Write-Host "Validating MAML structure: $cultureName..."

    $xml = Read-XmlDocument -Path $xmlPath

    $topicNames = Get-MamlCommandTopic -Document $xml

    if ($topicNames.Count -eq 0) {
        throw "No command topics found for culture '$cultureName'."
    }

    Write-Host (
        'MAML structure valid: {0} / {1} command topics.' -f
        $cultureName, $topicNames.Count
    )
}
#endregion

#region Prepare isolated PowerShell probe
$probeSource = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $manifestPath = $env:PIPEDFE_BUILD_PROBE_MANIFEST
    $cultureName = $env:PIPEDFE_BUILD_PROBE_CULTURE

    if ([string]::IsNullOrWhiteSpace($manifestPath)) {
        throw 'Probe manifest environment variable is missing.'
    }

    if ([string]::IsNullOrWhiteSpace($cultureName)) {
        throw 'Probe culture environment variable is missing.'
    }

    $culture = [System.Globalization.CultureInfo]::GetCultureInfo(
        $cultureName
    )

    [System.Threading.Thread]::CurrentThread.CurrentCulture = $culture
    [System.Threading.Thread]::CurrentThread.CurrentUICulture = $culture

    $moduleDirectory = Split-Path -Path $manifestPath -Parent
    $moduleParent = Split-Path -Path $moduleDirectory -Parent

    # Versioned package: <root>/PipeDFe/<version>
    # Gallery package:   <root>/PSGallery/PipeDFe

    if ((Split-Path -Path $moduleDirectory -Leaf) -ceq 'PipeDFe') {
        $moduleSearchRoot = $moduleParent
    } else {
        $moduleSearchRoot = Split-Path -Path $moduleParent -Parent
    }

    if (-not (Test-Path -LiteralPath $moduleSearchRoot -PathType Container)) {
        throw "Module search root not found: '$moduleSearchRoot'."
    }

    $existingModulePaths = @(
        $env:PSModulePath -split [regex]::Escape(
            [string][System.IO.Path]::PathSeparator
        ) |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
    )

    $env:PSModulePath = @(
        $moduleSearchRoot
        $existingModulePaths
    ) -join [System.IO.Path]::PathSeparator

    # Validate the manifest independently of the importing process.
    $manifestInfo = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop

    if ($manifestInfo.Name -cne 'PipeDFe') {
        throw "Unexpected module name: '$($manifestInfo.Name)'."
    }

    $moduleData = Import-PowerShellDataFile -LiteralPath $manifestPath
    $expectedVersion = [version]$moduleData.ModuleVersion

    if ($manifestInfo.Version -ne $expectedVersion) {
        throw 'Manifest version validation failed.'
    }

    # Import only the staged manifest.
    Import-Module -Name $manifestPath -Force -ErrorAction Stop

    $module = Get-Module -Name 'PipeDFe'

    if ($null -eq $module) {
        throw 'PipeDFe module was not imported successfully.'
    }

    if ($module.Version -ne $manifestInfo.Version) {
        throw 'Imported module version differs from the packaged manifest.'
    }

    $commands = @($module.ExportedFunctions.Keys | Sort-Object -Unique)

    if ($commands.Count -eq 0) {
        throw 'The staged module does not export any functions.'
    }

    $xmlPath = Join-Path -Path $moduleDirectory -ChildPath (
        '{0}/PipeDFe-help.xml' -f $cultureName
    )

    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null

    $xml = [System.Xml.XmlDocument]::new()
    $xml.XmlResolver = $null

    $reader = $null

    try {
        $reader = [System.Xml.XmlReader]::Create($xmlPath, $settings)
        $xml.Load($reader)
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }

    $ns = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)

    $ns.AddNamespace(
        'command',
        'http://schemas.microsoft.com/maml/dev/command/2004/10'
    )

    $ns.AddNamespace(
        'maml',
        'http://schemas.microsoft.com/maml/2004/10'
    )

    $topics = @(
        $xml.SelectNodes('/helpItems/command:command', $ns)
    )

    $topicNames = @{}

    foreach ($topic in $topics) {
        $nameNode = $topic.SelectSingleNode(
            'command:details/command:name',
            $ns
        )

        if ($null -eq $nameNode) {
            throw 'MAML command topic is missing its name.'
        }

        $topicName = $nameNode.InnerText.Trim()

        if ([string]::IsNullOrWhiteSpace($topicName)) {
            throw 'MAML contains an empty command name.'
        }

        if ($topicNames.ContainsKey($topicName)) {
            throw "Duplicate MAML topic: '$topicName'."
        }

        $topicNames[$topicName] = $topic
    }

    if ($topicNames.Count -ne $commands.Count) {
        throw (
            'MAML topic count ({0}) differs from exported function count ({1}).' -f
            $topicNames.Count, $commands.Count
        )
    }

    foreach ($commandName in $commands) {
        if (-not $topicNames.ContainsKey($commandName)) {
            throw "Missing MAML topic for exported function '$commandName'."
        }

        $topic = $topicNames[$commandName]

        $synopsisNode = $topic.SelectSingleNode(
            'command:details/maml:description/maml:para',
            $ns
        )

        if ($null -eq $synopsisNode -or [string]::IsNullOrWhiteSpace($synopsisNode.InnerText)) {
            throw "Missing MAML synopsis for '$commandName'."
        }

        $help = Get-Help -Name $commandName -Full -ErrorAction Stop

        if ($null -eq $help) {
            throw "Get-Help returned no result for '$commandName'."
        }

        if ([string]::IsNullOrWhiteSpace([string]$help.Synopsis) -or
            $help.Synopsis.Trim() -cne $synopsisNode.InnerText.Trim()
        ) {
            throw (
                "Localized MAML was not loaded correctly for " +
                "'$commandName' ($cultureName)."
            )
        }
    }

    $about = Get-Help -Name 'about_PipeDFe' -ErrorAction Stop

    if ($null -eq $about -or $about.Name -cne 'about_PipeDFe' -or
        [string]::IsNullOrWhiteSpace([string]$about.Synopsis)
    ) {
        throw "Localized about_PipeDFe topic was not loaded ($cultureName)."
    }

    [Console]::Out.WriteLine(
        'PASS: {0} / {1} commands / about_PipeDFe' -f
        $cultureName, $commands.Count
    )

    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 1
}
'@
#endregion

#region Execute isolated culture probes
$probePath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath (
    'PipeDFe-BuildProbe-{0}.ps1' -f [guid]::NewGuid().ToString('N')
)

$environmentVariables = @(
    'PIPEDFE_BUILD_PROBE_MANIFEST'
    'PIPEDFE_BUILD_PROBE_CULTURE'
)

$originalEnvironment = @{}

foreach ($variableName in $environmentVariables) {
    $originalEnvironment[$variableName] = (
        [System.Environment]::GetEnvironmentVariable(
            $variableName,
            [System.EnvironmentVariableTarget]::Process
        )
    )
}

try {
    [System.IO.File]::WriteAllText(
        $probePath,
        $probeSource,
        [System.Text.UTF8Encoding]::new($true)
    )

    $powerShellExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    if ([string]::IsNullOrWhiteSpace($powerShellExe) -or -not
        (Test-Path -LiteralPath $powerShellExe -PathType Leaf)
    ) {
        throw 'Unable to determine the current PowerShell executable.'
    }

    [System.Environment]::SetEnvironmentVariable(
        'PIPEDFE_BUILD_PROBE_MANIFEST',
        $manifestPath,
        [System.EnvironmentVariableTarget]::Process
    )

    foreach ($cultureName in $cultures) {
        Write-Host "Testing PowerShell help resolution: $cultureName..."

        [System.Environment]::SetEnvironmentVariable(
            'PIPEDFE_BUILD_PROBE_CULTURE',
            $cultureName,
            [System.EnvironmentVariableTarget]::Process
        )

        $arguments = @(
            '-NoLogo'
            '-NoProfile'
            '-NonInteractive'
            '-File'
            $probePath
        )

        # Reset the native exit code before each process invocation.
        $global:LASTEXITCODE = 0

        $result = @(& $powerShellExe @arguments 2>&1)

        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            $details = $result -join [Environment]::NewLine

            throw (
                "Build probe failed for culture '{0}' (exit code {1}).{2}{3}" -f
                $cultureName,
                $exitCode,
                [Environment]::NewLine,
                $details
            )
        }

        if ($result.Count -eq 0) {
            throw "Build probe returned no output for culture '$cultureName'."
        }

        Write-Host ($result -join [Environment]::NewLine)
    }
} finally {
    foreach ($variableName in $environmentVariables) {
        [System.Environment]::SetEnvironmentVariable(
            $variableName,
            $originalEnvironment[$variableName],
            [System.EnvironmentVariableTarget]::Process
        )
    }

    if (Test-Path -LiteralPath $probePath -PathType Leaf) {
        Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
    }
}
#endregion

Write-Host ''
Write-Host 'Build artifact validation passed.'
