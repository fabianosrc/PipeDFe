<#
.SYNOPSIS
Invokes the kernel32 SetDllDirectory API

.DESCRIPTION
Thin PowerShell wrapper around [PipeDFe.NativeLoader]::SetDllDirectory.
Exists exclusively as a mockable seam for unit testing.

Returns $true on success. Returns $false on failure - the caller is
responsible for reading the Win32 error via GetLastWin32Error immediately
after this function returns $false.

.PARAMETER LiteralPath
The directory to set as the DLL search path.

.OUTPUTS
System.Boolean

.EXAMPLE
PS C:\> $ok = Invoke-NativeSetDllDirectory -LiteralPath 'C:\lib\native'

.NOTES
Dependencies: PipeDFe.NativeLoader must be registered before calling.
#>
function Invoke-NativeSetDllDirectory {
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    return [PipeDFe.NativeLoader]::SetDllDirectory($LiteralPath)
}
