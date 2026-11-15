<#
.SYNOPSIS
Persists a parsed NFS-e Nacional and its source identity.

.DESCRIPTION
Writes one row with a single atomic SQLite upsert. The national access key
and number are stored as text. Monetary amounts use invariant Decimal TEXT.
An identical hash retains the fiscal data, but can refresh the source path.

This function does not read the XML. The caller must supply the hash of the
exact bytes represented by the parsed projection.

.PARAMETER Cnpj
The company whose SQLite index owns the record.

.PARAMETER FiscalData
The projection returned by Get-DFeNFSeFiscalData.

.PARAMETER SourcePath
Absolute path to the XML represented by the projection.

.PARAMETER SourceSha256
SHA-256 of the XML represented by the projection.

.OUTPUTS
None.
#>
function Save-DFeNFSeFiscalData {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidatePattern('^(?-i)[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$FiscalData,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [ValidatePattern('\A[0-9A-Fa-f]{64}\z')]
        [string]$SourceSha256
    )

    $getValue = {
        param ($Record, [string]$Property)

        if ($null -ne $Record) {
            $propertyInfo = $Record.PSObject.Properties[$Property]
            if ($null -ne $propertyInfo) {
                $propertyInfo.Value
            }
        }
    }

    if ($FiscalData.PSTypeNames -notcontains 'PipeDFe.Fiscal.NFSeDocument' -or
        (& $getValue $FiscalData 'SchemaVersion') -ne 1 -or
        (& $getValue $FiscalData 'ChaveAcesso') -notmatch '\A[0-9]{50}\z' -or
        (& $getValue $FiscalData 'Numero') -notmatch '\A[1-9][0-9]{0,12}\z')
    {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'Invalid NFS-e Nacional fiscal projection.'
                ),
                'InvalidNFSeFiscalData',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $FiscalData
            )
        )
    }

    if (-not [System.IO.Path]::IsPathRooted($SourcePath)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'SourcePath must be an absolute filesystem path.'
                ),
                'InvalidNFSeSourcePath',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $SourcePath
            )
        )
    }

    $row = [ordered]@{
        chave_acesso                        = $FiscalData.ChaveAcesso
        numero                              = $FiscalData.Numero
        schema_version                      = [int]$FiscalData.SchemaVersion
        versao_leiaute                      = $FiscalData.VersaoLeiaute
        file_path                           = [System.IO.Path]::GetFullPath($SourcePath)
        source_sha256                       = $SourceSha256.ToLowerInvariant()
        extraido_em                         = [System.DateTimeOffset]::UtcNow
        gerado_em                           = $FiscalData.DhProcessamento
        dps_emitida_em                      = $FiscalData.DPS.DhEmissao
        competencia                         = $FiscalData.DPS.Competencia
        status                              = $FiscalData.Status
        municipio_incidencia                = $FiscalData.MunicipioIncidencia
        dps_id                              = $FiscalData.DPS.Id
        dps_numero                          = $FiscalData.DPS.Numero
        dps_serie                           = $FiscalData.DPS.Serie
        dps_ambiente                        = $FiscalData.DPS.Ambiente
        dps_municipio_emissao               = $FiscalData.DPS.MunicipioEmissao
        servico_codigo_tributacao_nacional  = $FiscalData.Servico.CodigoTributacaoNacional
        servico_codigo_tributacao_municipal = $FiscalData.Servico.CodigoTributacaoMunicipal
        servico_codigo_nbs                  = $FiscalData.Servico.CodigoNbs
        servico_descricao                   = $FiscalData.Servico.Descricao
        servico_municipio_prestacao         = $FiscalData.Servico.MunicipioPrestacao
        servico_pais_prestacao              = $FiscalData.Servico.PaisPrestacao
        issqn_tributacao                    = $FiscalData.ISSQN.Tributacao
        issqn_tipo_retencao                 = $FiscalData.ISSQN.TipoRetencao
        issqn_base_calculo                  = $FiscalData.ISSQN.BaseCalculo
        issqn_aliquota                      = $FiscalData.ISSQN.Aliquota
        valor_servico                       = $FiscalData.Totais.ValorServico
        valor_liquido                       = $FiscalData.Totais.ValorLiquido
        valor_issqn                         = $FiscalData.Totais.ValorISSQN
        valor_retencoes                     = $FiscalData.Totais.ValorTotalRetencoes
        valor_total_nf                      = & $getValue $FiscalData.IBSCBS 'ValorTotalNF'
        valor_ibs                           = & $getValue $FiscalData.IBSCBS 'ValorIBS'
        valor_cbs                           = & $getValue $FiscalData.IBSCBS 'ValorCBS'
    }

    $partyFields = [ordered]@{
        cnpj                = 'Cnpj'
        cpf                 = 'Cpf'
        nif                 = 'Nif'
        codigo_ausencia_nif = 'CodigoAusenciaNif'
        im                  = 'InscricaoMunicipal'
        nome                = 'Nome'
    }

    foreach ($role in @('emitente', 'prestador', 'tomador', 'intermediario')) {
        $party = & $getValue $FiscalData $role

        foreach ($field in $partyFields.GetEnumerator()) {
            $row["${role}_$($field.Key)"] = & $getValue $party $field.Value
        }
    }

    # All column identifiers come from the fixed names above; values are bound
    # via parameters, so there is no risk of SQL injection.
    $columns = @($row.Keys)

    $placeholders = foreach ($column in $columns) {
        "@$column"
    }

    # chave_acesso is the conflict target and is excluded from the SET clause.
    # file_path is always refreshed regardless of hash change.
    # All other columns are updated only when the source hash differs.
    $assignments = foreach ($column in $columns) {
        if ($column -eq 'file_path') {
            'file_path = excluded.file_path'
        } elseif ($column -ne 'chave_acesso') {
            (
                "$column = CASE WHEN dfe_nfse.source_sha256 <> excluded.source_sha256 " +
                "THEN excluded.$column ELSE dfe_nfse.$column END"
            )
        }
    }

    $connection = $null
    $command    = $null

    try {
        $connection = Open-DFeIndexConnection -Cnpj $Cnpj
        $command = $connection.CreateCommand()
        $assignmentSql = $assignments -join (',' + [System.Environment]::NewLine + '    ')
        $command.CommandText = @"
INSERT INTO dfe_nfse ($($columns -join ', '))
VALUES ($($placeholders -join ', '))
ON CONFLICT (chave_acesso) DO UPDATE SET
    $assignmentSql
WHERE dfe_nfse.source_sha256 <> excluded.source_sha256
   OR dfe_nfse.file_path <> excluded.file_path;
"@

        $invariant = [System.Globalization.CultureInfo]::InvariantCulture

        foreach ($column in $columns) {
            $value = $row[$column]
            if ($null -eq $value) {
                $value = [System.DBNull]::Value
            } elseif ($value -is [decimal]) {
                $value = $value.ToString('G29', $invariant)
            } elseif ($value -is [System.DateTimeOffset]) {
                $value = $value.ToUniversalTime().ToString('o', $invariant)
            }

            $null = $command.Parameters.AddWithValue("@$column", $value)
        }

        $null = $command.ExecuteNonQuery()
    } catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                'NFSeFiscalDataSaveFailed',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $FiscalData.ChaveAcesso
            )
        )
    } finally {
        if ($null -ne $command) {
            $command.Dispose()
        }

        if ($null -ne $connection) {
            $connection.Dispose()
        }
    }
}
