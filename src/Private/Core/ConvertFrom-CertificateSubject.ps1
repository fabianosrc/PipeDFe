<#
.SYNOPSIS
Parses an X.509 certificate Subject DN into structured objects.

.DESCRIPTION
Converts a Distinguished Name string in RFC 4514 format into structured
PSCustomObject instances, one per attribute found. Each object exposes a
fixed set of properties for consistent programmatic consumption.

Supports quoted values, backslash escaping, hex escapes (\xx) and both
comma and plus separators per RFC 4514.

When -Strict is specified, throws InvalidData instead of emitting warnings
for invalid components or empty output.

.PARAMETER Subject
The DN string to parse. Accepts pipeline input.

.PARAMETER Strict
Throws InvalidData for invalid components or when no valid attribute is found.

.OUTPUTS
System.Management.Automation.PSCustomObject

Attribute   [string]   Attribute abbreviation in uppercase (e.g. CN, OU).
Description [string]   Portuguese human-readable label.
Values      [string[]] All values for that attribute.

.EXAMPLE
PS C:\> ConvertFrom-CertificateSubject -Subject 'CN=ACME IND,OU=IT,O=ACME,C=BR'

.EXAMPLE
PS C:\> $cert.Subject | ConvertFrom-CertificateSubject |
>> Where-Object Attribute -EQ 'CN'

.NOTES
Pure function - no I/O, no side effects.

Private dependencies:
  ConvertFrom-DnString
  $Script:DnAttributeMap
#>
function ConvertFrom-CertificateSubject {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string]$Subject,

        [Parameter()]
        [switch]$Strict
    )

    process {
        $grouped = [System.Collections.Specialized.OrderedDictionary]::new()

        foreach ($pair in (ConvertFrom-DnString -InputObject $Subject)) {
            if ([string]::IsNullOrWhiteSpace($pair.Key)) {
                $message = 'Componente DN invalido: chave vazia.'

                if ($Strict) {
                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.FormatException]::new($message),
                            'InvalidDnComponent',
                            [System.Management.Automation.ErrorCategory]::InvalidData,
                            $Subject
                        )
                    )
                }

                Write-Warning -Message $message
                continue
            }

            if (-not $grouped.Contains($pair.Key)) {
                $grouped[$pair.Key] = [System.Collections.Generic.List[string]]::new()
            }

            $grouped[$pair.Key].Add($pair.Value)
        }

        if ($Strict -and $grouped.Count -eq 0) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.FormatException]::new(
                        "Nenhum componente DN valido foi encontrado em: '$Subject'."
                    ),
                    'EmptyDnSubject',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $Subject
                )
            )
        }

        foreach ($entry in $grouped.GetEnumerator()) {
            $attribute = $entry.Key

            $description = if ($Script:DnAttributeMap.ContainsKey($attribute)) {
                $Script:DnAttributeMap[$attribute]
            } else {
                $attribute
            }

            [PSCustomObject]@{
                Attribute   = $attribute
                Description = $description
                Values      = $entry.Value.ToArray()
            }
        }
    }
}
