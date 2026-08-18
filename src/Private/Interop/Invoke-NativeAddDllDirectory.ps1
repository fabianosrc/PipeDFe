<#
.SYNOPSIS
Invokes the kernel32 AddDllDirectory API

.DESCRIPTION
Thin PowerShell wrapper around [PipeDFe.NativeLoader]::AddDllDirectory.
Exists exclusively as a mockable seam for unit testing.

Returns the opaque cookie handle on success. Returns [System.IntPtr]::Zero
on failure - the caller is responsible for reading the Win32 error via
GetLastWin32Error immediately after this function returns Zero.

Throws [System.EntryPointNotFoundException] when the API is unavailable
(pre-Windows 8 / pre-KB2533623 environments).

.PARAMETER LiteralPath
The directory to register as a DLL search path.

.OUTPUTS
System.IntPtr

.EXAMPLE
PS C:\> $cookie = Invoke-NativeAddDllDirectory -LiteralPath 'C:\lib\native'

.NOTES
Dependencies: PipeDFe.NativeLoader must be registered before calling.
#>
function Invoke-NativeAddDllDirectory {
    [CmdletBinding()]
    [OutputType([System.IntPtr])]
    param (
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    return [PipeDFe.NativeLoader]::AddDllDirectory($LiteralPath)
}
