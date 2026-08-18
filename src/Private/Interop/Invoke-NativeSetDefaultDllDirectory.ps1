<#
.SYNOPSIS
Invokes the kernel32 SetDefaultDllDirectories API

.DESCRIPTION
Thin PowerShell wrapper around [PipeDFe.NativeLoader]::SetDefaultDllDirectories.
Exists exclusively as a mockable seam for unit testing.

Returns $true on success. Returns $false on failure - the caller is
responsible for reading the Win32 error via GetLastWin32Error immediately
after this function returns $false.

Throws [System.EntryPointNotFoundException] when the API is unavailable
(pre-Windows 8 / pre-KB2533623 environments).

.PARAMETER Flags
The directory flags to pass to SetDefaultDllDirectories.

.OUTPUTS
System.Boolean

.EXAMPLE
PS C:\> $ok = Invoke-NativeSetDefaultDllDirectory -Flags 0x00001400

.NOTES
Dependencies: PipeDFe.NativeLoader must be registered before calling.
#>
function Invoke-NativeSetDefaultDllDirectory {
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [UInt32]$Flags
    )

    return [PipeDFe.NativeLoader]::SetDefaultDllDirectories($Flags)
}
