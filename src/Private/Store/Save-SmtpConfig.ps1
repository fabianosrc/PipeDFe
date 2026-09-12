<#
.SYNOPSIS
Persists the SMTP configuration to smtp.json.

.DESCRIPTION
Normalizes, validates and writes the SMTP configuration using an atomic
write pattern.

The configuration is first serialized to a uniquely named temporary file
in the same directory as smtp.json. The temporary file is then atomically
promoted to smtp.json via File.Replace (update) or File.Move (first save).

Placing the temporary file in the same directory guarantees that the
promotion is a filesystem-level rename, never a cross-device copy.

A named mutex serializes concurrent writes from cooperating PipeDFe
processes sharing the same store path. The mutex name is derived from
the SHA-256 hash of the normalized store path so that different PipeDFe
installations do not block each other.

Password must contain the DPAPI-encrypted password blob. This function
does not decrypt or otherwise transform the password.

Timestamps are stored as ISO 8601 UTC strings (e.g. 2026-09-12T16:04:15.0000000Z).
This format is round-trip safe across ConvertTo-Json and ConvertFrom-Json
on both .NET Framework and .NET Core.

CreatedAt is preserved from the caller when supplied. When not supplied
on an update, it is read from the existing smtp.json. On first save it
is set to the current UTC timestamp.

UpdatedAt is set to the current UTC timestamp only on updates (when
smtp.json already exists at the time the mutex is acquired). On first
save, UpdatedAt is set to $null.

Throws SmtpConfigInvalidCreatedAt when the supplied CreatedAt cannot be parsed.

Throws SmtpConfigInvalid when the configuration fails validation.

Throws SmtpConfigLockTimeout when the write lock cannot be acquired
within 30 seconds.

Throws SmtpConfigSaveFailed when the configuration cannot be persisted.

.PARAMETER Config
The SMTP configuration object to persist.

.OUTPUTS
None.

.EXAMPLE
PS C:\> Save-SmtpConfig -Config $smtpConfig

.NOTES
Private dependencies:
  Get-StorePath
  Test-Smtp

