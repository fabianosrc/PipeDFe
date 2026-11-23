<#
.SYNOPSIS
Creates ZIP archives grouped by fiscal model and NF-e direction.

.DESCRIPTION
Prevalidates the complete archive plan before creating directories, loading
fiscal events, compressing sources, or publishing any ZIP. NF-e (model 55)
requires an explicit Entrada or Saida direction; other models use model-only
grouping. Every NF-e entry must be covered by exactly one archive definition.

Loads each document's events once and selects events using the document keys
included in the corresponding archive. Delegates source-hash validation and
ZIP construction to Compress-DFeArchive, then publishes each completed ZIP
atomically through Publish-DFeArchive.

Prevalidation prevents partial output caused by an invalid archive plan.
However, publishing multiple ZIP files is not a single atomic transaction:
a later compression or publication failure may leave earlier ZIPs published.
Temporary ZIPs are removed on a best-effort basis.

.PARAMETER Cnpj
Normalized company CNPJ.

.PARAMETER Company
Company object exposing XmlPath and OutputPath.

.PARAMETER Entries
Document entries returned by Get-DFeDocumentEntry.

.PARAMETER ArchiveInfos
Definitions returned by Resolve-DFeArchiveInfo. Each definition must expose
TipoDFe, FileName, TempPath and DestPath. For NFe, Direcao must be Entrada or
Saida. For other models, Direcao must be null or absent.

.PARAMETER DateRange
Date range used to derive the internal ZIP period segment.

.OUTPUTS
System.Management.Automation.PSCustomObject

Each successfully published archive returns TipoDFe, FileName, FileHash,
TempPath and DestPath. No results are returned for an empty archive plan.

.NOTES
Private dependencies:
  Compress-DFeArchive
  Get-ArchivePeriodSegment
  Get-DFeEventoEntry
  Get-FileSha256
  Publish-DFeArchive
