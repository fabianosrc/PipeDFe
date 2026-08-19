<#
.SYNOPSIS
Adds a custom ETS type name and optional default display properties to a PSObject.

.DESCRIPTION
Uses the PowerShell Extended Type System to assign a custom type name to any
object. Optionally defines which properties are shown by default in console
output without affecting Select-Object * or Format-List *.

All properties listed in DefaultDisplayProperties must already exist on the
object. If any property is absent, the function throws with ErrorId
MissingDisplayProperty to prevent silent data loss in formatted output.

.PARAMETER InputObject
The object to decorate. Accepts pipeline input.

.PARAMETER TypeName
The type name to assign (e.g. 'Company'). Combined with the namespace to
form the full ETS type name (e.g. 'PipeDFe.Company').

.PARAMETER Namespace
The namespace prefix. Defaults to 'PipeDFe'.

.PARAMETER DefaultDisplayProperties
Optional list of property names to show by default in console output.
Every listed property must exist on the object.

.OUTPUTS
System.Management.Automation.PSObject

.EXAMPLE
PS C:\> $company | Add-TypeName -TypeName 'Company'
>> -DefaultDisplayProperties Cnpj, RazaoSocial

.NOTES
Pure function - no I/O, no side effects.
#>
function Add-TypeName {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TypeName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Namespace = 'PipeDFe',

        [Parameter()]
        [string[]]$DefaultDisplayProperties
    )

    process {
        $psObject   = [System.Management.Automation.PSObject]::AsPSObject($InputObject)
        $customType = '{0}.{1}' -f $Namespace, $TypeName

        if (-not $psObject.PSObject.TypeNames.Contains($customType)) {
            $psObject.PSObject.TypeNames.Insert(0, $customType)
        }

        if ($PSBoundParameters.ContainsKey('DefaultDisplayProperties')) {
            foreach ($property in $DefaultDisplayProperties) {
                if (-not $psObject.PSObject.Properties[$property]) {
                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.ArgumentException]::new(
                                "Property '$property' does not exist on the object." +
                                "Ensure the object is fully constructed before calling Add-TypeName."
                            ),
                            'MissingDisplayProperty',
                            [System.Management.Automation.ErrorCategory]::InvalidArgument,
                            $InputObject
                        )
                    )
                }
            }

            $displayPropertySet = [System.Management.Automation.PSPropertySet]::new(
                'DefaultDisplayPropertySet',
                [string[]]$DefaultDisplayProperties
            )

            $standardMembers = [System.Management.Automation.PSMemberSet]::new(
                'PSStandardMembers',
                [System.Management.Automation.PSMemberInfo[]]@($displayPropertySet)
            )

            if ($psObject.PSObject.Members['PSStandardMembers']) {
                $psObject.PSObject.Members.Remove('PSStandardMembers')
            }

            $psObject.PSObject.Members.Add($standardMembers)
        }

        $psObject
    }
}
