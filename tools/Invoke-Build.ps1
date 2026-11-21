#Requires -Version 5.1

<#
.SYNOPSIS
Builds, validates, and optionally publishes the PipeDFe module.

.DESCRIPTION
Runs PSScriptAnalyzer and Pester by default, stages the versioned module
under output/PipeDFe/<ModuleVersion>, installs localized help into the
module root, validates the staged artifact, and generates a SHA-256
integrity inventory.

A separate module-name directory is created under output/PSGallery/PipeDFe
for PowerShellGet compatibility.

Publishing is explicitly opt-in and requires all verification stages
to complete successfully.

.PARAMETER SkipTests
Skips Pester tests. Intended for local development only.

.PARAMETER SkipLint
Skips PSScriptAnalyzer. Intended for local development only.

.PARAMETER NoCoverage
Disables coverage collection when Pester is executed.

.PARAMETER ArtifactRoot
Optional output directory for build artifacts.
Defaults to the project's output directory.

.PARAMETER Publish
Explicitly publishes the validated module to the PowerShell Gallery.
Requires PSGALLERY_API_KEY and release approval.

.EXAMPLE
PS C:\> .\tools\Invoke-Build.ps1

.EXAMPLE
PS C:\> .\tools\Invoke-Build.ps1 -SkipLint -SkipTests

.EXAMPLE
PS C:\> .\tools\Invoke-Build.ps1 -ArtifactRoot C:\BuildArtifacts

.NOTES
Compatible with Windows PowerShell 5.1.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost',
    '',
    Justification = 'This is a maintainer-facing build script.'
)]
[CmdletBinding()]
param (
    [Parameter()]
    [switch]$SkipTests,

    [Parameter()]
    [switch]$SkipLint,

    [Parameter()]
    [switch]$Publish,

    [Parameter()]
    [switch]$NoCoverage,

    [Parameter()]
    [string]$ArtifactRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helper functions
function ConvertTo-NormalizedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)

    $separators = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )

    if ($fullPath.Length -gt $pathRoot.Length) {
        return $fullPath.TrimEnd($separators)
    }

    return $fullPath
}

function Test-PathOverlap {
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Directory
    )

    $comparison = [System.StringComparison]::OrdinalIgnoreCase

    if ($Path.Equals($Directory, $comparison)) {
        return $true
    }

    $separators = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )

    $directoryPrefix = '{0}{1}' -f (
        $Directory.TrimEnd($separators)
    ), [System.IO.Path]::DirectorySeparatorChar

    return $Path.StartsWith($directoryPrefix, $comparison)
}

function Assert-SafeBuildDestination {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ArtifactRoot
    )

    if (-not (Test-PathOverlap -Path $Path -Directory $ArtifactRoot)) {
        throw "Build destination is outside ArtifactRoot: '$Path'."
    }

    if ($Path.Equals($ArtifactRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Build destination cannot be ArtifactRoot itself: '$Path'."
    }
}

function Assert-NoReparsePointOnPath {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    # Check each existing ancestor, not just the destination. A junction in
    # ArtifactRoot can otherwise redirect recursive deletion outside the build.
    $current = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($current)

    while ($true) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue

        if ($null -ne $item -and
            ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "Build path contains a symbolic link or junction: '$current'."
        }

        if ($current.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        $parent = [System.IO.Path]::GetDirectoryName($current)

        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }

        $current = $parent
    }
}

function Assert-NoReparsePointsInTree {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    Assert-NoReparsePointOnPath -Path $Path

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    # Traverse only real directories. Never follow a reparse point, including
    # one nested inside an older build artifact.
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push([System.IO.Path]::GetFullPath($Path))

    while ($pending.Count -gt 0) {
        $current = $pending.Pop()

        foreach ($entryPath in [System.IO.Directory]::EnumerateFileSystemEntries($current)) {
            $entry = Get-Item -LiteralPath $entryPath -Force -ErrorAction Stop

            if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "Build artifact contains a symbolic link or junction: '$entryPath'."
            }

            if ($entry.PSIsContainer) {
                $pending.Push($entry.FullName)
            }
        }
    }
}

function Invoke-BuildScript {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        [hashtable]$Arguments = @{},

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FailureMessage
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Build script not found: '$Path'."
    }

    # Prevent a previous native command's exit code from affecting this run.
    $global:LASTEXITCODE = 0

    & $Path @Arguments

    if ($global:LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}
#endregion

#region Validate build configuration
# Publishing must always include every verification stage.
if ($Publish -and ($SkipLint -or $SkipTests -or $NoCoverage)) {
    throw 'Publishing requires lint, tests, and coverage. Remove skip switches.'
}

if ($Publish -and [string]::IsNullOrWhiteSpace($env:PSGALLERY_API_KEY)) {
    throw 'PSGALLERY_API_KEY must be set before publishing.'
}
#endregion

#region Paths and version
$root = (
    Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')
).Path

$root = ConvertTo-NormalizedPath -Path $root

$outputPath = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    Join-Path -Path $root -ChildPath 'output'
} else {
    [System.IO.Path]::GetFullPath($ArtifactRoot)
}

