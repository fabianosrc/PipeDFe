<#
.SYNOPSIS
Configures the native DLL search path for unmanaged dependencies.

.DESCRIPTION
Initializes the Windows native DLL loading behavior required by
managed assemblies that depend on native DLLs.

The function uses AddDllDirectory when available and falls back to
SetDllDirectory for compatibility with older Windows environments.

This function is intended for internal module initialization and should not
be called directly by module consumers.

.PARAMETER LiteralPath
Specifies the directory containing native DLL dependencies.

.NOTES
Requires Windows because it relies on kernel32.dll APIs.

.LINK
https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/
#>
function Initialize-NativeDllLoader {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$LiteralPath
    )

    if ($Script:NativeDllDirectoryCookie -ne [System.IntPtr]::Zero) {
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
    # Prefer AddDllDirectory when available.
    # Fall back to SetDllDirectory for compatibility.
    #
    $Script:NativeDllDirectoryCookie = [System.IntPtr]::Zero

    $cookie = [System.IntPtr]::Zero

    $searchDefaultDirs = [PipeDFe.NativeLoader]::LOAD_LIBRARY_SEARCH_DEFAULT_DIRS
    $searchUserDirs    = [PipeDFe.NativeLoader]::LOAD_LIBRARY_SEARCH_USER_DIRS

    $flags = $searchDefaultDirs -bor $searchUserDirs

    try {
        # Prefer modern Windows DLL loading model.
        try {
            if (-not [PipeDFe.NativeLoader]::SetDefaultDllDirectories($flags)) {
                $lastWin32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()

                throw [System.ComponentModel.Win32Exception]::new(
                    $lastWin32Error,
                    "Failed to configure default DLL search directories."
                )
            }
        } catch [System.EntryPointNotFoundException] {
            Write-Debug -Message "SetDefaultDllDirectories is unavailable."
        }

        # Preferred method.
        $cookie = [PipeDFe.NativeLoader]::AddDllDirectory($LiteralPath)

        if ($cookie -eq [System.IntPtr]::Zero) {
            $lastWin32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()

            $exception = [System.ComponentModel.Win32Exception]::new($lastWin32Error)

            Write-Debug -Message ("AddDllDirectory failed: {0}" -f $exception.Message)
        }
    } catch [System.EntryPointNotFoundException] {
        Write-Debug -Message "AddDllDirectory is unavailable."
    }

    if ($cookie -eq [System.IntPtr]::Zero) {
        Write-Debug -Message "Using legacy SetDllDirectory fallback."

        if (-not [PipeDFe.NativeLoader]::SetDllDirectory($LiteralPath)) {
            $lastWin32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()

            throw [System.ComponentModel.Win32Exception]::new(
                $lastWin32Error,
                "Failed to configure native DLL directory."
            )
        }
    }

    if ($cookie -ne [System.IntPtr]::Zero) {
        $Script:NativeDllDirectoryCookie = $cookie
    }

}
