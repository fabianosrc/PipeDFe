$projectRoot = 'C:\Workspace\Projects\PipeDFe'

$sourceFiles = @(
    # Join-Path $projectRoot '.\src\Private\Crypt\ConvertFrom-DpapiString.ps1'
    # Join-Path $projectRoot '.\src\Private\Crypt\ConvertTo-DpapiString.ps1'
    # Join-Path $projectRoot '.\src\Private\Store\Get-StorePath.ps1'

    # Join-Path $projectRoot '.\src\Private\Execution\Enter-PipeDFeExecutionLock.ps1'
    # Join-Path $projectRoot '.\src\Private\Execution\Exit-PipeDFeExecutionLock.ps1'
    # Join-Path $projectRoot '.\src\Public\Invoke-PipeDFe.ps1'

    Join-Path $projectRoot '.\src\Private\Store\Initialize-DFeAudit.ps1'
    Join-Path $projectRoot '.\src\Private\Store\Start-DFeAuditExecution.ps1'
    Join-Path $projectRoot '.\src\Private\Store\Save-DFeAuditEvent.ps1'
)

$testFiles = @(
    # Join-Path $projectRoot '.\tests\Unit\Private\Crypt\ConvertFrom-DpapiString.Tests.ps1'
    # Join-Path $projectRoot '.\tests\Unit\Private\Crypt\ConvertTo-DpapiString.Tests.ps1'
    # Join-Path $projectRoot '.\tests\Unit\Private\Store\Get-StorePath.Tests.ps1'

    # Join-Path $projectRoot '.\tests\Unit\Private\Execution\Enter-PipeDFeExecutionLock.Tests.ps1'
    # Join-Path $projectRoot '.\tests\Unit\Private\Execution\Exit-PipeDFeExecutionLock.Tests.ps1'
    # Join-Path $projectRoot '.\tests\Unit\Public\Invoke-PipeDFe.Tests.ps1'

    Join-Path $projectRoot '.\tests\Integration\Private\Store\Initialize-DFeAudit.Tests.ps1'
    Join-Path $projectRoot '.\tests\Unit\Private\Store\Initialize-DFeAudit.Tests.ps1'
)

$outputDirectory = Join-Path $projectRoot 'TestResults'
$outputPath = Join-Path $outputDirectory 'coverage.xml'

if (-not (Test-Path $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory | Out-Null
}

$config = New-PesterConfiguration

$config.Run.Path = $testFiles

$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path = $sourceFiles
$config.CodeCoverage.OutputPath = $outputPath
$config.CodeCoverage.OutputFormat = 'JaCoCo'

$config.Output.Verbosity = 'Detailed'

$result = Invoke-Pester -Configuration $config

Write-Host ''
Write-Host 'Code coverage:' -ForegroundColor Cyan

$result.CodeCoverage | Format-List *

Write-Host ''
Write-Host "Coverage report: $outputPath" -ForegroundColor Cyan
