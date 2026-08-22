<#
.SYNOPSIS
Normalizes and sanitizes a string for safe, consistent use.

.DESCRIPTION
Normalizes Unicode text, removes diacritical marks, removes characters
outside the supported character set, collapses whitespace sequences into
a configurable separator, and optionally removes remaining non-ASCII
characters and converts the result to uppercase.

Input resolution:
  - $null, empty strings, and whitespace-only strings return an empty string.
  - Unicode text is normalized using FormD, combining marks are removed,
    and the result is recomposed using FormC.
  - Characters other than Unicode letters, Unicode decimal digits,
    whitespace, and '&' are removed.
  - When AsciiOnly is specified, remaining non-ASCII characters are removed.
  - Consecutive whitespace is replaced by Separator.
  - When UpperCase is specified, the result is converted using Culture.

AsciiOnly removes non-ASCII characters; it does not perform transliteration.

This function is a normalization/sanitization utility. It does not provide
context-specific escaping for SQL, HTML, URLs, shell commands, file paths,
or other security-sensitive contexts.

.PARAMETER InputObject
The string to normalize.

Accepts pipeline input. Null, empty, and whitespace-only values return
an empty string.

.PARAMETER UpperCase
Converts the normalized result to uppercase using Culture.

.PARAMETER Separator
String used to replace each sequence of one or more whitespace characters.

Defaults to '_'.

The separator is inserted literally and is not interpreted as a regular
expression replacement pattern.

.PARAMETER AsciiOnly
Removes remaining characters outside the ASCII range (U+0000 through U+007F).

This removes non-ASCII characters; it does not transliterate them.

.PARAMETER Culture
Culture used for uppercase conversion.

Defaults to InvariantCulture.

.OUTPUTS
System.String

.NOTES
No I/O or external side effects.

Each non-null pipeline input produces exactly one System.String output.

Private implementation detail:
  Separator replacement uses a MatchEvaluator so that characters such as
  '$' are treated literally rather than as Regex replacement tokens.
#>
function ConvertTo-SafeString {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter',
        'Match',
        Justification = 'Required by MatchEvaluator'
    )]

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter',
        'Separator',
        Justification = 'Captured by replacement delegate'
    )]

    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(ValueFromPipeline)]
        [AllowNull()]
        [Alias('Text', 'Value')]
        [string]$InputObject,

        [Parameter()]
        [switch]$UpperCase,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Separator = '_',

        [Parameter()]
        [switch]$AsciiOnly,

        [Parameter()]
        [cultureinfo]$Culture = [cultureinfo]::InvariantCulture
    )

    begin {
        $regexNonSpacing = [regex]::new(
            '\p{Mn}',
            [System.Text.RegularExpressions.RegexOptions]::Compiled
        )

        $regexInvalidChars = [regex]::new(
            '[^\p{L}\p{Nd}\s&]',
            [System.Text.RegularExpressions.RegexOptions]::Compiled
        )

        $regexWhitespace = [regex]::new(
            '\s+',
            [System.Text.RegularExpressions.RegexOptions]::Compiled
        )

        $regexNonAscii = [regex]::new(
            '[^\x00-\x7F]',
            [System.Text.RegularExpressions.RegexOptions]::Compiled
        )

        $separatorEvaluator = [System.Text.RegularExpressions.MatchEvaluator] {
            param (
                [System.Text.RegularExpressions.Match]$Match
            )

            $Separator
        }
    }

    process {
        if ([string]::IsNullOrWhiteSpace($InputObject)) {
            [string]::Empty
            return
        }

        $result = $InputObject.Normalize([System.Text.NormalizationForm]::FormD)

        $result = $regexNonSpacing.Replace($result, [string]::Empty)

        $result = $result.Normalize([System.Text.NormalizationForm]::FormC)

        $result = $regexInvalidChars.Replace($result, [string]::Empty)

        if ($AsciiOnly) {
            $result = $regexNonAscii.Replace($result, [string]::Empty)
        }

        $result = $regexWhitespace.Replace($result.Trim(), $separatorEvaluator)

        if ($UpperCase) {
            $result = $result.ToUpper($Culture)
        }

        [string]$result
    }
}
