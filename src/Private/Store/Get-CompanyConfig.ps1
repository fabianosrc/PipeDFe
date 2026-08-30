<#
.SYNOPSIS
Reads one or all company configuration files.

.DESCRIPTION
Deserializes the company JSON file stored under the per-CNPJ config folder.

When -Cnpj is supplied the function returns that single company or throws a
terminating error with ErrorId 'CompanyNotFound' if the file does not exist.

When -Cnpj is omitted the function scans every subfolder under the module
store root and returns all companies whose config file can be read.
Subfolders without a matching config file are silently skipped.
Subfolders whose config file cannot be deserialized emit a non-terminating
warning and are skipped; the remaining companies are still returned.

Certificate passwords remain DPAPI-encrypted in the returned object.
Call Get-CompanyCertificatePassword to obtain the plaintext password.

.PARAMETER Cnpj
14-character CNPJ composed of uppercase letters and/or digits (supports
both the conventional numeric format and the alphanumeric format).
When omitted all registered companies are returned.

.OUTPUTS
[System.Management.Automation.PSCustomObject] - TypeName: PipeDFe.Company

.EXAMPLE
PS C:\> Get-CompanyConfig -Cnpj '12345678000195'

Returns the configuration for the specified CNPJ.

.EXAMPLE
PS C:\> Get-CompanyConfig

Returns configuration objects for all registered companies.

.EXAMPLE
PS C:\> Get-CompanyConfig | Where-Object IsActive

Returns only active companies.

.NOTES
Private dependencies (resolved via module scope):
  Get-StorePath    - resolves store paths by scope.
  Read-companyFileName - deserializes a single company JSON file.
#>
function Get-CompanyConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        # 14-character CNPJ: uppercase letters and/or digits.
        # Supports the conventional numeric format and the alphanumeric
        # format introduced by Receita Federal (Instrucao Normativa 2.229/2024).
        # The (?-i) inline flag makes the match case-sensitive even when the
        # caller has set a case-insensitive regex preference.
        [Parameter()]
        [ValidatePattern('^(?-i)[A-Z0-9]{14}$')]
        [string]$Cnpj
    )

    # Single-company branch
    if (-not [string]::IsNullOrEmpty($Cnpj)) {
        $configStorePath = Get-StorePath -Scope Config -Cnpj $Cnpj
        $companyFileName = Join-Path -Path $configStorePath -ChildPath "$Cnpj.json"

        if (-not (Test-Path -LiteralPath $companyFileName -PathType Leaf)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new("Company not found: '$Cnpj'"),
                    'CompanyNotFound',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                    $Cnpj
                )
            )
        }

        Read-companyFileName -Path $companyFileName
        return
    }

    # Bulk-read branch
    $root = Get-StorePath -Scope Root

    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Write-Verbose -Message 'Store root does not exist. No companies registered.'
        return
    }

    $subfolders = @(Get-ChildItem -LiteralPath $root -Directory)

    if ($subfolders.Count -eq 0) {
        Write-Verbose -Message 'Store root is empty. No companies registered.'
        return
    }

    foreach ($folder in $subfolders) {
        $cnpjKey = $folder.Name

        $joinParams  = @{
            Path      = $folder.FullName
            ChildPath = 'config'
        }

        $configDirectory = Join-Path @joinParams
        $companyFileName = Join-Path -Path $configDirectory -ChildPath "$cnpjKey.json"

        if (-not (Test-Path -LiteralPath $companyFileName -PathType Leaf)) {
            Write-Debug -Message "Skipping '$cnpjKey': config file not found."
            continue
        }

        try {
            Read-companyFileName -Path $companyFileName
        } catch {
            Write-Warning -Message (
                "Skipping CNPJ '$cnpjKey': unable to read config file. $($_.Exception.Message)"
            )
        }
    }
}

#region Private Helper
<#
.SYNOPSIS
Deserializes a single company JSON file into a [pscustomobject].