Pure validation is performed before any file-system write occurs.
UTF8Encoding does not implement IDisposable - no Dispose() call is made.
#>
function Save-SmtpConfig {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Internal persistence layer. Not a user-facing cmdlet.'
    )]
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Config
    )

    #region Paths
    $rootPath = Get-StorePath -Scope Root

    if ([string]::IsNullOrWhiteSpace($rootPath)) {
        throw 'SMTP configuration root path is empty.'
    }

    try {
        $rootPath = [System.IO.Path]::GetFullPath($rootPath)
    } catch {
        throw [System.ArgumentException]::new(
            "SMTP configuration root path is invalid: '$rootPath'.",
            'rootPath',
            $_.Exception
        )
    }

    $configPath = Join-Path -Path $rootPath -ChildPath 'smtp.json'

    $newGuid = [System.Guid]::NewGuid().ToString('N')

    # Temporary and backup files stay in the same directory/volume as
    # smtp.json. This is required for File.Replace atomic filesystem semantics.
    $tempPath   = Join-Path -Path $rootPath -ChildPath ('smtp.{0}.tmp' -f $newGuid)
    $backupPath = Join-Path -Path $rootPath -ChildPath ('smtp.{0}.bak' -f $newGuid)
    #endregion

    $mutex         = $null
    $mutexAcquired = $false

    try {
        #region Mutex
        $sha256 = [System.Security.Cryptography.SHA256]::Create()

        try {
            $targetHash = [System.Text.Encoding]::UTF8.GetBytes($rootPath.ToLowerInvariant())
            $hashBytes  = $sha256.ComputeHash($targetHash)
        } finally {
            $sha256.Dispose()
        }

        $hash      = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join [string]::Empty
        $mutexName = 'Local\PipeDFe-SmtpConfig-{0}' -f $hash
        $mutex     = [System.Threading.Mutex]::new($false, $mutexName)

        try {
            $mutexAcquired = $mutex.WaitOne([System.TimeSpan]::FromSeconds(30))
        } catch [System.Threading.AbandonedMutexException] {
            # An abandoned mutex is granted to the current thread.
            $mutexAcquired = $true
        }

        if (-not $mutexAcquired) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.TimeoutException]::new(
                        'Timed out waiting for the SMTP configuration lock.'
                    ),
                    'SmtpConfigLockTimeout',
                    [System.Management.Automation.ErrorCategory]::ResourceBusy,
                    $configPath
                )
            )
        }
        #endregion

        #region Timestamps
        # Everything that depends on smtp.json existing is evaluated after
        # acquiring the mutex to avoid race conditions.
        $utcNow   = [System.DateTimeOffset]::UtcNow
        $isUpdate = [System.IO.File]::Exists($configPath)

        $createdAt = $null

        $hasCreatedAt = (
            $null -ne $Config.CreatedAt -and -not
            [string]::IsNullOrWhiteSpace([string]$Config.CreatedAt)
        )

        if ($hasCreatedAt) {
            if ($Config.CreatedAt -is [System.DateTimeOffset]) {
                $createdAt = (
                    [System.DateTimeOffset]$Config.CreatedAt
                ).ToUniversalTime()
            } elseif ($Config.CreatedAt -is [System.DateTime]) {
                $createdAt = [System.DateTimeOffset](
                    [System.DateTime]$Config.CreatedAt
                ).ToUniversalTime()
            } else {
                $createdAtText = [string]$Config.CreatedAt

                try {
                    $createdAt = (
                        [System.DateTimeOffset]::Parse(
                            $createdAtText,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind
                        )
                    ).ToUniversalTime()
                } catch {
                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.FormatException]::new(
                                "CreatedAt is not a valid timestamp: '$createdAtText'.",
                                $_.Exception
                            ),
                            'SmtpConfigInvalidCreatedAt',
                            [System.Management.Automation.ErrorCategory]::InvalidData,
                            $Config.CreatedAt
                        )
                    )
                }
            }
        }

        # On update, preserve CreatedAt from the existing file when not supplied.
        if ($isUpdate -and $null -eq $createdAt) {
            try {
                $existingJson = [System.IO.File]::ReadAllText(
                    $configPath,
                    [System.Text.Encoding]::UTF8
                )

                if (-not [string]::IsNullOrWhiteSpace($existingJson)) {
                    $existingModel          = $existingJson | ConvertFrom-Json
                    $existingCreatedAtValue = $existingModel.CreatedAt

                    $hasExistingCreatedAt = (
                        $null -ne $existingCreatedAtValue -and -not
                        [string]::IsNullOrWhiteSpace([string]$existingCreatedAtValue)
                    )

                    if ($hasExistingCreatedAt) {
                        $createdAt = (
                            [System.DateTimeOffset]::Parse(
                                [string]$existingCreatedAtValue,
                                [System.Globalization.CultureInfo]::InvariantCulture,
                                [System.Globalization.DateTimeStyles]::RoundtripKind
                            )
                        ).ToUniversalTime()
                    }
                }
            } catch {
                throw [System.IO.IOException]::new(
                    'The existing SMTP configuration could not be read or its CreatedAt value is invalid.',
                    $_.Exception
                )
            }
        }

        if ($null -eq $createdAt) {
            $createdAt = $utcNow
        }

        $updatedAt = if ($isUpdate) { $utcNow } else { $null }
        #endregion

        #region Model
        # Timestamps are serialized as ISO 8601 strings via ToString('o') so
        # that ConvertTo-Json emits a stable, round-trip-safe representation.
        # Passing DateTimeOffset directly causes ConvertTo-Json to emit a
        # locale-dependent format that breaks string equality across saves.
        $model = [PSCustomObject][ordered]@{
            SchemaVersion = [int]$Script:SmtpSchemaVersion
            Server        = [string]$Config.Server
            Port          = [int]$Config.Port
            Ssl           = [bool]$Config.Ssl
            Username      = [string]$Config.Username
            Password      = [string]$Config.Password
            From          = $Config.From
            SenderAddress = $Config.SenderAddress
            ReplyTo       = $Config.ReplyTo
            Timeout       = [int]$Config.Timeout
            CreatedAt     = $createdAt.ToString('o')
            UpdatedAt     = if ($null -ne $updatedAt) { $updatedAt.ToString('o') } else { $null }
        }
        #endregion

        #region Validation
        $validation = Test-Smtp -InputObject $model

        if (-not $validation.IsValid) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.IOException]::new(
                        'SMTP configuration is invalid and cannot be saved. ' +
                        ($validation.Errors -join ' ')
                    ),
                    'SmtpConfigInvalid',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $model
                )
            )
        }
        #endregion

        #region Write
        [System.IO.Directory]::CreateDirectory($rootPath) | Out-Null

        # UTF8Encoding does not implement IDisposable - no Dispose() call.
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $json      = $model | ConvertTo-Json -Depth 5

        if ([string]::IsNullOrWhiteSpace($json)) {
            throw [System.IO.IOException]::new(
                'Serialized SMTP configuration is empty.'
            )
        }

        [System.IO.File]::WriteAllText($tempPath, $json, $utf8NoBom)

        if (-not [System.IO.File]::Exists($tempPath)) {
            throw [System.IO.IOException]::new(
                'Temporary SMTP configuration file was not created.'
            )
        }

        if ([System.IO.FileInfo]::new($tempPath).Length -le 0) {
            throw [System.IO.IOException]::new(
                'Temporary SMTP configuration file is empty.'
            )
        }
        #endregion

        #region Atomic promotion
        # for + break is used instead of while with compound condition.
        # In PowerShell 5.1, a typed catch inside a while loop with a
        # compound condition can cause break/continue to escape the loop
        # boundary, which Pester intercepts as a fatal error.
        $maxAttempts        = 3
        $promotionSucceeded = $false
        $lastException      = $null

        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                if ([System.IO.File]::Exists($configPath)) {
                    [System.IO.File]::Replace(
                        $tempPath,
                        $configPath,
                        $backupPath,
                        $false
                    )
                } else {
                    [System.IO.File]::Move(
                        $tempPath,
                        $configPath
                    )
                }

                $promotionSucceeded = $true
                break
            } catch [System.IO.IOException] {
                $lastException = $_.Exception
            } catch [System.UnauthorizedAccessException] {
                $lastException = $_.Exception
            }

            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Milliseconds (100 * $attempt)
            }
        }

        if (-not $promotionSucceeded) {
            if ($null -ne $lastException) {
                throw $lastException
            }

            throw [System.IO.IOException]::new(
                'SMTP configuration could not be atomically promoted.'
            )
        }
        #endregion

        #region Backup cleanup
        # smtp.json is already committed. Backup cleanup failure must not
        # turn a successful save into a failed save.
        if ([System.IO.File]::Exists($backupPath)) {
            try {
                [System.IO.File]::Delete($backupPath)
            } catch {
                Write-Verbose -Message (
                    "Could not remove SMTP backup file '$backupPath': $($_.Exception.Message)"
                )
            }
        }
        #endregion

    } catch [System.TimeoutException] {
        throw
    } catch [System.ArgumentException] {
        throw
    } catch [System.IO.IOException] {
        throw
    } catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.IOException]::new(
                    'Failed to save the SMTP configuration.',
                    $_.Exception
                ),
                'SmtpConfigSaveFailed',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $configPath
            )
        )
    } finally {
        #region Cleanup
        if ($null -ne $tempPath -and [System.IO.File]::Exists($tempPath)) {
            try {
                [System.IO.File]::Delete($tempPath)
            } catch {
                Write-Verbose -Message (
                    "Could not remove SMTP temporary file '$tempPath': $($_.Exception.Message)"
                )
            }
        }

        if ($mutexAcquired -and $null -ne $mutex) {
            try {
                $mutex.ReleaseMutex()
            } catch {
                Write-Verbose -Message (
                    "Could not release SMTP configuration mutex: $($_.Exception.Message)"
                )
            }
        }

        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
        #endregion
    }
}
