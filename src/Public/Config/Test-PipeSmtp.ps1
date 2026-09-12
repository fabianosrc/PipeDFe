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

The -TimeoutSeconds parameter overrides the timeout configured in the
SMTP object. When omitted, the configured timeout is used; when the
configured timeout is also absent or zero, defaults to 15 seconds.

Before attempting SMTP, performs a TCP connectivity probe to the server
and port. A failed TCP probe returns immediately with a clear diagnosis,
avoiding the full SMTP timeout. A successful TCP probe proceeds to the
full SMTP send, allowing the failure message to distinguish between a
network/firewall problem and an SMTP/TLS configuration problem.

Note: System.Net.Mail.SmtpClient does not support implicit TLS (port 465).
Send-SmtpMessage implements the SMTP protocol directly over
TcpClient and SslStream to support both port 465 (implicit TLS) and
port 587 (STARTTLS).

Never throws. Always returns a structured result object.

.PARAMETER Cnpj
14-digit CNPJ of the company whose SMTP configuration will be tested.
Resolves via Resolve-DFeSmtp with automatic fallback to global SMTP when
no company-specific configuration exists.

.PARAMETER SmtpConfig
SMTP configuration object as returned by Get-PipeSmtp or Resolve-DFeSmtp.
Tested directly without any resolution or fallback logic.

.PARAMETER TimeoutSeconds
Optional timeout override in seconds. Applies to both the TCP probe and
the SMTP send. Overrides the timeout configured in the SMTP object.
Must be greater than zero.

.OUTPUTS
System.Management.Automation.PSCustomObject - TypeName: PipeDFe.SmtpTestResult

  Success       [bool]   - Whether the test message was sent successfully.
  Source        [string] - 'Company', 'Global', or 'Direct'.
  Server        [string] - SMTP server hostname tested.
  Port          [int]    - SMTP server port tested.
  Ssl           [bool]   - Whether SSL/TLS was enabled during the test.
  Authenticated [bool]   - Whether SMTP authentication succeeded.
  ErrorMessage  [string] - Error message on failure, $null on success.
  FailureStage  [string] - Stage that failed: 'Configuration', 'Credentials',
                           'Connection', 'Message', 'Send', or $null on success.

.EXAMPLE
PS C:\> Test-PipeSmtp

.EXAMPLE
PS C:\> Test-PipeSmtp -Cnpj 'AB12CD34000195'

.EXAMPLE
PS C:\> Test-PipeSmtp -SmtpConfig (Get-PipeSmtp)

.EXAMPLE
PS C:\> Test-PipeSmtp -TimeoutSeconds 5

