<#
.SYNOPSIS
Creates or retrieves a persistent DFe delivery.

.DESCRIPTION
Creates a delivery in Prepared state, including its archive and recipient
metadata, using one SQLite transaction.

The delivery_key is a SHA-256 hash of a canonical representation containing:
  - UTC period start and end
  - Archive type and SHA-256, sorted ordinally
  - Recipient type and normalized address, sorted ordinally

Archive file names and destination paths are persisted but do not participate
in delivery identity. The archive content is identified by its SHA-256 hash.

Archive files are verified before opening the database transaction. Their
actual SHA-256 must match the supplied FileHash.

Repeated calls with the same identity retrieve the existing delivery and
its persisted metadata. Existing delivery states are never reset.

Recipients are normalized through ConvertTo-NormalizedMailRecipient.
Duplicate addresses within the same recipient type are stored only once.
Recipient names are not persisted because the delivery schema stores
addresses only.

The delivery and all child records are committed atomically. A failure
during any insert rolls back the entire operation.

.PARAMETER Cnpj
14-character normalized CNPJ identifying the company index.

.PARAMETER PeriodStart
Inclusive start of the delivery period.

.PARAMETER PeriodEnd
Inclusive end of the delivery period.

.PARAMETER Archives
Archive objects returned by New-DFeArchive. Each object must expose:
  TipoDFe
  FileName
  FileHash
  DestPath

At least one archive is required.

.PARAMETER To
Primary recipients. At least one valid normalized address is required.

.PARAMETER Cc
Optional carbon-copy recipients.

.PARAMETER Bcc
Optional blind-carbon-copy recipients.

.OUTPUTS
System.Management.Automation.PSCustomObject

PSTypeName:
  PipeDFe.Delivery

Properties:
  Cnpj                 [string]
  DeliveryId           [string]
  DeliveryKey          [string]
  PeriodStart          [string]
  PeriodEnd            [string]
  DeliveryStatus       [string]
  CreatedAt            [string]
  UpdatedAt            [string]
  DeliveryStartedAt    [string]
  DeliveredAt          [string]
  DeliveryError        [string]
  Archives             [pscustomobject[]]
  Recipients           [pscustomobject[]]
  Created              [bool]

Created is true only when this invocation inserted the delivery.
It is false when an existing delivery was retrieved.

.EXAMPLE
PS C:\> $params = @{
    Cnpj        = '12345678000199'
    PeriodStart = [DateTimeOffset]'2026-11-01T00:00:00-03:00'
    PeriodEnd   = [DateTimeOffset]'2026-11-30T23:59:59-03:00'
    Archives    = $archives
    To          = $company.Email.Para
    Cc          = $company.Email.Cc
    Bcc         = $company.Email.Cco
}

PS C:\> $delivery = New-DFeDelivery @params

.NOTES
Private dependencies:
  ConvertTo-NormalizedMailRecipient
  Get-FileSha256
  Open-DFeIndexConnection
