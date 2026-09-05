<#
.SYNOPSIS
Tests SMTP connectivity and authentication by sending a test message.

.DESCRIPTION
Validates SMTP connectivity and authentication by sending a test message
to the sender's own address (From.Email). No external recipients are
involved.

When called without parameters, tests the global SMTP configuration.
When called with -Cnpj, resolves the company SMTP via Resolve-DFeSmtp,
falling back to the global configuration with a warning if none is found.
When called with -SmtpConfig, tests the provided configuration directly.

Never throws. Always returns a structured result object.

.PARAMETER Cnpj
14-digit CNPJ of the company whose SMTP configuration will be tested.
Resolves via Resolve-DFeSmtp with automatic fallback to global SMTP when
no company-specific configuration exists.

.PARAMETER SmtpConfig
SMTP configuration object as returned by Get-PipeSmtp or Resolve-DFeSmtp.
Tested directly without any resolution or fallback logic.

.OUTPUTS
System.Management.Automation.PSCustomObject

  Success       [bool]   - Whether the test message was sent successfully.
  Source        [string] - 'Company', 'Global', or 'Direct'.
  Server        [string] - SMTP server hostname tested.
  Port          [int]    - SMTP server port tested.
  Authenticated [bool]   - Whether the SMTP operation authenticated successfully.
  ErrorMessage  [string] - Error message on failure, $null on success.
  FailureStage  [string] - Stage that failed: 'Configuration', 'Credentials',
                           'Connection', 'Message', 'Send', or $null on success.

.EXAMPLE
PS C:\> Test-PipeSmtp

.EXAMPLE
PS C:\> Test-PipeSmtp -Cnpj 'AB12CD34000195'

.EXAMPLE
PS C:\> Test-PipeSmtp -SmtpConfig (Get-PipeSmtp)

.NOTES
  Private dependencies:
    ConvertTo-NormalizedCnpj
    Get-CompanyConfig
    Get-SmtpConfig
    Resolve-DFeSmtp
    ConvertFrom-DpapiString
    Send-PipeSmtpTestMessage
