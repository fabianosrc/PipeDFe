<#
.SYNOPSIS
Low-level DN parser. Emits raw key/value pairs via pipeline.

.DESCRIPTION
Parses a Distinguished Name string character by character using an
explicit state machine.

Supports:

  - Attribute separators using comma and plus.
  - Quoted attribute values.
  - Backslash-escaped characters.
  - Hexadecimal escaped octets.
  - UTF-8 sequences represented by hexadecimal escaped octets.
  - Duplicate attributes.

Each attribute is emitted immediately as a PSCustomObject.

Duplicate attributes are intentionally preserved. Grouping or semantic
interpretation is the responsibility of the caller.

.PARAMETER InputObject
The Distinguished Name string to parse.

.OUTPUTS
System.Management.Automation.PSCustomObject

Properties:

  Key   [string]
  Value [string]

.EXAMPLE
PS C:\> ConvertFrom-DnString -InputObject 'CN=ACME LTDA,O=ICP-Brasil,C=BR'

Key Value
--- -----
CN  ACME LTDA
O   ICP-Brasil
C   BR

.NOTES
Pure function.

No filesystem, network, registry or external state is accessed.
#>
function ConvertFrom-DnString {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string]$InputObject
    )

    process {
        $builder = [System.Text.StringBuilder]::new()

        $key = $null
        $readKey = $true
        $inQuote = $false
        $escaped = $false

        $utf8Strict = [System.Text.UTF8Encoding]::new(
            $false,
            $true
        )

        for ($i = 0; $i -lt $InputObject.Length; $i++) {
            $char = $InputObject[$i]

            if ($escaped) {
                $escaped = $false

                $hasHexPair = (
                    ($i + 1) -lt $InputObject.Length -and
                    [Uri]::IsHexDigit($char) -and
                    [Uri]::IsHexDigit($InputObject[$i + 1])
                )

                if ($hasHexPair) {
                    $bytes = [System.Collections.Generic.List[byte]]::new()

                    while (
                        ($i + 1) -lt $InputObject.Length -and
                        [Uri]::IsHexDigit($InputObject[$i]) -and
                        [Uri]::IsHexDigit($InputObject[$i + 1])
                    ) {
                        $hex = [string]::Concat(
                            $InputObject[$i],
                            $InputObject[$i + 1]
                        )

                        $bytes.Add(
                            [System.Convert]::ToByte($hex, 16)
                        )

                        $i += 2

                        if (
                            $i -lt $InputObject.Length -and
                            $InputObject[$i] -eq '\'
                        ) {
                            $nextIsHexPair = (
                                ($i + 2) -lt $InputObject.Length -and
                                [Uri]::IsHexDigit($InputObject[$i + 1]) -and
                                [Uri]::IsHexDigit($InputObject[$i + 2])
                            )

                            if ($nextIsHexPair) {
                                $i++
                                continue
                            }
                        }

                        $i--
                        break
                    }

                    try {
                        $decoded = $utf8Strict.GetString(
                            $bytes.ToArray()
                        )
                    } catch {
                        $decoded = [System.Text.Encoding]::ASCII.GetString(
                            $bytes.ToArray()
                        )
                    }

                    $null = $builder.Append($decoded)
                    continue
                }

                $null = $builder.Append($char)
                continue
            }

            if ($char -eq '\') {
                $escaped = $true
                continue
            }

            if ($char -eq '"') {
                $inQuote = -not $inQuote
                continue
            }

            if (
                $char -eq '=' -and
                $readKey -and
                -not $inQuote
            ) {
                $trimmedKey = $builder.ToString().Trim()

                if ($trimmedKey.Length -gt 0) {
                    $key = $trimmedKey.ToUpperInvariant()
                }

                $readKey = $false

                $null = $builder.Clear()

                continue
            }

            if (
                ($char -eq ',' -or $char -eq '+') -and
                -not $inQuote
            ) {
                $value = $builder.ToString().Trim()

                if (
                    $null -ne $key -and
                    -not [string]::IsNullOrWhiteSpace($value)
                ) {
                    [PSCustomObject]@{
                        Key   = [string]$key
                        Value = [string]$value
                    }
                }

                $key = $null
                $readKey = $true

                $null = $builder.Clear()

                continue
            }

            $null = $builder.Append($char)
        }

        if ($escaped) {
            $null = $builder.Append('\')
        }

        if ($null -ne $key) {
            $value = $builder.ToString().Trim()

            if (-not [string]::IsNullOrWhiteSpace($value)) {
                [PSCustomObject]@{
                    Key   = [string]$key
                    Value = [string]$value
                }
            }
        }
    }
}
