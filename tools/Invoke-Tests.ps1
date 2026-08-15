#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Runs the PipeDFe test suite using Pester 5.

.DESCRIPTION
Discovers and executes all Pester tests under the tests/ directory.
Optionally collects code coverage and writes a JaCoCo-compatible XML
report to output/coverage/ for use in CI pipelines (GitHub Actions,
Azure DevOps, etc.).

Exit codes:
    0 - all tests passed
    1 - one or more tests failed
    2 - test discovery returned no tests

.PARAMETER Coverage
Enables code coverage collection. Instruments all .ps1 files under src/.
Writes a JaCoCo XML report to output/coverage/coverage.xml.

.PARAMETER OutputFormat
Format for the test-results XML. Accepted values: NUnitXml, JUnitXml.
Defaults to NUnitXml (compatible with most CI systems).

.PARAMETER TestPath
Path to the test root. Defaults to <repo-root>/tests.

.PARAMETER Tag
Runs only tests with the specified Pester tag(s).

.PARAMETER ExcludeTag
Excludes tests with the specified Pester tag(s).

.PARAMETER PassThru
Returns the Pester result object to the caller instead of exiting.

.EXAMPLE
PS C:\> .\tools\Invoke-Tests.ps1

.EXAMPLE
PS C:\> .\tools\Invoke-Tests.ps1 -Coverage

.EXAMPLE
PS C:\> .\tools\Invoke-Tests.ps1 -Coverage -Tag Unit

.EXAMPLE
PS C:\> .\tools\Invoke-Tests.ps1 -PassThru | Select-Object -ExpandProperty FailedCount

.OUTPUTS
[Pester.Run] Only when -PassThru is specified.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param (
    [Parameter()]
    [switch]$Coverage,

    [Parameter()]
    [ValidateSet('NUnitXml', 'JUnitXml')]
    [string]$OutputFormat = 'NUnitXml',

    [Parameter()]
    [string]$TestPath,

    [Parameter()]
    [string[]]$Tag = @(),

    [Parameter()]
    [string[]]$ExcludeTag = @(),

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Resolve paths
$root             = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')
$srcPath          = Join-Path -Path $root -ChildPath 'src'
$outputPath       = Join-Path -Path $root -ChildPath 'output'
$resultsDir       = Join-Path -Path $outputPath -ChildPath 'test-results'
$coverageDir      = Join-Path -Path $outputPath -ChildPath 'coverage'
$resolvedTestPath = if ($PSBoundParameters.ContainsKey('TestPath')) {
    $TestPath
} else {
    Join-Path -Path $root -ChildPath 'tests'
}

if (-not (Test-Path -LiteralPath $resolvedTestPath -PathType Container)) {
    Write-Error "Test directory not found: $resolvedTestPath"
    exit 2
}

foreach ($dir in $resultsDir, $coverageDir) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
}
#endregion

#region Banner
$pesterVersion = (
    Get-Module -Name Pester -ListAvailable |
        Sort-Object Version -Descending |
        Select-Object -First 1
).Version

Write-Host ''
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
Write-Host "  PipeDFe - Test Runner  (Pester $pesterVersion)" -ForegroundColor Cyan
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
Write-Host ''
#endregion

#region Pester configuration
$config = New-PesterConfiguration

$config.Run.Path                = $resolvedTestPath
$config.Run.PassThru            = $true
$config.Output.Verbosity        = 'Detailed'
$config.TestResult.Enabled      = $true
$config.TestResult.OutputPath   = Join-Path -Path $resultsDir -ChildPath "TestResults.$OutputFormat.xml"
$config.TestResult.OutputFormat = $OutputFormat

if ($Tag.Count -gt 0) {
    $config.Filter.Tag = $Tag
}
if ($ExcludeTag.Count -gt 0) {
    $config.Filter.ExcludeTag = $ExcludeTag
}

if ($Coverage) {
    $coveredFiles = Get-ChildItem -Path $srcPath -Filter '*.ps1' -Recurse |
        Select-Object -ExpandProperty FullName

    if ($coveredFiles.Count -eq 0) {
        Write-Warning "No .ps1 files found under '$srcPath' - coverage will be empty."
    }

    $config.CodeCoverage.Enabled               = $true
    $config.CodeCoverage.Path                  = $coveredFiles
    $config.CodeCoverage.OutputPath            = Join-Path -Path $coverageDir -ChildPath 'coverage.xml'
    $config.CodeCoverage.OutputFormat          = 'JaCoCo'
    $config.CodeCoverage.CoveragePercentTarget = 80
}
#endregion

#region Run
$result = Invoke-Pester -Configuration $config
#endregion

#region Coverage report
if ($Coverage -and $null -ne $result.CodeCoverage) {
    $cc            = $result.CodeCoverage
    $totalCmds     = $cc.CommandsAnalyzed
    $missedCmds    = $cc.CommandsMissed
    $executedCmds  = $totalCmds - $missedCmds
    $pct           = if ($totalCmds -gt 0) { [Math]::Round(($executedCmds / $totalCmds) * 100, 1) } else { 0 }
    $coverageColor = if ($pct -ge 80) { 'Green' } elseif ($pct -ge 60) { 'Yellow' } else { 'Red' }

    Write-Host ''
    Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
    Write-Host '  Code Coverage' -ForegroundColor Cyan
    Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ("  Overall : {0,6}%  ({1} / {2} commands)" -f $pct, $executedCmds, $totalCmds) -ForegroundColor $coverageColor

    if ($cc.CommandsNotExecuted.Count -gt 0) {
        Write-Host ''
        Write-Host '  Missed commands by file:' -ForegroundColor DarkGray
        Write-Host ''

        $cc.CommandsNotExecuted |
            Group-Object { Split-Path $_.File -Leaf } |
            Sort-Object Count -Descending |
            ForEach-Object {
                Write-Host ("    {0,-45} {1,3} missed" -f $_.Name, $_.Count) -ForegroundColor Yellow
            }
    }

    Write-Host ''
    Write-Host "  Report  : $($config.CodeCoverage.OutputPath.Value)" -ForegroundColor Gray
    Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
    Write-Host ''
}
#endregion

#region Test results summary
Write-Host ''
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray

$passColor = if ($result.FailedCount -eq 0) { 'Green' } else { 'Red' }
Write-Host ("  Passed  : {0}" -f $result.PassedCount)  -ForegroundColor Green
Write-Host ("  Failed  : {0}" -f $result.FailedCount)  -ForegroundColor $passColor
Write-Host ("  Skipped : {0}" -f $result.SkippedCount) -ForegroundColor DarkGray
Write-Host ("  Total   : {0}" -f $result.TotalCount)   -ForegroundColor Cyan
Write-Host ("  Duration: {0:n2}s" -f $result.Duration.TotalSeconds) -ForegroundColor DarkGray
Write-Host ''
Write-Host "  Results : $($config.TestResult.OutputPath.Value)" -ForegroundColor Gray
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
Write-Host ''
#endregion

#region Exit code
if ($PassThru) {
    return $result
}

if ($result.TotalCount -eq 0) {
    Write-Warning 'No tests were discovered. Check the -TestPath and file naming (*.Tests.ps1).'
    exit 2
}

exit $(if ($result.FailedCount -gt 0) { 1 } else { 0 })
#endregion