$outputPath = ConvertTo-NormalizedPath -Path $outputPath

$allowedOutput = ConvertTo-NormalizedPath -Path (
    Join-Path -Path $root -ChildPath 'output'
)

# The default output directory is the only permitted exception.
$isDefaultOutput = $outputPath.Equals(
    $allowedOutput,
    [System.StringComparison]::OrdinalIgnoreCase
)

if (-not $isDefaultOutput -and (
        (Test-PathOverlap -Path $outputPath -Directory $root) -or
        (Test-PathOverlap -Path $root -Directory $outputPath)
    )
) {
    throw 'ArtifactRoot must be outside the source tree or use the default output directory.'
}

$manifestPath = Join-Path -Path $root -ChildPath 'PipeDFe.psd1'

$moduleData = Import-PowerShellDataFile -LiteralPath $manifestPath
$version = [string]$moduleData.ModuleVersion

if ([string]::IsNullOrWhiteSpace($version)) {
    throw 'ModuleVersion must be defined in PipeDFe.psd1.'
}

$packageRoot = Join-Path -Path $outputPath -ChildPath 'PipeDFe'
$destination = Join-Path -Path $packageRoot -ChildPath $version

$galleryRoot = Join-Path -Path $outputPath -ChildPath 'PSGallery'
$galleryDestination = Join-Path -Path $galleryRoot -ChildPath 'PipeDFe'

# Validate all destinations before performing destructive operations.
# Reparse-point checks also cover existing parent directories of ArtifactRoot.
Assert-NoReparsePointOnPath -Path $outputPath
Assert-NoReparsePointOnPath -Path $packageRoot
Assert-NoReparsePointOnPath -Path $destination
Assert-NoReparsePointOnPath -Path $galleryRoot
Assert-NoReparsePointOnPath -Path $galleryDestination

Assert-SafeBuildDestination -Path $packageRoot        -ArtifactRoot $outputPath
Assert-SafeBuildDestination -Path $destination        -ArtifactRoot $outputPath
Assert-SafeBuildDestination -Path $galleryRoot        -ArtifactRoot $outputPath
Assert-SafeBuildDestination -Path $galleryDestination -ArtifactRoot $outputPath
#endregion

#region Validate source manifest
$requiredFiles = @('PipeDFe.psd1', 'PipeDFe.psm1', 'LICENSE')

foreach ($fileName in $requiredFiles) {
    $sourceFile = Join-Path -Path $root -ChildPath $fileName

    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
        throw "Required module file not found: '$sourceFile'."
    }
}

$requiredDirectories = @('src', 'lib')

foreach ($directory in $requiredDirectories) {
    $sourceDirectory = Join-Path -Path $root -ChildPath $directory

    if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
        throw "Required module directory not found: '$sourceDirectory'."
    }
}

$cultures = @('pt-BR', 'en-US')

$helpFiles = @('PipeDFe-help.xml', 'about_PipeDFe.help.txt')

foreach ($cultureName in $cultures) {
    foreach ($helpName in $helpFiles) {
        $sourceHelp = Join-Path -Path $root -ChildPath (
            'src/{0}/{1}' -f $cultureName, $helpName
        )

        if (-not (Test-Path -LiteralPath $sourceHelp -PathType Leaf)) {
            throw "Required localized help file not found: '$sourceHelp'."
        }
    }
}
#endregion

#region Lint and tests
if ($SkipLint) {
    Write-Warning -Message 'Lint is being skipped. Do not publish an unverified release.'
} else {
    Write-Host 'Running PSScriptAnalyzer...'

    $lintScript = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-Lint.ps1'

    $buildParams = @{
        Path           = $lintScript
        Arguments      = @{ Strict = $true }
        FailureMessage = 'Lint failed. Module build aborted.'
    }

    Invoke-BuildScript @buildParams
}

if ($SkipTests) {
    Write-Warning -Message 'Pester tests are being skipped. Do not publish an unverified release.'
} else {
    Write-Host 'Running Pester tests...'

    $testScript = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-Tests.ps1'

    $testParams = @{}

    if (-not $NoCoverage) {
        $testParams['Coverage'] = $true
        $testParams['CoverageTarget'] = 80
    }

    $buildParams = @{
        Path           = $testScript
        Arguments      = $testParams
        FailureMessage = 'Pester tests failed. Module build aborted.'
    }

    Invoke-BuildScript @buildParams
}
#endregion

#region Stage module
Write-Host "Staging PipeDFe $version..."

Assert-NoReparsePointsInTree -Path $destination

if (Test-Path -LiteralPath $destination) {
    Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction Stop
}

[void][System.IO.Directory]::CreateDirectory($destination)

$directoriesToCopy = @('src', 'lib', 'templates')

foreach ($directory in $directoriesToCopy) {
    $sourceDirectory = Join-Path -Path $root -ChildPath $directory

    if (Test-Path -LiteralPath $sourceDirectory -PathType Container) {
        Assert-NoReparsePointsInTree -Path $sourceDirectory

        $copyParams = @{
            LiteralPath = $sourceDirectory
            Destination = $destination
            Recurse     = $true
            Force       = $true
            ErrorAction = 'Stop'
        }

        Copy-Item @copyParams
    }
}

