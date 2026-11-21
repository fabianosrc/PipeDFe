#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for safe PipeDFe build destinations.

.DESCRIPTION
Loads only the safety helper functions through the PowerShell AST, without
executing the build pipeline, modifying the repository, or publishing.

Coverage includes:
  - Exact and descendant path comparisons
  - Boundary-aware overlap checks
  - Rejection of symbolic links and junctions in ancestors or artifacts
  - Acceptance of ordinary directories and nonexisting output paths
#>

Describe 'Invoke-Build destination safety' -Tag 'Unit' {

    BeforeAll {

        $root = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.FullName
        $scriptPath = Join-Path -Path $root -ChildPath 'tools/Invoke-Build.ps1'

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$parseErrors
        )

        if (@($parseErrors).Count -gt 0) {
            throw 'Build script contains PowerShell parse errors.'
        }

        $helperNames = @(
            'ConvertTo-NormalizedPath'
            'Test-PathOverlap'
            'Assert-SafeBuildDestination'
            'Assert-NoReparsePointOnPath'
            'Assert-NoReparsePointsInTree'
            'Invoke-BuildScript'
        )

        $functions = @(
            $ast.FindAll(
                {
                    param ($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true
            )
        )

        foreach ($helperName in $helperNames) {
            $definition = @($functions | Where-Object { $_.Name -eq $helperName })

            if ($definition.Count -ne 1) {
                throw "Expected exactly one definition of '$helperName'."
            }

            . ([scriptblock]::Create($definition[0].Extent.Text))
        }
    }

    It 'Accepts the root directory itself and its descendants' {
        $root = Join-Path -Path $TestDrive -ChildPath 'artifacts'
        $child = Join-Path -Path $root -ChildPath 'PipeDFe/0.1.0'

        Test-PathOverlap -Path $root -Directory $root | Should -BeTrue
        Test-PathOverlap -Path $child -Directory $root | Should -BeTrue
    }

    It 'Does not mistake similarly prefixed directories for descendants' {
        $root = Join-Path -Path $TestDrive -ChildPath 'artifacts'
        $sibling = Join-Path -Path $TestDrive -ChildPath 'artifacts-backup'

        Test-PathOverlap -Path $sibling -Directory $root | Should -BeFalse
    }

    It 'Rejects removal of ArtifactRoot itself' {
        $root = Join-Path -Path $TestDrive -ChildPath 'artifacts'

        { Assert-SafeBuildDestination -Path $root -ArtifactRoot $root } |
            Should -Throw '*cannot be ArtifactRoot*'
    }

    It 'Rejects a destination outside ArtifactRoot' {
        $root = Join-Path -Path $TestDrive -ChildPath 'artifacts'
        $outside = Join-Path -Path $TestDrive -ChildPath 'unrelated'

        { Assert-SafeBuildDestination -Path $outside -ArtifactRoot $root } |
            Should -Throw '*outside ArtifactRoot*'
    }

    It 'Accepts an ordinary directory and a not-yet-created descendant' {
        $root = Join-Path -Path $TestDrive -ChildPath 'normal'

        [void][System.IO.Directory]::CreateDirectory($root)
        $child = Join-Path -Path $root -ChildPath 'new/subdirectory'

        { Assert-NoReparsePointOnPath  -Path $child } | Should -Not -Throw
        { Assert-NoReparsePointsInTree -Path $root  } | Should -Not -Throw
    }

    #region Child script failures
    Context 'Child script failures' {

        It 'Rejects a missing maintenance script' {
            $script = Join-Path -Path $TestDrive -ChildPath 'absent.ps1'

            $params = @{
                Path = $script
                FailureMessage = 'Maintenance step failed.'
            }

            { Invoke-BuildScript @params } | Should -Throw '*not found*'
        }

        It 'Propagates a terminating failure from a maintenance script' {
            $script = Join-Path -Path $TestDrive -ChildPath 'throws.ps1'

            [System.IO.File]::WriteAllText($script, "throw 'Simulated lint failure.'")

            $params = @{
                Path = $script
                FailureMessage = 'Maintenance step failed.'
            }

            { Invoke-BuildScript @params } | Should -Throw '*Simulated lint failure*'
        }

        It 'Rejects a nonzero native exit code returned by a maintenance script' {
            $script = Join-Path -Path $TestDrive -ChildPath 'exit-code.ps1'

            [System.IO.File]::WriteAllText($script, '$global:LASTEXITCODE = 5')

            $params = @{
                Path = $script
                FailureMessage = 'Maintenance step failed.'
            }

            { Invoke-BuildScript @params } | Should -Throw '*Maintenance step failed*'
        }
    }
    #endregion

    #region Reparse points on Windows
    Context 'Reparse points on Windows' -Skip:([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {

        It 'Rejects a symbolic link used as an ancestor of a destination' {
            $target = Join-Path -Path $TestDrive -ChildPath 'actual'
            $link   = Join-Path -Path $TestDrive -ChildPath 'linked'

            [void][System.IO.Directory]::CreateDirectory($target)

            try {
                New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop |
                    Out-Null
            } catch {
                Set-ItResult -Skipped -Because 'Creating directory symlinks requires system permission.'
                return
            }

            try {
                $child = Join-Path -Path $link -ChildPath 'PipeDFe/0.1.0'
                { Assert-NoReparsePointOnPath -Path $child } |
                    Should -Throw '*symbolic link or junction*'
            } finally {
                [System.IO.Directory]::Delete($link)
            }
        }

        It 'Rejects linked entries nested in an existing artifact' {
            $target   = Join-Path -Path $TestDrive -ChildPath 'outside'
            $artifact = Join-Path -Path $TestDrive -ChildPath 'existing'
            $link     = Join-Path -Path $artifact -ChildPath 'linked'

            [void][System.IO.Directory]::CreateDirectory($target)
            [void][System.IO.Directory]::CreateDirectory($artifact)

            try {
                New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop |
                    Out-Null
            } catch {
                Set-ItResult -Skipped -Because 'Creating directory symlinks requires system permission.'
                return
            }

            try {
                { Assert-NoReparsePointsInTree -Path $artifact } |
                    Should -Throw '*symbolic link or junction*'
            } finally {
                [System.IO.Directory]::Delete($link)
            }
        }
        #region
    }
}