.NOTES
Private dependencies:
  ConvertTo-NormalizedCnpj
  Get-CompanyConfig
  Get-SmtpConfig
  Resolve-DFeSmtp
  ConvertFrom-DpapiString
  Send-SmtpMessage
  Test-SmtpTcpConnection
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
        [pscustomobject]$SmtpConfig,

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$TimeoutSeconds
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

            [Parameter()]
            [bool]$Ssl,

            [Parameter(Mandatory)]
            [bool]$Authenticated,

            [Parameter()]
            [string]$ErrorMessage,

            [Parameter()]
            [string]$FailureStage
        )

        $result = [PSCustomObject]@{
            Success       = $Success
            Source        = $Source
            Server        = $Server
            Port          = $Port
            Ssl           = $Ssl
            Authenticated = $Authenticated
            ErrorMessage  = $ErrorMessage
            FailureStage  = $FailureStage
        }

        $result.PSObject.TypeNames.Insert(0, 'PipeDFe.SmtpTestResult')

        $result
    }
    #endregion

    $config = $null
    $source = 'Global'

    #region Resolve configuration
    try {
        switch ($PSCmdlet.ParameterSetName) {
            'ByCnpj' {
                $cnpjNormalized = ConvertTo-NormalizedCnpj -Value $Cnpj
                $companyConfig  = Get-CompanyConfig -Cnpj $cnpjNormalized

                $resolveWarnings = $null

                $resolveParams = @{
                    Company         = $companyConfig
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
            Ssl           = $false
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
            Ssl           = $false
            Authenticated = $false
            ErrorMessage  = 'SMTP configuration not found.'
            FailureStage  = 'Configuration'
        }

        return New-SmtpTestResult @resultParams
    }
    #endregion

    #region Validate configuration
    $server = [string]$config.Server

    if ([string]::IsNullOrWhiteSpace($server)) {
        $resultParams = @{
            Success       = $false
            Source        = $source
            Ssl           = $false
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
            Ssl           = $false
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
            Ssl           = [bool]$config.Ssl
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
            Ssl           = [bool]$config.Ssl
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
            Ssl           = [bool]$config.Ssl
            Authenticated = $false
            ErrorMessage  = "SMTP sender address '$fromAddress' is invalid."
            FailureStage  = 'Configuration'
        }

        return New-SmtpTestResult @resultParams
    }

    $sslEnabled = [bool]$config.Ssl

    $effectiveTimeout = if ($PSBoundParameters.ContainsKey('TimeoutSeconds')) {
        $TimeoutSeconds
    } elseif ($null -ne $config.PSObject.Properties['Timeout'] -and
        [int]$config.Timeout -gt 0
    ) {
        [int]$config.Timeout
    } else {
        15
    }
    #endregion

    #region Credentials
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
            Ssl           = $sslEnabled
            Authenticated = $false
            ErrorMessage  = $_.Exception.Message
            FailureStage  = 'Credentials'
        }

        return New-SmtpTestResult @resultParams
    }
    #endregion

    #region TCP probe
    # Distinguishes network/firewall failures from SMTP/TLS failures
    # without waiting for the full SMTP timeout. The TCP connection is
    # intentionally closed after the probe - Send-SmtpMessage opens its
    # own connection for the actual SMTP exchange.
    $tcpParams = @{
        Server    = $server
        Port      = $port
        TimeoutMs = $effectiveTimeout * 1000
    }

    try {
        $tcpConnected = Test-SmtpTcpConnection @tcpParams
    } catch {
        $errorMessage = if ($null -ne $_.Exception.InnerException) {
            $_.Exception.InnerException.Message
        } else {
            $_.Exception.Message
        }

        $resultParams = @{
            Success       = $false
            Source        = $source
            Server        = $server
            Port          = $port
            Ssl           = $sslEnabled
            Authenticated = $false
            ErrorMessage  = "TCP connection to '$server':'$port' failed: $errorMessage"
            FailureStage  = 'Connection'
        }

        return New-SmtpTestResult @resultParams
    }

    if (-not $tcpConnected) {
        $resultParams = @{
            Success       = $false
            Source        = $source
            Server        = $server
            Port          = $port
            Ssl           = $sslEnabled
            Authenticated = $false
            ErrorMessage  = "TCP connection to '$server':'$port' timed out. Check server address, port and firewall rules."
            FailureStage  = 'Connection'
        }

        return New-SmtpTestResult @resultParams
    }
    #endregion

    #region Build test message
    $testMsg = $null

    try {
        $testMsg                 = [System.Net.Mail.MailMessage]::new()
        $testMsg.From            = [System.Net.Mail.MailAddress]::new($fromAddress)
        $testMsg.Subject         = '[PipeDFe] SMTP connectivity test'
        $testMsg.Body            = 'This is an automated SMTP connectivity test sent by PipeDFe. You can ignore this message.'
        $testMsg.IsBodyHtml      = $false
        $testMsg.BodyEncoding    = [System.Text.Encoding]::UTF8
        $testMsg.SubjectEncoding = [System.Text.Encoding]::UTF8

        [void]$testMsg.To.Add([System.Net.Mail.MailAddress]::new($fromAddress))
    } catch {
        if ($null -ne $testMsg) {
            $testMsg.Dispose()
        }

        $resultParams = @{
            Success       = $false
            Source        = $source
            Server        = $server
            Port          = $port
            Ssl           = $sslEnabled
            Authenticated = $false
            ErrorMessage  = $_.Exception.Message
            FailureStage  = 'Message'
        }

        return New-SmtpTestResult @resultParams
    }
    #endregion

    #region SMTP send
    try {
        $sendParams = @{
            Server         = $server
            Port           = $port
            EnableSsl      = $sslEnabled
            Credential     = $credential
            Message        = $testMsg
            TimeoutSeconds = $effectiveTimeout
        }

        Send-SmtpMessage @sendParams

        $resultParams = @{
            Success       = $true
            Source        = $source
            Server        = $server
            Port          = $port
            Ssl           = $sslEnabled
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
            Ssl           = $sslEnabled
            Authenticated = $false
            ErrorMessage  = $_.Exception.Message
            FailureStage  = 'Send'
        }

        return New-SmtpTestResult @resultParams
    } finally {
        if ($null -ne $testMsg) {
            $testMsg.Dispose()
        }
    }
    #endregion
}
