#Requires -Version 5.1

<#
.SYNOPSIS
Builds the PipeDFe module, optionally running lint, tests, and publishing
to the PowerShell Gallery.

.DESCRIPTION
Orchestrates the full release pipeline in order:

    1. Lint    - PSScriptAnalyzer (skippable with -SkipLint)
    2. Test    - Pester with coverage (skippable with -SkipTests)
    3. Build   - copies source into output/PipeDFe/<version>/
    4. Publish - Publish-Module to PSGallery (opt-in with -Publish)

The output artifact is a self-contained module directory ready for
installation or gallery upload. A SHA-256 manifest (hashes.json) is
written alongside the module files so consumers can verify integrity.

Exit codes:
    0 - build succeeded
    1 - lint or test step failed (pipeline aborted)

.PARAMETER SkipTests
Skips the Pester test run.

.PARAMETER SkipLint
Skips PSScriptAnalyzer.

.PARAMETER Publish
Publishes the built module to the PowerShell Gallery.
Requires the PSGALLERY_API_KEY environment variable.

.PARAMETER NoCoverage
When tests run, skips code-coverage collection (faster for local iteration).

.EXAMPLE
PS C:\> .\tools\Invoke-Build.ps1

.EXAMPLE
PS C:\> .\tools\Invoke-Build.ps1 -SkipTests

.EXAMPLE
PS C:\> .\tools\Invoke-Build.ps1 -Publish
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param (
    [Parameter()]
    [switch]$SkipTests,

    [Parameter()]
    [switch]$SkipLint,

    [Parameter()]
    [switch]$Publish,

    [Parameter()]
    [switch]$NoCoverage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Paths
$root         = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')
$outputPath   = Join-Path -Path $root -ChildPath 'output'
$tools        = Join-Path -Path $root -ChildPath 'tools'
$manifestPath = Join-Path -Path $root -ChildPath 'PipeDFe.psd1'
#endregion

#region Helpers
function Write-Step {
    param (
        [string]$Index,
        [string]$Total,
        [string]$Label
    )
    Write-Host ''
    Write-Host "  [$Index/$Total] $Label" -ForegroundColor Cyan
    Write-Host ''
}

function Write-StepSkipped {
    param (
        [string]$Index,
        [string]$Total,
        [string]$Label
    )
    Write-Host ''
    Write-Host "  [$Index/$Total] $Label - skipped" -ForegroundColor DarkGray
}
#endregion

#region Banner
$moduleData = Import-PowerShellDataFile -Path $manifestPath
$version    = $moduleData.ModuleVersion

Write-Host ''
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
Write-Host "  PipeDFe - Build Pipeline  v$version" -ForegroundColor Cyan
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray

$totalSteps = 3 + [int]$Publish.IsPresent
$step       = 0
#endregion

#region Step 1: Lint
$step++
if ($SkipLint) {
    Write-StepSkipped -Index $step -Total $totalSteps -Label 'Lint'
} else {
    Write-Step -Index $step -Total $totalSteps -Label 'Lint (PSScriptAnalyzer)'
    & (Join-Path -Path $tools -ChildPath 'Invoke-Lint.ps1') -Strict
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host '  [ABORTED] Lint step failed. Fix errors before building.' -ForegroundColor Red
        Write-Host ''
        exit 1
    }
}
#endregion

#region Step 2: Test
$step++
if ($SkipTests) {
    Write-StepSkipped -Index $step -Total $totalSteps -Label 'Tests'
} else {
    Write-Step -Index $step -Total $totalSteps -Label 'Tests (Pester)'
    $testArgs = @()
    if (-not $NoCoverage) { $testArgs += '-Coverage' }
    & (Join-Path -Path $tools -ChildPath 'Invoke-Tests.ps1') @testArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host '  [ABORTED] Test step failed. All tests must pass before building.' -ForegroundColor Red
        Write-Host ''
        exit 1
    }
}
#endregion

#region Step 3: Build
$step++
Write-Step -Index $step -Total $totalSteps -Label 'Build'

$dest = Join-Path -Path $outputPath -ChildPath "PipeDFe\$version"

if (Test-Path -LiteralPath $dest) {
    Remove-Item -LiteralPath $dest -Recurse -Force
}

New-Item -ItemType Directory -Path $dest | Out-Null

# Directories to copy into the artifact
foreach ($dir in @('src', 'lib', 'templates')) {
    $src = Join-Path -Path $root -ChildPath $dir
    if (Test-Path -LiteralPath $src -PathType Container) {
        Copy-Item -Path $src -Destination (Join-Path -Path $dest -ChildPath $dir) -Recurse
    }
}

# Root-level files
foreach ($file in @('PipeDFe.psd1', 'PipeDFe.psm1', 'LICENSE', 'CHANGELOG.md')) {
    $src = Join-Path -Path $root -ChildPath $file
    if (Test-Path -LiteralPath $src -PathType Leaf) {
        Copy-Item -Path $src -Destination $dest
    }
}

# Write integrity manifest (SHA-256 of every file in artifact)
$hashes = Get-ChildItem -Path $dest -Recurse -File | ForEach-Object {
    $rel  = $_.FullName.Substring($dest.Length + 1) -replace '\\', '/'
    $hash = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash
    [ordered]@{ file = $rel; sha256 = $hash }
}

[ordered]@{
    module  = 'PipeDFe'
    version = $version
    builtAt = (Get-Date -Format 'o')
    files   = $hashes
} | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path -Path $dest -ChildPath 'hashes.json') -Encoding UTF8

Write-Host "  Output  : $dest" -ForegroundColor Green
Write-Host "  Files   : $($hashes.Count) (hashes.json written)" -ForegroundColor Gray
#endregion

#region Step 4: Publish
if ($Publish) {
    $step++
    Write-Step -Index $step -Total $totalSteps -Label 'Publish (PowerShell Gallery)'

    $apiKey = $env:PSGALLERY_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-Host '  [ABORTED] PSGALLERY_API_KEY environment variable is not set.' -ForegroundColor Red
        exit 1
    }

    Publish-Module -Path $dest -NuGetApiKey $apiKey
    Write-Host "  Published PipeDFe v$version to PowerShell Gallery." -ForegroundColor Green
}
#endregion

#region Footer
Write-Host ''
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
Write-Host "  Build complete - PipeDFe v$version" -ForegroundColor Green
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
Write-Host ''
#endregion