#>
function New-DFeDelivery {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'State changes are controlled by the delivery workflow.'
    )]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingEmptyCatchBlock',
        '',
        Justification = 'Rollback failures are intentionally ignored to preserve the original error.'
    )]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^(?-i)[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [DateTimeOffset]$PeriodStart,

        [Parameter(Mandatory)]
        [DateTimeOffset]$PeriodEnd,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Archives,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$To,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Cc = @(),

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Bcc = @()
    )

    #region Period validation
    $periodStartUtc = $PeriodStart.ToUniversalTime()
    $periodEndUtc   = $PeriodEnd.ToUniversalTime()

    if ($periodEndUtc -lt $periodStartUtc) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'PeriodEnd must be greater than or equal to PeriodStart.'
                ),
                'DFeDeliveryInvalidPeriod',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $PeriodEnd
            )
        )
    }

    $invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

    $periodStartText = $periodStartUtc.ToString('o', $invariantCulture)
    $periodEndText   = $periodEndUtc.ToString('o', $invariantCulture)
    #endregion

    #region Archive validation and normalization
    if ($Archives.Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'At least one archive is required to create a delivery.'
                ),
                'DFeDeliveryArchiveRequired',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Archives
            )
        )
    }

    $normalizedArchives = [System.Collections.Generic.List[pscustomobject]]::new()

    $seenArchiveTypes = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($archive in $Archives) {
        if ($null -eq $archive) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'Archive entries must not be null.'
                    ),
                    'DFeDeliveryArchiveInvalid',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $archive
                )
            )
        }

        foreach ($propertyName in @('TipoDFe', 'FileName', 'FileHash', 'DestPath')) {
            $property = $archive.PSObject.Properties[$propertyName]

            if ($null -eq $property -or
                [string]::IsNullOrWhiteSpace([string]$property.Value)) {

                $PSCmdlet.ThrowTerminatingError(
                    [System.Management.Automation.ErrorRecord]::new(
                        [System.ArgumentException]::new(
                            "Archive is missing a valid '$propertyName' property."
                        ),
                        'DFeDeliveryArchiveInvalid',
                        [System.Management.Automation.ErrorCategory]::InvalidArgument,
                        $archive
                    )
                )
            }
        }

        # ToUpperInvariant ensures identity is case-insensitive across calls.
        # The deduplication HashSet already uses OrdinalIgnoreCase; normalizing
        # here keeps the canonical form consistent in the delivery key.
        $archiveType     = ([string]$archive.TipoDFe).Trim().ToUpperInvariant()
        $archiveFileName = ([string]$archive.FileName).Trim()
        $archiveHash     = ([string]$archive.FileHash).Trim().ToLowerInvariant()
        $destinationPath = ([string]$archive.DestPath).Trim()

        if ($archiveType.IndexOf([char]0) -ge 0) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'Archive TipoDFe must not contain null characters.'
                    ),
                    'DFeDeliveryArchiveInvalid',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $archive
                )
            )
        }

        if ($archiveHash -notmatch '^[0-9a-f]{64}$') {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "Archive '$archiveType' has an invalid SHA-256 hash."
                    ),
                    'DFeDeliveryInvalidArchiveHash',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $archive
                )
            )
        }

        if (-not $seenArchiveTypes.Add($archiveType)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "More than one archive was supplied for type '$archiveType'."
                    ),
                    'DFeDeliveryDuplicateArchiveType',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $archive
                )
            )
        }

        try {
            $destinationPath = [System.IO.Path]::GetFullPath($destinationPath)
            $destinationFileName = [System.IO.Path]::GetFileName($destinationPath)
        } catch {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "Archive '$archiveType' has an invalid destination path.",
                        $_.Exception
                    ),
                    'DFeDeliveryArchiveInvalid',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $archive
                )
            )
        }

        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($archiveFileName, $destinationFileName)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "Archive '$archiveType' FileName does not match DestPath."
                    ),
                    'DFeDeliveryArchiveInvalid',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $archive
                )
            )
        }

        # Verify the actual artifact before opening the database transaction.
        # File I/O must not extend the transaction lifetime.
        $actualHash = Get-FileSha256 -Path $destinationPath

        if (-not [System.StringComparer]::Ordinal.Equals($actualHash, $archiveHash)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.InvalidDataException]::new(
                        "Archive '$archiveType' does not match its supplied SHA-256 hash."
                    ),
                    'DFeDeliveryArchiveHashMismatch',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $destinationPath
                )
            )
        }

        $normalizedArchives.Add(
            [PSCustomObject]@{
                TipoDFe  = $archiveType
                FileName = $archiveFileName
                FileHash = $archiveHash
                DestPath = $destinationPath
            }
        )
    }
    #endregion

    #region Recipient normalization
    $recipientRows = [System.Collections.Generic.List[pscustomobject]]::new()

    $recipientGroups = @(
        [PSCustomObject]@{
            RecipientType = 'To'
            Entries       = $To
        }
        [PSCustomObject]@{
            RecipientType = 'Cc'
            Entries       = $Cc
        }
        [PSCustomObject]@{
            RecipientType = 'Bcc'
            Entries       = $Bcc
        }
    )

    foreach ($recipientGroup in $recipientGroups) {
        $seenAddresses = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )

        $normalizedRecipients = @(
            ConvertTo-NormalizedMailRecipient -InputObject $recipientGroup.Entries
        )

        foreach ($recipient in $normalizedRecipients) {
            $address = [string]$recipient.Email

            if (-not $seenAddresses.Add($address)) {
                continue
            }

            $recipientRows.Add(
                [PSCustomObject]@{
                    RecipientType = $recipientGroup.RecipientType
                    Address       = $address
                }
            )
        }
    }

    $primaryRecipientCount = @(
        $recipientRows |
            Where-Object { $_.RecipientType -eq 'To' }
    ).Count

    if ($primaryRecipientCount -eq 0) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'At least one valid primary recipient (To) is required.'
                ),
                'DFeDeliveryMissingPrimaryRecipient',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $To
            )
        )
    }
    #endregion

    #region Deterministic delivery identity
    # Pre-initialize so the catch block always has a non-null targetObject
    # even when an exception is raised before the hash is computed.
    $deliveryKey = $null

    # Ordinal sorting avoids dependence on the machine's current culture.
    # Null separators distinguish the components of each composite identity.
    $archiveIdentity = [System.Collections.Generic.List[string]]::new()

    foreach ($archive in $normalizedArchives) {
        $archiveIdentity.Add(
            $archive.TipoDFe + [char]0 + $archive.FileHash
        )
    }

    $archiveIdentity.Sort([System.StringComparer]::Ordinal)

    $recipientIdentity = [System.Collections.Generic.List[string]]::new()

    foreach ($recipient in $recipientRows) {
        $recipientIdentity.Add(
            $recipient.RecipientType + [char]0 + $recipient.Address
        )
    }

    $recipientIdentity.Sort([System.StringComparer]::Ordinal)

    # Length-prefix every field to avoid delimiter ambiguity.
    $canonicalFields = [System.Collections.Generic.List[string]]::new()

    $canonicalFields.Add('PipeDFe.Delivery.v1')
    $canonicalFields.Add($periodStartText)
    $canonicalFields.Add($periodEndText)
    $canonicalFields.Add($archiveIdentity.Count.ToString($invariantCulture))

    foreach ($archiveToken in $archiveIdentity) {
        $canonicalFields.Add($archiveToken)
    }

    $canonicalFields.Add($recipientIdentity.Count.ToString($invariantCulture))

    foreach ($recipientToken in $recipientIdentity) {
        $canonicalFields.Add($recipientToken)
    }

    $canonicalBuilder = [System.Text.StringBuilder]::new()

    foreach ($field in $canonicalFields) {
        $fieldLength = $field.Length.ToString($invariantCulture)

        $null = $canonicalBuilder.Append($fieldLength)
        $null = $canonicalBuilder.Append(':')
        $null = $canonicalBuilder.Append($field)
        $null = $canonicalBuilder.Append('|')
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        $canonicalBytes = [System.Text.Encoding]::UTF8.GetBytes(
            $canonicalBuilder.ToString()
        )

        $deliveryKeyBytes = $sha256.ComputeHash($canonicalBytes)

        $deliveryKey = [System.BitConverter]::ToString(
            $deliveryKeyBytes
        ).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
    #endregion

    #region Persistence
    $deliveryId = [guid]::NewGuid().ToString('N')

    $timestamp = [System.DateTimeOffset]::UtcNow.ToString(
        'o',
        $invariantCulture
    )

    $connection  = $null
    $transaction = $null
    $reader      = $null

    $insertCommand          = $null
    $archiveCommand         = $null
    $conflictCommand        = $null
    $recipientCommand       = $null
    $deliveryCommand        = $null
    $archiveSelectCommand   = $null
    $recipientSelectCommand = $null

    try {
        $connection = Open-DFeIndexConnection -Cnpj $Cnpj
        $transaction = $connection.BeginTransaction()

        # Insert first to acquire SQLite's write lock before deciding whether
        # this delivery already exists. The unique key serializes concurrent
        # attempts for the same identity.
        $insertCommand = $connection.CreateCommand()
        $insertCommand.Transaction = $transaction
        $insertCommand.CommandText = @'
INSERT INTO dfe_delivery (
    delivery_id,
    delivery_key,
    period_start,
    period_end,
    delivery_status,
    created_at,
    updated_at
) VALUES (
    @delivery_id,
    @delivery_key,
    @period_start,
    @period_end,
    'Prepared',
    @created_at,
    @updated_at
)
ON CONFLICT (delivery_key) DO NOTHING;
'@

        $insertCommand.Parameters.AddWithValue('@delivery_id', $deliveryId) | Out-Null
        $insertCommand.Parameters.AddWithValue('@delivery_key', $deliveryKey) | Out-Null
        $insertCommand.Parameters.AddWithValue('@period_start', $periodStartText) | Out-Null
        $insertCommand.Parameters.AddWithValue('@period_end', $periodEndText) | Out-Null
        $insertCommand.Parameters.AddWithValue('@created_at', $timestamp) | Out-Null
        $insertCommand.Parameters.AddWithValue('@updated_at', $timestamp) | Out-Null

        $rowsInserted = [int]$insertCommand.ExecuteNonQuery()

        if ($rowsInserted -notin @(0, 1)) {
            throw [System.InvalidOperationException]::new(
                "Unexpected number of delivery rows inserted: $rowsInserted."
            )
        }

        # Block a new delivery identity when the same company and period
        # already has a completed or potentially transmitted delivery.
        # The existing delivery_key remains the idempotency authority
        # when the archive hashes and recipients have not changed.
        $conflictCommand = $connection.CreateCommand()
        $conflictCommand.Transaction = $transaction
        $conflictCommand.CommandText = @'
SELECT delivery_id
FROM dfe_delivery
WHERE period_start = @period_start
AND period_end = @period_end
AND delivery_key <> @delivery_key
AND delivery_status IN ('Delivered', 'Sending', 'Indeterminate')
LIMIT 1;
'@

        $conflictCommand.Parameters.AddWithValue(
            '@period_start',
            $periodStartText
        ) | Out-Null

        $conflictCommand.Parameters.AddWithValue(
            '@period_end',
            $periodEndText
        ) | Out-Null

        $conflictCommand.Parameters.AddWithValue(
            '@delivery_key',
            $deliveryKey
        ) | Out-Null

        $conflictingDeliveryId = $conflictCommand.ExecuteScalar()

        if ($null -ne $conflictingDeliveryId -and
            $conflictingDeliveryId -isnot [System.DBNull]
        ) {
            throw [System.InvalidOperationException]::new(
                'A delivery with a different identity already exists ' +
                'for this company and period in a terminal or uncertain ' +
                'SMTP state. Automatic redelivery is blocked. ' +
                "Existing DeliveryId: $conflictingDeliveryId"
            )
        }

        $wasCreated = $rowsInserted -eq 1

        if ($wasCreated) {
            # Persist archive metadata in the same transaction as the delivery.
            $archiveCommand = $connection.CreateCommand()
            $archiveCommand.Transaction = $transaction
            $archiveCommand.CommandText = @'
INSERT INTO dfe_delivery_archive (
    delivery_id,
    tipo_dfe,
    file_name,
    file_hash,
    dest_path
) VALUES (
    @delivery_id,
    @tipo_dfe,
    @file_name,
    @file_hash,
    @dest_path
);
'@

            $archiveIdParam = $archiveCommand.Parameters.Add(
                '@delivery_id',
                [System.Data.DbType]::String
            )

            $archiveTypeParam = $archiveCommand.Parameters.Add(
                '@tipo_dfe',
                [System.Data.DbType]::String
            )

            $archiveNameParam = $archiveCommand.Parameters.Add(
                '@file_name',
                [System.Data.DbType]::String
            )

            $archiveHashParam = $archiveCommand.Parameters.Add(
                '@file_hash',
                [System.Data.DbType]::String
            )

            $archivePathParam = $archiveCommand.Parameters.Add(
                '@dest_path',
                [System.Data.DbType]::String
            )

            foreach ($archive in $normalizedArchives) {
                $archiveIdParam.Value = $deliveryId
                $archiveTypeParam.Value = $archive.TipoDFe
                $archiveNameParam.Value = $archive.FileName
                $archiveHashParam.Value = $archive.FileHash
                $archivePathParam.Value = $archive.DestPath

                $archiveRowsInserted = $archiveCommand.ExecuteNonQuery()

                if ($archiveRowsInserted -ne 1) {
                    throw [System.InvalidOperationException]::new(
                        "Failed to persist archive '$($archive.TipoDFe)'."
                    )
                }
            }

            # Persist normalized recipient addresses in the same transaction.
            $recipientCommand = $connection.CreateCommand()
            $recipientCommand.Transaction = $transaction
            $recipientCommand.CommandText = @'
INSERT INTO dfe_delivery_recipient (
    delivery_id,
    recipient_type,
    address
) VALUES (
    @delivery_id,
    @recipient_type,
    @address
);
'@

            $recipientIdParam = $recipientCommand.Parameters.Add(
                '@delivery_id',
                [System.Data.DbType]::String
            )

            $recipientTypeParam = $recipientCommand.Parameters.Add(
                '@recipient_type',
                [System.Data.DbType]::String
            )

            $recipientAddressParam = $recipientCommand.Parameters.Add(
                '@address',
                [System.Data.DbType]::String
            )

            foreach ($recipient in $recipientRows) {
                $recipientIdParam.Value = $deliveryId
                $recipientTypeParam.Value = $recipient.RecipientType
                $recipientAddressParam.Value = $recipient.Address

                $recipientRowsInserted = $recipientCommand.ExecuteNonQuery()

                if ($recipientRowsInserted -ne 1) {
                    throw [System.InvalidOperationException]::new(
                        "Failed to persist recipient '$($recipient.Address)'."
                    )
                }
            }
        }

        # Read the persisted delivery instead of returning caller-supplied data.
        $deliveryCommand = $connection.CreateCommand()
        $deliveryCommand.Transaction = $transaction
        $deliveryCommand.CommandText = @'
SELECT
    delivery_id,
    period_start,
    period_end,
    delivery_status,
    created_at,
    updated_at,
    delivery_started_at,
    delivered_at,
    delivery_error
FROM dfe_delivery
WHERE delivery_key = @delivery_key;
'@

        $deliveryCommand.Parameters.AddWithValue('@delivery_key', $deliveryKey) |
            Out-Null

        $reader = $deliveryCommand.ExecuteReader()

        try {
            if (-not $reader.Read()) {
                throw [System.InvalidOperationException]::new(
                    'The delivery insert completed but the persisted record was not found.'
                )
            }

            $storedDeliveryId = $reader.GetString(0)
            $storedPeriodStart = $reader.GetString(1)
            $storedPeriodEnd = $reader.GetString(2)
            $storedStatus = $reader.GetString(3)
            $storedCreatedAt = $reader.GetString(4)
            $storedUpdatedAt = $reader.GetString(5)

            $storedStartedAt = if ($reader.IsDBNull(6)) {
                $null
            } else {
                $reader.GetString(6)
            }

            $storedDeliveredAt = if ($reader.IsDBNull(7)) {
                $null
            } else {
                $reader.GetString(7)
            }

            $storedError = if ($reader.IsDBNull(8)) {
                $null
            } else {
                $reader.GetString(8)
            }
        } finally {
            $reader.Dispose()
            $reader = $null
        }

        # Read archive metadata from SQLite.
        $archiveRows = [System.Collections.Generic.List[pscustomobject]]::new()

        $archiveSelectCommand = $connection.CreateCommand()
        $archiveSelectCommand.Transaction = $transaction
        $archiveSelectCommand.CommandText = @'
SELECT
    tipo_dfe,
    file_name,
    file_hash,
    dest_path
FROM dfe_delivery_archive
WHERE delivery_id = @delivery_id
ORDER BY tipo_dfe COLLATE BINARY;
'@

        $archiveSelectCommand.Parameters.AddWithValue(
            '@delivery_id',
            $storedDeliveryId
        ) | Out-Null

        $reader = $archiveSelectCommand.ExecuteReader()

        try {
            while ($reader.Read()) {
                $archiveRows.Add(
                    [PSCustomObject]@{
                        TipoDFe  = $reader.GetString(0)
                        FileName = $reader.GetString(1)
                        FileHash = $reader.GetString(2)
                        DestPath = $reader.GetString(3)
                    }
                )
            }
        } finally {
            $reader.Dispose()
            $reader = $null
        }

        # Read recipient metadata from SQLite.
        $storedRecipients = [System.Collections.Generic.List[pscustomobject]]::new()

        $recipientSelectCommand = $connection.CreateCommand()
        $recipientSelectCommand.Transaction = $transaction
        $recipientSelectCommand.CommandText = @'
SELECT
    recipient_type,
    address
FROM dfe_delivery_recipient
WHERE delivery_id = @delivery_id
ORDER BY recipient_type COLLATE BINARY, address COLLATE BINARY;
'@

        $recipientSelectCommand.Parameters.AddWithValue(
            '@delivery_id',
            $storedDeliveryId
        ) | Out-Null

        $reader = $recipientSelectCommand.ExecuteReader()

        try {
            while ($reader.Read()) {
                $storedRecipients.Add(
                    [PSCustomObject]@{
                        RecipientType = $reader.GetString(0)
                        Address       = $reader.GetString(1)
                    }
                )
            }
        } finally {
            $reader.Dispose()
            $reader = $null
        }

        $transaction.Commit()

        [PSCustomObject]@{
            PSTypeName         = 'PipeDFe.Delivery'
            Cnpj               = $Cnpj
            DeliveryId         = $storedDeliveryId
            DeliveryKey        = $deliveryKey
            PeriodStart        = $storedPeriodStart
            PeriodEnd          = $storedPeriodEnd
            DeliveryStatus     = $storedStatus
            CreatedAt          = $storedCreatedAt
            UpdatedAt          = $storedUpdatedAt
            DeliveryStartedAt  = $storedStartedAt
            DeliveredAt        = $storedDeliveredAt
            DeliveryError      = $storedError
            Archives           = $archiveRows.ToArray()
            Recipients         = $storedRecipients.ToArray()
            Created            = $wasCreated
        }
    } catch {
        $originalException = $_.Exception

        if ($null -ne $transaction) {
            try {
                $transaction.Rollback()
            } catch {
                # Preserve the original persistence error.
            }
        }

        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $originalException,
                'DFeDeliveryCreateFailed',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $deliveryKey
            )
        )
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }

        if ($null -ne $insertCommand) {
            $insertCommand.Dispose()
        }

        if ($null -ne $archiveCommand) {
            $archiveCommand.Dispose()
        }

        if ($null -ne $conflictCommand) {
            $conflictCommand.Dispose()
        }

        if ($null -ne $recipientCommand) {
            $recipientCommand.Dispose()
        }

        if ($null -ne $deliveryCommand) {
            $deliveryCommand.Dispose()
        }

        if ($null -ne $archiveSelectCommand) {
            $archiveSelectCommand.Dispose()
        }

        if ($null -ne $recipientSelectCommand) {
            $recipientSelectCommand.Dispose()
        }

        if ($null -ne $transaction) {
            $transaction.Dispose()
        }

        if ($null -ne $connection) {
            $connection.Dispose()
        }
    }
}
