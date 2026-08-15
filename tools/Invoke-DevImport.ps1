#Requires -Version 5.1

<#
.SYNOPSIS
Imports the PipeDFe module in development mode.

.DESCRIPTION
Forces a clean re-import of PipeDFe from the local source tree.
Removes any previously loaded instance, validates the manifest, and
imports the module. Optionally suppresses verbose output and skips
PSScriptAnalyzer.

Exit codes:
    0 - module imported successfully
    1 - import failed

.PARAMETER Quiet
Suppresses verbose output during import.

.PARAMETER SkipLint
Skips the PSScriptAnalyzer check after import.

.EXAMPLE
PS C:\> .\tools\Invoke-DevImport.ps1

.EXAMPLE
PS C:\> .\tools\Invoke-DevImport.ps1 -Quiet

.EXAMPLE
PS C:\> .\tools\Invoke-DevImport.ps1 -Quiet -SkipLint
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param (
    [Parameter()]
    [switch]$Quiet,

    [Parameter()]
    [switch]$SkipLint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Paths
$moduleName   = 'PipeDFe'
$moduleRoot   = Split-Path -Path $PSScriptRoot -Parent
$manifestPath = Join-Path -Path $moduleRoot -ChildPath "$moduleName.psd1"
#endregion

#region Banner
Write-Host ''
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
Write-Host '  PipeDFe - Dev Import' -ForegroundColor Cyan
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
Write-Host ''
#endregion

#region Validate manifest
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Write-Host "  [ERROR] Manifest not found: $manifestPath" -ForegroundColor Red
    exit 1
}
#endregion

#region Remove previously loaded module
$loaded = Get-Module -Name $moduleName -ErrorAction SilentlyContinue
if ($loaded) {
    Write-Host "  Removing loaded module: v$($loaded.Version)" -ForegroundColor Yellow
    Remove-Module -Name $moduleName -Force
}
#endregion

#region Import
Write-Host "  Importing from: $manifestPath" -ForegroundColor Gray
Write-Host ''

try {
    if ($Quiet) {
        Import-Module -Name $manifestPath -Force
    } else {
        Import-Module -Name $manifestPath -Force -Verbose
    }
} catch {
    Write-Host ''
    Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    exit 1
}
#endregion

#region Summary
$module = Get-Module -Name $moduleName -ErrorAction SilentlyContinue

if (-not $module) {
    Write-Host "  [ERROR] Module was not loaded after import." -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
Write-Host "  Module   : $($module.Name) v$($module.Version)" -ForegroundColor Green
Write-Host "  Commands : $($module.ExportedCommands.Count) exported" -ForegroundColor Green
Write-Host "  Path     : $($module.Path)" -ForegroundColor Gray
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
Write-Host ''

$module.ExportedCommands.Keys | Sort-Object | ForEach-Object {
    Write-Host "    $_" -ForegroundColor DarkCyan
}

Write-Host ''
#endregion

#region Lint
if (-not $SkipLint) {
    $analyzer = Get-Module -Name PSScriptAnalyzer -ListAvailable -ErrorAction SilentlyContinue

    if (-not $analyzer) {
        Write-Host '  PSScriptAnalyzer not installed - skipping lint.' -ForegroundColor DarkGray
        Write-Host '  Install with: Install-Module PSScriptAnalyzer -Scope CurrentUser' -ForegroundColor DarkGray
        Write-Host ''
        exit 0
    }

    Write-Host '  Running PSScriptAnalyzer...' -ForegroundColor Gray
    Write-Host ''

    $settingsPath   = Join-Path -Path $moduleRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'
    $analyzerParams = @{
        Path     = Join-Path -Path $moduleRoot -ChildPath 'src'
        Recurse  = $true
        Severity = @('Error', 'Warning')
    }

    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        $analyzerParams['Settings'] = $settingsPath
    }

    $lintResults = @(Invoke-ScriptAnalyzer @analyzerParams)

    if ($lintResults.Count -eq 0) {
        Write-Host '  PSScriptAnalyzer : no issues found.' -ForegroundColor Green
    } else {
        Write-Host "  PSScriptAnalyzer : $($lintResults.Count) issue(s) found." -ForegroundColor Yellow
        Write-Host ''
        $lintResults |
            Sort-Object Severity, ScriptName, Line |
            Format-Table -AutoSize -Property Severity, RuleName, ScriptName, Line, Message
    }

    Write-Host ''
}
#endregion
