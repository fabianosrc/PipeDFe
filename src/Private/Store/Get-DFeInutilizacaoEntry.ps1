<#
.SYNOPSIS
Reads inutilizacao entries from the index for a given CNPJ.

.DESCRIPTION
Queries dfe_inutilizacao with optional filters for Modelo and Serie.
Returns no output when no records match. An empty result is not an error.

.PARAMETER Cnpj
14-digit normalized CNPJ identifying the company index.

.PARAMETER Modelo
Optional model filter.

.PARAMETER Serie
Optional serie filter.

.OUTPUTS
System.Management.Automation.PSCustomObject

Each object contains:
    [string] id_inut
    [int]    modelo
    [string] serie
    [int]    nnf_ini
    [int]    nnf_fin
    [string] file_path
    [string] sha256
    [string] indexed_at

.EXAMPLE
PS C:\> Get-DFeInutilizacaoEntry -Cnpj '12345678000199'
>> -Modelo ([ModeloDFe]::NFe) -Serie '001'

.NOTES
Private dependencies:
  Get-StorePath
  Open-SqliteConnection
#>
function Get-DFeInutilizacaoEntry {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter()]
        [ModeloDFe]$Modelo,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Serie
    )

    process {
        $databasePath = Get-StorePath -Scope 'Index' -Cnpj $Cnpj

        $connection = $null
        $command    = $null
        $reader     = $null

        try {
            $connection = Open-SqliteConnection -Path $databasePath
            $command    = $connection.CreateCommand()

            $conditions = [System.Collections.Generic.List[string]]::new()

            $conditions.Add('1 = 1')

            if ($PSBoundParameters.ContainsKey('Modelo')) {
                $conditions.Add('modelo = @modelo')

                $parameter = $command.Parameters.Add('@modelo', [System.Data.DbType]::Int32)
                $parameter.Value = [int]$Modelo
            }

            if ($PSBoundParameters.ContainsKey('Serie')) {
                $conditions.Add('serie = @serie')

                $parameter = $command.Parameters.Add('@serie', [System.Data.DbType]::String)
                $parameter.Value = $Serie
            }

            $command.CommandText = @"
SELECT id_inut, modelo, serie, nnf_ini, nnf_fin, file_path, sha256, indexed_at
FROM dfe_inutilizacao
WHERE $($conditions -join ' AND ')
ORDER BY modelo ASC, serie ASC, nnf_ini ASC;
"@

            $reader = $command.ExecuteReader()

            while ($reader.Read()) {
                [PSCustomObject]@{
                    id_inut    = $reader.GetString(0)
                    modelo     = $reader.GetInt32(1)
                    serie      = $reader.GetString(2)
                    nnf_ini    = $reader.GetInt32(3)
                    nnf_fin    = $reader.GetInt32(4)
                    file_path  = $reader.GetString(5)
                    sha256     = $reader.GetString(6)
                    indexed_at = $reader.GetString(7)
                }
            }
        } catch {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    $_.Exception,
                    'InutilizacaoEntryReadFailed',
                    [System.Management.Automation.ErrorCategory]::ReadError,
                    $databasePath
                )
            )
        } finally {
            if ($null -ne $reader) {
                $reader.Dispose()
            }

            if ($null -ne $command) {
                $command.Dispose()
            }

            if ($null -ne $connection) {
                $connection.Dispose()
            }
        }
    }
}
