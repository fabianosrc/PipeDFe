<#
.SYNOPSIS
Validates a CNPJ string.

.DESCRIPTION
Validates a Brazilian CNPJ using the official Modulo 11 check digit
algorithm defined by SERPRO.

Supports both numeric and alphanumeric CNPJ formats (RFB 2026).
Character values are computed as ASCII minus 48, per the official
SERPRO specification (e.g. '0'=0, '9'=9, 'A'=17, 'Z'=42).

Accepts formatted CNPJs. Formatting characters are normalized by
ConvertTo-NormalizedCnpj.

In Homologacao environment, only structural validation is performed;
check digits are not verified.

Invalid input always returns $false. This includes values rejected
by ConvertTo-NormalizedCnpj.

.PARAMETER Value
The CNPJ string to validate. Accepts pipeline input.

.PARAMETER Ambiente
Target fiscal environment. When set to Homologacao, only structural
validation is performed and check digits are skipped.

.OUTPUTS
System.Boolean

.EXAMPLE
PS C:\> Test-Cnpj -Value '12.ABC.345/01DE-35' -Ambiente Producao

.EXAMPLE
PS C:\> '11222333000181', '00000000000000' |
>> Test-Cnpj -Ambiente Producao

.NOTES
Pure function - no I/O, no side effects.

Private dependencies:
  ConvertTo-NormalizedCnpj
#>
function Test-Cnpj {
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string]$Value,

        [Parameter(Mandatory)]
        [Ambiente]$Ambiente
    )

    begin {
        $weights1 = [int[]]@(5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2)
        $weights2 = [int[]]@(6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2)

        function Get-CheckDigit {
            [CmdletBinding()]
            [OutputType([int])]
            param (
                [Parameter(Mandatory)]
                [char[]]$Chars,

                [Parameter(Mandatory)]
                [int[]]$Weights
            )

            $sum = 0

            for ($i = 0; $i -lt $Chars.Count; $i++) {
                $value = [int][char]$Chars[$i] - 48
                $sum += $value * $Weights[$i]
            }

            $remainder = $sum % 11

            if ($remainder -lt 2) {
                return 0
            }

            return 11 - $remainder
        }
    }

    process {
        # Normalize and reject invalid input without exposing
        # normalization errors to the caller of this Test-* function.
        try {
            $clean = ConvertTo-NormalizedCnpj -Value $Value -ErrorAction Stop
        } catch {
            return $false
        }

        # Defensive structural validation.
        if ($clean.Length -ne 14) {
            return $false
        }

        # First 12 characters may be numeric or alphanumeric.
        if ($clean.Substring(0, 12) -notmatch '(?-i)^[0-9A-Z]{12}$') {
            return $false
        }

        # Check digits must always be numeric.
        if ($clean.Substring(12, 2) -notmatch '(?-i)^[0-9]{2}$') {
            return $false
        }

        # Reject CNPJs composed of a single repeated character.
        if ($clean -match '^(.)\1{13}$') {
            return $false
        }

        # Homologacao requires only structural validation.
        if ($Ambiente -eq [Ambiente]::Homologacao) {
            return $true
        }

        [char[]]$baseChars = $clean.Substring(0, 12).ToCharArray()

        $dv1 = Get-CheckDigit -Chars $baseChars -Weights $weights1

        [char[]]$charsWithDv1 = $clean.Substring(0, 12) + $dv1.ToString()

        $dv2 = Get-CheckDigit -Chars $charsWithDv1 -Weights $weights2

        $expectedCheckDigits = '{0}{1}' -f $dv1, $dv2
        $actualCheckDigits = $clean.Substring(12, 2)

        return $actualCheckDigits -ceq $expectedCheckDigits
    }
}
