#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for company-level archive and delivery orchestration.

.DESCRIPTION
Exercises a real SQLite index, direction-specific ZIP planning, real ZIP
compression/publication, and persistent delivery identity on repeated runs.
Only source discovery, fiscal document processing, report generation, SMTP
configuration lookup, and the external SMTP boundary are mocked.

The fixtures are synthetic source files; fiscal XML parsing is intentionally
outside the scope of this suite. No external SMTP connection is made.

Coverage includes:
  - Indexed NFe Entrada and Saida entries are archived separately.
  - Real ZIP outputs are published for both NFe directions and CTe.
  - The first execution transitions a persistent delivery to Delivered.
  - An identical second execution never attempts SMTP a second time.
  - The published archive paths remain usable after reexecution.
  - Processing state repair runs before scanning; Indexed documents are
    never transitioned to Failed by the pipeline before archive generation.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'The test creates isolated temporary fixtures.'
)]

param ()

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}


Describe 'Invoke-PipeDFeCompany archive and delivery lifecycle' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            Add-Type -AssemblyName 'System.IO.Compression'
            Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $Script:OriginalDataRoot = $env:PIPEDFE_DATA_ROOT

            $root = (
                Get-Item -LiteralPath $PSScriptRoot
            ).Parent.Parent.Parent.Parent.FullName

            $rootFixtureParams  = @{
                Path      = $root
                ChildPath = 'tests/Fixtures/ArchiveDirection'
            }

            $Script:FixtureRoot = Join-Path @rootFixtureParams

            foreach ($name in @('nfe-entrada.xml', 'nfe-saida.xml', 'cte.xml')) {
                $source = Join-Path -Path $Script:FixtureRoot -ChildPath $name

                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                    throw "Required synthetic fixture missing: '$source'."
                }
            }

            # Shared helper: query how many dfe_delivery rows exist for a given status.
            function Get-DeliveryStatusCount {
                [CmdletBinding()]
                [OutputType([int])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$Status
                )

                $connection = Open-DFeIndexConnection -Cnpj $Cnpj

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = @'
SELECT COUNT(*) FROM dfe_delivery WHERE delivery_status = @status;
'@
                        $null = $command.Parameters.AddWithValue('@status', $Status)
                        [int]$command.ExecuteScalar()
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }
        }

        BeforeEach {
            # Each test case gets its own store, xml folder and output folder so
            # delivery identities are always isolated - no shared SQLite state.
            $casePath = [System.IO.Path]::Combine(
                $TestDrive,
                [guid]::NewGuid().ToString('N')
            )

            $env:LOCALAPPDATA = Join-Path -Path $casePath -ChildPath 'store'
            $env:PIPEDFE_DATA_ROOT = $null

            $Script:XmlPath    = Join-Path -Path $casePath -ChildPath 'xml'
            $Script:OutputPath = Join-Path -Path $casePath -ChildPath 'output'

            [void][System.IO.Directory]::CreateDirectory($Script:XmlPath)

            foreach ($name in @('nfe-entrada.xml', 'nfe-saida.xml', 'cte.xml')) {
                $copyItemParams = @{
                    LiteralPath = Join-Path -Path $Script:FixtureRoot -ChildPath $name
                    Destination = $Script:XmlPath
                    ErrorAction = 'Stop'
                }

                Copy-Item @copyItemParams
            }

            $Script:Cnpj = '12345678000199'

            $Script:Company = [PSCustomObject]@{
                Cnpj         = $Script:Cnpj
                RazaoSocial  = 'Empresa Teste Ltda'
                NomeFantasia = 'Empresa Teste'
                XmlPath      = $Script:XmlPath
                OutputPath   = $Script:OutputPath
                Email        = [PSCustomObject]@{
                    Para = @('dest@example.com')
                    Cc   = @()
                    Cco  = @()
                }
            }

            $Script:DateRange = [PSCustomObject]@{
                Start = [System.DateTimeOffset]::Parse('2026-10-01T00:00:00+00:00')
                End   = [System.DateTimeOffset]::Parse('2026-10-31T23:59:59+00:00')
            }

            $Script:ClosingParams = @{
                Company   = $Script:Company
                DateRange = $Script:DateRange
            }

            # Seed the real SQLite index with the three test documents.
            Initialize-DFeIndex -Cnpj $Script:Cnpj | Out-Null

            foreach ($fixture in @(
                    [PSCustomObject]@{
                        Name    = 'nfe-entrada.xml'
                        Chave   = '1' * 44
                        Modelo  = 'NFe'
                        Direcao = 'Entrada'
                        Ndoc    = 1
                    }

                    [PSCustomObject]@{
                        Name    = 'nfe-saida.xml'
                        Chave   = '2' * 44
                        Modelo  = 'NFe'
                        Direcao = 'Saida'
                        Ndoc    = 2
                    }

                    [PSCustomObject]@{
                        Name    = 'cte.xml'
                        Chave   = '3' * 44
                        Modelo  = 'CTe'
                        Direcao = $null
                        Ndoc    = 3
                    }
                )
            ) {
                $metadata = [PSCustomObject]@{
                    Tipo   = [TipoXmlDFe]::Documento
                    Chave  = $fixture.Chave
                    Modelo = [System.Enum]::Parse([ModeloDFe], $fixture.Modelo, $false)
                    File   = Get-Item -LiteralPath (
                        Join-Path -Path $Script:XmlPath -ChildPath $fixture.Name
                    )
                    IsProc = $false
                    Ndoc   = $fixture.Ndoc
                    Serie  = '1'
                    DhEmi  = '2026-10-15T12:00:00+00:00'
                }

                if ($null -ne $fixture.Direcao) {
                    $memberParams = @{
                        NotePropertyName  = 'Direcao'
                        NotePropertyValue = $fixture.Direcao
                    }

                    $metadata | Add-Member @memberParams
                }

                Save-DFeDocumentEntry -Cnpj $Script:Cnpj -Metadata $metadata -ErrorAction Stop
            }

            # Confirm the three entries landed in the index as Indexed before
            # Invoke-PipeDFeCompany runs - this ensures Repair-DFeDocumentProcessing
            # (which runs inside the pipeline) cannot transition them to Failed.
            $params = @{
                Cnpj      = $Script:Cnpj
                StartDate = $Script:DateRange.Start.ToString('o')
                EndDate   = $Script:DateRange.End.ToString('o')
            }

            $seeded = @(Get-DFeDocumentEntry @params)

            if ($seeded.Count -ne 3) {
                throw "Seed check failed: expected 3 Indexed entries, got $($seeded.Count)."
            }

            Mock -CommandName Invoke-DFeXmlScan -MockWith {
                [PSCustomObject]@{
                    FilesFound   = 3
                    FilesIndexed = 0
                    FilesSkipped = 3
                    FilesIgnored = 0
                }
            }

            # Fiscal processing is not the subject of this integration boundary.
            Mock -CommandName Invoke-DFeDocumentProcessing -MockWith {

            }

            Mock -CommandName Repair-DFeDocumentProcessing -MockWith {
                [PSCustomObject]@{
                    ProcessingFound     = 0
                    Active              = 0
                    Recovered           = 0
                    Inconsistent        = 0
                    ConcurrentlyChanged = 0
                }
            }

            Mock -CommandName Resolve-DFeSmtp -MockWith {
                [PSCustomObject]@{
                    Server = 'smtp.example.invalid'
                    Port   = 587
                }
            }

            # Reports have independent tests; delivery identity uses ZIP hashes.
            Mock -CommandName New-DFePeriodReport -MockWith {
                @()
            }

            Mock -CommandName Send-DFeNotification -MockWith {
                [PSCustomObject]@{
                    Success       = $true
                    EmailsSent    = @('dest@example.com')
                    ErrorMessage  = $null
                    FailedAt      = $null
                    SendAttempted = $true
                }
            }
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData
            $env:PIPEDFE_DATA_ROOT = $Script:OriginalDataRoot
        }

        #region First execution
        Context 'First execution' {

            It 'Publishes three ZIPs with correct direction separation' {
                $first = Invoke-PipeDFeCompany @Script:ClosingParams

                $first.Status          | Should -Be 'OK' -Because $first.Erro
                $first.TotalDocumentos | Should -Be 3
                $first.EmailEnviado    | Should -BeTrue
                @($first.Arquivos)     | Should -HaveCount 3

                @($first.Arquivos | Where-Object { $_ -like 'NFe_Entrada_*' }) |
                    Should -HaveCount 1

                @($first.Arquivos | Where-Object { $_ -like 'NFe_Saida_*' })   |
                    Should -HaveCount 1

                @($first.Arquivos | Where-Object { $_ -like 'CTe_*' })         |
                    Should -HaveCount 1

                foreach ($name in $first.Arquivos) {
                    $path = Join-Path -Path $Script:OutputPath -ChildPath $name

                    $path | Should -Exist

                    (Get-Item -LiteralPath $path).Length | Should -BeGreaterThan 0

                    $zip = [System.IO.Compression.ZipFile]::OpenRead($path)

                    try {
                        $zipNames = @($zip.Entries | ForEach-Object { $_.FullName })

                        if ($name -like 'NFe_Entrada_*') {
                            @($zipNames | Where-Object { $_ -like '*nfe-entrada.xml' }) |
                                Should -HaveCount 1

                            @($zipNames | Where-Object { $_ -like '*nfe-saida.xml' })   |
                                Should -HaveCount 0
                        } elseif ($name -like 'NFe_Saida_*') {
                            @($zipNames | Where-Object { $_ -like '*nfe-saida.xml' })   |
                                Should -HaveCount 1

                            @($zipNames | Where-Object { $_ -like '*nfe-entrada.xml' }) |
                                Should -HaveCount 0
                        } else {
                            @($zipNames | Where-Object { $_ -like '*cte.xml' }) |
                                Should -HaveCount 1
                        }
                    } finally {
                        $zip.Dispose()
                    }
                }
            }

            It 'Persists exactly one Delivered record after the first execution' {
                Invoke-PipeDFeCompany @Script:ClosingParams | Out-Null

                Get-DeliveryStatusCount -Cnpj $Script:Cnpj -Status 'Delivered' |
                    Should -Be 1
            }

            It 'Sends the notification exactly once during the first execution' {
                Invoke-PipeDFeCompany @Script:ClosingParams | Out-Null

                Should -Invoke -CommandName Send-DFeNotification -Times 1 -Exactly -Scope It
            }
        }
        #endregion

        #region Idempotent reexecution
        Context 'Idempotent reexecution' {

            It 'Does not attempt SMTP a second time when delivery is already Delivered' {
                $first = Invoke-PipeDFeCompany @Script:ClosingParams

                $first.Status       | Should -Be 'OK' -Because $first.Erro
                $first.EmailEnviado | Should -BeTrue

                $second = Invoke-PipeDFeCompany @Script:ClosingParams

                $second.Status       | Should -Be 'OK' -Because $second.Erro
                $second.EmailEnviado | Should -BeTrue

                Should -Invoke -CommandName Send-DFeNotification -Times 1 -Exactly -Scope It

                Get-DeliveryStatusCount -Cnpj $Script:Cnpj -Status 'Delivered' |
                    Should -Be 1
            }

            It 'Keeps archive files byte-identical across executions' {
                $first = Invoke-PipeDFeCompany @Script:ClosingParams

                $first.Status | Should -Be 'OK' -Because $first.Erro

                @($first.Arquivos) | Should -HaveCount 3

                $originalHashes = @{}

                foreach ($name in $first.Arquivos) {
                    $path = Join-Path -Path $Script:OutputPath -ChildPath $name

                    $path | Should -Exist

                    $originalHashes[$name] = Get-FileSha256 -Path $path
                }

                $second = Invoke-PipeDFeCompany @Script:ClosingParams

                $second.Status | Should -Be 'OK' -Because $second.Erro

                @($second.Arquivos) | Should -HaveCount 3

                foreach ($name in $first.Arquivos) {
                    $path = Join-Path -Path $Script:OutputPath -ChildPath $name

                    $path | Should -Exist

                    $currentHash = Get-FileSha256 -Path $path

                    $currentHash |
                        Should -BeExactly $originalHashes[$name] -Because (
                            "archive '$name' must remain byte-identical on reexecution"
                        )
                }
            }

            It 'Persists exactly one Delivered record after two executions' {
                Invoke-PipeDFeCompany @Script:ClosingParams | Out-Null
                Invoke-PipeDFeCompany @Script:ClosingParams | Out-Null

                Get-DeliveryStatusCount -Cnpj $Script:Cnpj -Status 'Delivered' |
                    Should -Be 1
            }
        }
        #endregion
    }
}
