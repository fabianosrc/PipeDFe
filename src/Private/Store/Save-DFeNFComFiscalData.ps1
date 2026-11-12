<#
.SYNOPSIS
Atomically persists a normalized NFCom fiscal projection.

.DESCRIPTION
Validates fiscal identity and schema version, confirms the indexed SHA-256
against the supplied hash, then replaces the NFCom projection in a single
SQLite transaction. Leaves the original dfe_document row and processing
state unchanged. The XML is never re-read by this function.

Decimal values are stored as invariant-culture TEXT. Missing optional
values remain SQLite NULL. Replacement is atomic: a failure at any
insert point rolls back the entire operation.

.PARAMETER Cnpj
Normalized 14-character company CNPJ.

.PARAMETER FiscalData
NFCom fiscal projection as returned by Get-DFeNFComFiscalData.
PSTypeName must be PipeDFe.Fiscal.NFComDocument with SchemaVersion 1.

.PARAMETER SourceSha256
SHA-256 hex string of the indexed physical source file.
Must match the hash stored in dfe_document for this access key.

.PARAMETER ExtractedAt
UTC extraction timestamp. Defaults to the current UTC instant.

.OUTPUTS
None.

.EXAMPLE
PS C:\> $params = @{
    Cnpj         = '12345678000199'
    FiscalData   = $fiscalData
    SourceSha256 = $sha256
}

PS C:\> Save-DFeNFComFiscalData @params

.NOTES
Private dependencies:
  Open-DFeIndexConnection
