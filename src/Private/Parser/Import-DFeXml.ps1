<#
.SYNOPSIS
Loads a DFe XML file into an XmlDocument.

.DESCRIPTION
Loads a DFe XML file from disk and returns a populated XmlDocument.

The XML parser is configured with secure defaults to prevent XML External
Entity (XXE) attacks by disabling external entity resolution and prohibiting
DTD processing.

The XML encoding is automatically detected by the .NET XML parser according
to the XML specification.

This function only loads and parses the XML document. Schema validation and
business rule validation are the responsibility of the caller.

.PARAMETER Path
The full path to the XML file.

.OUTPUTS
System.Xml.XmlDocument

.EXAMPLE
PS C:\> Import-DFeXml -Path 'C:\Xml\nfe.xml'
#>
function Import-DFeXml {
    [CmdletBinding()]
    [OutputType([System.Xml.XmlDocument])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    process {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new(
                        "XML file not found: '$Path'",
                        $Path
                    ),
                    'XmlFileNotFound',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                    $Path
                )
            )
        }

        $xmlDocument = [System.Xml.XmlDocument]::new()
        $xmlDocument.XmlResolver = $null

        $xmlReaderSettings = [System.Xml.XmlReaderSettings]::new()

        $xmlReaderSettings.XmlResolver                  = $null
        $xmlReaderSettings.DtdProcessing                = [System.Xml.DtdProcessing]::Prohibit
        $xmlReaderSettings.IgnoreWhitespace             = $false
        $xmlReaderSettings.IgnoreProcessingInstructions = $false

        $xmlReader = [System.Xml.XmlReader]::Create($Path, $xmlReaderSettings)

        try {
            $xmlDocument.Load($xmlReader)
        } catch [System.Xml.XmlException] {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Xml.XmlException]::new(
                        "Failed to parse XML file '$Path': $($_.Exception.Message)",
                        $_.Exception
                    ),
                    'InvalidXml',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $Path
                )
            )
        } finally {
            if ($null -ne $xmlReader) {
                $xmlReader.Dispose()
            }
        }

        return $xmlDocument
    }
}
