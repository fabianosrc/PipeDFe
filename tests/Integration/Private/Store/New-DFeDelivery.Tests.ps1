#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for New-DFeDelivery.

.DESCRIPTION
Verifies persistent delivery creation and retrieval against the real SQLite
index initialized by Initialize-DFeIndex.

The tests use isolated LOCALAPPDATA directories and real temporary files
for archive SHA-256 verification. No production data is accessed.

Coverage includes:
  - Parameter contract and validation.
  - Creation of a Prepared delivery.
  - Persistence of archive and recipient metadata.
  - UTC period and timestamp persistence.
  - Idempotent retrieval of an existing delivery.
  - Stable delivery identity regardless of archive or recipient order.
  - New identity when archive content changes.
  - New identity when recipients change.
  - Recipient normalization and duplicate removal.
  - Preservation of an existing delivery state.
  - Archive path and hash validation.
  - Atomic rollback when a child insert fails.
  - CNPJ isolation.
  - Persistence after the original connection is closed.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Test helpers modify isolated SQLite fixtures.'
)]

param ()

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'New-DFeDelivery' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $testId = [guid]::NewGuid().ToString('N')

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.New-DFeDelivery.Tests-{0}' -f $testId
            )

            New-Item -Path $Script:TempRoot -ItemType Directory -Force |
                Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot

            $Script:TestCnpj = '12345678000199'

            $Script:PeriodStart = [DateTimeOffset]::Parse(
                '2026-11-01T00:00:00-03:00'
            )

            $Script:PeriodEnd = [DateTimeOffset]::Parse(
                '2026-11-30T23:59:59-03:00'
            )

            Initialize-DFeIndex -Cnpj $Script:TestCnpj | Out-Null

            function New-TestArchive {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$TipoDFe,

                    [Parameter(Mandatory)]
                    [string]$Content
                )

                $fileName = '{0}_{1}.zip' -f (
                    $TipoDFe,
                    [guid]::NewGuid().ToString('N')
                )

                $path = [System.IO.Path]::Combine(
                    $Script:TempRoot,
                    $fileName
                )

                [System.IO.File]::WriteAllText(
                    $path,
                    $Content,
                    [System.Text.Encoding]::UTF8
                )

                [PSCustomObject]@{
                    TipoDFe  = $TipoDFe
                    FileName = $fileName
                    FileHash = Get-FileSha256 -Path $path
                    DestPath = $path
                }
            }

            function Get-TestScalar {
                [CmdletBinding()]
                [OutputType([object])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$Sql,

                    [Parameter()]
                    [hashtable]$Parameters = @{}
                )

                $connection = Open-DFeIndexConnection -Cnpj $Cnpj

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = $Sql

                        foreach ($entry in $Parameters.GetEnumerator()) {
                            $parameter = $command.Parameters.Add(
                                [string]$entry.Key,
                                [System.Data.DbType]::String
                            )

                            $parameter.Value = $entry.Value
                        }

                        $command.ExecuteScalar()
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }

            function Invoke-TestNonQuery {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$Sql,

                    [Parameter()]
                    [hashtable]$Parameters = @{}
                )

                $connection = Open-DFeIndexConnection -Cnpj $Cnpj

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = $Sql

                        foreach ($entry in $Parameters.GetEnumerator()) {
                            $parameter = $command.Parameters.Add(
                                [string]$entry.Key,
                                [System.Data.DbType]::String
                            )

                            $parameter.Value = $entry.Value
                        }

                        $command.ExecuteNonQuery() | Out-Null
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }

            function Get-TestDeliveryCount {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$DeliveryId
                )

                $parameters = @{
                    '@delivery_id' = $DeliveryId
                }

                $deliveryCount = Get-TestScalar -Cnpj $Cnpj -Parameters $parameters -Sql @'
SELECT COUNT(*)
FROM dfe_delivery
WHERE delivery_id = @delivery_id;
'@

                $archiveCount = Get-TestScalar -Cnpj $Cnpj -Parameters $parameters -Sql @'
SELECT COUNT(*)
FROM dfe_delivery_archive
WHERE delivery_id = @delivery_id;
'@

                $recipientCount = Get-TestScalar -Cnpj $Cnpj -Parameters $parameters -Sql @'
