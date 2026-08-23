<#
.SYNOPSIS
Extracts the ICP-Brasil titular identity from a certificate Subject DN.

.DESCRIPTION
Parses the CN attribute of an X.509 Subject Distinguished Name following
the ICP-Brasil encoding convention:
  Pessoa Juridica : 'RAZAO SOCIAL:CNPJ'
  Pessoa Fisica   : 'NOME TITULAR:CPF'
  Pessoa Fisica   : 'NOME TITULAR:CPF:DDMMYYYY'

The document type is inferred from the second CN segment:
  11 digits             -> CPF
  14 uppercase A-Z 0-9  -> CNPJ
  anything else         -> TipoDocumento = $null

The raw document value is always preserved when a document segment
exists, regardless of whether it can be classified.

When no CN attribute exists, all output properties are $null.

When CN exists without a document separator, the complete CN value is
returned as TitularNome and the document properties are $null.

Only the first CN attribute is considered.

.PARAMETER Subject
The Subject DN string from an X.509 certificate.

Accepts pipeline input.

.OUTPUTS
System.Management.Automation.PSCustomObject

Properties:
  TitularNome
  TitularDocumento
  TipoDocumento

.EXAMPLE
PS C:\> Resolve-IcpBrasilSubject
>> -Subject 'CN=ACME LTDA:12345678000195,O=ICP-Brasil,C=BR'

.EXAMPLE
PS C:\> Resolve-IcpBrasilSubject
>> -Subject 'CN=JOAO DA SILVA:12345678900,O=ICP-Brasil,C=BR'

.EXAMPLE
PS C:\> $cert.Subject | Resolve-IcpBrasilSubject

.NOTES
Pure function.

No filesystem, network, registry or external state is accessed.

Private dependencies:
  ConvertFrom-DnString
#>
function Resolve-IcpBrasilSubject {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string]$Subject
    )

    process {
        $cn = $null

        foreach ($pair in ConvertFrom-DnString -InputObject $Subject) {
            if ($pair.Key -eq 'CN') {
                $cn = $pair.Value
                break
            }
        }

        $result = [PSCustomObject]@{
            TitularNome      = $null
            TitularDocumento = $null
            TipoDocumento    = $null
        }

        if ($null -eq $cn) {
            return $result
        }

        $parts = $cn -split ':', 3

        $titularNome = $parts[0].Trim()

        if ($parts.Count -lt 2) {
            $result.TitularNome = $titularNome

            return $result
        }

        $rawDocument = $parts[1].Trim()

        $result.TitularNome = $titularNome
        $result.TitularDocumento = $rawDocument

        if ($rawDocument -match '^\d{11}$') {
            $result.TipoDocumento = 'CPF'

            return $result
        }

        if ($rawDocument -match '^(?-i:[A-Z0-9]{14})$') {
            $result.TipoDocumento = 'CNPJ'
        }

        return $result
    }
}
