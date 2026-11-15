#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Get-DFeNFSeEntry

.DESCRIPTION
Coverage includes:
  - Empty result when the company has no NFS-e records
  - Filtering by gerado_em, not dps_emitida_em or competencia
  - Inclusive UTC bounds (exact boundary instants included, adjacent excluded)
  - Offset-bearing date strings normalized to UTC before comparison
  - Isolation between different CNPJs (separate SQLite databases)
  - One-sided and unbounded queries
  - Reversed bounds rejected before the database is opened
  - Date parser error contract preserved (UnsupportedDateFormat)
#>

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

Describe 'Get-DFeNFSeEntry' -Tag 'Integration' {

    InModuleScope PipeDFe {

        #region Setup
        BeforeAll {

            $script:PreviousLocalAppData = $env:LOCALAPPDATA

            $env:LOCALAPPDATA = $TestDrive

            $script:Cnpj      = '12345678000199'
            $script:OtherCnpj = '12345678000188'

            $script:Start  = '2026-11-01T00:00:00.0000000+00:00'
            $script:End    = '2026-11-30T23:59:59.9999999+00:00'
            $script:Before = '2026-10-31T23:59:59.9999999+00:00'
            $script:After  = '2026-12-01T00:00:00.0000000+00:00'

            function Add-NFSeQueryFixture {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter()]
                    [string]$Cnpj,

                    [Parameter()]
                    [string]$Key,

                    [Parameter()]
                    [string]$Generated,

                    [Parameter()]
                    [string]$DpsIssued,

                    [Parameter()]
                    [string]$Competence,

                    [Parameter()]
                    [string]$Number = '9876543210123'
                )

                $connection = Open-DFeIndexConnection -Cnpj $Cnpj

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = @'
INSERT INTO dfe_nfse (
    chave_acesso,
    numero,
    schema_version,
    versao_leiaute,
    file_path,
    source_sha256,
    extraido_em,
    gerado_em,
    dps_emitida_em,
    competencia,
    valor_servico,
    valor_liquido
) VALUES (
    @key,
    @number,
    1,
    '1.01',
    '/tmp/nfse.xml',
    @hash,
    '2026-11-15T00:00:00.0000000+00:00',
    @generated,
    @issued,
    @competence,
    '100.00',
    '98.00'
);
'@
                        foreach ($pair in
                            @(
                                @('@key',       $Key),
                                @('@number',    $Number),
                                @('@hash',      ('a' * 64)),
                                @('@generated', $Generated),
                                @('@issued',    $DpsIssued),
                                @('@competence',$Competence)
                            )
                        ) {
                            $null = $command.Parameters.AddWithValue($pair[0], $pair[1])
                        }

                        $null = $command.ExecuteNonQuery()
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }
        }

        AfterAll {

            $env:LOCALAPPDATA = $script:PreviousLocalAppData
        }

        BeforeEach {

            foreach ($cnpj in @($script:Cnpj, $script:OtherCnpj)) {

                $connection = Open-DFeIndexConnection -Cnpj $cnpj

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = 'DELETE FROM dfe_nfse;'
                        $null = $command.ExecuteNonQuery()
                    } finally {
                        $command.Dispose()
                    }
                } finally { $connection.Dispose() }
            }
        }
        #endregion

        #region Query behavior
        It 'Returns no output for a company with no NFS-e' {
            Get-DFeNFSeEntry -Cnpj $script:Cnpj | Should -HaveCount 0
        }

        It 'Uses NFS-e generation, not DPS issuance or competence, for the month' {
            # Key 1: gerado_em inside range; dps_emitida_em and competencia outside
            $fixtureParams = @{
                Cnpj       = $script:Cnpj
                Key        = '1' * 50
                Generated  = '2026-11-01T03:05:00.0000000+00:00'
                DpsIssued  = '2026-10-31T23:58:00.0000000+00:00'
                Competence = '2026-10-01'
            }

            Add-NFSeQueryFixture @fixtureParams

            # Key 2: gerado_em outside range; dps_emitida_em and competencia inside
            $fixtureParams = @{
                Cnpj       = $script:Cnpj
                Key        = '2' * 50
                Generated  = '2026-12-01T00:00:00.0000000+00:00'
                DpsIssued  = '2026-11-30T20:00:00.0000000+00:00'
                Competence = '2026-11-01'
            }

            Add-NFSeQueryFixture @fixtureParams

            $queryParams = @{
                Cnpj      = $script:Cnpj
                StartDate = $script:Start
                EndDate   = $script:End
            }

            $rows = @(Get-DFeNFSeEntry @queryParams)

            $rows                 | Should -HaveCount 1
            $rows[0].chave_acesso | Should -BeExactly ('1' * 50)
            $rows[0].numero       | Should -BeExactly '9876543210123'
            $rows[0].competencia  | Should -BeExactly '2026-10-01'
        }

        It 'Includes both exact UTC bounds and excludes adjacent instants' {
            foreach ($fixture in
                @(
                    @{
                        Key  = '1' * 50
                        Date = $script:Before
                    }
                    @{
                        Key  = '2' * 50
                        Date = $script:Start
                    }
                    @{
                        Key  = '3' * 50
                        Date = $script:End
                    }
                    @{
                        Key  = '4' * 50
                        Date = $script:After
                    }
                )
            ) {
                $fixtureParams = @{
                    Cnpj       = $script:Cnpj
                    Key        = $fixture.Key
                    Generated  = $fixture.Date
                    DpsIssued  = $fixture.Date
                    Competence = '2026-11-01'
                }

                Add-NFSeQueryFixture @fixtureParams
            }

            $queryParams = @{
                Cnpj      = $script:Cnpj
                StartDate = $script:Start
                EndDate   = $script:End
            }

            $rows = @(Get-DFeNFSeEntry @queryParams)

            $rows                 | Should -HaveCount 2
            $rows[0].chave_acesso | Should -BeExactly ('2' * 50)
            $rows[1].chave_acesso | Should -BeExactly ('3' * 50)
        }

        It 'Normalizes offset-bearing bounds to UTC' {
            $fixtureParams = @{
                Cnpj       = $script:Cnpj
                Key        = '1' * 50
                Generated  = $script:Start
                DpsIssued  = $script:Start
                Competence = '2026-11-01'
            }

            Add-NFSeQueryFixture @fixtureParams

            # 2026-10-31T21:00:00-03:00 == 2026-11-01T00:00:00+00:00 == $script:Start
            $queryParams = @{
                Cnpj      = $script:Cnpj
                StartDate = '2026-10-31T21:00:00-03:00'
                EndDate   = '2026-10-31T21:00:00-03:00'
            }

            Get-DFeNFSeEntry @queryParams | Should -HaveCount 1
        }

        It 'Does not return records from another company' {
            $fixtureParams = @{
                Cnpj       = $script:OtherCnpj
                Key        = '1' * 50
                Generated  = $script:Start
                DpsIssued  = $script:Start
                Competence = '2026-11-01'
            }

            Add-NFSeQueryFixture @fixtureParams

            Get-DFeNFSeEntry -Cnpj $script:Cnpj      | Should -HaveCount 0
            Get-DFeNFSeEntry -Cnpj $script:OtherCnpj | Should -HaveCount 1
        }

        It 'Supports unbounded and one-sided queries' {
            $fixtureParams = @{
                Cnpj       = $script:Cnpj
                Key        = '1' * 50
                Generated  = $script:Before
                DpsIssued  = $script:Before
                Competence = '2026-10-01'
            }

            Add-NFSeQueryFixture @fixtureParams

            $fixtureParams = @{
                Cnpj       = $script:Cnpj
                Key        = '2' * 50
                Generated  = $script:After
                DpsIssued  = $script:After
                Competence = '2026-12-01'
            }

            Add-NFSeQueryFixture @fixtureParams

            Get-DFeNFSeEntry -Cnpj $script:Cnpj                          | Should -HaveCount 2
            Get-DFeNFSeEntry -Cnpj $script:Cnpj -StartDate $script:Start | Should -HaveCount 1
            Get-DFeNFSeEntry -Cnpj $script:Cnpj -EndDate   $script:End   | Should -HaveCount 1
        }
        #endregion

        #region Parameter validation
        It 'Rejects reversed bounds before opening the database' {
            $queryParams = @{
                Cnpj      = $script:Cnpj
                StartDate = $script:After
                EndDate   = $script:Before
            }

            { Get-DFeNFSeEntry @queryParams } |
                Should -Throw -ErrorId 'InvalidNFSeDateRange*'
        }

        It 'Preserves the existing date parser error contract' {
            { Get-DFeNFSeEntry -Cnpj $script:Cnpj -StartDate 'not-a-date' } |
                Should -Throw -ErrorId 'UnsupportedDateFormat*'
        }
        #endregion
    }
}
