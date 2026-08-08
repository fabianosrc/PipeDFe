<#
.SYNOPSIS
Extracts the access key from a Brazilian DFe XML element.

.DESCRIPTION
Extracts the 44-digit access key from the Id attribute of a DFe
information XML element.

The Id attribute is expected to contain a document-specific prefix
followed immediately by the 44-digit access key.

The function validates only the structure of the value:

* The XML node is not null.
* The Id attribute exists and contains a non-empty value.
* The Id starts with the expected prefix.
* The value following the prefix contains exactly 44 ASCII numeric digits.

The function does not validate the access key check digit or perform
any fiscal validation. The XML document is treated as the source of
truth.

Invalid input produces no output.

.PARAMETER Node
The XML element containing the Id attribute of the DFe information node.

.PARAMETER Prefix
The document-specific prefix expected at the beginning of the Id value.

Examples:

* NFe
* CTe
* MDFe

.OUTPUTS
System.String

Returns the 44-digit access key for valid input.

.EXAMPLE
PS C:> Get-DFeAccessKey -Node $infNFe -Prefix 'NFe'

Extracts the access key from an NF-e information element.

.EXAMPLE
PS C:> Get-DFeAccessKey -Node $infCte -Prefix 'CTe'

Extracts the access key from a CT-e information element.

.NOTES
Brazilian DFe access keys contain exactly 44 ASCII numeric digits.

This function performs structural extraction only. It does not validate
the access key check digit or determine whether the document is valid,
authorized, or otherwise accepted by a fiscal authority.

In the context of PipeDFe, this function is used to extract the access
key from processed DFe XML for indexing, archival, and audit trail
purposes. The caller is responsible for handling extraction failures
(via empty output) and logging.
#>
function Get-DFeAccessKey {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNull()]
        [System.Xml.XmlElement]$Node,

        [Parameter(Mandatory)]
        [ValidateScript(
            {
                if ([string]::IsNullOrWhiteSpace($_)) {
                    throw 'Prefix cannot be null, empty, or whitespace.'
                }

                $true
            }
        )]
        [string]$Prefix
    )

    process {
        # GetAttribute returns an empty string when the attribute
        # does not exist.
        $id = $Node.GetAttribute('Id')

        if ([string]::IsNullOrWhiteSpace($id)) {
            return
        }

        # Prefix is treated as a literal string, not a regular expression.
        # Ordinal comparison avoids culture-sensitive behavior.
        if (-not $id.StartsWith($Prefix, [System.StringComparison]::Ordinal)) {
            return
        }

        # Do not trim the value.
        #
        # Whitespace after the prefix must cause structural validation
        # to fail rather than silently modifying the source value.
        $accessKey = $id.Substring($Prefix.Length)

        # The access key must contain exactly 44 ASCII numeric digits.
        #
        # [0-9] is intentionally used instead of \d because .NET
        # \d can match Unicode decimal digits.
        if ($accessKey -notmatch '^[0-9]{44}$') {
            return
        }

        $accessKey
    }
}
