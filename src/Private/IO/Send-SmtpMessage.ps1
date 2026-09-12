<#
.SYNOPSIS
Sends a test SMTP message using a raw protocol implementation.

.DESCRIPTION
Implements the SMTP protocol directly over TcpClient and SslStream,
bypassing System.Net.Mail.SmtpClient which does not support implicit
TLS (SMTPS) on port 465.

Supports two flows:

  Port 465 with EnableSsl:
    TCP → TLS (implicit, immediate) → greeting → EHLO → AUTH LOGIN →
    MAIL FROM → RCPT TO → DATA → QUIT

  Port 587 with EnableSsl:
    TCP → greeting → EHLO → STARTTLS → TLS → EHLO → AUTH LOGIN →
    MAIL FROM → RCPT TO → DATA → QUIT

  Port 587 without EnableSsl:
    TCP → greeting → EHLO → AUTH LOGIN → MAIL FROM → RCPT TO → DATA → QUIT

Only AUTH LOGIN is used. The server must advertise AUTH LOGIN in its
EHLO response. SMTPUTF8 is negotiated automatically when envelope
addresses contain non-ASCII characters.

Protocol framing (commands, response codes, line terminators) is
transmitted as UTF-8. All commands emitted by this function are
pure-ASCII literals, so this is equivalent to ASCII for the command
channel, but it additionally ensures that non-ASCII envelope addresses
(SMTPUTF8) and the non-ASCII message body/headers are transmitted as
the UTF-8 bytes they were declared to be, instead of being silently
mangled to '?' by an ASCII-constrained stream.

Throws on any SMTP protocol failure. The caller is responsible for
translating thrown exceptions into structured result objects.

.PARAMETER Server
SMTP server hostname.

.PARAMETER Port
SMTP server port. Values 1-65535 are accepted.

.PARAMETER EnableSsl
Whether to use TLS. Port 465 uses implicit TLS; port 587 uses STARTTLS.
Defaults to $true.

.PARAMETER Credential
Network credential containing the SMTP username and cleartext password.
System.Net.NetworkCredential is required for direct Base64 encoding of
credentials during AUTH LOGIN.

.PARAMETER Message
The MailMessage to send. From, To, Subject and Body are used.

.PARAMETER TimeoutSeconds
Connection and read/write timeout in seconds. Range 1-300.

.OUTPUTS
None.

.EXAMPLE
PS C:\> $sendParams = @{
    Server         = 'smtp.example.com'
    Port           = 465
    EnableSsl      = $true
    Credential     = $credential
    Message        = $message
    TimeoutSeconds = 15
}

