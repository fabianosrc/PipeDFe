<#
.SYNOPSIS
Reads evento entries from the index for a given CNPJ and parent document key.

.DESCRIPTION
Queries dfe_evento filtered by ChavePai. ChavePai is always required —
an evento has no meaning without its parent document.

When -EventoTipo is omitted, all evento types for the parent are returned.
Returns no output when no records match. An empty result is not an error.

.PARAMETER Cnpj
14-digit normalized CNPJ identifying the company index.

.PARAMETER ChavePai
44-character chave de acesso of the parent document.

.PARAMETER EventoTipo
Optional evento type filter.

.OUTPUTS
System.Management.Automation.PSCustomObject

Each object contains:
    [string] chave_pai
    [string] file_path
    [string] evento_tipo
    [string] dh_emi
    [string] sha256
    [string] indexed_at

.EXAMPLE
PS C:\> Get-DFeEventoEntry -Cnpj '12345678000199' -ChavePai ('1' * 44)

.NOTES
Private dependencies:
  Get-StorePath
  Open-SqliteConnection
#>
function Get-DFeEventoEntry {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^\d{44}$')]
        [string]$ChavePai,

        [Parameter()]
        [DFeEvento]$EventoTipo
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
            $conditions.Add('chave_pai = @chave_pai')

            $parameter = $command.Parameters.Add('@chave_pai', [System.Data.DbType]::String)
            $parameter.Value = $ChavePai

            if ($PSBoundParameters.ContainsKey('EventoTipo')) {
                $conditions.Add('evento_tipo = @evento_tipo')

                $parameter = $command.Parameters.Add('@evento_tipo', [System.Data.DbType]::String)
                $parameter.Value = $EventoTipo.ToString()
            }

            $command.CommandText = @"
SELECT chave_pai, file_path, evento_tipo, dh_emi, sha256, indexed_at
FROM dfe_evento
WHERE $($conditions -join ' AND ')
ORDER BY dh_emi ASC;
"@

            $reader = $command.ExecuteReader()

            while ($reader.Read()) {
                [PSCustomObject]@{
                    chave_pai   = $reader.GetString(0)
                    file_path   = $reader.GetString(1)
                    evento_tipo = if ($reader.IsDBNull(2)) { $null } else { $reader.GetString(2) }
                    dh_emi      = if ($reader.IsDBNull(3)) { $null } else { $reader.GetString(3) }
                    sha256      = $reader.GetString(4)
                    indexed_at  = $reader.GetString(5)
                }
            }
        } catch {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    $_.Exception,
                    'EventoEntryReadFailed',
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