$filesToCopy = @(
    'PipeDFe.psd1'
    'PipeDFe.psm1'
    'LICENSE'
    'README.md'
    'CHANGELOG.md'
    'RELEASE.md'
)

foreach ($fileName in $filesToCopy) {
    $sourceFile = Join-Path -Path $root -ChildPath $fileName

    if (Test-Path -LiteralPath $sourceFile -PathType Leaf) {
        $copyParams = @{
            LiteralPath = $sourceFile
            Destination = $destination
            Force       = $true
            ErrorAction = 'Stop'
        }

        Assert-NoReparsePointOnPath -Path $sourceFile
        Copy-Item @copyParams
    }
}

# Keep src/<culture> as the source of truth.
# PowerShell's help engine expects localized help in the module root.
foreach ($cultureName in $cultures) {
    $sourceCulture = Join-Path -Path $root -ChildPath ('src/{0}' -f $cultureName)

    $destinationCulture = Join-Path -Path $destination -ChildPath $cultureName

    $copyParams = @{
        LiteralPath = $sourceCulture
        Destination = $destinationCulture
        Recurse     = $true
        Force       = $true
        ErrorAction = 'Stop'
    }

    Copy-Item @copyParams
}
#endregion

# Disallow linked content originating from source directories as well.
Assert-NoReparsePointsInTree -Path $destination

#region Verify staged artifact
$verifyScript = Join-Path -Path $PSScriptRoot -ChildPath 'Test-BuildArtifact.ps1'

$verifyParams = @{
    ModulePath = $destination
    ErrorAction = 'Stop'
}

Write-Host 'Validating the staged module in isolated PowerShell processes...'

$buildScriptStagingArtifactParams = @{
    Path           = $verifyScript
    Arguments      = $verifyParams
    FailureMessage = 'Staged module validation failed. Build aborted.'
}

Invoke-BuildScript @buildScriptStagingArtifactParams
#endregion

#region Integrity inventory
# The inventory intentionally excludes itself.
# It is generated last to avoid recursive hashing.
$hashes = @(
    Get-ChildItem -LiteralPath $destination -Recurse -File -Force |
        Sort-Object FullName |
        ForEach-Object {
            $relativePath = $_.FullName.Substring(
                $destination.Length + 1
            ) -replace '\\', '/'

            [ordered]@{
                file   = $relativePath
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        }
)

$integrityData = [ordered]@{
    module  = 'PipeDFe'
    version = $version
    builtAt = [System.DateTimeOffset]::UtcNow.ToString('o')
    files   = $hashes
}

$integrityPath = Join-Path -Path $destination -ChildPath 'hashes.json'

$integrityJson = ConvertTo-Json -InputObject $integrityData -Depth 5

[System.IO.File]::WriteAllText(
    $integrityPath,
    $integrityJson,
    [System.Text.UTF8Encoding]::new($false)
)
#endregion

#region PowerShell Gallery staging
# PowerShellGet requires a directory named after the module.
# Preserve the versioned installation artifact and create a separate copy.
Assert-NoReparsePointsInTree -Path $galleryDestination

if (Test-Path -LiteralPath $galleryDestination) {
    Remove-Item -LiteralPath $galleryDestination -Recurse -Force -ErrorAction Stop
}

[void][System.IO.Directory]::CreateDirectory($galleryDestination)

# Enumerating explicitly avoids wildcard interpretation of source paths
# and includes hidden files and directories.
Get-ChildItem -LiteralPath $destination -Force |
    ForEach-Object {
        $copyItemStagingParams = @{
            LiteralPath = $_.FullName
            Destination = $galleryDestination
            Recurse     = $true
            Force       = $true
            ErrorAction = 'Stop'
        }

        Copy-Item @copyItemStagingParams
    }

Assert-NoReparsePointsInTree -Path $galleryDestination

$buildScriptStagingParams = @{
    Path           = $verifyScript
    Arguments      = @{ ModulePath  = $galleryDestination; ErrorAction = 'Stop' }
    FailureMessage = 'Gallery staging validation failed. Build aborted.'
}

Invoke-BuildScript @buildScriptStagingParams

#endregion

#region Optional publication
if ($Publish) {
    $publishCommand = Get-Command -Name Publish-Module -ErrorAction SilentlyContinue

    if ($null -eq $publishCommand) {
        throw 'Publish-Module (PowerShellGet) is not available.'
    }

    $publishParams = @{
        Path        = $galleryDestination
        Repository  = 'PSGallery'
        NuGetApiKey = $env:PSGALLERY_API_KEY
        ErrorAction = 'Stop'
    }

    Publish-Module @publishParams

    Write-Host "Published PipeDFe $version to the PowerShell Gallery."
}
#endregion

Write-Host ''
Write-Host 'Build completed successfully.'
Write-Host "Validated module artifact: $destination"
Write-Host "Gallery staging directory: $galleryDestination"
Write-Host "Integrity inventory: $integrityPath"