#>
function New-DFeArchive {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'ShouldProcess is owned by the pipeline orchestration contract.'
    )]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Company,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Entries,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$ArchiveInfos,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$DateRange
    )

    # Build and validate the complete plan before any filesystem writes.
    $plans = [System.Collections.Generic.List[pscustomobject]]::new()

    $archiveIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    $destPaths = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    $tempPaths = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    $nfeEntries = @($Entries | Where-Object { [int]$_.modelo -eq 55 })

    $coveredNfeKeys = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )

    foreach ($entry in $nfeEntries) {
        $directionProperty = $entry.PSObject.Properties['direcao']

        $direction = if ($null -ne $directionProperty) {
            [string]$directionProperty.Value
        } else {
            $null
        }

        if ($direction -cnotin @('Entrada', 'Saida')) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "[$Cnpj] NF-e '$($entry.chave_acesso)' has no valid direction."
                ),
                'ArchiveDirectionUncovered',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $entry
            )
        }
    }

    foreach ($archiveInfo in $ArchiveInfos) {
        foreach ($name in @('TipoDFe', 'FileName', 'TempPath', 'DestPath')) {
            $member = $archiveInfo.PSObject.Properties[$name]

            if ($null -eq $member -or [string]::IsNullOrWhiteSpace([string]$member.Value)) {
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "[$Cnpj] Archive information requires '$name'."
                    ),
                    'ArchiveInfoIncomplete',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $archiveInfo
                )
            }
        }

        try {
            $modelValue = [int][System.Enum]::Parse(
                [ModeloDFe],
                [string]$archiveInfo.TipoDFe,
                $false
            )
        } catch {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "[$Cnpj] Archive type '$($archiveInfo.TipoDFe)' " +
                    "is not defined in ModeloDFe.",
                    $_.Exception
                ),
                'ArchiveModelUnsupported',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $archiveInfo.TipoDFe
            )
        }

        $directionMember = $archiveInfo.PSObject.Properties['Direcao']

        $direction = if ($null -ne $directionMember) {
            $directionMember.Value
        } else {
            $null
        }

        if ($modelValue -eq 55 -and $direction -cnotin @('Entrada', 'Saida')) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "[$Cnpj] NFe archive '$($archiveInfo.FileName)' requires Entrada or Saida."
                ),
                'ArchiveDirectionRequired',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $archiveInfo
            )
        }

        if ($modelValue -ne 55 -and $null -ne $direction) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "[$Cnpj] Direction is not supported for '$($archiveInfo.TipoDFe)'."
                ),
                'ArchiveDirectionUnsupported',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $archiveInfo
            )
        }

        $archiveId = if ($modelValue -eq 55) {
            '{0}:{1}' -f $modelValue, $direction
        } else {
            [string]$modelValue
        }

        if (-not $archiveIds.Add($archiveId)) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "[$Cnpj] Duplicate archive group '$archiveId'."
                ),
                'ArchiveDirectionDuplicate',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $archiveInfo
            )
        }

        $destPath = [System.IO.Path]::GetFullPath([string]$archiveInfo.DestPath)
        $tempPath = [System.IO.Path]::GetFullPath([string]$archiveInfo.TempPath)

        $pathConflict = (
            $destPaths.Contains($destPath) -or
            $tempPaths.Contains($tempPath) -or
            $tempPaths.Contains($destPath) -or
            $destPaths.Contains($tempPath) -or
            [System.StringComparer]::OrdinalIgnoreCase.Equals($destPath, $tempPath)
        )

        if ($pathConflict) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "[$Cnpj] Archive paths are duplicated or overlap."
                ),
                'ArchivePathConflict',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $archiveInfo
            )
        }

        $null = $destPaths.Add($destPath)
        $null = $tempPaths.Add($tempPath)

        $groupEntries = @(
            $Entries | Where-Object {
                if ([int]$_.modelo -ne $modelValue) {
                    return $false
                }

                if ($modelValue -ne 55) {
                    return $true
                }

                $member = $_.PSObject.Properties['direcao']
                return ($null -ne $member -and $member.Value -ceq $direction)
            }
        )

        if ($groupEntries.Count -eq 0) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "[$Cnpj] Archive '$($archiveInfo.FileName)' has no matching documents."
                ),
                'ArchiveEntriesNotFound',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $archiveInfo
            )
        }

        if ($modelValue -eq 55) {
            foreach ($entry in $groupEntries) {
                if (-not $coveredNfeKeys.Add([string]$entry.chave_acesso)) {
                    throw [System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new(
                            "[$Cnpj] NF-e '$($entry.chave_acesso)' is covered more than once."
                        ),
                        'ArchiveDirectionDuplicate',
                        [System.Management.Automation.ErrorCategory]::InvalidData,
                        $entry
                    )
                }
            }
        }

        $plans.Add(
            [PSCustomObject]@{
                Info    = $archiveInfo
                Entries = $groupEntries
            }
        )
    }

    foreach ($entry in $nfeEntries) {
        if (-not $coveredNfeKeys.Contains([string]$entry.chave_acesso)) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "[$Cnpj] NF-e '$($entry.chave_acesso)' has no matching archive."
                ),
                'ArchiveDirectionUncovered',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $entry
            )
        }
    }

    if ($plans.Count -eq 0) {
        return
    }

    $periodSegment = Get-ArchivePeriodSegment -DateRange $DateRange

    if (-not (Test-Path -LiteralPath $Company.OutputPath -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($Company.OutputPath) | Out-Null
    }

    # Load each event once, then isolate it by the archive's document keys.
    $eventsByKey = @{}

    foreach ($entry in $Entries) {
        $key = [string]$entry.chave_acesso

        if ($eventsByKey.ContainsKey($key)) {
            continue
        }

        $eventParams = @{
            Cnpj        = $Cnpj
            ChavePai    = $key
            ErrorAction = 'Stop'
        }

        $eventsByKey[$key] = @(
            Get-DFeEventoEntry @eventParams | ForEach-Object {
                [PSCustomObject]@{
                    ChavePai = $_.chave_pai
                    FilePath = $_.file_path
                    Sha256   = $_.sha256
                }
            }
        )
    }

    foreach ($plan in $plans) {
        $info = $plan.Info

        try {
            $mappedEntries = @(
                $plan.Entries | ForEach-Object {
                    [PSCustomObject]@{
                        ChaveAcesso = $_.chave_acesso
                        Modelo      = $_.modelo
                        FilePath    = $_.file_path
                        Sha256      = $_.sha256
                    }
                }
            )

            $groupEvents = @(
                foreach ($entry in $plan.Entries) {
                    foreach ($eventDoc in $eventsByKey[[string]$entry.chave_acesso]) {
                        $eventDoc
                    }
                }
            )

            $compressParams = @{
                XmlPath       = $Company.XmlPath
                Entries       = $mappedEntries
                Eventos       = $groupEvents
                ZipPath       = $info.TempPath
                PeriodSegment = $periodSegment
                ErrorAction   = 'Stop'
            }

            Compress-DFeArchive @compressParams

            if (-not (Test-Path -LiteralPath $info.TempPath -PathType Leaf)) {
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new(
                        "[$Cnpj] Compress-DFeArchive did not create '$($info.TempPath)'."
                    ),
                    'ZipNotCreated',
                    [System.Management.Automation.ErrorCategory]::ResourceUnavailable,
                    $info.TempPath
                )
            }

            $zipHash = Get-FileSha256 -Path $info.TempPath -ErrorAction 'Stop'

            $publishParams = @{
                SourcePath      = $info.TempPath
                DestinationPath = $info.DestPath
                ExpectedHash    = $zipHash
                ErrorAction     = 'Stop'
            }

            Publish-DFeArchive @publishParams

            [PSCustomObject]@{
                TipoDFe  = $info.TipoDFe
                FileName = $info.FileName
                FileHash = $zipHash
                TempPath = $info.TempPath
                DestPath = $info.DestPath
            }
        } finally {
            if (Test-Path -LiteralPath $info.TempPath -PathType Leaf) {
                $removeParams = @{
                    LiteralPath = $info.TempPath
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeParams
            }
        }
    }
}