#>
function Save-DFeNFComFiscalData {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^(?-i)[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$FiscalData,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$SourceSha256,

        [Parameter()]
        [System.DateTimeOffset]$ExtractedAt = [System.DateTimeOffset]::UtcNow
    )

    #region Input validation
    if ($FiscalData.PSObject.TypeNames -notcontains 'PipeDFe.Fiscal.NFComDocument') {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'FiscalData must be a PipeDFe.Fiscal.NFComDocument object.'
                ),
                'NFComFiscalDataInvalidType',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $FiscalData
            )
        )
    }

    if ($null -eq $FiscalData.SchemaVersion -or
        [string]$FiscalData.SchemaVersion -cne '1')
    {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.NotSupportedException]::new(
                    'NFCom fiscal schema version must be 1.'
                ),
                'NFComFiscalDataUnsupportedSchemaVersion',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $FiscalData.SchemaVersion
            )
        )
    }

    if ([int]$FiscalData.Modelo -ne 62) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'NFCom fiscal model must be 62.'
                ),
                'NFComFiscalDataInvalidModel',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $FiscalData.Modelo
            )
        )
    }

    $key = [string]$FiscalData.ChaveAcesso

    if ($key -notmatch '^[0-9]{44}$') {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'NFCom access key must be exactly 44 digits.'
                ),
                'NFComFiscalDataInvalidAccessKey',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $key
            )
        )
    }

    foreach ($required in @('Identificacao', 'Emitente', 'Itens')) {
        if ($null -eq $FiscalData.PSObject.Properties[$required] -or
            $null -eq $FiscalData.$required) {

            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "FiscalData is missing required property '$required'."
                    ),
                    'NFComFiscalDataMissingProperty',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $FiscalData
                )
            )
        }
    }

    $itemNumbers = [System.Collections.Generic.HashSet[int]]::new()

    foreach ($item in $FiscalData.Itens) {
        if ($null -eq $item -or $null -eq
            $item.Produto -or $null -eq $item.Tributos)
        {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'NFCom item structure is invalid: Produto and Tributos are required.'
                    ),
                    'NFComFiscalDataInvalidItem',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $item
                )
            )
        }

        $parsed = 0

        if (-not [int]::TryParse([string]$item.Numero, [ref]$parsed) -or
            $parsed -le 0 -or -not $itemNumbers.Add($parsed)
        ) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'NFCom item numbers must be positive integers and unique within the document.'
                    ),
                    'NFComFiscalDataInvalidItemNumber',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $item.Numero
                )
            )
        }
    }
    #endregion

    $normalizedHash = $SourceSha256.ToLowerInvariant()
    $extractedAtUtc = $ExtractedAt.ToUniversalTime().ToString('o')
    $invariant      = [System.Globalization.CultureInfo]::InvariantCulture

    # Safe property navigation - absent optional group or leaf returns $null,
    # which the insertRow helper converts to SQLite NULL.
    $readValue = {
        param (
            [Parameter()]
            [object]$Object,

            [Parameter()]
            [string]$Path
        )

        $current = $Object

        foreach ($part in $Path.Split('.')) {
            if ($null -eq $current) {
                return $null
            }

            $prop = $current.PSObject.Properties[$part]

            if ($null -eq $prop) {
                return $null
            }

            $current = $prop.Value
        }

        $current
    }

    $connection  = $null
    $transaction = $null

    try {
        $connection  = Open-DFeIndexConnection -Cnpj $Cnpj
        $transaction = $connection.BeginTransaction()

        # All table and column identifiers are hardcoded internal strings.
        # User data is bound exclusively via SQLite parameters.
        $insertRow = {
            param (
                [Parameter()]
                [string]$Table,

                [Parameter()]
                [System.Collections.IDictionary]$Data
            )

            $columns        = @($Data.Keys)
            $parameterNames = @(for ($i = 0; $i -lt $columns.Count; $i++) { '@p' + $i })

            $cmd = $connection.CreateCommand()
            $cmd.Transaction = $transaction

            try {
                $cmd.CommandText = 'INSERT INTO {0} ({1}) VALUES ({2});' -f (
                    $Table, ($columns -join ', '), ($parameterNames -join ', ')
                )

                for ($i = 0; $i -lt $columns.Count; $i++) {
                    $value = $Data[$columns[$i]]

                    if ($null -eq $value) {
                        $value = [System.DBNull]::Value
                    } elseif ($value -is [decimal]) {
                        $value = $value.ToString('G29', $invariant)
                    } elseif ($value -is [System.DateTimeOffset]) {
                        $value = $value.ToString('o')
                    } elseif ($value -isnot [int]) {
                        $value = [string]$value
                    }

                    $cmd.Parameters.AddWithValue($parameterNames[$i], $value) | Out-Null
                }

                $cmd.ExecuteNonQuery() | Out-Null
            } finally {
                $cmd.Dispose()
            }
        }

        # Verify that the indexed document matches the supplied model and hash
        # before modifying any projection data.
        $verifyCommand = $connection.CreateCommand()
        $verifyCommand.Transaction = $transaction

        try {
            $verifyCommand.CommandText = @'
SELECT modelo, sha256
FROM dfe_document
WHERE chave_acesso = @key;
'@

            $verifyCommand.Parameters.AddWithValue('@key', $key) | Out-Null

            $reader = $verifyCommand.ExecuteReader()

            try {
                if (-not $reader.Read()) {
                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.InvalidOperationException]::new(
                                "Indexed NFCom document not found for access key '$key'."
                            ),
                            'NFComDocumentNotIndexed',
                            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                            $key
                        )
                    )
                }

                $indexedModel = $reader.GetInt32(0)
                $indexedHash  = $reader.GetString(1)
            } finally {
                $reader.Dispose()
            }

            if ($indexedModel -ne 62 -or
                -not $indexedHash.Equals($normalizedHash,
                    [System.StringComparison]::OrdinalIgnoreCase)
            ) {

                $PSCmdlet.ThrowTerminatingError(
                    [System.Management.Automation.ErrorRecord]::new(
                        [System.IO.InvalidDataException]::new(
                            'Indexed NFCom model or source SHA-256 does not match the projection.'
                        ),
                        'NFComDocumentHashMismatch',
                        [System.Management.Automation.ErrorCategory]::InvalidData,
                        $key
                    )
                )
            }
        } finally {
            $verifyCommand.Dispose()
        }

        # CASCADE removes every child projection row; no old data survives replacement.
        $deleteCommand = $connection.CreateCommand()
        $deleteCommand.Transaction = $transaction

        try {
            $deleteCommand.CommandText = 'DELETE FROM dfe_nfcom WHERE chave_acesso = @key;'
            $deleteCommand.Parameters.AddWithValue('@key', $key) | Out-Null
            $deleteCommand.ExecuteNonQuery() | Out-Null
        } finally {
            $deleteCommand.Dispose()
        }

        $headerRow = [ordered]@{
            chave_acesso               = & $readValue $FiscalData 'ChaveAcesso'
            schema_version             = & $readValue $FiscalData 'SchemaVersion'
            source_sha256              = $normalizedHash
            extracted_at               = $extractedAtUtc
            modelo                     = & $readValue $FiscalData 'Modelo'
            uf_emissao                 = & $readValue $FiscalData 'Identificacao.CUF'
            ambiente                   = & $readValue $FiscalData 'Identificacao.Ambiente'
            serie                      = & $readValue $FiscalData 'Identificacao.Serie'
            numero                     = & $readValue $FiscalData 'Identificacao.Numero'
            codigo_numerico            = & $readValue $FiscalData 'Identificacao.CodigoNumerico'
            digito_verificador         = & $readValue $FiscalData 'Identificacao.DigitoVerificador'
            emitido_em                 = & $readValue $FiscalData 'Identificacao.DhEmi'
            tipo_emissao               = & $readValue $FiscalData 'Identificacao.TipoEmissao'
            municipio_fato_gerador     = & $readValue $FiscalData 'Identificacao.MunicipioFG'
            finalidade                 = & $readValue $FiscalData 'Identificacao.Finalidade'
            tipo_faturamento           = & $readValue $FiscalData 'Identificacao.TipoFaturamento'
            versao_processo            = & $readValue $FiscalData 'Identificacao.VersaoProcesso'
            assinante_codigo           = & $readValue $FiscalData 'Assinante.Codigo'
            assinante_tipo             = & $readValue $FiscalData 'Assinante.Tipo'
            assinante_tipo_servico     = & $readValue $FiscalData 'Assinante.TipoServico'
            assinante_contrato         = & $readValue $FiscalData 'Assinante.Contrato'
            assinante_contrato_inicio  = & $readValue $FiscalData 'Assinante.ContratoInicio'
            assinante_contrato_fim     = & $readValue $FiscalData 'Assinante.ContratoFim'
            assinante_terminal         = & $readValue $FiscalData 'Assinante.Terminal'
            assinante_uf_principal     = & $readValue $FiscalData 'Assinante.UFPrincipal'
            faturamento_competencia    = & $readValue $FiscalData 'Faturamento.Competencia'
            faturamento_vencimento     = & $readValue $FiscalData 'Faturamento.Vencimento'
            faturamento_periodo_inicio = & $readValue $FiscalData 'Faturamento.PeriodoInicio'
            faturamento_periodo_fim    = & $readValue $FiscalData 'Faturamento.PeriodoFim'
            faturamento_codigo_barras  = & $readValue $FiscalData 'Faturamento.CodigoBarras'
            protocolo_numero           = & $readValue $FiscalData 'Protocolo.Numero'
            protocolo_status           = & $readValue $FiscalData 'Protocolo.Status'
            protocolo_motivo           = & $readValue $FiscalData 'Protocolo.Motivo'
            protocolo_recebido_em      = & $readValue $FiscalData 'Protocolo.RecebidoEm'
        }

        & $insertRow 'dfe_nfcom' $headerRow

        foreach ($participantDef in @(
                [PSCustomObject]@{
                    Type = 'Emitente'
                    Data = $FiscalData.Emitente
                }
                [PSCustomObject]@{
                    Type = 'Destinatario'
                    Data = $FiscalData.Destinatario
                }
            )
        ) {
            $participant = $participantDef.Data

            if ($null -eq $participant) {
                continue
            }

            $participantRow = [ordered]@{
                chave_acesso               = & $readValue $FiscalData 'ChaveAcesso'
                tipo_participante          = $participantDef.Type
                cnpj                       = & $readValue $participant 'Cnpj'
                cpf                        = & $readValue $participant 'Cpf'
                razao_social               = & $readValue $participant 'RazaoSocial'
                nome_fantasia              = & $readValue $participant 'NomeFantasia'
                inscricao_estadual         = & $readValue $participant 'IE'
                regime_tributario          = & $readValue $participant 'CRT'
                indicador_ie_destinatario  = & $readValue $participant 'IndIEDest'
                email                      = & $readValue $participant 'Email'
                logradouro                 = & $readValue $participant 'Endereco.Logradouro'
                numero                     = & $readValue $participant 'Endereco.Numero'
                complemento                = & $readValue $participant 'Endereco.Complemento'
                bairro                     = & $readValue $participant 'Endereco.Bairro'
                codigo_municipio           = & $readValue $participant 'Endereco.CodMunicipio'
                municipio                  = & $readValue $participant 'Endereco.Municipio'
                uf                         = & $readValue $participant 'Endereco.UF'
                cep                        = & $readValue $participant 'Endereco.CEP'
                codigo_pais                = & $readValue $participant 'Endereco.CodPais'
                pais                       = & $readValue $participant 'Endereco.Pais'
                telefone                   = & $readValue $participant 'Endereco.Telefone'
                endereco_email             = & $readValue $participant 'Endereco.Email'
            }

            & $insertRow 'dfe_nfcom_participante' $participantRow
        }

        foreach ($item in $FiscalData.Itens) {
            $itemNumber = [int]$item.Numero

            $itemRow = [ordered]@{
                chave_acesso        = & $readValue $FiscalData 'ChaveAcesso'
                n_item              = $itemNumber
                cod_produto         = & $readValue $item 'Produto.Codigo'
                descricao           = & $readValue $item 'Produto.Descricao'
                classificacao       = & $readValue $item 'Produto.Classificacao'
                cfop                = & $readValue $item 'Produto.CFOP'
                unidade             = & $readValue $item 'Produto.Unidade'
                qte_faturada        = & $readValue $item 'Produto.Quantidade'
                vlr_item            = & $readValue $item 'Produto.ValorUnitario'
                vlr_produto         = & $readValue $item 'Produto.ValorProduto'
                vlr_desconto        = & $readValue $item 'Produto.Desconto'
                vlr_outras_despesas = & $readValue $item 'Produto.OutrasDespesas'
                ind_sem_cst         = & $readValue $item 'Tributos.IndSemCST'
                icms_grupo          = & $readValue $item 'Tributos.ICMS.Grupo'
                icms_cst            = & $readValue $item 'Tributos.ICMS.CST'
                icms_ind_sn         = & $readValue $item 'Tributos.ICMS.IndSN'
                icms_vbc            = & $readValue $item 'Tributos.ICMS.VBC'
                icms_picms          = & $readValue $item 'Tributos.ICMS.PICMS'
                icms_vicms          = & $readValue $item 'Tributos.ICMS.VICMS'
            }

            & $insertRow 'dfe_nfcom_item' $itemRow

            $tax = $item.Tributos.IBSCBS

            if ($null -ne $tax) {
                $ibsCbsRow = [ordered]@{
                    chave_acesso         = & $readValue $FiscalData 'ChaveAcesso'
                    n_item               = $itemNumber
                    cst                  = & $readValue $tax 'CST'
                    cclass_trib          = & $readValue $tax 'CClassTrib'
                    ind_doacao           = & $readValue $tax 'IndDoacao'
                    vbc                  = & $readValue $tax 'Valores.VBC'
                    vibs                 = & $readValue $tax 'Valores.VIBS'
                    ibsuf_pibsuf         = & $readValue $tax 'Valores.IBSUF.PIBSUF'
                    ibsuf_vibsuf         = & $readValue $tax 'Valores.IBSUF.VIBSUF'
                    ibsuf_pdif           = & $readValue $tax 'Valores.IBSUF.PDif'
                    ibsuf_vdif           = & $readValue $tax 'Valores.IBSUF.VDif'
                    ibsuf_vdevtrib       = & $readValue $tax 'Valores.IBSUF.VDevTrib'
                    ibsuf_predaliq       = & $readValue $tax 'Valores.IBSUF.PRedAliq'
                    ibsuf_paliqefet      = & $readValue $tax 'Valores.IBSUF.PAliqEfet'
                    ibsmun_pibsmun       = & $readValue $tax 'Valores.IBSMun.PIBSMun'
                    ibsmun_vibsmun       = & $readValue $tax 'Valores.IBSMun.VIBSMun'
                    ibsmun_pdif          = & $readValue $tax 'Valores.IBSMun.PDif'
                    ibsmun_vdif          = & $readValue $tax 'Valores.IBSMun.VDif'
                    ibsmun_vdevtrib      = & $readValue $tax 'Valores.IBSMun.VDevTrib'
                    ibsmun_predaliq      = & $readValue $tax 'Valores.IBSMun.PRedAliq'
                    ibsmun_paliqefet     = & $readValue $tax 'Valores.IBSMun.PAliqEfet'
                    cbs_pcbs             = & $readValue $tax 'Valores.CBS.PCBS'
                    cbs_vcbs             = & $readValue $tax 'Valores.CBS.VCBS'
                    cbs_pdif             = & $readValue $tax 'Valores.CBS.PDif'
                    cbs_vdif             = & $readValue $tax 'Valores.CBS.VDif'
                    cbs_vdevtrib         = & $readValue $tax 'Valores.CBS.VDevTrib'
                    cbs_predaliq         = & $readValue $tax 'Valores.CBS.PRedAliq'
                    cbs_paliqefet        = & $readValue $tax 'Valores.CBS.PAliqEfet'
                    regular_cst          = & $readValue $tax 'Valores.TribRegular.CSTReg'
                    regular_cclass_trib  = & $readValue $tax 'Valores.TribRegular.CClassTribReg'
                    regular_paliq_ibsuf  = & $readValue $tax 'Valores.TribRegular.PAliqEfetIBSUF'
                    regular_vtrib_ibsuf  = & $readValue $tax 'Valores.TribRegular.VTribIBSUF'
                    regular_paliq_ibsmun = & $readValue $tax 'Valores.TribRegular.PAliqEfetIBSMun'
                    regular_vtrib_ibsmun = & $readValue $tax 'Valores.TribRegular.VTribIBSMun'
                    regular_paliq_cbs    = & $readValue $tax 'Valores.TribRegular.PAliqEfetCBS'
                    regular_vtrib_cbs    = & $readValue $tax 'Valores.TribRegular.VTribCBS'
                    gov_paliq_ibsuf      = & $readValue $tax 'Valores.TribCompraGov.PAliqIBSUF'
                    gov_vtrib_ibsuf      = & $readValue $tax 'Valores.TribCompraGov.VTribIBSUF'
                    gov_paliq_ibsmun     = & $readValue $tax 'Valores.TribCompraGov.PAliqIBSMun'
                    gov_vtrib_ibsmun     = & $readValue $tax 'Valores.TribCompraGov.VTribIBSMun'
                    gov_paliq_cbs        = & $readValue $tax 'Valores.TribCompraGov.PAliqCBS'
                    gov_vtrib_cbs        = & $readValue $tax 'Valores.TribCompraGov.VTribCBS'
                }

                & $insertRow 'dfe_nfcom_item_ibscbs' $ibsCbsRow
            }
        }

        if ($null -ne $FiscalData.Totais) {
            $totaisRow = [ordered]@{
                chave_acesso           = & $readValue $FiscalData 'ChaveAcesso'
                vprod                  = & $readValue $FiscalData 'Totais.VProd'
                vbc                    = & $readValue $FiscalData 'Totais.VBC'
                vicms                  = & $readValue $FiscalData 'Totais.VICMS'
                vicms_deson            = & $readValue $FiscalData 'Totais.VICMSDeson'
                vfcp                   = & $readValue $FiscalData 'Totais.VFCP'
                vpis                   = & $readValue $FiscalData 'Totais.VPIS'
                vcofins                = & $readValue $FiscalData 'Totais.VCOFINS'
                vfust                  = & $readValue $FiscalData 'Totais.VFUST'
                vfunttel               = & $readValue $FiscalData 'Totais.VFUNTTEL'
                vdesc                  = & $readValue $FiscalData 'Totais.VDesc'
                voutro                 = & $readValue $FiscalData 'Totais.VOutro'
                vnf                    = & $readValue $FiscalData 'Totais.VNF'
                ret_vpis               = & $readValue $FiscalData 'Totais.RetTrib.VRetPIS'
                ret_vcofins            = & $readValue $FiscalData 'Totais.RetTrib.VRetCOFINS'
                ret_vcsll              = & $readValue $FiscalData 'Totais.RetTrib.VRetCSLL'
                ret_virrf              = & $readValue $FiscalData 'Totais.RetTrib.VIRRF'
                ibscbs_vbc             = & $readValue $FiscalData 'Totais.IBSCBSTot.VBCIBSCBS'
                ibscbs_vibsuf          = & $readValue $FiscalData 'Totais.IBSCBSTot.VIBSUF'
                ibscbs_vibsmun         = & $readValue $FiscalData 'Totais.IBSCBSTot.VIBSMun'
                ibscbs_vibs            = & $readValue $FiscalData 'Totais.IBSCBSTot.VIBS'
                ibscbs_vcbs            = & $readValue $FiscalData 'Totais.IBSCBSTot.VCBS'
                ibscbs_vdif_ibsuf      = & $readValue $FiscalData 'Totais.IBSCBSTot.VDifIBSUF'
                ibscbs_vdevtrib_ibsuf  = & $readValue $FiscalData 'Totais.IBSCBSTot.VDevTribIBSUF'
                ibscbs_vdif_ibsmun     = & $readValue $FiscalData 'Totais.IBSCBSTot.VDifIBSMun'
                ibscbs_vdevtrib_ibsmun = & $readValue $FiscalData 'Totais.IBSCBSTot.VDevTribIBSMun'
                ibscbs_vdif_cbs        = & $readValue $FiscalData 'Totais.IBSCBSTot.VDifCBS'
                ibscbs_vdevtrib_cbs    = & $readValue $FiscalData 'Totais.IBSCBSTot.VDevTribCBS'
                ibscbs_vibs_est_cred   = & $readValue $FiscalData 'Totais.IBSCBSTot.VIBSEstCred'
                ibscbs_vcbs_est_cred   = & $readValue $FiscalData 'Totais.IBSCBSTot.VCBSEstCred'
            }

            & $insertRow 'dfe_nfcom_total' $totaisRow
        }

        $transaction.Commit()
    } catch {
        $originalError = $_

        if ($null -ne $transaction) {
            try {
                $transaction.Rollback()
            } catch {
                # Rollback failure is silenced to preserve the original error.
                $null = $_
            }
        }

        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $originalError.Exception,
                'NFComFiscalDataSaveFailed',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $key
            )
        )
    } finally {
        if ($null -ne $transaction) {
            $transaction.Dispose()
        }

        $connection.Dispose()
    }
}
