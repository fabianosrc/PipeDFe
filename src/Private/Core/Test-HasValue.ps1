<#
.SYNOPSIS
Determines whether an object contains meaningful data.

.DESCRIPTION
Returns $true when the input contains data and $false otherwise.

The following values are considered empty:
  - $null
  - empty or whitespace-only strings
  - empty dictionaries
  - empty enumerable collections

All other values are considered to have a value, including:
  - zero
  - $false
  - empty PSCustomObjects
  - other non-collection objects

When used through the pipeline, each input object is evaluated independently
and produces exactly one Boolean result.

.PARAMETER InputObject
The object to evaluate. Accepts pipeline input. Accepts null.

.OUTPUTS
System.Boolean

.EXAMPLE
PS C:\> Test-HasValue -InputObject 'hello'
True

.EXAMPLE
PS C:\> Test-HasValue -InputObject ''
False

.EXAMPLE
PS C:\> $null | Test-HasValue
False

.EXAMPLE
PS C:\> 0, $false, '', 'hello' | Test-HasValue
True
True
False
True

.EXAMPLE
PS C:\> Test-HasValue -InputObject @(1, 2, 3)
True

.NOTES
Pure function - no I/O and no external side effects.
Each pipeline input produces exactly one Boolean result.
#>
function Test-HasValue {
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object]$InputObject
    )

    process {
        $hasValue = $true

        if ($null -eq $InputObject) {
            $hasValue = $false
        } elseif ($InputObject -is [string]) {
            $hasValue = -not [string]::IsNullOrWhiteSpace($InputObject)
        } elseif ($InputObject -is [System.Collections.IDictionary]) {
            $hasValue = $InputObject.Count -gt 0
        } elseif ($InputObject -is [System.Collections.IEnumerable]) {
            $hasValue = $false

            foreach ($item in $InputObject) {
                $hasValue = $true
                break
            }
        }

        Write-Output -InputObject $hasValue -NoEnumerate
    }
}
