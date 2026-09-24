<#
.SYNOPSIS
Persists a normalized NF-e/NFC-e fiscal projection in the company index.

.DESCRIPTION
Persists a PipeDFe.Fiscal.NFeDocument object into the normalized schema
introduced in index schema version 4.

The fiscal projection is always rebuilt atomically for the access key:

    dfe_nfe
      -> participants
      -> items
      -> item taxes
      -> document totals

Before any fiscal data is replaced, the function verifies that:

  - the source document exists in dfe_document;
  - the indexed model matches the fiscal projection model;
  - SourceSha256 matches the SHA-256 currently stored in dfe_document.

This prevents stale fiscal data extracted from a superseded XML from being
persisted against the current document identity.

The original XML remains the fiscal source of truth. dfe_nfe and its child
tables are normalized projections only.

All Decimal values are stored as invariant-culture TEXT. SQLite REAL is not
used for fiscal numeric values.

The complete replacement happens inside one SQLite transaction. Existing
projection rows are removed through ON DELETE CASCADE from dfe_nfe and rebuilt
from the supplied fiscal object.

This function does not change dfe_document.processing_status. Processing-state
integration belongs to the processing orchestration layer.

.PARAMETER Cnpj
14-character normalized CNPJ identifying the company index.

.PARAMETER FiscalData
Normalized fiscal object returned by Get-DFeNFeFiscalData.

.PARAMETER SourceSha256
SHA-256 of the XML from which FiscalData was extracted. It must match the
current dfe_document.sha256 for FiscalData.ChaveAcesso.

.PARAMETER ExtractedAt
Timestamp associated with the fiscal extraction. Defaults to UtcNow.

.OUTPUTS
None.

.NOTES
Private dependencies:
  Open-DFeIndexConnection
