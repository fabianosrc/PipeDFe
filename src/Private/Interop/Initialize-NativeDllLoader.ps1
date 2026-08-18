<#
.SYNOPSIS
Configures the native DLL search path for unmanaged dependencies

.DESCRIPTION
Initializes the Windows native DLL loading behavior required by managed
assemblies that depend on native DLLs.

The initialization follows three ordered steps:

    1. SetDefaultDllDirectories - restricts the default search order to safe
        directories. Skipped silently when unavailable (pre-Windows 8 /
        pre-KB2533623 environments).

    2. AddDllDirectory - registers the caller-supplied directory and stores
        the returned cookie in $Script:NativeDllDirectoryCookie for potential
        cleanup by the caller. If AddDllDirectory is unavailable or returns a
        null handle, the function degrades silently to step 3.

    3. SetDllDirectory (fallback) - used when AddDllDirectory is unavailable
        or fails. Less precise than AddDllDirectory but compatible with older
        Windows environments.

The function is idempotent: subsequent calls return immediately once
$Script:NativeDllDirectoryInitialized is $true.

Requires Windows. Behavior on non-Windows platforms is undefined.

.PARAMETER LiteralPath
The directory containing native DLL dependencies. Must exist at call time.

.OUTPUTS
None.

.EXAMPLE
PS C:\> Initialize-NativeDllLoader -LiteralPath (Join-Path $PSScriptRoot 'lib\native')

.NOTES
Private. Not exported. Intended for module initialization only.

The psm1 must declare both script-scope variables before loading this layer:

    $Script:NativeDllDirectoryInitialized = $false
    $Script:NativeDllDirectoryCookie      = [System.IntPtr]::Zero

Each kernel32 call is delegated to a thin private wrapper function
(Invoke-NativeSetDefaultDllDirectory, Invoke-NativeAddDllDirectory,
Invoke-NativeSetDllDirectory) so that unit tests can mock them without
replacing this function itself.

Private dependencies:
  Invoke-NativeSetDefaultDllDirectory
  Invoke-NativeAddDllDirectory
  Invoke-NativeSetDllDirectory
#>
function Initialize-NativeDllLoader {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container } )]
        [string]$LiteralPath
    )

    if ($Script:NativeDllDirectoryInitialized) {
        return
    }

    $nativeLoaderType = [System.Management.Automation.PSTypeName]'PipeDFe.NativeLoader'

    if (-not $nativeLoaderType.Type) {
        Add-Type -TypeDefinition @'
        using System;
        using System.Runtime.InteropServices;

        namespace PipeDFe
        {
            public static class NativeLoader
            {
                public const uint LOAD_LIBRARY_SEARCH_DEFAULT_DIRS = 0x00001000;
                public const uint LOAD_LIBRARY_SEARCH_USER_DIRS    = 0x00000400;

                [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
                public static extern IntPtr AddDllDirectory(string path);

                [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
                public static extern bool SetDllDirectory(string path);

                [DllImport("kernel32.dll", SetLastError=true)]
                public static extern bool SetDefaultDllDirectories(uint directoryFlags);
            }
        }
'@ -Language CSharp -IgnoreWarnings
    }

    #
    # Configure the native DLL search path.
    #
    # Prefer AddDllDirectory when available (Windows 8+ / KB2533623).
    # Fall back to SetDllDirectory for compatibility with older environments.
    #
    $flags = [PipeDFe.NativeLoader]::LOAD_LIBRARY_SEARCH_DEFAULT_DIRS -bor
    [PipeDFe.NativeLoader]::LOAD_LIBRARY_SEARCH_USER_DIRS

    # Step 1 - restrict the default search order to safe directories.
    try {
        if (-not (Invoke-NativeSetDefaultDllDirectory -Flags $flags)) {
            $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ComponentModel.Win32Exception]::new(
                        $lastError,
                        'Failed to configure default DLL search directories.'
                    ),
                    'DefaultDllDirectoriesConfigFailed',
                    [System.Management.Automation.ErrorCategory]::InvalidOperation,
                    $LiteralPath
                )
            )
        }
    } catch [System.EntryPointNotFoundException] {
        Write-Debug -Message 'SetDefaultDllDirectories is unavailable; skipping.'
    }

    # Step 2 - register the caller-supplied directory.
    $cookie = [System.IntPtr]::Zero

    try {
        $cookie = Invoke-NativeAddDllDirectory -LiteralPath $LiteralPath

        if ($cookie -eq [System.IntPtr]::Zero) {
            $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $exception = [System.ComponentModel.Win32Exception]::new($lastError)
            Write-Debug -Message (
                'AddDllDirectory failed ({0}); degrading to SetDllDirectory fallback.' -f
                $exception.Message
            )
        }
    } catch [System.EntryPointNotFoundException] {
        Write-Debug -Message 'AddDllDirectory is unavailable; degrading to SetDllDirectory fallback.'
    }

    # Step 3 - fall back to SetDllDirectory if AddDllDirectory was unavailable or failed.
    if ($cookie -eq [System.IntPtr]::Zero) {
        if (-not (Invoke-NativeSetDllDirectory -LiteralPath $LiteralPath)) {
            $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ComponentModel.Win32Exception]::new(
                        $lastError,
                        'Failed to configure native DLL directory.'
                    ),
                    'NativeDllDirectoryConfigFailed',
                    [System.Management.Automation.ErrorCategory]::InvalidOperation,
                    $LiteralPath
                )
            )
        }
    } else {
        $Script:NativeDllDirectoryCookie = $cookie
    }

    $Script:NativeDllDirectoryInitialized = $true
}