.DESCRIPTION
Performs three post-processing steps after ConvertFrom-Json:

  1. Timestamp preservation - ConvertFrom-Json converts ISO 8601 strings to
     [DateTime] in PS 7.3+, which loses offset precision on round-trips.
     CreatedAt and UpdatedAt are restored from the raw JSON text so they
     remain plain strings regardless of the PowerShell version.

  2. Certificado normalization - guarantees the Certificado block is always
     a [pscustomobject] with Path and EncryptedPassword properties, even
     when the source JSON omits the block entirely.

  3. Email array normalization - guarantees Para, Cc, and Cco are always
     arrays (never $null or a scalar), filtering out any null/empty entries.
     Also tolerates a missing Email block in the source JSON.

The object receives the 'PipeDFe.Company' type name so that downstream
format files and type extensions can target it with ETS.
#>
function Read-companyFileName {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    # Read the raw bytes then decode with UTF-8 to honour BOM when present.
    # Using [System.IO.File]::ReadAllText avoids Get-Content quirks in PS 5.1
    # (e.g. -Raw adds a trailing newline on some builds).
    $raw     = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
    $company = $raw | ConvertFrom-Json

    # 1. Timestamp preservation
    # Regex captures the raw ISO 8601 string from the JSON text so that
    # ConvertFrom-Json's automatic DateTime coercion (PS 7.3+) is bypassed.
    $createdAtMatch = [regex]::Match($raw, '"CreatedAt"\s*:\s*"([^"]+)"')
    $updatedAtMatch = [regex]::Match($raw, '"UpdatedAt"\s*:\s*"([^"]+)"')

    $createdAtValue = if ($createdAtMatch.Success) {
        $createdAtMatch.Groups[1].Value
    } else {
        $null
    }

    $updatedAtValue = if ($updatedAtMatch.Success) {
        $updatedAtMatch.Groups[1].Value
    } else {
        $null
    }

    if ($null -eq $company.PSObject.Properties['CreatedAt']) {
        $company.PSObject.Properties.Add(
            [System.Management.Automation.PSNoteProperty]::new(
                'CreatedAt', $createdAtValue
            )
        )
    } else {
        $company.CreatedAt = $createdAtValue
    }

    if ($null -eq $company.PSObject.Properties['UpdatedAt']) {
        $company.PSObject.Properties.Add(
            [System.Management.Automation.PSNoteProperty]::new(
                'UpdatedAt', $updatedAtValue
            )
        )
    } else {
        $company.UpdatedAt = $updatedAtValue
    }

    # 2. Certificado normalization
    $certObj  = $company.PSObject.Properties['Certificado']

    $certPath = if ($null -ne $certObj) {
        $certObj.Value.Path
    } else {
        $null
    }

    $certPass = if ($null -ne $certObj) {
        $certObj.Value.EncryptedPassword
    } else {
        $null
    }

    $certValue = [PSCustomObject]@{
        Path              = $certPath
        EncryptedPassword = $certPass
    }

    if ($null -eq $certObj) {
        $company.PSObject.Properties.Add(
            [System.Management.Automation.PSNoteProperty]::new(
                'Certificado', $certValue
            )
        )
    } else {
        $company.Certificado = $certValue
    }

    # 3. Email array normalization
    $email = $company.PSObject.Properties['Email']
    $emailValue = [PSCustomObject]@{
        Para = @(if ($null -ne $email) { $email.Value.Para | Where-Object { $null -ne $_ } })
        Cc   = @(if ($null -ne $email) { $email.Value.Cc   | Where-Object { $null -ne $_ } })
        Cco  = @(if ($null -ne $email) { $email.Value.Cco  | Where-Object { $null -ne $_ } })
    }

    if ($null -eq $email) {
        $company.PSObject.Properties.Add(
            [System.Management.Automation.PSNoteProperty]::new(
                'Email', $emailValue
            )
        )
    } else {
        $company.Email = $emailValue
    }

    # ETS type name
    $company.PSObject.TypeNames.Insert(0, 'PipeDFe.Company')

    $company
}
#endregion