#>
function Save-DFeNFeFiscalData {
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
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$SourceSha256,

        [Parameter()]
        [System.DateTimeOffset]$ExtractedAt = [System.DateTimeOffset]::UtcNow
    )

    if ($FiscalData.PSObject.TypeNames -notcontains 'PipeDFe.Fiscal.NFeDocument') {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'FiscalData must be a PipeDFe.Fiscal.NFeDocument object.'
                ),
                'InvalidNFeFiscalDataType',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $FiscalData
            )
        )
    }

    # Contract validation intentionally distinguishes between a missing property
    # (schema/contract drift) and a property whose value is null (which may be a
    # valid representation for optional NF-e fields).
    $assertProperties = {
        param (
            [Parameter()]
            $Object,

            [Parameter(Mandatory)]
            [string[]]$Names,

            [Parameter(Mandatory)]
            [string]$Path
        )

        if ($null -eq $Object) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "FiscalData.$Path must not be null."
                    ),
                    'InvalidNFeFiscalDataStructure',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $FiscalData
                )
            )
        }

        foreach ($name in $Names) {
            if ($null -eq $Object.PSObject.Properties[$name]) {
                $PSCmdlet.ThrowTerminatingError(
                    [System.Management.Automation.ErrorRecord]::new(
                        [System.ArgumentException]::new(
                            "FiscalData.$Path is missing expected property '$name'."
                        ),
                        'InvalidNFeFiscalDataStructure',
                        [System.Management.Automation.ErrorCategory]::InvalidData,
                        $Object
                    )
                )
            }
        }
    }

    & $assertProperties $FiscalData @(
        'SchemaVersion'
        'Modelo'
        'ChaveAcesso'
        'Identificacao'
        'Emitente'
        'Destinatario'
        'Totais'
        'Itens'
    ) '<root>'

    if ([string]::IsNullOrWhiteSpace($FiscalData.ChaveAcesso) -or
        $FiscalData.ChaveAcesso -notmatch '^\d{44}$')
    {

        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'FiscalData.ChaveAcesso must contain exactly 44 digits.'
                ),
                'InvalidNFeFiscalAccessKey',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $FiscalData
            )
        )
    }

    $schemaVersion = 0

    if ($null -eq $FiscalData.SchemaVersion -or -not [int]::TryParse(
            [string]$FiscalData.SchemaVersion,
            [ref]$schemaVersion
        ) -or
        $schemaVersion -le 0
    ) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'FiscalData.SchemaVersion must be a positive integer.'
                ),
                'InvalidNFeFiscalSchemaVersion',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $FiscalData
            )
        )
    }

    if ($schemaVersion -ne 1) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.NotSupportedException]::new(
                    "FiscalData.SchemaVersion '$schemaVersion' " +
                    "is not supported. Supported version: 1."
                ),
                'UnsupportedNFeFiscalSchemaVersion',
                [System.Management.Automation.ErrorCategory]::NotImplemented,
                $FiscalData
            )
        )
    }

    $modelo = 0
    $validModelo = $true

    try {
        if ($null -eq $FiscalData.Modelo) {
            $validModelo = $false
        } else {
            # Supports both the numeric representation and ModeloDFe enum values.
            $modelo = [int]$FiscalData.Modelo
        }
    } catch {
        $validModelo = $false
    }

    if (-not $validModelo -or $modelo -notin @(55, 65)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    "FiscalData.Modelo must be NF-e (55) or NFC-e (65)."
                ),
                'InvalidNFeFiscalModel',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $FiscalData
            )
        )
    }

    # Validate the object shape before opening the database. Property existence
    # is validated even when a value itself is allowed to be null.
    & $assertProperties $FiscalData.Identificacao @(
        'CUF'
        'NaturezaOperacao'
        'Modelo'
        'Serie'
        'Numero'
        'DhEmi',
        'DhSaiEnt'
        'TipoOperacao'
        'IdDestino'
        'CodigoMunicipioFatoGerador'
        'TipoImpressao'
        'TipoEmissao'
        'Finalidade'
        'ConsumidorFinal'
        'IndicadorPresenca'
    ) 'Identificacao'

    & $assertProperties $FiscalData.Emitente @(
        'Cnpj'
        'Cpf'
        'RazaoSocial'
        'NomeFantasia'
        'IE'
        'IndIEDest'
        'CRT'
        'Email'
        'Endereco'
    ) 'Emitente'

    foreach ($participantDefinition in @(
            @{
                Path = 'Emitente'
                Data = $FiscalData.Emitente
            }
            @{
                Path = 'Destinatario'
                Data = $FiscalData.Destinatario
            }
        )
    ) {
        $participant = $participantDefinition.Data

        if ($null -eq $participant) {
            continue
        }

        & $assertProperties $participant @(
            'Cnpj'
            'Cpf'
            'RazaoSocial'
            'NomeFantasia'
            'IE'
            'IndIEDest',
            'CRT'
            'Email'
            'Endereco'
        ) $participantDefinition.Path

        if ($null -ne $participant.Endereco) {
            & $assertProperties $participant.Endereco @(
                'Logradouro'
                'Numero'
                'Complemento'
                'Bairro',
                'CodigoMunicipio'
                'Municipio'
                'UF'
                'CEP'
                'CodigoPais'
                'Pais'
                'Telefone'
            ) "$($participantDefinition.Path).Endereco"
        }
    }

    if ($null -ne $FiscalData.Totais) {
        & $assertProperties $FiscalData.Totais @(
            'VBC'
            'VICMS'
            'VICMSDeson'
            'VFCP'
            'VBCST'
            'VST'
            'VFCPST'
            'VFCPSTRet'
            'VProd'
            'VFrete'
            'VSeg'
            'VDesc'
            'VII'
            'VIPI',
            'VIPIDevol'
            'VPIS'
            'VCOFINS'
            'VOutro'
            'VNF'
            'VTotTrib'
            'IBSCBSTot'
            'RetTrib'
        ) 'Totais'

        if ($null -ne $FiscalData.Totais.IBSCBSTot) {
            & $assertProperties $FiscalData.Totais.IBSCBSTot @(
                'VBCIBSCbs'
                'VIBSUF'
                'VDifIBSUF'
                'VDevTribIBSUF'
                'VIBSMun'
                'VDifIBSMun'
                'VDevTribIBSMun'
                'VIBS'
                'VCredPres'
                'VCredPresCondSus'
                'VCBS'
                'VDifCBS'
                'VDevTribCBS'
                'VCredPresCBS'
                'VCredPresCondSusCBS'
            ) 'Totais.IBSCBSTot'
        }

        if ($null -ne $FiscalData.Totais.RetTrib) {
            & $assertProperties $FiscalData.Totais.RetTrib @(
                'VRetCSLL'
                'VBCIrrf'
                'VIrrf'
            ) 'Totais.RetTrib'
        }
    }

    # Validate item identity and nested contract before opening the database.
    $itemNumbers = @{}
    $items = @($FiscalData.Itens)

    if ($items.Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'FiscalData.Itens must contain at least one fiscal item.'
                ),
                'InvalidNFeFiscalItemCollection',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $FiscalData
            )
        )
    }

    foreach ($item in $items) {
        if ($null -eq $item) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'FiscalData.Itens must not contain null elements.'
                    ),
                    'InvalidNFeFiscalItem',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $FiscalData
                )
            )
        }

        & $assertProperties $item @('Numero', 'Produto', 'Tributos') 'Itens[]'

        & $assertProperties $item.Produto @(
            'Codigo'
            'EAN'
            'Descricao'
            'NCM'
            'CEST'
            'CFOP'
            'Unidade'
            'Quantidade'
            'ValorUnitario'
            'ValorProduto'
            'EANTrib'
            'UnidadeTrib'
            'QuantidadeTrib'
            'ValorUnitarioTrib'
            'ValorFrete'
            'ValorSeguro'
            'ValorDesconto'
            'OutrasDespesas'
            'IndTotal'
        ) "Itens[$($item.Numero)].Produto"

        if ($null -ne $item.Tributos) {
            & $assertProperties $item.Tributos @(
                'ICMS'
                'IPI'
                'PIS'
                'COFINS'
                'IBSCBS'
            ) "Itens[$($item.Numero)].Tributos"

            $taxContracts = @(
                @{
                    Name = 'ICMS'
                    Properties = @(
                        'Grupo'
                        'Orig'
                        'CST'
                        'CSOSN'
                        'ModBC'
                        'VBC'
                        'PRedBC'
                        'PICMS'
                        'VICMS'
                        'ModBCST'
                        'PMVAST'
                        'PRedBCST'
                        'VBCST',
                        'PICMSST'
                        'VICMSST'
                        'VICMSDeson'
                        'MotDesICMS'
                        'VBCFCP'
                        'PFCP'
                        'VFCP'
                        'VBCFCPST'
                        'PFCPST'
                        'VFCPST'
                    )
                }
                @{
                    Name = 'IPI'
                    Properties = @(
                        'Grupo'
                        'CEnq'
                        'CST'
                        'VBC'
                        'PIPI'
                        'QUnid'
                        'VUnid'
                        'VIPI'
                    )
                }
                @{
                    Name = 'PIS'
                    Properties = @(
                        'Grupo'
                        'CST'
                        'VBC'
                        'PPIS'
                        'QBCProd'
                        'VAliqProd'
                        'VPIS'
                    )
                }
                @{
                    Name = 'COFINS'
                    Properties = @(
                        'Grupo'
                        'CST'
                        'VBC'
                        'PCOFINS'
                        'QBCProd'
                        'VAliqProd'
                        'VCOFINS'
                    )
                }
                @{
                    Name = 'IBSCBS'
                    Properties = @(
                        'CST'
                        'CClassTrib'
                        'VBC'
                        'PIBSUF'
                        'VIBSUF'
                        'PIBSMun'
                        'VIBSMun'
                        'VIBS'
                        'PCBS'
                        'VCBS'
                    )
                }
            )

            foreach ($taxContract in $taxContracts) {
                $taxObject = $item.Tributos.($taxContract.Name)

                if ($null -ne $taxObject) {
                    & $assertProperties $taxObject $taxContract.Properties (
                        "Itens[$($item.Numero)].Tributos.$($taxContract.Name)"
                    )
                }
            }
        }

        $nItem = 0

        if ($null -eq $item.Numero -or
            -not [int]::TryParse([string]$item.Numero, [ref]$nItem) -or
            $nItem -le 0) {

            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'Every fiscal item must have a positive Numero.'
                    ),
                    'InvalidNFeFiscalItemNumber',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $item
                )
            )
        }

        if ($itemNumbers.ContainsKey($nItem)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "Duplicate fiscal item number '$nItem'."
                    ),
                    'DuplicateNFeFiscalItemNumber',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $item
                )
            )
        }

        $itemNumbers[$nItem] = $true
    }

    $connection  = $null
    $transaction = $null

    try {
        $connection  = Open-DFeIndexConnection -Cnpj $Cnpj
        $transaction = $connection.BeginTransaction()

        # Converts normalized values into SQLite parameter values.
        #
        # Decimal is deliberately serialized with InvariantCulture and stored
        # as TEXT to avoid binary floating-point representation.
        $toDbValue = {
            param ($Value)

            if ($null -eq $Value) {
                return [System.DBNull]::Value
            }

            # Keep already-normalized database nulls intact. This also makes the
            # conversion helper safe if a future caller explicitly supplies DBNull.
            if ($Value -is [System.DBNull]) {
                return $Value
            }

            if ($Value -is [decimal]) {
                return $Value.ToString(
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
            }

            if ($Value -is [System.DateTimeOffset]) {
                return $Value.ToUniversalTime().ToString('o')
            }

            [string]$Value
        }

        # Executes a parameterized non-query inside the current transaction.
        $executeNonQuery = {
            param (
                [Parameter(Mandatory)]
                [string]$Sql,

                [Parameter()]
                [hashtable]$Parameters = @{}
            )

            $cmd = $connection.CreateCommand()
            $cmd.Transaction = $transaction

            try {
                $cmd.CommandText = $Sql

                foreach ($name in $Parameters.Keys) {
                    $cmd.Parameters.AddWithValue(
                        $name,
                        (& $toDbValue $Parameters[$name])
                    ) | Out-Null
                }

                $cmd.ExecuteNonQuery() | Out-Null
            } finally {
                $cmd.Dispose()
            }
        }

        # Extracts a raw property value already validated by the structural
        # contract. Conversion to SQLite representation happens exactly once,
        # at the parameter-binding boundary in $executeNonQuery.
        #
        # Null optional objects therefore remain PowerShell $null here and are
        # converted to SQLite NULL by $toDbValue. Missing properties on a
        # non-null object are rejected as contract drift.
        $prop = {
            param (
                [Parameter()]
                $Object,

                [Parameter(Mandatory)]
                [string]$Name
            )

            if ($null -eq $Object) {
                return $null
            }

            $property = $Object.PSObject.Properties[$Name]

            if ($null -eq $property) {
                throw [System.InvalidOperationException]::new(
                    "Fiscal projection contract drift: property '$Name' was not found."
                )
            }

            $property.Value
        }

        # -----------------------------------------------------------------
        # Validate the indexed source while holding the same transaction
        # used for the replacement.
        # -----------------------------------------------------------------
        $sourceCmd = $connection.CreateCommand()
        $sourceCmd.Transaction = $transaction
        $sourceCmd.CommandText = @'
SELECT modelo, sha256
FROM dfe_document
WHERE chave_acesso = @chave;
'@

        $sourceCmd.Parameters.AddWithValue(
            '@chave',
            $FiscalData.ChaveAcesso
        ) | Out-Null

        $indexedModelo = $null
        $indexedSha256 = $null

        $reader = $sourceCmd.ExecuteReader()

        try {
            if ($reader.Read()) {
                $indexedModelo = [int]$reader['modelo']
                $indexedSha256 = [string]$reader['sha256']
            }
        } finally {
            $reader.Dispose()
            $sourceCmd.Dispose()
        }

        if ($null -eq $indexedModelo) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        "Document '$($FiscalData.ChaveAcesso)' is not indexed."
                    ),
                    'NFeFiscalSourceDocumentNotFound',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                    $FiscalData.ChaveAcesso
                )
            )
        }

        if ($indexedModelo -ne $modelo) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        "Indexed model '$indexedModelo' does not match fiscal " +
                        "projection model '$modelo' for access key " +
                        "'$($FiscalData.ChaveAcesso)'."
                    ),
                    'NFeFiscalSourceModelMismatch',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $FiscalData.ChaveAcesso
                )
            )
        }

        if (-not [string]::Equals($indexedSha256, $SourceSha256,
                [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        "Source SHA-256 does not match the currently indexed document " +
                        "for access key '$($FiscalData.ChaveAcesso)'."
                    ),
                    'NFeFiscalSourceHashMismatch',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $FiscalData.ChaveAcesso
                )
            )
        }

        # -----------------------------------------------------------------
        # Replace the projection.
        #
        # dfe_nfe is the fiscal aggregate root. Deleting it removes every
        # dependent fiscal row through ON DELETE CASCADE.
        # -----------------------------------------------------------------
        & $executeNonQuery @'
