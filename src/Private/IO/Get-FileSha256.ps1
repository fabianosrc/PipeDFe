<#
.SYNOPSIS
Computes the SHA-256 hash of a file.

.DESCRIPTION
Reads the file at the given path and returns its SHA-256 hash as a
lowercase hexadecimal string. The file is opened with read-only sharing
so it can be hashed while in use by another process.

Throws FileNotFound when the path does not exist or is not a file.

.PARAMETER Path
Full path to the file to hash.

.OUTPUTS
System.String

.EXAMPLE
PS C:\> Get-FileSha256 -Path 'C:\xml\NFe\doc.xml'

.NOTES
Pure IO function - no side effects beyond reading the file.
#>
function Get-FileSha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    process {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new(
                        "File not found: '$Path'."
                    ),
                    'FileNotFound',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                    $Path
                )
            )
        }

        $sha256 = $null
        $stream = $null

        try {
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            $stream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::Read
            )

            $hashBytes = $sha256.ComputeHash($stream)

            [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
        } catch [System.IO.FileNotFoundException] {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    $_.Exception,
                    'FileNotFound',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                    $Path
                )
            )
        } catch {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    $_.Exception,
                    'FileSha256Failed',
                    [System.Management.Automation.ErrorCategory]::ReadError,
                    $Path
                )
            )
        } finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }

            if ($null -ne $sha256) {
                $sha256.Dispose()
            }
        }
    }
}