PS C:\> Send-SmtpMessage @sendParams
#>
function Send-SmtpMessage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUsePSCredentialType',
        '',
        Justification = 'AUTH LOGIN requires direct access to the password for Base64 encoding.'
    )]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Creates in-memory stream wrappers and does not change system state.'
    )]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter',
        '',
        Justification = 'Parameters are required by the TLS callback signature.'
    )]
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$Port,

        [Parameter()]
        [bool]$EnableSsl = $true,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Net.NetworkCredential]$Credential,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Net.Mail.MailMessage]$Message,

        [Parameter(Mandatory)]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds
    )

    $timeoutMs  = $TimeoutSeconds * 1000
    $utf8NoBom  = [System.Text.UTF8Encoding]::new($false)

    $tcpClient     = $null
    $networkStream = $null
    $sslStream     = $null
    $reader        = $null
    $writer        = $null

    try {
        #region Protocol helpers
        function Read-SmtpResponse {
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param (
                [Parameter(Mandatory)]
                [System.IO.StreamReader]$Reader
            )

            $lines = [System.Collections.Generic.List[string]]::new()

            while ($true) {
                try {
                    $line = $Reader.ReadLine()
                } catch {
                    throw "Failed while reading SMTP response: $($_.Exception.Message)"
                }

                if ($null -eq $line) {
                    throw 'SMTP server closed the connection unexpectedly.'
                }

                if ($line.Length -lt 3 -or $line -notmatch '^\d{3}([ -])') {
                    throw "Invalid SMTP response: '$line'"
                }

                $lines.Add($line)

                if ($line.Length -ge 4 -and $line[3] -eq ' ') {
                    break
                }

                if ($line.Length -lt 4 -or $line[3] -ne '-') {
                    throw "Invalid SMTP response continuation: '$line'"
                }
            }

            $lastLine = $lines[$lines.Count - 1]
            $code     = [int]$lastLine.Substring(0, 3)

            [PSCustomObject]@{
                Code  = $code
                Lines = $lines.ToArray()
                Text  = $lines -join "`n"
            }
        }

        function Send-SmtpCommand {
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param (
                [Parameter(Mandatory)]
                [System.IO.StreamWriter]$Writer,

                [Parameter(Mandatory)]
                [System.IO.StreamReader]$Reader,

                [Parameter(Mandatory)]
                [string]$Command,

                [Parameter(Mandatory)]
                [int[]]$ExpectedCodes
            )

            Write-Verbose -Message "SMTP C: $Command"

            try {
                $Writer.WriteLine($Command)
                $Writer.Flush()
            } catch {
                throw "Failed to send SMTP command '$Command': $($_.Exception.Message)"
            }

            $response = Read-SmtpResponse -Reader $Reader

            Write-Verbose -Message "SMTP S: $($response.Text)"

            if ($ExpectedCodes -notcontains $response.Code) {
                throw (
                    "SMTP command failed. Command: '{0}'. Expected: {1}. Response: {2}" -f
                    $Command, ($ExpectedCodes -join ', '), $response.Text
                )
            }

            $response
        }

        function Test-SmtpCapability {
            [CmdletBinding()]
            [OutputType([bool])]
            param (
                [Parameter(Mandatory)]
                [string[]]$Lines,

                [Parameter(Mandatory)]
                [string]$Capability
            )

            foreach ($line in $Lines) {
                if ($line -match "^\d{3}[- ]$([regex]::Escape($Capability))(?:\s|$)") {
                    return $true
                }
            }

            return $false
        }

        function Get-SmtpCapabilityArgument {
            [CmdletBinding()]
            [OutputType([string])]
            param (
                [Parameter(Mandatory)]
                [string[]]$Lines,

                [Parameter(Mandatory)]
                [string]$Capability
            )

            foreach ($line in $Lines) {
                if ($line -match "^\d{3}[- ]$([regex]::Escape($Capability))(?:\s+(.*))?$") {
                    return $matches[1]
                }
            }

            return $null
        }

        function ConvertTo-MimeHeader {
            [CmdletBinding()]
            [OutputType([string])]
            param (
                [Parameter(Mandatory)]
                [AllowEmptyString()]
                [string]$Value
            )

            if ([string]::IsNullOrEmpty($Value)) {
                return [string]::Empty
            }

            $hasNonAscii = $Value.ToCharArray() |
                Where-Object { [int][char]$_ -gt 127 } |
                Select-Object -First 1

            if ($null -eq $hasNonAscii) {
                return $Value
            }

            $encoded = [System.Convert]::ToBase64String($utf8NoBom.GetBytes($Value))

            return "=?UTF-8?B?{0}?=" -f $encoded
        }

        function Write-SmtpDataLine {
            [CmdletBinding()]
            [OutputType([void])]
            param (
                [Parameter(Mandatory)]
                [System.IO.StreamWriter]$Writer,

                [Parameter(Mandatory)]
                [AllowEmptyString()]
                [string]$Line
            )

            # RFC 5321 dot-stuffing: lines beginning with '.' must be
            # prefixed with an additional '.' during DATA transmission.
            if ($Line.StartsWith('.')) {
                $Writer.WriteLine(".$Line")
            } else {
                $Writer.WriteLine($Line)
            }
        }

        function New-SmtpTextStream {
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param (
                [Parameter(Mandatory)]
                [System.IO.Stream]$Stream
            )

            # UTF-8 (no BOM) is used instead of ASCII so that:
            #   - SMTPUTF8 envelope addresses (MAIL FROM / RCPT TO) survive
            #     the wire transmission intact.
            #   - The message body/headers, declared as charset=utf-8 with
            #     8bit transfer encoding, are not silently corrupted to '?'
            #     by an ASCII-only encoder.
            # All literal SMTP commands issued by this function are
            # pure ASCII, so this is a strict superset with no protocol
            # regression.
            $streamReader = [System.IO.StreamReader]::new(
                $Stream,
                $utf8NoBom,
                $false,
                1024,
                $true
            )

            $streamWriter = [System.IO.StreamWriter]::new(
                $Stream,
                $utf8NoBom,
                1024,
                $true
            )

            $streamWriter.NewLine   = "`r`n"
            $streamWriter.AutoFlush = $false

            [PSCustomObject]@{
                Reader = $streamReader
                Writer = $streamWriter
            }
        }

        function New-SmtpSslStream {
            [CmdletBinding()]
            [OutputType([System.Net.Security.SslStream])]
            param (
                [Parameter(Mandatory)]
                [System.IO.Stream]$InnerStream,

                [Parameter(Mandatory)]
                [string]$TargetHost,

                [Parameter(Mandatory)]
                [int]$TimeoutMs,

                [Parameter(Mandatory)]
                [string]$FailureContext
            )

            $newSslStream = [System.Net.Security.SslStream]::new(
                $InnerStream,
                $false,
                {
                    param (
                        [object]$CallbackSender,
                        [System.Security.Cryptography.X509Certificates.X509Certificate]$Certificate,
                        [System.Security.Cryptography.X509Certificates.X509Chain]$Chain,
                        [System.Net.Security.SslPolicyErrors]$SslPolicyErrors
                    )

                    if ($SslPolicyErrors -ne [System.Net.Security.SslPolicyErrors]::None) {
                        Write-Verbose -Message "$FailureContext certificate validation failed: $SslPolicyErrors"

                        return $false
                    }

                    return $true
                }
            )

            $newSslStream.ReadTimeout  = $TimeoutMs
            $newSslStream.WriteTimeout = $TimeoutMs

            $newSslStream.AuthenticateAsClient(
                $TargetHost,
                $null,
                [System.Security.Authentication.SslProtocols]::None,
                $true
            )

            if (-not $newSslStream.IsAuthenticated -or -not $newSslStream.IsEncrypted) {
                throw "$FailureContext authentication failed."
            }

            $newSslStream
        }
        #endregion

        #region Validation
        if ($null -eq $Message.From) {
            throw 'Message.From must be specified.'
        }

        if ($Message.To.Count -eq 0) {
            throw 'Message must contain at least one recipient.'
        }

        if ([string]::IsNullOrWhiteSpace($Credential.UserName)) {
            throw 'SMTP username must not be empty.'
        }

        if ($Port -eq 465 -and -not $EnableSsl) {
            throw 'Port 465 requires implicit TLS. Set EnableSsl to $true.'
        }
        #endregion

        #region TCP
        $tcpClient   = [System.Net.Sockets.TcpClient]::new()
        $connectTask = $tcpClient.ConnectAsync($Server, $Port)

        if (-not $connectTask.Wait($timeoutMs)) {
            throw "TCP connection to '$Server':'$Port' timed out after $TimeoutSeconds second(s)."
        }

        if ($connectTask.IsFaulted) {
            $inner = $connectTask.Exception.InnerException

            if ($null -ne $inner) {
                throw "TCP connection to '$Server':'$Port' failed: $($inner.Message)"
            }

            throw "TCP connection to '$Server':'$Port' failed."
        }

        if (-not $tcpClient.Connected) {
            throw "TCP connection to '$Server':'$Port' failed."
        }

        $networkStream              = $tcpClient.GetStream()
        $networkStream.ReadTimeout  = $timeoutMs
        $networkStream.WriteTimeout = $timeoutMs
        #endregion

        #region TLS setup
        # Port 465 - implicit TLS: negotiate TLS immediately before any SMTP traffic.
        # Port 587 - STARTTLS: start plaintext, then upgrade after EHLO.
        $implicitTls = $Port -eq 465 -and $EnableSsl

        if ($implicitTls) {
            Write-Verbose -Message 'Starting implicit TLS.'

            $sslParams = @{
                InnerStream    = $networkStream
                TargetHost     = $Server
                TimeoutMs      = $timeoutMs
                FailureContext = 'TLS'
            }

            $sslStream = New-SmtpSslStream @sslParams

            $activeStream = $sslStream
        } else {
            $activeStream = $networkStream
        }
        #endregion

        #region Text streams
        $textStreams = New-SmtpTextStream -Stream $activeStream

        $reader = $textStreams.Reader
        $writer = $textStreams.Writer
        #endregion

        #region Greeting
        $greeting = Read-SmtpResponse -Reader $reader

        Write-Verbose -Message "SMTP S: $($greeting.Text)"

        if ($greeting.Code -ne 220) {
            throw "SMTP server rejected connection: $($greeting.Text)"
        }
        #endregion

        #region EHLO
        $ehloParams = @{
            Writer        = $writer
            Reader        = $reader
            Command       = 'EHLO PipeDFe'
            ExpectedCodes = @(250)
        }

        $ehlo = Send-SmtpCommand @ehloParams
        #endregion

        #region STARTTLS
        if (-not $implicitTls -and $EnableSsl) {
            $capParams = @{
                Lines      = $ehlo.Lines
                Capability = 'STARTTLS'
            }

            if (-not (Test-SmtpCapability @capParams)) {
                throw "SMTP server '$Server':'$Port' does not advertise STARTTLS."
            }

            $startTlsParams = @{
                Writer        = $writer
                Reader        = $reader
                Command       = 'STARTTLS'
                ExpectedCodes = @(220)
            }

            Send-SmtpCommand @startTlsParams | Out-Null

            # Dispose plaintext reader/writer before upgrading to TLS.
            # Nothing may be sent through the plaintext layer after STARTTLS.
            $reader.Dispose()
            $writer.Dispose()
            $reader = $null
            $writer = $null

            $sslParams = @{
                InnerStream    = $networkStream
                TargetHost     = $Server
                TimeoutMs      = $timeoutMs
                FailureContext = 'STARTTLS'
            }

            $sslStream = New-SmtpSslStream @sslParams

            $textStreams = New-SmtpTextStream -Stream $sslStream

            $reader = $textStreams.Reader
            $writer = $textStreams.Writer

            # RFC 3207: EHLO must be re-issued after STARTTLS.
            $ehloAfterTlsParams = @{
                Writer        = $writer
                Reader        = $reader
                Command       = 'EHLO PipeDFe'
                ExpectedCodes = @(250)
            }

            $ehlo = Send-SmtpCommand @ehloAfterTlsParams
        }
        #endregion

        #region AUTH LOGIN
        $authCapParams = @{
            Lines      = $ehlo.Lines
            Capability = 'AUTH'
        }

        $authArguments = Get-SmtpCapabilityArgument @authCapParams

        if ([string]::IsNullOrWhiteSpace($authArguments)) {
            throw "SMTP server '$Server':'$Port' does not advertise AUTH."
        }

        $authMethods = $authArguments -split '\s+' |
            Where-Object { $_ } |
            ForEach-Object { $_.ToUpperInvariant() }

        if ('LOGIN' -notin $authMethods) {
            throw (
                "SMTP server '$Server':'$Port' does not advertise AUTH LOGIN. " +
                "Advertised mechanisms: $($authMethods -join ', ')"
            )
        }

        $writer.WriteLine('AUTH LOGIN')
        $writer.Flush()

        $response = Read-SmtpResponse -Reader $reader

        if ($response.Code -ne 334) {
            throw "AUTH LOGIN was rejected: $($response.Text)"
        }

        $usernameBase64 = [System.Convert]::ToBase64String($utf8NoBom.GetBytes($Credential.UserName))

        $writer.WriteLine($usernameBase64)
        $writer.Flush()

        $usernameBase64 = $null

        $response = Read-SmtpResponse -Reader $reader

        if ($response.Code -ne 334) {
            throw "SMTP username was rejected: $($response.Text)"
        }

        $targetToBase64 = $utf8NoBom.GetBytes($Credential.Password)
        $passwordBase64 = [System.Convert]::ToBase64String($targetToBase64)

        $writer.WriteLine($passwordBase64)
        $writer.Flush()

        $passwordBase64 = $null

        $response = Read-SmtpResponse -Reader $reader

        if ($response.Code -ne 235) {
            throw "SMTP authentication failed: $($response.Text)"
        }
        #endregion

        #region Envelope
        $mailFrom = $Message.From.Address

        $envelopeAddresses = @(
            $mailFrom
            foreach ($recipient in $Message.To) {
                $recipient.Address
            }
        )

        $requiresSmtpUtf8 = $false

        foreach ($address in $envelopeAddresses) {
            if ($address -match '[^\x00-\x7F]') {
                $requiresSmtpUtf8 = $true
                break
            }
        }

        $mailFromCommand = "MAIL FROM:<$mailFrom>"

        if ($requiresSmtpUtf8) {
            $utf8CapParams = @{
                Lines      = $ehlo.Lines
                Capability = 'SMTPUTF8'
            }

            if (-not (Test-SmtpCapability @utf8CapParams)) {
                throw (
                    "The message contains non-ASCII envelope addresses, " +
                    "but SMTP server '$Server':'$Port' does not advertise SMTPUTF8."
                )
            }

            $mailFromCommand += ' SMTPUTF8'
        }

        $mailFromParams = @{
            Writer        = $writer
            Reader        = $reader
            Command       = $mailFromCommand
            ExpectedCodes = @(250)
        }

        Send-SmtpCommand @mailFromParams | Out-Null

        foreach ($recipient in $Message.To) {
            $rcptParams = @{
                Writer        = $writer
                Reader        = $reader
                Command       = "RCPT TO:<$($recipient.Address)>"
                ExpectedCodes = @(250, 251)
            }

            Send-SmtpCommand @rcptParams | Out-Null
        }
        #endregion

        #region DATA
        $dataParams = @{
            Writer        = $writer
            Reader        = $reader
            Command       = 'DATA'
            ExpectedCodes = @(354)
        }

        Send-SmtpCommand @dataParams | Out-Null

        $lineParams = @{ Writer = $writer }

        $lineParams.Line = "From: <$($Message.From.Address)>"
        Write-SmtpDataLine @lineParams

        foreach ($recipient in $Message.To) {
            $lineParams.Line = "To: <$($recipient.Address)>"
            Write-SmtpDataLine @lineParams
        }

        $lineParams.Line = "Subject: $(ConvertTo-MimeHeader -Value $Message.Subject)"
        Write-SmtpDataLine @lineParams

        $lineParams.Line = "Date: $([System.DateTime]::UtcNow.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture))"
        Write-SmtpDataLine @lineParams

        $lineParams.Line = "Message-ID: <$([System.Guid]::NewGuid())@$Server>"
        Write-SmtpDataLine @lineParams

        $lineParams.Line = 'MIME-Version: 1.0'
        Write-SmtpDataLine @lineParams

        $lineParams.Line = if ($Message.IsBodyHtml) {
            'Content-Type: text/html; charset=utf-8'
        } else {
            'Content-Type: text/plain; charset=utf-8'
        }

        Write-SmtpDataLine @lineParams

        # 8bit encoding supports non-ASCII characters in the body.
        # 8bit encoding is honored end-to-end: the underlying StreamWriter
        # uses UTF-8 so bytes on the wire match the declared charset.
        $lineParams.Line = 'Content-Transfer-Encoding: 8bit'
        Write-SmtpDataLine @lineParams

        $lineParams.Line = [string]::Empty
        Write-SmtpDataLine @lineParams

        $body = if ($null -eq $Message.Body) {
            [string]::Empty
        } else {
            $Message.Body
        }

        # Normalize line endings before DATA transmission.
        $body      = $body -replace "`r`n", "`n"
        $body      = $body -replace "`r",   "`n"
        $bodyLines = $body -split   "`n",    -1

        foreach ($line in $bodyLines) {
            $lineParams.Line = $line
            Write-SmtpDataLine @lineParams
        }

        $writer.WriteLine('.')
        $writer.Flush()

        $dataResult = Read-SmtpResponse -Reader $reader

        if ($dataResult.Code -ne 250) {
            throw "SMTP server rejected message: $($dataResult.Text)"
        }
        #endregion

        #region QUIT
        try {
            $writer.WriteLine('QUIT')
            $writer.Flush()

            $quitResponse = Read-SmtpResponse -Reader $reader

            if ($quitResponse.Code -ne 221) {
                Write-Verbose -Message "Unexpected SMTP QUIT response: $($quitResponse.Text)"
            }
        } catch {
            # DATA returned 250 - the message was accepted by the server.
            # A failure during QUIT must not turn a successful send into a failure.
            Write-Verbose -Message "SMTP QUIT failed (non-fatal): $($_.Exception.Message)"
        }
        #endregion
    } finally {
        $usernameBase64 = $null
        $passwordBase64 = $null

        if ($null -ne $reader) {
            try {
                $reader.Dispose()
            } catch {
                Write-Verbose -Message "Failed to dispose SMTP reader: $($_.Exception.Message)"
            }
        }

        if ($null -ne $writer) {
            try {
                $writer.Dispose()
            } catch {
                Write-Verbose -Message "Failed to dispose SMTP writer: $($_.Exception.Message)"
            }
        }

        if ($null -ne $sslStream) {
            try {
                $sslStream.Dispose()
            } catch {
                Write-Verbose -Message "Failed to dispose TLS stream: $($_.Exception.Message)"
            }
        }

        if ($null -ne $networkStream) {
            try {
                $networkStream.Dispose()
            } catch {
                Write-Verbose -Message "Failed to dispose network stream: $($_.Exception.Message)"
            }
        }

        if ($null -ne $tcpClient) {
            try {
                $tcpClient.Dispose()
            } catch {
                Write-Verbose -Message "Failed to dispose TCP client: $($_.Exception.Message)"
            }
        }
    }
}