DELETE FROM dfe_nfe
WHERE chave_acesso = @chave;
'@ @{
            '@chave' = $FiscalData.ChaveAcesso
        }

        $identificacao = $FiscalData.Identificacao

        & $executeNonQuery @'
INSERT INTO dfe_nfe (
    chave_acesso,
    schema_version,
    source_sha256,
    extracted_at,
    modelo,
    uf_emissao,
    natureza_operacao,
    serie,
    numero,
    emitido_em,
    saida_entrada_em,
    tipo_operacao,
    destino,
    municipio_fato_gerador,
    tipo_impressao,
    tipo_emissao,
    finalidade,
    ind_consumidor_final,
    ind_presenca
) VALUES (
    @chave,
    @schema_version,
    @source_sha256,
    @extracted_at,
    @modelo,
    @uf_emissao,
    @natureza_operacao,
    @serie,
    @numero,
    @emitido_em,
    @saida_entrada_em,
    @tipo_operacao,
    @destino,
    @municipio_fato_gerador,
    @tipo_impressao,
    @tipo_emissao,
    @finalidade,
    @ind_consumidor_final,
    @ind_presenca
);
'@ @{
            '@chave'                  = $FiscalData.ChaveAcesso
            '@schema_version'         = $schemaVersion
            '@source_sha256'          = $SourceSha256.ToUpperInvariant()
            '@extracted_at'           = $ExtractedAt
            '@modelo'                 = $modelo
            '@uf_emissao'             = & $prop $identificacao 'CUF'
            '@natureza_operacao'      = & $prop $identificacao 'NaturezaOperacao'
            '@serie'                  = & $prop $identificacao 'Serie'
            '@numero'                 = & $prop $identificacao 'Numero'
            '@emitido_em'             = & $prop $identificacao 'DhEmi'
            '@saida_entrada_em'       = & $prop $identificacao 'DhSaiEnt'
            '@tipo_operacao'          = & $prop $identificacao 'TipoOperacao'
            '@destino'                = & $prop $identificacao 'IdDestino'
            '@municipio_fato_gerador' = & $prop $identificacao 'CodigoMunicipioFatoGerador'
            '@tipo_impressao'         = & $prop $identificacao 'TipoImpressao'
            '@tipo_emissao'           = & $prop $identificacao 'TipoEmissao'
            '@finalidade'             = & $prop $identificacao 'Finalidade'
            '@ind_consumidor_final'   = & $prop $identificacao 'ConsumidorFinal'
            '@ind_presenca'           = & $prop $identificacao 'IndicadorPresenca'
        }

        # -----------------------------------------------------------------
        # Participants
        # -----------------------------------------------------------------
        foreach ($participantDefinition in @(
                @{
                    Tipo = 'Emitente'
                    Data = $FiscalData.Emitente
                }
                @{
                    Tipo = 'Destinatario'
                    Data = $FiscalData.Destinatario
                }
            )
        ) {
            $participant = $participantDefinition.Data

            if ($null -eq $participant) {
                continue
            }

            $address = $participant.Endereco

            & $executeNonQuery @'
INSERT INTO dfe_nfe_participante (
    chave_acesso,
    tipo_participante,
    cnpj,
    cpf,
    razao_social,
    nome_fantasia,
    inscricao_estadual,
    ind_ie,
    regime_tributario,
    email,
    logradouro,
    numero,
    complemento,
    bairro,
    cod_municipio,
    municipio,
    uf,
    cep,
    cod_pais,
    pais,
    telefone
) VALUES (
    @chave,
    @tipo_participante,
    @cnpj,
    @cpf,
    @razao_social,
    @nome_fantasia,
    @inscricao_estadual,
    @ind_ie,
    @regime_tributario,
    @email,
    @logradouro,
    @numero,
    @complemento,
    @bairro,
    @cod_municipio,
    @municipio,
    @uf,
    @cep,
    @cod_pais,
    @pais,
    @telefone
);
'@ @{
                '@chave'              = $FiscalData.ChaveAcesso
                '@tipo_participante'  = $participantDefinition.Tipo
                '@cnpj'               = & $prop $participant 'Cnpj'
                '@cpf'                = & $prop $participant 'Cpf'
                '@razao_social'       = & $prop $participant 'RazaoSocial'
                '@nome_fantasia'      = & $prop $participant 'NomeFantasia'
                '@inscricao_estadual' = & $prop $participant 'IE'
                '@ind_ie'             = & $prop $participant 'IndIEDest'
                '@regime_tributario'  = & $prop $participant 'CRT'
                '@email'              = & $prop $participant 'Email'
                '@logradouro'         = & $prop $address 'Logradouro'
                '@numero'             = & $prop $address 'Numero'
                '@complemento'        = & $prop $address 'Complemento'
                '@bairro'             = & $prop $address 'Bairro'
                '@cod_municipio'      = & $prop $address 'CodigoMunicipio'
                '@municipio'          = & $prop $address 'Municipio'
                '@uf'                 = & $prop $address 'UF'
                '@cep'                = & $prop $address 'CEP'
                '@cod_pais'           = & $prop $address 'CodigoPais'
                '@pais'               = & $prop $address 'Pais'
                '@telefone'           = & $prop $address 'Telefone'
            }
        }

        # -----------------------------------------------------------------
        # Items and per-item taxes
        # -----------------------------------------------------------------
        foreach ($item in $items) {
            $nItem    = [int]$item.Numero
            $produto  = $item.Produto
            $tributos = $item.Tributos

            & $executeNonQuery @'
INSERT INTO dfe_nfe_item (
    chave_acesso,
    n_item,
    cod_produto,
    ean,
    descricao,
    ncm,
    cest,
    cfop,
    unidade,
    qte_comercial,
    vlr_unitario,
    vlr_produto,
    ean_tributavel,
    unidade_tributavel,
    qte_tributavel,
    vlr_unitario_tributavel,
    vlr_frete,
    vlr_seguro,
    vlr_desconto,
    vlr_outras_despesas,
    ind_compoe_total
) VALUES (
    @chave,
    @n_item,
    @cod_produto,
    @ean,
    @descricao,
    @ncm,
    @cest,
    @cfop,
    @unidade,
    @qte_comercial,
    @vlr_unitario,
    @vlr_produto,
    @ean_tributavel,
    @unidade_tributavel,
    @qte_tributavel,
    @vlr_unitario_tributavel,
    @vlr_frete,
    @vlr_seguro,
    @vlr_desconto,
    @vlr_outras_despesas,
    @ind_compoe_total
);
'@ @{
                '@chave'                   = $FiscalData.ChaveAcesso
                '@n_item'                  = $nItem
                '@cod_produto'             = & $prop $produto 'Codigo'
                '@ean'                     = & $prop $produto 'EAN'
                '@descricao'               = & $prop $produto 'Descricao'
                '@ncm'                     = & $prop $produto 'NCM'
                '@cest'                    = & $prop $produto 'CEST'
                '@cfop'                    = & $prop $produto 'CFOP'
                '@unidade'                 = & $prop $produto 'Unidade'
                '@qte_comercial'           = & $prop $produto 'Quantidade'
                '@vlr_unitario'            = & $prop $produto 'ValorUnitario'
                '@vlr_produto'             = & $prop $produto 'ValorProduto'
                '@ean_tributavel'          = & $prop $produto 'EANTrib'
                '@unidade_tributavel'      = & $prop $produto 'UnidadeTrib'
                '@qte_tributavel'          = & $prop $produto 'QuantidadeTrib'
                '@vlr_unitario_tributavel' = & $prop $produto 'ValorUnitarioTrib'
                '@vlr_frete'               = & $prop $produto 'ValorFrete'
                '@vlr_seguro'              = & $prop $produto 'ValorSeguro'
                '@vlr_desconto'            = & $prop $produto 'ValorDesconto'
                '@vlr_outras_despesas'     = & $prop $produto 'OutrasDespesas'
                '@ind_compoe_total'        = & $prop $produto 'IndTotal'
            }

            if ($null -ne $tributos -and $null -ne $tributos.ICMS) {
                $tax = $tributos.ICMS

                & $executeNonQuery @'
INSERT INTO dfe_nfe_item_icms (
    chave_acesso,
    n_item,
    grupo,
    origem,
    cst,
    csosn,
    modalidade_bc,
    vlr_bc,
    pct_reducao_bc,
    pct_icms,
    vlr_icms,
    modalidade_bc_st,
    pct_mva_st,
    pct_reducao_bc_st,
    vlr_bc_st,
    pct_icms_st,
    vlr_icms_st,
    vlr_icms_desonerado,
    motivo_desoneracao,
    vlr_bc_fcp,
    pct_fcp,
    vlr_fcp,
    vlr_bc_fcp_st,
    pct_fcp_st,
    vlr_fcp_st
) VALUES (
    @chave,
    @n_item,
    @grupo,
    @origem,
    @cst,
    @csosn,
    @modalidade_bc,
    @vlr_bc,
    @pct_reducao_bc,
    @pct_icms,
    @vlr_icms,
    @modalidade_bc_st,
    @pct_mva_st,
    @pct_reducao_bc_st,
    @vlr_bc_st,
    @pct_icms_st,
    @vlr_icms_st,
    @vlr_icms_desonerado,
    @motivo_desoneracao,
    @vlr_bc_fcp,
    @pct_fcp,
    @vlr_fcp,
    @vlr_bc_fcp_st,
    @pct_fcp_st,
    @vlr_fcp_st
);
'@ @{
                    '@chave'               = $FiscalData.ChaveAcesso
                    '@n_item'              = $nItem
                    '@grupo'               = & $prop $tax 'Grupo'
                    '@origem'              = & $prop $tax 'Orig'
                    '@cst'                 = & $prop $tax 'CST'
                    '@csosn'               = & $prop $tax 'CSOSN'
                    '@modalidade_bc'       = & $prop $tax 'ModBC'
                    '@vlr_bc'              = & $prop $tax 'VBC'
                    '@pct_reducao_bc'      = & $prop $tax 'PRedBC'
                    '@pct_icms'            = & $prop $tax 'PICMS'
                    '@vlr_icms'            = & $prop $tax 'VICMS'
                    '@modalidade_bc_st'    = & $prop $tax 'ModBCST'
                    '@pct_mva_st'          = & $prop $tax 'PMVAST'
                    '@pct_reducao_bc_st'   = & $prop $tax 'PRedBCST'
                    '@vlr_bc_st'           = & $prop $tax 'VBCST'
                    '@pct_icms_st'         = & $prop $tax 'PICMSST'
                    '@vlr_icms_st'         = & $prop $tax 'VICMSST'
                    '@vlr_icms_desonerado' = & $prop $tax 'VICMSDeson'
                    '@motivo_desoneracao'  = & $prop $tax 'MotDesICMS'
                    '@vlr_bc_fcp'          = & $prop $tax 'VBCFCP'
                    '@pct_fcp'             = & $prop $tax 'PFCP'
                    '@vlr_fcp'             = & $prop $tax 'VFCP'
                    '@vlr_bc_fcp_st'       = & $prop $tax 'VBCFCPST'
                    '@pct_fcp_st'          = & $prop $tax 'PFCPST'
                    '@vlr_fcp_st'          = & $prop $tax 'VFCPST'
                }
            }

            if ($null -ne $tributos -and $null -ne $tributos.IPI) {
                $tax = $tributos.IPI

                & $executeNonQuery @'
INSERT INTO dfe_nfe_item_ipi (
    chave_acesso,
    n_item,
    grupo,
    enquadramento,
    cst,
    vlr_bc,
    pct_ipi,
    qte_unidade,
    vlr_unidade,
    vlr_ipi
) VALUES (
    @chave,
    @n_item,
    @grupo,
    @enquadramento,
    @cst,
    @vlr_bc,
    @pct_ipi,
    @qte_unidade,
    @vlr_unidade,
    @vlr_ipi
);
'@ @{
                    '@chave'         = $FiscalData.ChaveAcesso
                    '@n_item'        = $nItem
                    '@grupo'         = & $prop $tax 'Grupo'
                    '@enquadramento' = & $prop $tax 'CEnq'
                    '@cst'           = & $prop $tax 'CST'
                    '@vlr_bc'        = & $prop $tax 'VBC'
                    '@pct_ipi'       = & $prop $tax 'PIPI'
                    '@qte_unidade'   = & $prop $tax 'QUnid'
                    '@vlr_unidade'   = & $prop $tax 'VUnid'
                    '@vlr_ipi'       = & $prop $tax 'VIPI'
                }
            }

            if ($null -ne $tributos -and $null -ne $tributos.PIS) {
                $tax = $tributos.PIS

                & $executeNonQuery @'
INSERT INTO dfe_nfe_item_pis (
    chave_acesso,
    n_item,
    grupo,
    cst,
    vlr_bc,
    pct_pis,
    qte_bc,
    vlr_aliquota_unidade,
    vlr_pis
) VALUES (
    @chave,
    @n_item,
    @grupo,
    @cst,
    @vlr_bc,
    @pct_pis,
    @qte_bc,
    @vlr_aliquota_unidade,
    @vlr_pis
);
'@ @{
                    '@chave'                = $FiscalData.ChaveAcesso
                    '@n_item'               = $nItem
                    '@grupo'                = & $prop $tax 'Grupo'
                    '@cst'                  = & $prop $tax 'CST'
                    '@vlr_bc'               = & $prop $tax 'VBC'
                    '@pct_pis'              = & $prop $tax 'PPIS'
                    '@qte_bc'               = & $prop $tax 'QBCProd'
                    '@vlr_aliquota_unidade' = & $prop $tax 'VAliqProd'
                    '@vlr_pis'              = & $prop $tax 'VPIS'
                }
            }

            if ($null -ne $tributos -and $null -ne $tributos.COFINS) {
                $tax = $tributos.COFINS

                & $executeNonQuery @'
INSERT INTO dfe_nfe_item_cofins (
    chave_acesso,
    n_item,
    grupo,
    cst,
    vlr_bc,
    pct_cofins,
    qte_bc,
    vlr_aliquota_unidade,
    vlr_cofins
) VALUES (
    @chave,
    @n_item,
    @grupo,
    @cst,
    @vlr_bc,
    @pct_cofins,
    @qte_bc,
    @vlr_aliquota_unidade,
    @vlr_cofins
);
'@ @{
                    '@chave'                = $FiscalData.ChaveAcesso
                    '@n_item'               = $nItem
                    '@grupo'                = & $prop $tax 'Grupo'
                    '@cst'                  = & $prop $tax 'CST'
                    '@vlr_bc'               = & $prop $tax 'VBC'
                    '@pct_cofins'           = & $prop $tax 'PCOFINS'
                    '@qte_bc'               = & $prop $tax 'QBCProd'
                    '@vlr_aliquota_unidade' = & $prop $tax 'VAliqProd'
                    '@vlr_cofins'           = & $prop $tax 'VCOFINS'
                }
            }

            if ($null -ne $tributos -and $null -ne $tributos.IBSCBS) {
                $tax = $tributos.IBSCBS

                & $executeNonQuery @'
INSERT INTO dfe_nfe_item_ibscbs (
    chave_acesso,
    n_item,
    cst,
    classificacao_tributaria,
    vlr_bc,
    pct_ibs_uf,
    vlr_ibs_uf,
    pct_ibs_municipio,
    vlr_ibs_municipio,
    vlr_ibs,
    pct_cbs,
    vlr_cbs
) VALUES (
    @chave,
    @n_item,
    @cst,
    @classificacao_tributaria,
    @vlr_bc,
    @pct_ibs_uf,
    @vlr_ibs_uf,
    @pct_ibs_municipio,
    @vlr_ibs_municipio,
    @vlr_ibs,
    @pct_cbs,
    @vlr_cbs
);
'@ @{
                    '@chave'                    = $FiscalData.ChaveAcesso
                    '@n_item'                   = $nItem
                    '@cst'                      = & $prop $tax 'CST'
                    '@classificacao_tributaria' = & $prop $tax 'CClassTrib'
                    '@vlr_bc'                   = & $prop $tax 'VBC'
                    '@pct_ibs_uf'               = & $prop $tax 'PIBSUF'
                    '@vlr_ibs_uf'               = & $prop $tax 'VIBSUF'
                    '@pct_ibs_municipio'        = & $prop $tax 'PIBSMun'
                    '@vlr_ibs_municipio'        = & $prop $tax 'VIBSMun'
                    '@vlr_ibs'                  = & $prop $tax 'VIBS'
                    '@pct_cbs'                  = & $prop $tax 'PCBS'
                    '@vlr_cbs'                  = & $prop $tax 'VCBS'
                }
            }
        }

        # -----------------------------------------------------------------
        # Totals
        # -----------------------------------------------------------------
        $totais = $FiscalData.Totais

        if ($null -ne $totais) {
            & $executeNonQuery @'
INSERT INTO dfe_nfe_total_icms (
    chave_acesso,
    vlr_bc_icms,
    vlr_icms,
    vlr_icms_desonerado,
    vlr_fcp,
    vlr_bc_st,
    vlr_st,
    vlr_fcp_st,
    vlr_fcp_st_retido,
    vlr_produtos,
    vlr_frete,
    vlr_seguro,
    vlr_desconto,
    vlr_ii,
    vlr_ipi,
    vlr_ipi_devolucao,
    vlr_pis,
    vlr_cofins,
    vlr_outras_despesas,
    vlr_nota,
    vlr_total_tributos
) VALUES (
    @chave,
    @vlr_bc_icms,
    @vlr_icms,
    @vlr_icms_desonerado,
    @vlr_fcp,
    @vlr_bc_st,
    @vlr_st,
    @vlr_fcp_st,
    @vlr_fcp_st_retido,
    @vlr_produtos,
    @vlr_frete,
    @vlr_seguro,
    @vlr_desconto,
    @vlr_ii,
    @vlr_ipi,
    @vlr_ipi_devolucao,
    @vlr_pis,
    @vlr_cofins,
    @vlr_outras_despesas,
    @vlr_nota,
    @vlr_total_tributos
);
'@ @{
                '@chave'              = $FiscalData.ChaveAcesso
                '@vlr_bc_icms'        = & $prop $totais 'VBC'
                '@vlr_icms'           = & $prop $totais 'VICMS'
                '@vlr_icms_desonerado'= & $prop $totais 'VICMSDeson'
                '@vlr_fcp'            = & $prop $totais 'VFCP'
                '@vlr_bc_st'          = & $prop $totais 'VBCST'
                '@vlr_st'             = & $prop $totais 'VST'
                '@vlr_fcp_st'         = & $prop $totais 'VFCPST'
                '@vlr_fcp_st_retido'  = & $prop $totais 'VFCPSTRet'
                '@vlr_produtos'       = & $prop $totais 'VProd'
                '@vlr_frete'          = & $prop $totais 'VFrete'
                '@vlr_seguro'         = & $prop $totais 'VSeg'
                '@vlr_desconto'       = & $prop $totais 'VDesc'
                '@vlr_ii'             = & $prop $totais 'VII'
                '@vlr_ipi'            = & $prop $totais 'VIPI'
                '@vlr_ipi_devolucao'  = & $prop $totais 'VIPIDevol'
                '@vlr_pis'            = & $prop $totais 'VPIS'
                '@vlr_cofins'         = & $prop $totais 'VCOFINS'
                '@vlr_outras_despesas'= & $prop $totais 'VOutro'
                '@vlr_nota'           = & $prop $totais 'VNF'
                '@vlr_total_tributos' = & $prop $totais 'VTotTrib'
            }

            if ($null -ne $totais.IBSCBSTot) {
                $ibs = $totais.IBSCBSTot

                & $executeNonQuery @'
INSERT INTO dfe_nfe_total_ibscbs (
    chave_acesso,
    vlr_bc,
    vlr_ibs_uf,
    vlr_diferimento_ibs_uf,
    vlr_devolucao_tributo_ibs_uf,
    vlr_ibs_municipio,
    vlr_diferimento_ibs_municipio,
    vlr_devolucao_tributo_ibs_municipio,
    vlr_ibs,
    vlr_credito_presumido_ibs,
    vlr_credito_presumido_cond_sus_ibs,
    vlr_cbs,
    vlr_diferimento_cbs,
    vlr_devolucao_tributo_cbs,
    vlr_credito_presumido_cbs,
    vlr_credito_presumido_cond_sus_cbs
) VALUES (
    @chave,
    @vlr_bc,
    @vlr_ibs_uf,
    @vlr_diferimento_ibs_uf,
    @vlr_devolucao_tributo_ibs_uf,
    @vlr_ibs_municipio,
    @vlr_diferimento_ibs_municipio,
    @vlr_devolucao_tributo_ibs_municipio,
    @vlr_ibs,
    @vlr_credito_presumido_ibs,
    @vlr_credito_presumido_cond_sus_ibs,
    @vlr_cbs,
    @vlr_diferimento_cbs,
    @vlr_devolucao_tributo_cbs,
    @vlr_credito_presumido_cbs,
    @vlr_credito_presumido_cond_sus_cbs
);
'@ @{
                    '@chave'                               = $FiscalData.ChaveAcesso
                    '@vlr_bc'                              = & $prop $ibs 'VBCIBSCbs'
                    '@vlr_ibs_uf'                          = & $prop $ibs 'VIBSUF'
                    '@vlr_diferimento_ibs_uf'              = & $prop $ibs 'VDifIBSUF'
                    '@vlr_devolucao_tributo_ibs_uf'        = & $prop $ibs 'VDevTribIBSUF'
                    '@vlr_ibs_municipio'                   = & $prop $ibs 'VIBSMun'
                    '@vlr_diferimento_ibs_municipio'       = & $prop $ibs 'VDifIBSMun'
                    '@vlr_devolucao_tributo_ibs_municipio' = & $prop $ibs 'VDevTribIBSMun'
                    '@vlr_ibs'                             = & $prop $ibs 'VIBS'
                    '@vlr_credito_presumido_ibs'           = & $prop $ibs 'VCredPres'
                    '@vlr_credito_presumido_cond_sus_ibs'  = & $prop $ibs 'VCredPresCondSus'
                    '@vlr_cbs'                             = & $prop $ibs 'VCBS'
                    '@vlr_diferimento_cbs'                 = & $prop $ibs 'VDifCBS'
                    '@vlr_devolucao_tributo_cbs'           = & $prop $ibs 'VDevTribCBS'
                    '@vlr_credito_presumido_cbs'           = & $prop $ibs 'VCredPresCBS'
                    '@vlr_credito_presumido_cond_sus_cbs'  = & $prop $ibs 'VCredPresCondSusCBS'
                }
            }

            if ($null -ne $totais.RetTrib) {
                $ret = $totais.RetTrib

                & $executeNonQuery @'
INSERT INTO dfe_nfe_total_rettrib (
    chave_acesso,
    vlr_csll_retido,
    vlr_bc_irrf,
    vlr_irrf
) VALUES (
    @chave,
    @vlr_csll_retido,
    @vlr_bc_irrf,
    @vlr_irrf
);
'@ @{
                    '@chave'           = $FiscalData.ChaveAcesso
                    '@vlr_csll_retido' = & $prop $ret 'VRetCSLL'
                    '@vlr_bc_irrf'     = & $prop $ret 'VBCIrrf'
                    '@vlr_irrf'        = & $prop $ret 'VIrrf'
                }
            }
        }

        $transaction.Commit()

    } catch {
        $caughtError = $_

        if ($null -ne $transaction) {
            try {
                $transaction.Rollback()
            } catch {
                Write-Debug -Message (
                    'Rollback failed after fiscal persistence error: {0}' -f
                    $_.Exception.Message
                )
            }
        }

        # Source-consistency errors are part of the public persistence contract
        # and keep their specific ErrorId for callers/orchestrators.
        if ($caughtError.FullyQualifiedErrorId -match '^NFeFiscalSource') {
            $PSCmdlet.ThrowTerminatingError($caughtError)
        }

        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $caughtError.Exception,
                'NFeFiscalDataSaveFailed',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $FiscalData.ChaveAcesso
            )
        )
    } finally {
        if ($null -ne $transaction) {
            $transaction.Dispose()
        }

        if ($null -ne $connection) {
            $connection.Dispose()
        }
    }
}