SELECT COUNT(*)
FROM dfe_delivery_recipient
WHERE delivery_id = @delivery_id;
'@

                [PSCustomObject]@{
                    Deliveries = [int]$deliveryCount
                    Archives   = [int]$archiveCount
                    Recipients = [int]$recipientCount
                }
            }

            function Set-TestDeliveryStatus {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$DeliveryId,

                    [Parameter(Mandatory)]
                    [string]$Status
                )

                $timestamp = '2026-11-05T12:00:00.0000000+00:00'

                $parameters = @{
                    '@delivery_id' = $DeliveryId
                    '@timestamp'   = $timestamp
                }

                $sql = switch ($Status) {
                    'Delivered' {
                        @'
UPDATE dfe_delivery
SET
    delivery_status = 'Delivered',
    delivered_at = @timestamp,
    updated_at = @timestamp
WHERE delivery_id = @delivery_id;
'@
                    }

                    default {
                        throw "Unsupported test status '$Status'."
                    }
                }

                Invoke-TestNonQuery -Cnpj $Cnpj -Sql $sql -Parameters $parameters
            }

            function Assert-TestErrorId {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [scriptblock]$ScriptBlock,

                    [Parameter(Mandatory)]
                    [string]$ErrorId
                )

                $caught = $false

                try {
                    & $ScriptBlock
                } catch {
                    $caught = $true

                    $_.FullyQualifiedErrorId | Should -BeLike "$ErrorId*"
                }

                $caught | Should -BeTrue
            }
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData

            $removeItemParams = @{
                LiteralPath = $Script:TempRoot
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeItemParams
        }
        #endregion

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Cnpj, PeriodStart, PeriodEnd, Archives and To as mandatory' {
                $command = Get-Command -Name New-DFeDelivery

                foreach ($name in @('Cnpj','PeriodStart','PeriodEnd','Archives','To')
                ) {
                    $mandatory = @(
                        $command.Parameters[$name].Attributes |
                            Where-Object {
                                $_ -is [System.Management.Automation.ParameterAttribute] -and
                                $_.Mandatory
                            }
                    )

                    $mandatory | Should -HaveCount 1 -Because "'$name' is required."
                }
            }

            It 'Accepts empty Cc and Bcc collections' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'empty cc and bcc'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('primary@example.com')
                    Cc          = @()
                    Bcc         = @()
                }

                $result = New-DFeDelivery @params

                $result.DeliveryStatus | Should -Be 'Prepared'
                $result.Recipients | Should -HaveCount 1
            }
        }
        #endregion

        #region Successful creation
        Context 'Successful creation' {

            It 'Creates a Prepared delivery with a deterministic SHA-256 key' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'prepared delivery'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('finance@example.com')
                }

                $result = New-DFeDelivery @params

                $result.PSTypeNames    | Should -Contain 'PipeDFe.Delivery'
                $result.Cnpj           | Should -Be $Script:TestCnpj
                $result.DeliveryId     | Should -Match '^[0-9a-f]{32}$'
                $result.DeliveryKey    | Should -Match '^[0-9a-f]{64}$'
                $result.DeliveryStatus | Should -Be 'Prepared'
                $result.Created        | Should -BeTrue
            }

            It 'Persists the archive metadata' {
                $archive = New-TestArchive -TipoDFe 'NFCe' -Content 'archive metadata'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('archive@example.com')
                }

                $result = New-DFeDelivery @params

                $result.Archives             | Should -HaveCount 1
                $result.Archives[0].TipoDFe  | Should -Be 'NFCe'
                $result.Archives[0].FileName | Should -Be $archive.FileName
                $result.Archives[0].FileHash | Should -Be $archive.FileHash
                $result.Archives[0].DestPath | Should -Be $archive.DestPath
            }

            It 'Persists To, Cc and Bcc recipient addresses' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'recipient metadata'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('to@example.com')
                    Cc          = @('cc@example.com')
                    Bcc         = @('bcc@example.com')
                }

                $result = New-DFeDelivery @params

                $result.Recipients | Should -HaveCount 3

                $result.Recipients |
                    Where-Object RecipientType -eq 'To' |
                    Select-Object -ExpandProperty Address |
                    Should -Be 'to@example.com'

                $result.Recipients |
                    Where-Object RecipientType -eq 'Cc' |
                    Select-Object -ExpandProperty Address |
                    Should -Be 'cc@example.com'

                $result.Recipients |
                    Where-Object RecipientType -eq 'Bcc' |
                    Select-Object -ExpandProperty Address |
                    Should -Be 'bcc@example.com'
            }

            It 'Does not persist recipient display names' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'recipient names'

                $recipient = [PSCustomObject]@{
                    Name  = 'Finance Department'
                    Email = 'finance@example.com'
                }

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @($recipient)
                }

                $result = New-DFeDelivery @params

                $result.Recipients[0].PSObject.Properties.Name |
                    Should -Not -Contain 'Name'

                $result.Recipients[0].Address | Should -Be 'finance@example.com'
            }

            It 'Stores period and timestamps in UTC round-trip format' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'utc timestamps'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('utc@example.com')
                }

                $result = New-DFeDelivery @params

                $storedStart = [DateTimeOffset]::Parse($result.PeriodStart)
                $storedEnd   = [DateTimeOffset]::Parse($result.PeriodEnd)
                $createdAt   = [DateTimeOffset]::Parse($result.CreatedAt)
                $updatedAt   = [DateTimeOffset]::Parse($result.UpdatedAt)

                $storedStart.Offset | Should -Be ([TimeSpan]::Zero)
                $storedEnd.Offset   | Should -Be ([TimeSpan]::Zero)
                $createdAt.Offset   | Should -Be ([TimeSpan]::Zero)
                $updatedAt.Offset   | Should -Be ([TimeSpan]::Zero)

                $storedStart | Should -Be $Script:PeriodStart.ToUniversalTime()
                $storedEnd   | Should -Be $Script:PeriodEnd.ToUniversalTime()

                $result.CreatedAt | Should -Be $result.UpdatedAt
            }

            It 'Leaves delivery transition fields null when first prepared' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'initial state fields'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('state@example.com')
                }

                $result = New-DFeDelivery @params

                $result.DeliveryStartedAt | Should -BeNullOrEmpty
                $result.DeliveredAt       | Should -BeNullOrEmpty
                $result.DeliveryError     | Should -BeNullOrEmpty
            }

            It 'Returns exactly one delivery object' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'single output'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('single@example.com')
                }

                $result = @(New-DFeDelivery @params)

                $result                | Should -HaveCount 1
                $result[0].PSTypeNames | Should -Contain 'PipeDFe.Delivery'
            }
        }
        #endregion

        #region Idempotency
        Context 'Idempotent creation and retrieval' {

            It 'Returns the existing delivery for the same identity' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'same identity'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('same@example.com')
                    Cc          = @('copy@example.com')
                }

                $first  = New-DFeDelivery @params
                $second = New-DFeDelivery @params

                $first.Created  | Should -BeTrue
                $second.Created | Should -BeFalse

                $second.DeliveryId     | Should -Be $first.DeliveryId
                $second.DeliveryKey    | Should -Be $first.DeliveryKey
                $second.DeliveryStatus | Should -Be 'Prepared'

                $second.Archives | Should -HaveCount 1
                $second.Recipients | Should -HaveCount 2

                $countParams = @{
                    Cnpj       = $Script:TestCnpj
                    DeliveryId = $first.DeliveryId
                }

                $counts = Get-TestDeliveryCount @countParams

                $counts.Deliveries | Should -Be 1
                $counts.Archives   | Should -Be 1
                $counts.Recipients | Should -Be 2
            }

            It 'Returns persisted data after the original connection is closed' {
                $archive = New-TestArchive -TipoDFe 'NFCe' -Content 'reopened connection'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('reopen@example.com')
                }

                $first  = New-DFeDelivery @params

                # New-DFeDelivery owns and disposes its connection. This call
                # therefore verifies retrieval through a newly opened connection.
                $second = New-DFeDelivery @params

                $second.Created               | Should -BeFalse
                $second.DeliveryId            | Should -Be $first.DeliveryId
                $second.Archives[0].FileHash  | Should -Be $archive.FileHash
                $second.Recipients[0].Address | Should -Be 'reopen@example.com'
            }

            It 'Does not reset an existing delivery state to Prepared' {
                # Use an isolated company index so a Delivered record cannot
                # interfere with subsequent delivery identity tests.
                $cnpj = '12345678000901'

                Initialize-DFeIndex -Cnpj $cnpj | Out-Null

                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'preserve delivery state'

                $params = @{
                    Cnpj        = $cnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('preserve@example.com')
                }

                $first = New-DFeDelivery @params

                $deliveryStatusParams = @{
                    Cnpj       = $cnpj
                    DeliveryId = $first.DeliveryId
                    Status     = 'Delivered'
                }

                Set-TestDeliveryStatus @deliveryStatusParams

                $second = New-DFeDelivery @params

                $second.Created        | Should -BeFalse
                $second.DeliveryId     | Should -Be $first.DeliveryId
                $second.DeliveryStatus | Should -Be 'Delivered'
                $second.DeliveredAt    | Should -Not -BeNullOrEmpty
            }

        }
        #endregion

        #region Delivery identity
        Context 'Delivery identity' {

            It 'Produces the same key regardless of archive order' {
                $nfe  = New-TestArchive -TipoDFe 'NFe' -Content 'ordered archive nfe'
                $nfce = New-TestArchive -TipoDFe 'NFCe' -Content 'ordered archive nfce'

                $firstParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($nfe, $nfce)
                    To          = @('one@example.com', 'two@example.com')
                }

                $secondParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($nfce, $nfe)
                    To          = @('one@example.com', 'two@example.com')
                }

                $first  = New-DFeDelivery @firstParams
                $second = New-DFeDelivery @secondParams

                $second.DeliveryKey | Should -Be $first.DeliveryKey
                $second.DeliveryId  | Should -Be $first.DeliveryId
                $second.Created     | Should -BeFalse
            }

            It 'Produces the same key regardless of recipient order' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'ordered recipients'

                $firstParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('one@example.com', 'two@example.com')
                    Cc          = @('three@example.com', 'four@example.com')
                    Bcc         = @('five@example.com', 'six@example.com')
                }

                $secondParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('two@example.com', 'one@example.com')
                    Cc          = @('four@example.com', 'three@example.com')
                    Bcc         = @('six@example.com', 'five@example.com')
                }

                $first  = New-DFeDelivery @firstParams
                $second = New-DFeDelivery @secondParams

                $second.DeliveryKey | Should -Be $first.DeliveryKey
                $second.DeliveryId  | Should -Be $first.DeliveryId
                $second.Created     | Should -BeFalse
            }

            It 'Does not include recipient display names in the delivery identity' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'recipient name identity'

                $firstRecipient = [PSCustomObject]@{
                    Name  = 'Finance'
                    Email = 'identity@example.com'
                }

                $secondRecipient = [PSCustomObject]@{
                    Name  = 'Accounts Payable'
                    Email = 'identity@example.com'
                }

                $firstParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @($firstRecipient)
                }

                $secondParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @($secondRecipient)
                }

                $first  = New-DFeDelivery @firstParams
                $second = New-DFeDelivery @secondParams

                $second.DeliveryKey | Should -Be $first.DeliveryKey
                $second.DeliveryId  | Should -Be $first.DeliveryId
                $second.Created     | Should -BeFalse
            }

            It 'Keeps the same identity when the archive has a different path' {
                # FileName and DestPath are excluded from the delivery key.
                # Two archives with identical content but different paths must
                # produce the same identity and return the originally stored path.
                $firstArchive  = New-TestArchive -TipoDFe 'NFe' -Content 'same archive bytes'
                $secondArchive = New-TestArchive -TipoDFe 'NFe' -Content 'same archive bytes'

                $firstParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($firstArchive)
                    To          = @('same-path@example.com')
                }

                $secondParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($secondArchive)
                    To          = @('same-path@example.com')
                }

                $first  = New-DFeDelivery @firstParams
                $second = New-DFeDelivery @secondParams

                $firstArchive.FileHash       | Should -Be $secondArchive.FileHash
                $second.Created              | Should -BeFalse
                $second.DeliveryId           | Should -Be $first.DeliveryId
                $second.Archives[0].DestPath | Should -Be $firstArchive.DestPath
            }

            It 'Creates a new delivery when archive content changes' {
                $firstArchive  = New-TestArchive -TipoDFe 'NFe' -Content 'archive content A'
                $secondArchive = New-TestArchive -TipoDFe 'NFe' -Content 'archive content B'

                $firstParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($firstArchive)
                    To          = @('archive-change@example.com')
                }

                $secondParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($secondArchive)
                    To          = @('archive-change@example.com')
                }

                $first  = New-DFeDelivery @firstParams
                $second = New-DFeDelivery @secondParams

                $second.Created     | Should -BeTrue
                $second.DeliveryId  | Should -Not -Be $first.DeliveryId
                $second.DeliveryKey | Should -Not -Be $first.DeliveryKey
            }

            It 'Creates a new delivery when recipients change' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'recipient change'

                $firstParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('first@example.com')
                }

                $secondParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('second@example.com')
                }

                $first  = New-DFeDelivery @firstParams
                $second = New-DFeDelivery @secondParams

                $second.Created     | Should -BeTrue
                $second.DeliveryId  | Should -Not -Be $first.DeliveryId
                $second.DeliveryKey | Should -Not -Be $first.DeliveryKey
            }

            It 'Creates a new delivery when a recipient type changes' {
                # Recipient type (To/Cc/Bcc) is part of the logical content of a
                # delivery. Moving the same address from Cc to Bcc must produce a
                # new identity, not recover the existing one.
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'recipient type identity'

                $firstParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('fixed@example.com')
                    Cc          = @('moving@example.com')
                }

                $secondParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('fixed@example.com')
                    Bcc         = @('moving@example.com')
                }

                $first  = New-DFeDelivery @firstParams
                $second = New-DFeDelivery @secondParams

                $second.Created     | Should -BeTrue
                $second.DeliveryId  | Should -Not -Be $first.DeliveryId
                $second.DeliveryKey | Should -Not -Be $first.DeliveryKey
            }

            It 'Creates a new delivery when the period changes' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'period change'

                $firstParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('period@example.com')
                }

                $secondParams = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart.AddDays(1)
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('period@example.com')
                }

                $first  = New-DFeDelivery @firstParams
                $second = New-DFeDelivery @secondParams

                $second.Created     | Should -BeTrue
                $second.DeliveryKey | Should -Not -Be $first.DeliveryKey
            }
        }
        #endregion

        #region Conflicting delivery states
        Context 'Conflicting delivery states' {

            It 'Blocks changed archive content after a delivered period' {
                $cnpj = '12345678000432'
                Initialize-DFeIndex -Cnpj $cnpj | Out-Null

                $firstArchive  = New-TestArchive -TipoDFe 'NFe' -Content 'original archive'
                $secondArchive = New-TestArchive -TipoDFe 'NFe' -Content 'changed archive'

                $params = @{
                    Cnpj        = $cnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($firstArchive)
                    To          = @('accounting@example.com')
                }

                $first = New-DFeDelivery @params

                Set-TestDeliveryStatus -Cnpj $cnpj -DeliveryId $first.DeliveryId -Status 'Delivered'

                $params.Archives = @($secondArchive)

                { New-DFeDelivery @params } |
                    Should -Throw -ErrorId 'DFeDeliveryCreateFailed*'

                $count = Get-TestScalar -Cnpj $cnpj -Sql @'
SELECT COUNT(*) FROM dfe_delivery;
'@

                [int]$count | Should -Be 1
            }

            It 'Blocks changed recipients after a delivered period' {
                $cnpj = '12345678000513'
                Initialize-DFeIndex -Cnpj $cnpj | Out-Null

                $archive = New-TestArchive -TipoDFe 'NFCom' -Content 'fiscal archive'

                $params = @{
                    Cnpj        = $cnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('first@example.com')
                }

                $first = New-DFeDelivery @params

                Set-TestDeliveryStatus -Cnpj $cnpj -DeliveryId $first.DeliveryId -Status 'Delivered'

                $params.To = @('second@example.com')

                { New-DFeDelivery @params } |
                    Should -Throw -ErrorId 'DFeDeliveryCreateFailed*'

                $count = Get-TestScalar -Cnpj $cnpj -Sql @'
SELECT COUNT(*) FROM dfe_delivery;
'@

                [int]$count | Should -Be 1
            }

            It 'Preserves idempotent retrieval for an identical delivered delivery' {
                $cnpj = '12345678000602'
                Initialize-DFeIndex -Cnpj $cnpj | Out-Null

                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'unchanged archive'

                $params = @{
                    Cnpj        = $cnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('accounting@example.com')
                }

                $first = New-DFeDelivery @params

                Set-TestDeliveryStatus -Cnpj $cnpj -DeliveryId $first.DeliveryId -Status 'Delivered'

                $second = New-DFeDelivery @params

                $second.Created        | Should -BeFalse
                $second.DeliveryId     | Should -Be $first.DeliveryId
                $second.DeliveryStatus | Should -Be 'Delivered'
            }

            It 'Blocks changed identities for Sending and Indeterminate deliveries' {
                $cases = @(
                    @{
                        Status = 'Sending'
                        Cnpj   = '12345678000701'
                    }
                    @{
                        Status = 'Indeterminate'
                        Cnpj   = '12345678000801'
                    }
                )

                foreach ($case in $cases) {
                    $cnpj = $case.Cnpj

                    Initialize-DFeIndex -Cnpj $cnpj | Out-Null

                    $original = New-TestArchive -TipoDFe 'NFe' -Content 'original content'
                    $changed  = New-TestArchive -TipoDFe 'NFe' -Content 'changed content'

                    $deliveryParams = @{
                        Cnpj        = $cnpj
                        PeriodStart = $Script:PeriodStart
                        PeriodEnd   = $Script:PeriodEnd
                        Archives    = @($original)
                        To          = @('accounting@example.com')
                    }

                    $delivery = New-DFeDelivery @deliveryParams

                    $sendingParams = @{
                        Cnpj                      = $cnpj
                        DeliveryId                = $delivery.DeliveryId
                        ExpectedStatus            = 'Prepared'
                        ExpectedDeliveryStartedAt = $null
                        Status                    = 'Sending'
                    }

                    $sending = Set-DFeDeliveryState @sendingParams

                    if ($case.Status -eq 'Indeterminate') {
                        $indeterminateParams = @{
                            Cnpj                      = $cnpj
                            DeliveryId                = $delivery.DeliveryId
                            ExpectedStatus            = 'Sending'
                            ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                            Status                    = 'Indeterminate'
                            ErrorMessage              = 'SMTP outcome cannot be confirmed.'
                        }

                        $null = Set-DFeDeliveryState @indeterminateParams
                    }

                    $deliveryParams.Archives = @($changed)

                    { New-DFeDelivery @deliveryParams } |
                        Should -Throw -ErrorId 'DFeDeliveryCreateFailed*'

                    $count = Get-TestScalar -Cnpj $cnpj -Sql @'
            SELECT COUNT(*) FROM dfe_delivery;
'@

                    [int]$count | Should -Be 1
                }
            }

            It 'Allows a changed identity after a failed delivery' {
                $cnpj = '12345678000902'

                Initialize-DFeIndex -Cnpj $cnpj | Out-Null

                $firstArchive   = New-TestArchive -TipoDFe 'NFe' -Content 'original content'
                $changedArchive = New-TestArchive -TipoDFe 'NFe' -Content 'changed content'

                $params = @{
                    Cnpj        = $cnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($firstArchive)
                    To          = @('accounting@example.com')
                }

                $first = New-DFeDelivery @params

                $deliveryStateParams = @{
                    Cnpj                      = $cnpj
                    DeliveryId                = $first.DeliveryId
                    ExpectedStatus            = 'Prepared'
                    ExpectedDeliveryStartedAt = $null
                    Status                    = 'Sending'
                }

                $sending = Set-DFeDeliveryState @deliveryStateParams

                $otherDeliveryStateParams = @{
                    Cnpj                      = $cnpj
                    DeliveryId                = $first.DeliveryId
                    ExpectedStatus            = 'Sending'
                    ExpectedDeliveryStartedAt = $sending.DeliveryStartedAt
                    Status                    = 'Failed'
                    ErrorMessage              = 'SMTP was not attempted.'
                }

                Set-DFeDeliveryState @otherDeliveryStateParams | Out-Null

                $params.Archives = @($changedArchive)

                $second = New-DFeDelivery @params
                $second.Created | Should -BeTrue

                $count = Get-TestScalar -Cnpj $cnpj -Sql @'
SELECT COUNT(*) FROM dfe_delivery;
'@

                [int]$count | Should -Be 2
            }
        }
        #endregion

        #region Recipient normalization
        Context 'Recipient normalization' {

            It 'Trims addresses and removes exact duplicates within a recipient type' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'recipient normalization'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @(
                        '  duplicate@example.com  '
                        'duplicate@example.com'
                        'unique@example.com'
                    )
                }

                $result = New-DFeDelivery @params

                $result.Recipients | Should -HaveCount 2

                $addresses = @(
                    $result.Recipients |
                        Select-Object -ExpandProperty Address
                )

                $addresses | Should -Contain 'duplicate@example.com'
                $addresses | Should -Contain 'unique@example.com'
            }

            It 'Keeps the same address when it appears in different recipient types' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'recipient type overlap'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('shared@example.com')
                    Cc          = @('shared@example.com')
                }

                $result = New-DFeDelivery @params

                $result.Recipients | Should -HaveCount 2

                $result.Recipients |
                    Select-Object -ExpandProperty RecipientType |
                    Should -Contain 'To'

                $result.Recipients |
                    Select-Object -ExpandProperty RecipientType |
                    Should -Contain 'Cc'
            }
        }
        #endregion

        #region Validation failures
        Context 'Validation failures' {

            It 'Rejects an empty archive collection' {
                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @()
                    To          = @('required@example.com')
                }

                Assert-TestErrorId -ErrorId 'DFeDeliveryArchiveRequired' -ScriptBlock {
                    New-DFeDelivery @params
                }
            }

            It 'Rejects an empty primary recipient collection' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'missing primary recipient'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @()
                }

                Assert-TestErrorId -ErrorId 'DFeDeliveryMissingPrimaryRecipient' -ScriptBlock {
                    New-DFeDelivery @params
                }
            }

            It 'Rejects a period whose end precedes its start' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'invalid period'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodEnd
                    PeriodEnd   = $Script:PeriodStart
                    Archives    = @($archive)
                    To          = @('period@example.com')
                }

                Assert-TestErrorId -ErrorId 'DFeDeliveryInvalidPeriod' -ScriptBlock {
                    New-DFeDelivery @params
                }
            }

            It 'Rejects duplicate archive types' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'duplicate archive type'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive, $archive)
                    To          = @('duplicate@example.com')
                }

                Assert-TestErrorId -ErrorId 'DFeDeliveryDuplicateArchiveType' -ScriptBlock {
                    New-DFeDelivery @params
                }
            }

            It 'Rejects an invalid archive hash format' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'invalid hash format'
                # Intentionally replace the real hash with a malformed value to
                # exercise the format validation before Get-FileSha256 is called.
                $archive.FileHash = 'invalid'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('hash@example.com')
                }

                Assert-TestErrorId -ErrorId 'DFeDeliveryInvalidArchiveHash' -ScriptBlock {
                    New-DFeDelivery @params
                }
            }

            It 'Rejects an archive whose actual hash differs from FileHash' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'hash mismatch'
                # Replace the real hash with a valid-format but incorrect value
                # so the file exists on disk but the supplied hash does not match.
                $archive.FileHash = '0' * 64

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('mismatch@example.com')
                }

                Assert-TestErrorId -ErrorId 'DFeDeliveryArchiveHashMismatch' -ScriptBlock {
                    New-DFeDelivery @params
                }
            }

            It 'Rejects an archive whose FileName does not match DestPath' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'filename mismatch'
                $archive.FileName = 'another-file.zip'

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('filename@example.com')
                }

                Assert-TestErrorId -ErrorId 'DFeDeliveryArchiveInvalid' -ScriptBlock {
                    New-DFeDelivery @params
                }
            }

            It 'Rejects an archive missing a required property' {
                $archive = [PSCustomObject]@{
                    TipoDFe  = 'NFe'
                    FileName = 'missing-hash.zip'
                    DestPath = [System.IO.Path]::Combine(
                        $Script:TempRoot,
                        'missing-hash.zip'
                    )
                }

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('missing-property@example.com')
                }

                Assert-TestErrorId -ErrorId 'DFeDeliveryArchiveInvalid' -ScriptBlock {
                    New-DFeDelivery @params
                }
            }

            It 'Propagates FileNotFound when the archive no longer exists' {
                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'missing archive file'

                Remove-Item -LiteralPath $archive.DestPath -Force

                $params = @{
                    Cnpj        = $Script:TestCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('missing-file@example.com')
                }

                Assert-TestErrorId -ErrorId 'FileNotFound' -ScriptBlock {
                    New-DFeDelivery @params
                }
            }
        }
        #endregion

        #region Transaction atomicity
        Context 'Transaction atomicity' {

            It 'Rolls back the delivery and all child rows when recipient persistence fails' {
                # The trigger fires on dfe_delivery_recipient so that by the time
                # the failure occurs, both the delivery and its archive row are
                # already inserted. This proves atomicity across all three tables,
                # not just the first insert.
                $rollbackCnpj = '12345678000270'

                Initialize-DFeIndex -Cnpj $rollbackCnpj | Out-Null

                $triggerSql = @'
CREATE TRIGGER trg_test_delivery_recipient_failure
BEFORE INSERT ON dfe_delivery_recipient
BEGIN
    SELECT RAISE(ABORT, 'forced recipient insert failure');
END;
'@

                Invoke-TestNonQuery -Cnpj $rollbackCnpj -Sql $triggerSql

                try {
                    $archive = New-TestArchive -TipoDFe 'NFe' -Content 'transaction rollback'

                    $params = @{
                        Cnpj        = $rollbackCnpj
                        PeriodStart = $Script:PeriodStart
                        PeriodEnd   = $Script:PeriodEnd
                        Archives    = @($archive)
                        To          = @('rollback@example.com')
                    }

                    Assert-TestErrorId -ErrorId 'DFeDeliveryCreateFailed' -ScriptBlock {
                        New-DFeDelivery @params
                    }
                } finally {
                    Invoke-TestNonQuery -Cnpj $rollbackCnpj -Sql @'
DROP TRIGGER IF EXISTS trg_test_delivery_recipient_failure;
'@
                }

                $deliveryCount = Get-TestScalar -Cnpj $rollbackCnpj -Sql @'
SELECT COUNT(*) FROM dfe_delivery;
'@

                $archiveCount = Get-TestScalar -Cnpj $rollbackCnpj -Sql @'
SELECT COUNT(*) FROM dfe_delivery_archive;
'@

                $recipientCount = Get-TestScalar -Cnpj $rollbackCnpj -Sql @'
SELECT COUNT(*) FROM dfe_delivery_recipient;
'@

                [int]$deliveryCount  | Should -Be 0
                [int]$archiveCount   | Should -Be 0
                [int]$recipientCount | Should -Be 0
            }
        }
        #endregion

        #region CNPJ isolation
        Context 'CNPJ isolation' {

            It 'Stores deliveries in the index belonging to the supplied CNPJ' {
                $otherCnpj = '12345678000351'

                Initialize-DFeIndex -Cnpj $otherCnpj | Out-Null

                $archive = New-TestArchive -TipoDFe 'NFe' -Content 'cnpj isolation'

                $params = @{
                    Cnpj        = $otherCnpj
                    PeriodStart = $Script:PeriodStart
                    PeriodEnd   = $Script:PeriodEnd
                    Archives    = @($archive)
                    To          = @('isolation@example.com')
                }

                $result = New-DFeDelivery @params

                $result.Cnpj | Should -Be $otherCnpj

                $otherCount = Get-TestScalar -Cnpj $otherCnpj -Parameters @{
                    '@delivery_id' = $result.DeliveryId
                } -Sql 'SELECT COUNT(*) FROM dfe_delivery WHERE delivery_id = @delivery_id;'

                $primaryCount = Get-TestScalar -Cnpj $Script:TestCnpj -Parameters @{
                    '@delivery_id' = $result.DeliveryId
                } -Sql 'SELECT COUNT(*) FROM dfe_delivery WHERE delivery_id = @delivery_id;'

                [int]$otherCount   | Should -Be 1
                [int]$primaryCount | Should -Be 0
            }
        }
        #endregion
    }
}