#>
function Test-PipeSmtp {
    [CmdletBinding(DefaultParameterSetName = 'ByGlobal')]
    [OutputType([pscustomobject])]
    param (
        [Parameter(ParameterSetName = 'ByCnpj')]
        [ValidatePattern('^(?-i)[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(ParameterSetName = 'ByConfig')]
        [ValidateNotNull()]
        [pscustomobject]$SmtpConfig
    )

    #region Helpers
    function New-SmtpTestResult {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Internal result builder. No state is changed.'
        )]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param (
            [Parameter(Mandatory)]
            [bool]$Success,

            [Parameter(Mandatory)]
            [string]$Source,

            [Parameter()]
            [string]$Server,

            [Parameter()]
            [int]$Port,

            [Parameter(Mandatory)]
            [bool]$Authenticated,

            [Parameter()]
            [string]$ErrorMessage,

            [Parameter()]
            [string]$FailureStage
        )

        [PSCustomObject]@{
            Success       = $Success
            Source        = $Source
            Server        = $Server
            Port          = $Port
            Authenticated = $Authenticated
            ErrorMessage  = $ErrorMessage
            FailureStage  = $FailureStage
        }
    }
    #endregion

    $config = $null
    $source = 'Global'

    # Resolve SMTP configuration
    try {
        switch ($PSCmdlet.ParameterSetName) {
            'ByCnpj' {
                $cnpjNormalized = ConvertTo-NormalizedCnpj -Value $Cnpj
                $company        = Get-CompanyConfig -Cnpj $cnpjNormalized

                $resolveWarnings = $null

                $resolveParams = @{
                    Company         = $company
                    WarningVariable = 'resolveWarnings'
                }

                $config = Resolve-DFeSmtp @resolveParams
                $source = if ($resolveWarnings) { 'Global' } else { 'Company' }
            }

            'ByConfig' {
                $config = $SmtpConfig
                $source = 'Direct'
            }

            'ByGlobal' {
                $config = Get-SmtpConfig -ErrorAction Stop
                $source = 'Global'
            }
        }
    } catch {
        $resultParams = @{
            Success       = $false
            Source        = $source
            Authenticated = $false
            ErrorMessage  = $_.Exception.Message
            FailureStage  = 'Configuration'
        }

        return New-SmtpTestResult @resultParams
    }

    if ($null -eq $config) {
        $resultParams = @{
            Success       = $false
            Source        = $source
            Authenticated = $false
            ErrorMessage  = 'SMTP configuration not found.'
            FailureStage  = 'Configuration'
        }

        return New-SmtpTestResult @resultParams
    }

    # Validate SMTP configuration
    $server = [string]$config.Server

    if ([string]::IsNullOrWhiteSpace($server)) {
        $resultParams = @{
            Success       = $false
            Source        = $source
            Authenticated = $false
            ErrorMessage  = 'SMTP server is not configured.'
            FailureStage  = 'Configuration'
        }

        return New-SmtpTestResult @resultParams
    }

    $port = [int]$config.Port

    if ($port -lt 1 -or $port -gt 65535) {
        $resultParams = @{
            Success       = $false
            Source        = $source
            Server        = $server
            Port          = $port
            Authenticated = $false
            ErrorMessage  = "SMTP port '$port' is outside the valid range 1-65535."
            FailureStage  = 'Configuration'
        }

        return New-SmtpTestResult @resultParams
    }

    $username = [string]$config.Username

    if ([string]::IsNullOrWhiteSpace($username)) {
        $resultParams = @{
            Success       = $false
            Source        = $source
            Server        = $server
            Port          = $port
            Authenticated = $false
            ErrorMessage  = 'SMTP username is not configured.'
            FailureStage  = 'Configuration'
        }

        return New-SmtpTestResult @resultParams
    }

    $fromAddress = if ($null -ne $config.From) {
        [string]$config.From.Email
    } else {
        $null
    }

    if ([string]::IsNullOrWhiteSpace($fromAddress)) {
        $resultParams = @{
            Success       = $false
            Source        = $source
            Server        = $server
            Port          = $port
            Authenticated = $false
            ErrorMessage  = 'SMTP sender address is not configured.'
            FailureStage  = 'Configuration'
        }

        return New-SmtpTestResult @resultParams
    }

    try {
        $null = [System.Net.Mail.MailAddress]::new($fromAddress)
    } catch {
        $resultParams = @{
            Success       = $false
            Source        = $source
            Server        = $server
            Port          = $port
            Authenticated = $false
            ErrorMessage  = "SMTP sender address '$fromAddress' is invalid."
            FailureStage  = 'Configuration'
        }

        return New-SmtpTestResult @resultParams
    }

    $timeoutSeconds = if ($null -ne $config.Timeout -and [int]$config.Timeout -gt 0) {
        [int]$config.Timeout
    } else {
        30
    }

    # Resolve credentials
    try {
        $securePassword = ConvertFrom-DpapiString -Value $config.Password

        $credential = [System.Net.NetworkCredential]::new(
            $username,
            $securePassword
        )
    } catch {
        $resultParams = @{
            Success       = $false
            Source        = $source
            Server        = $server
            Port          = $port
            Authenticated = $false
            ErrorMessage  = $_.Exception.Message
            FailureStage  = 'Credentials'
        }

        return New-SmtpTestResult @resultParams
    }

    # Create SMTP client
    $smtpClient = $null

    try {
        $smtpClient                       = [System.Net.Mail.SmtpClient]::new($server, $port)
        $smtpClient.EnableSsl             = [bool]$config.Ssl
        $smtpClient.DeliveryMethod        = [System.Net.Mail.SmtpDeliveryMethod]::Network
        $smtpClient.UseDefaultCredentials = $false
        $smtpClient.Credentials           = $credential
        $smtpClient.Timeout               = $timeoutSeconds * 1000
    } catch {
        if ($null -ne $smtpClient) {
            $smtpClient.Dispose()
        }

        $resultParams = @{
            Success       = $false
            Source        = $source
            Server        = $server
            Port          = $port
            Authenticated = $false
            ErrorMessage  = $_.Exception.Message
            FailureStage  = 'Connection'
        }

        return New-SmtpTestResult @resultParams
    }

    # Build test message
    $testMsg = $null
    $bodyMsg = 'This is an automated SMTP connectivity test sent by PipeDFe. You can ignore this message.'

    try {
        $testMsg            = [System.Net.Mail.MailMessage]::new()
        $testMsg.From       = [System.Net.Mail.MailAddress]::new($fromAddress)
        $testMsg.Subject    = '[PipeDFe] SMTP connectivity test'
        $testMsg.Body       = $bodyMsg
        $testMsg.IsBodyHtml = $false

        [void]$testMsg.To.Add([System.Net.Mail.MailAddress]::new($fromAddress))
    } catch {
        if ($null -ne $testMsg) {
            $testMsg.Dispose()
        }

        $smtpClient.Dispose()

        $resultParams = @{
            Success       = $false
            Source        = $source
            Server        = $server
            Port          = $port
            Authenticated = $false
            ErrorMessage  = $_.Exception.Message
            FailureStage  = 'Message'
        }

        return New-SmtpTestResult @resultParams
    }

    # Send test message
    try {
        $sendParams = @{
            Client  = $smtpClient
            Message = $testMsg
        }

        Send-PipeSmtpTestMessage @sendParams

        $resultParams = @{
            Success       = $true
            Source        = $source
            Server        = $server
            Port          = $port
            Authenticated = $true
            FailureStage  = $null
        }

        return New-SmtpTestResult @resultParams
    } catch {
        $resultParams = @{
            Success       = $false
            Source        = $source
            Server        = $server
            Port          = $port
            Authenticated = $false
            ErrorMessage  = $_.Exception.Message
            FailureStage  = 'Send'
        }

        return New-SmtpTestResult @resultParams
    } finally {
        if ($null -ne $testMsg) {
            $testMsg.Dispose()
        }

        if ($null -ne $smtpClient) {
            $smtpClient.Dispose()
        }
    }
}
