<#
.SYNOPSIS
Sends an email message over a manually implemented SMTP/ESMTP session.

.DESCRIPTION
Implements the full SMTP client protocol without using
System.Net.Mail.SmtpClient for transport. Supports:
  - Implicit TLS (port 465)
  - STARTTLS (RFC 3207)
  - AUTH LOGIN (with SMTPUTF8-encoded credentials)
  - Multiple RCPT TO with per-recipient error tracking
  - Partial recipient rejection (proceeds if at least one is accepted)
  - SMTPUTF8 (RFC 6531) for non-ASCII envelope addresses
  - 8BITMIME (RFC 6152) for non-ASCII body content
  - RFC 2047 encoded-words (Base64/UTF-8) for non-ASCII Subject
  - RFC 5322 header folding for long ASCII Subject values
  - Dot-stuffing (RFC 5321 §4.5.2)
  - SMTP line-length limit enforcement (1000 octets including CRLF,
    measured in UTF-8 bytes, not characters)
  - SMTP multiline response parsing with strict byte-level validation

Security model:
  - TLS is required by default. Plaintext authentication requires the
    explicit -AllowInsecureAuthentication switch.
  - Certificate validation is strict: SslPolicyErrors.None required.
  - Hostname is validated by the SslStream framework (SNI + CN/SAN).
  - Credentials are cleared from managed heap after use.
  - CRLF injection is blocked in all header values and SMTP commands.

Timeout behavior:
  Task.Wait(ms) is used for both TCP connection and TLS handshake.
  On timeout, the underlying operation is abandoned and the socket is
  eventually reclaimed by the OS. Cooperative cancellation is not
  available in .NET Framework 4.x (PowerShell 5.1). After the text
  streams are open, NetworkStream.ReadTimeout / WriteTimeout bound
  subsequent I/O.

Disposal order on all code paths:
  StreamWriter -> SslStream -> NetworkStream -> TcpClient.

.PARAMETER Server
SMTP server hostname or IP address.

.PARAMETER Port
TCP port. 465 = implicit TLS; 587 = STARTTLS; 25 = plaintext/STARTTLS.

.PARAMETER EnableSsl
When $true (default), the connection is secured with TLS.
On port 465 this means implicit TLS; on other ports, STARTTLS.
Setting $false on port 465 throws immediately.

.PARAMETER AllowInsecureAuthentication
Must be specified explicitly to send credentials over a plaintext
connection (EnableSsl = $false). Has no effect when TLS is active.

.PARAMETER Credential
System.Net.NetworkCredential carrying username and cleartext password.
AUTH LOGIN requires the password in plaintext for Base64 encoding.

.PARAMETER Message
System.Net.Mail.MailMessage. Must have From and at least one recipient
across To, CC, or Bcc. CC and Bcc are submitted as RCPT TO but Bcc
is not emitted as a message header.

.PARAMETER TimeoutSeconds
Wall-clock timeout (1-300 s) applied to TCP connect, TLS handshake,
and individual stream read/write operations.

.OUTPUTS
None.

.EXAMPLE
.EXAMPLE
PS C:\> $msg = [System.Net.Mail.MailMessage]::new('from@mail.com', 'to@mail.com')
PS C:\> $msg.Subject = 'Hello'
PS C:\> $msg.Body = 'World'
PS C:\> Send-SmtpMessage -Server 'smtp.example.com'
>> -Port 587 -Credential $cred -Message $msg

.NOTES
Private. Depends on: New-TcpClientConnection, New-SmtpSslStream.
Does NOT support: SASL PLAIN, XOAUTH2, multipart MIME, attachments.
#>
function Send-SmtpMessage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUsePSCredentialType',
        '',
        Justification = 'AUTH LOGIN requires cleartext access to the password for Base64 encoding.
        SecureString cannot be used without extracting plaintext anyway.'
    )]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Sends a transient network message - no persistent system state is changed.'
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

        [Parameter()]
        [switch]$AllowInsecureAuthentication,

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

    $timeoutMs = $TimeoutSeconds * 1000

    # Strict UTF-8: invalid UTF-16 surrogate sequences are rejected
    # instead of silently replaced.
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)

    # SMTP replies are US-ASCII by protocol definition.
    $asciiEncoding = [System.Text.Encoding]::ASCII

    $tcpClient     = $null
    $networkStream = $null
    $sslStream     = $null
    $activeStream  = $null
    $writer        = $null

    $usernameBytes  = $null
    $passwordBytes  = $null
    $usernameBase64 = $null
    $passwordBase64 = $null

    try {

        #region Protocol helpers
        function Assert-NoCrLf {
            [CmdletBinding()]
            [OutputType([void])]
            param (
                [Parameter(Mandatory)]
                [AllowEmptyString()]
                [string]$Value,

                [Parameter(Mandatory)]
                [ValidateNotNullOrEmpty()]
                [string]$FieldName
            )

            if ($Value.IndexOf("`r") -ge 0 -or $Value.IndexOf("`n") -ge 0) {
                throw [System.FormatException]::new(
                    "SMTP field '$FieldName' contains CR or LF characters."
                )
            }
        }

        function Test-SmtpNonAscii {
            [CmdletBinding()]
            [OutputType([bool])]
            param (
                [Parameter(Mandatory)]
                [AllowEmptyString()]
                [string]$Value
            )

            foreach ($character in $Value.ToCharArray()) {
                if ([int][char]$character -gt 127) {
                    return $true
                }
            }

            return $false
        }

        function Assert-SmtpPath {
            [CmdletBinding()]
            [OutputType([void])]
            param (
                [Parameter(Mandatory)]
                [ValidateNotNullOrEmpty()]
                [string]$Address,

                [Parameter(Mandatory)]
                [ValidateNotNullOrEmpty()]
                [string]$FieldName
            )

            Assert-NoCrLf -Value $Address -FieldName $FieldName

            $pathBytes = $utf8NoBom.GetByteCount("<$Address>")

            # RFC 5321 path maximum: 256 octets including angle brackets.
            if ($pathBytes -gt 256) {
                throw [System.ArgumentOutOfRangeException]::new(
                    $FieldName,
                    $Address,
                    'SMTP path exceeds the 256-octet limit.'
                )
            }
        }

        function Read-SmtpResponse {
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param (
                [Parameter(Mandatory)]
                [System.IO.Stream]$Stream
            )

            $lines = [System.Collections.Generic.List[string]]::new()
            $expectedCode = $null

            while ($true) {
                $bytes = [System.Collections.Generic.List[byte]]::new()
                $sawCr = $false

                while ($true) {
                    try {
                        $value = $Stream.ReadByte()
                    } catch {
                        throw [System.IO.IOException]::new(
                            "Failed while reading SMTP response: $($_.Exception.Message)",
                            $_.Exception
                        )
                    }

                    if ($value -lt 0) {
                        throw [System.IO.IOException]::new(
                            'SMTP server closed the connection unexpectedly.'
                        )
                    }

                    if ($value -eq 13) {
                        if ($sawCr) {
                            throw [System.FormatException]::new(
                                'Invalid SMTP response: consecutive CR characters.'
                            )
                        }

                        $sawCr = $true
                        continue
                    }

                    if ($value -eq 10) {
                        if (-not $sawCr) {
                            throw [System.FormatException]::new(
                                'Invalid SMTP response: LF was not preceded by CR.'
                            )
                        }

                        break
                    }

                    if ($sawCr) {
                        throw [System.FormatException]::new(
                            'Invalid SMTP response: CR was not followed by LF.'
                        )
                    }

                    if ($value -gt 127) {
                        throw [System.FormatException]::new(
                            'Invalid SMTP response: non-ASCII octet received.'
                        )
                    }

                    $bytes.Add([byte]$value)

                    # RFC 5321: reply line <= 512 octets including CRLF.
                    if (($bytes.Count + 2) -gt 512) {
                        throw [System.FormatException]::new(
                            'SMTP reply line exceeds the 512-octet limit.'
                        )
                    }
                }

                $line = $asciiEncoding.GetString($bytes.ToArray())

                if ($line -match '^(?<Code>[2-5]\d{2})(?<Separator>[ -])(?<Text>.*)$') {
                    $currentCode = [int]$Matches['Code']
                    $separator   = $Matches['Separator']
                } elseif ($line -match '^(?<Code>[2-5]\d{2})$') {
                    $currentCode = [int]$Matches['Code']
                    $separator   = ' '
                } else {
                    throw [System.FormatException]::new(
                        "Invalid SMTP response: '$line'"
                    )
                }

                if ($null -eq $expectedCode) {
                    $expectedCode = $currentCode
                } elseif ($currentCode -ne $expectedCode) {
                    throw [System.FormatException]::new(
                        "Invalid SMTP multiline response: expected code " +
                        "$expectedCode but received $currentCode."
                    )
                }

                $lines.Add($line)

                if ($separator -eq ' ') {
                    break
                }

                if ($separator -ne '-') {
                    throw [System.FormatException]::new(
                        "Invalid SMTP response continuation: '$line'"
                    )
                }
            }

            $textLines = [System.Collections.Generic.List[string]]::new()

            foreach ($line in $lines) {
                if ($line.Length -gt 4) {
                    $textLines.Add($line.Substring(4))
                } else {
                    $textLines.Add([string]::Empty)
                }
            }

            [PSCustomObject]@{
                Code  = $expectedCode
                Lines = $lines.ToArray()
                Text  = $textLines -join "`r`n"
            }
        }

        function Send-SmtpCommand {
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param (
                [Parameter(Mandatory)]
                [System.IO.StreamWriter]$Writer,

                [Parameter(Mandatory)]
                [System.IO.Stream]$Stream,

                [Parameter(Mandatory)]
                [ValidateNotNullOrEmpty()]
                [string]$Command,

                [Parameter(Mandatory)]
                [ValidateNotNullOrEmpty()]
                [int[]]$ExpectedCodes
            )

            Assert-NoCrLf -Value $Command -FieldName 'SMTP command'

            $commandBytes = $utf8NoBom.GetByteCount($Command)

            # RFC 5321 command line maximum: 512 octets including CRLF.
            if (($commandBytes + 2) -gt 512) {
                throw [System.FormatException]::new(
                    'SMTP command exceeds the 512-octet limit.'
                )
            }

            Write-Verbose -Message "SMTP C: $Command"

            try {
                $Writer.WriteLine($Command)
                $Writer.Flush()
            } catch {
                throw [System.IO.IOException]::new(
                    "Failed to send SMTP command '$Command': $($_.Exception.Message)",
                    $_.Exception
                )
            }

            $response = Read-SmtpResponse -Stream $Stream

            Write-Verbose -Message "SMTP S: $($response.Text)"

            if ($ExpectedCodes -notcontains $response.Code) {
                throw [System.Net.Mail.SmtpException]::new(
                    "SMTP command failed. Command: '$Command'. " +
                    "Expected: $($ExpectedCodes -join ', '). " +
                    "Response: $($response.Code) $($response.Text)"
                )
            }

            return $response
        }

        function Test-SmtpCapability {
            [CmdletBinding()]
            [OutputType([bool])]
            param (
                [Parameter(Mandatory)]
                [string[]]$Lines,

                [Parameter(Mandatory)]
                [ValidateNotNullOrEmpty()]
                [string]$Capability
            )

            $escaped = [regex]::Escape($Capability)

            foreach ($line in $Lines) {
                if ($line -imatch "^\d{3}[- ]$escaped(?:\s|$)") {
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
                [ValidateNotNullOrEmpty()]
                [string]$Capability
            )

            $escaped = [regex]::Escape($Capability)

            foreach ($line in $Lines) {
                if ($line -imatch "^\d{3}[- ]$escaped(?:\s+(.*))?$") {
                    if ($matches.ContainsKey(1)) {
                        return $matches[1]
                    }

                    return [string]::Empty
                }
            }

            return $null
        }

        function ConvertTo-MimeHeaderLine {
            [CmdletBinding()]
            [OutputType([string[]])]
            param (
                [Parameter(Mandatory)]
                [ValidateNotNullOrEmpty()]
                [string]$FieldName,

                [Parameter(Mandatory)]
                [AllowEmptyString()]
                [string]$Value
            )

            Assert-NoCrLf -Value $Value -FieldName $FieldName

            $prefix = "${FieldName}: "

            if ([string]::IsNullOrEmpty($Value)) {
                return [string[]]@("${FieldName}:")
            }

            # ASCII path: fold at whitespace only.
            if (-not (Test-SmtpNonAscii -Value $Value)) {
                $result    = [System.Collections.Generic.List[string]]::new()
                $current   = $prefix
                $remaining = $Value

                while ($remaining.Length -gt 0) {
                    $available = 998 - $current.Length

                    if ($remaining.Length -le $available) {
                        $current += $remaining
                        $remaining = [string]::Empty
                        break
                    }

                    $breakAt = $remaining.LastIndexOf(' ', [System.Math]::Max(0, $available - 1))

                    if ($breakAt -le 0) {
                        throw [System.FormatException]::new(
                            "Header '$FieldName' contains an unbreakable " +
                            'token exceeding the SMTP header line limit.'
                        )
                    }

                    $current += $remaining.Substring(0, $breakAt)

                    $result.Add($current)

                    $remaining = $remaining.Substring($breakAt + 1).TrimStart()
                    $current   = ' '
                }

                if ($current.Length -gt 0) {
                    $result.Add($current)
                }

                return $result.ToArray()
            }

            # Non-ASCII path: RFC 2047 encoded-words.
            # 45 UTF-8 bytes -> 60 Base64 chars + 12 chars overhead = 72 chars.
            # Safely under the 75-char encoded-word limit (RFC 2047 §2).
            # Surrogate pairs are kept together.
            $encodedWords = [System.Collections.Generic.List[string]]::new()
            $currentBytes = [System.Collections.Generic.List[byte]]::new()

            $index = 0

            while ($index -lt $Value.Length) {
                $currentCharacter = $Value[$index]

                if ([char]::IsHighSurrogate($currentCharacter)) {
                    if (($index + 1) -ge $Value.Length -or -not [char]::IsLowSurrogate($Value[$index + 1])) {
                        throw [System.FormatException]::new(
                            "Header '$FieldName' contains an unpaired high surrogate."
                        )
                    }

                    $codePoint = $Value.Substring($index, 2)
                    $index += 2
                } elseif ([char]::IsLowSurrogate($currentCharacter)) {
                    throw [System.FormatException]::new(
                        "Header '$FieldName' contains an unpaired low surrogate."
                    )
                } else {
                    $codePoint = [string]$currentCharacter
                    $index++
                }

                $codePointBytes = $utf8NoBom.GetBytes($codePoint)

                if ($currentBytes.Count -gt 0 -and
                    ($currentBytes.Count + $codePointBytes.Length) -gt 45) {

                    $encodedWords.Add(
                        '=?UTF-8?B?{0}?=' -f [System.Convert]::ToBase64String($currentBytes.ToArray())
                    )

                    $currentBytes.Clear()
                }

                foreach ($byte in $codePointBytes) {
                    $currentBytes.Add($byte)
                }
            }

            if ($currentBytes.Count -gt 0) {
                $encodedWords.Add(
                    '=?UTF-8?B?{0}?=' -f [System.Convert]::ToBase64String($currentBytes.ToArray())
                )
            }

            # Emit "FieldName:" on its own line, then encoded-words on
            # continuation lines (max 76 chars per line).
            $result = [System.Collections.Generic.List[string]]::new()

            $result.Add("${FieldName}:")

            $currentLine = ' '

            foreach ($encodedWord in $encodedWords) {
                $candidate = if ($currentLine.Trim().Length -eq 0) {
                    "$currentLine$encodedWord"
                } else {
                    "$currentLine $encodedWord"
                }

                if ($candidate.Length -le 76) {
                    $currentLine = $candidate
                } else {
                    if ($currentLine.Trim().Length -gt 0) {
                        $result.Add($currentLine)
                    }

                    $currentLine = " $encodedWord"
                }
            }

            if ($currentLine.Trim().Length -gt 0) {
                $result.Add($currentLine)
            }

            return $result.ToArray()
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

            Assert-NoCrLf -Value $Line -FieldName 'SMTP DATA line'

            $wireLine = if ($Line.StartsWith('.')) {
                ".$Line"
            } else {
                $Line
            }

            # RFC 5321: max 1000 octets including CRLF.
            $wireLength = $utf8NoBom.GetByteCount($wireLine)

            if (($wireLength + 2) -gt 1000) {
                throw [System.FormatException]::new(
                    "SMTP DATA line exceeds the 1000-octet limit " +
                    "(wire length including CRLF: $($wireLength + 2) octets)."
                )
            }

            $Writer.WriteLine($wireLine)
        }

        function Write-SmtpAddressHeader {
            [CmdletBinding()]
            [OutputType([void])]
            param (
                [Parameter(Mandatory)]
                [System.IO.StreamWriter]$Writer,

                [Parameter(Mandatory)]
                [ValidateNotNullOrEmpty()]
                [string]$FieldName,

                [Parameter(Mandatory)]
                [System.Collections.IEnumerable]$Recipients
            )

            $addresses = [System.Collections.Generic.List[string]]::new()

            foreach ($recipient in $Recipients) {
                Assert-NoCrLf -Value $recipient.Address -FieldName $FieldName
                $addresses.Add("<$($recipient.Address)>")
            }

            if ($addresses.Count -eq 0) {
                return
            }

            $prefix  = "${FieldName}: "
            $current = $prefix

            for ($index = 0; $index -lt $addresses.Count; $index++) {
                $separator = if ($index -eq 0) {
                    [string]::Empty
                } else {
                    ', '
                }

                $candidate = $current + $separator + $addresses[$index]

                if (($utf8NoBom.GetByteCount($candidate) + 2) -le 998) {
                    $current = $candidate
                    continue
                }

                if ($current -eq $prefix) {
                    throw [System.FormatException]::new(
                        "SMTP '$FieldName' header contains an address " +
                        'that cannot fit within the 998-octet header limit.'
                    )
                }

                Write-SmtpDataLine -Writer $Writer -Line $current

                $current = ' ' + $addresses[$index]
            }

            Write-SmtpDataLine -Writer $Writer -Line $current
        }

        function ConvertTo-SmtpBodyLine {
            [CmdletBinding()]
            [OutputType([string[]])]
            param (
                [Parameter(Mandatory)]
                [AllowEmptyString()]
                [string]$Body
            )

            # Normalize CRLF and bare CR to LF, then split via .NET to
            # avoid the ambiguous limit=-1 behaviour of the -split operator
            # in PowerShell 5.1.
            $normalized = $Body.Replace("`r`n", "`n").Replace("`r", "`n")

            return $normalized.Split([char]"`n")
        }

        function Test-SmtpBodyNonAscii {
            [CmdletBinding()]
            [OutputType([bool])]
            param (
                [Parameter(Mandatory)]
                [AllowEmptyString()]
                [string[]]$Lines
            )

            foreach ($line in $Lines) {
                if (Test-SmtpNonAscii -Value $line) {
                    return $true
                }
            }

            return $false
        }
        #endregion

        #region Input validation
        if ($null -eq $Message.From) {
            throw [System.ArgumentException]::new(
                'Message.From must be specified.'
            )
        }

        $totalRecipients = $Message.To.Count + $Message.CC.Count + $Message.Bcc.Count

        if ($totalRecipients -eq 0) {
            throw [System.ArgumentException]::new(
                'Message must contain at least one recipient in To, Cc, or Bcc.'
            )
        }

        if ([string]::IsNullOrWhiteSpace($Credential.UserName)) {
            throw [System.ArgumentException]::new(
                'SMTP username must not be empty.'
            )
        }

        if ($Port -eq 465 -and -not $EnableSsl) {
            throw [System.ArgumentException]::new(
                'Port 465 requires implicit TLS. Set EnableSsl to $true.'
            )
        }

        if (-not $EnableSsl -and -not $AllowInsecureAuthentication) {
            throw [System.Security.Authentication.AuthenticationException]::new(
                'SMTP authentication requires TLS. Use -EnableSsl $true, ' +
                'or explicitly supply -AllowInsecureAuthentication to ' +
                'permit cleartext authentication.'
            )
        }

        Assert-NoCrLf -Value $Message.Subject -FieldName 'Subject'

        Assert-SmtpPath -Address $Message.From.Address -FieldName 'From'

        foreach ($recipient in $Message.To) {
            Assert-SmtpPath -Address $recipient.Address -FieldName 'To'
        }

        foreach ($recipient in $Message.CC) {
            Assert-SmtpPath -Address $recipient.Address -FieldName 'Cc'
        }

        foreach ($recipient in $Message.Bcc) {
            Assert-SmtpPath -Address $recipient.Address -FieldName 'Bcc'
        }

        # Analyze body before MAIL FROM because BODY=8BITMIME is a MAIL parameter.
        $body = if ($null -eq $Message.Body) { [string]::Empty } else { $Message.Body }

        $bodyLines = ConvertTo-SmtpBodyLine -Body $body

        $bodyContainsNonAscii = Test-SmtpBodyNonAscii -Lines $bodyLines
        #endregion

        #region TCP connection
        $tcpParams = @{
            Server    = $Server
            Port      = $Port
            TimeoutMs = $timeoutMs
        }

        $tcpClient     = New-TcpClientConnection @tcpParams
        $networkStream = $tcpClient.GetStream()

        if ($networkStream.CanTimeout) {
            $networkStream.ReadTimeout  = $timeoutMs
            $networkStream.WriteTimeout = $timeoutMs
        } else {
            Write-Verbose -Message (
                'Fluxo de rede não suporta timeout configurável. ' +
                'Read/write podem bloquear indefinidamente em falha de rede.'
            )
        }
        #endregion

        #region TLS setup
        $implicitTls = ($Port -eq 465) -and $EnableSsl

        if ($implicitTls) {
            Write-Verbose -Message 'Iniciando TLS implícito (porta 465).'

            $sslParams = @{
                InnerStream        = $networkStream
                TargetHost         = $Server
                HandshakeTimeoutMs = $timeoutMs
                FailureContext     = 'TLS'
            }

            $sslStream    = New-SmtpSslStream @sslParams
            $activeStream = $sslStream
        } else {
            $activeStream = $networkStream
        }
        #endregion

        #region Text writer
        $writer = [System.IO.StreamWriter]::new(
            $activeStream,
            $utf8NoBom,
            1024,
            $true
        )

        $writer.NewLine   = "`r`n"
        $writer.AutoFlush = $false
        #endregion

        #region Greeting
        $greeting = Read-SmtpResponse -Stream $activeStream

        Write-Verbose -Message "SMTP S: $($greeting.Text)"

        if ($greeting.Code -ne 220) {
            throw [System.Net.Mail.SmtpException]::new(
                "SMTP server rejected the connection: $($greeting.Code) $($greeting.Text)"
            )
        }
        #endregion

        #region EHLO
        $ehlo = Send-SmtpCommand `
            -Writer $writer `
            -Stream $activeStream `
            -Command 'EHLO PipeDFe' `
            -ExpectedCodes @(250)

        #endregion

        #region STARTTLS
        if (-not $implicitTls -and $EnableSsl) {
            if (-not (Test-SmtpCapability -Lines $ehlo.Lines -Capability 'STARTTLS')) {
                throw [System.Security.Authentication.AuthenticationException]::new(
                    "SMTP server '${Server}:${Port}' does not advertise STARTTLS."
                )
            }

            $cmdParams = @{
                Writer        = $writer
                Stream        = $activeStream
                Command       = 'STARTTLS'
                ExpectedCodes = @(220)
            }

            $null = Send-SmtpCommand @cmdParams

            $writer.Dispose()
            $writer = $null

            $sslParams = @{
                InnerStream        = $networkStream
                TargetHost         = $Server
                HandshakeTimeoutMs = $timeoutMs
                FailureContext     = 'STARTTLS'
            }

            $sslStream    = New-SmtpSslStream @sslParams
            $activeStream = $sslStream

            $writer = [System.IO.StreamWriter]::new(
                $activeStream,
                $utf8NoBom,
                1024,
                $true
            )

            $writer.NewLine   = "`r`n"
            $writer.AutoFlush = $false

            # RFC 3207 §4: EHLO must be sent again after STARTTLS.
            $ehloParams = @{
                Writer        = $writer
                Stream        = $activeStream
                Command       = 'EHLO PipeDFe'
                ExpectedCodes = @(250)
            }

            $ehlo = Send-SmtpCommand @ehloParams
        }
        #endregion

        #region Capability validation
        if ($bodyContainsNonAscii) {
            if (-not (Test-SmtpCapability -Lines $ehlo.Lines -Capability '8BITMIME')) {
                throw [System.Net.Mail.SmtpException]::new(
                    'The message body contains non-ASCII characters and ' +
                    "SMTP server '${Server}:${Port}' does not advertise 8BITMIME."
                )
            }
        }

        $envelopeRecipients = [System.Collections.Generic.List[object]]::new()

        foreach ($recipient in $Message.To) {
            $envelopeRecipients.Add($recipient)
        }

        foreach ($recipient in $Message.CC) {
            $envelopeRecipients.Add($recipient)
        }

        foreach ($recipient in $Message.Bcc) {
            $envelopeRecipients.Add($recipient)
        }

        $requiresSmtpUtf8 = Test-SmtpNonAscii -Value $Message.From.Address

        if (-not $requiresSmtpUtf8) {
            foreach ($recipient in $envelopeRecipients) {
                if (Test-SmtpNonAscii -Value $recipient.Address) {
                    $requiresSmtpUtf8 = $true
                    break
                }
            }
        }

        if ($requiresSmtpUtf8) {
            if (-not (Test-SmtpCapability -Lines $ehlo.Lines -Capability 'SMTPUTF8')) {
                throw [System.Net.Mail.SmtpException]::new(
                    'The message contains non-ASCII envelope addresses, ' +
                    "but SMTP server '${Server}:${Port}' does not advertise SMTPUTF8."
                )
            }

            # RFC 6531 requires an SMTPUTF8-capable server to also advertise 8BITMIME.
            if (-not (Test-SmtpCapability -Lines $ehlo.Lines -Capability '8BITMIME')) {
                throw [System.Net.Mail.SmtpException]::new(
                    'SMTP server advertises SMTPUTF8 but does not advertise ' +
                    '8BITMIME, which is required for SMTPUTF8 interoperability.'
                )
            }
        }
        #endregion

        #region Authentication
        $authArguments = Get-SmtpCapabilityArgument -Lines $ehlo.Lines -Capability 'AUTH'

        if ([string]::IsNullOrWhiteSpace($authArguments)) {
            throw [System.Net.Mail.SmtpException]::new(
                "SMTP server '${Server}:${Port}' does not advertise AUTH."
            )
        }

        $authMethods = @(
            $authArguments -split '\s+' |
                Where-Object { $_ } |
                ForEach-Object {
                    $_.ToUpperInvariant()
                }
        )

        if ('LOGIN' -notin $authMethods) {
            throw [System.Net.Mail.SmtpException]::new(
                "SMTP server '${Server}:${Port}' does not advertise AUTH LOGIN. " +
                "Advertised: $($authMethods -join ', ')"
            )
        }

        Write-Verbose -Message 'Iniciando AUTH LOGIN.'

        $cmdParams = @{
            Writer        = $writer
            Stream        = $activeStream
            Command       = 'AUTH LOGIN'
            ExpectedCodes = @(334)
        }

        $null = Send-SmtpCommand @cmdParams

        try {
            $usernameBytes = $utf8NoBom.GetBytes($Credential.UserName)

            try {
                $usernameBase64 = [Convert]::ToBase64String($usernameBytes)
            } finally {
                [Array]::Clear($usernameBytes, 0, $usernameBytes.Length)
                $usernameBytes = $null
            }

            if (($utf8NoBom.GetByteCount($usernameBase64) + 2) -gt 512) {
                throw [System.ArgumentOutOfRangeException]::new(
                    'Credential.UserName',
                    'Encoded SMTP username exceeds the command-line limit.'
                )
            }

            $writer.WriteLine($usernameBase64)
            $writer.Flush()
            $usernameBase64 = $null

            $response = Read-SmtpResponse -Stream $activeStream

            Write-Verbose -Message "SMTP S: $($response.Text)"

            if ($response.Code -ne 334) {
                throw [System.Security.Authentication.AuthenticationException]::new(
                    "SMTP username was rejected: $($response.Text)"
                )
            }

            $passwordBytes = $utf8NoBom.GetBytes($Credential.Password)

            try {
                $passwordBase64 = [Convert]::ToBase64String($passwordBytes)
            } finally {
                [Array]::Clear($passwordBytes, 0, $passwordBytes.Length)
                $passwordBytes = $null
            }

            if (($utf8NoBom.GetByteCount($passwordBase64) + 2) -gt 512) {
                throw [System.ArgumentOutOfRangeException]::new(
                    'Credential.Password',
                    'Encoded SMTP password exceeds the command-line limit.'
                )
            }

            $writer.WriteLine($passwordBase64)
            $writer.Flush()
            $passwordBase64 = $null

            $response = Read-SmtpResponse -Stream $activeStream

            Write-Verbose -Message "SMTP S: $($response.Text)"

            if ($response.Code -ne 235) {
                throw [System.Security.Authentication.AuthenticationException]::new(
                    "SMTP authentication failed: $($response.Text)"
                )
            }
        } finally {
            if ($null -ne $usernameBytes) {
                [Array]::Clear($usernameBytes, 0, $usernameBytes.Length)
            }

            if ($null -ne $passwordBytes) {
                [Array]::Clear($passwordBytes, 0, $passwordBytes.Length)
            }

            $usernameBytes  = $null
            $passwordBytes  = $null
            $usernameBase64 = $null
            $passwordBase64 = $null
        }
        #endregion

        #region MAIL FROM
        $mailFromCommand = "MAIL FROM:<$($Message.From.Address)>"

        if ($requiresSmtpUtf8) {
            $mailFromCommand += ' SMTPUTF8'
        }

        # RFC 6152: BODY=8BITMIME must be declared on MAIL when body is 8-bit.
        if ($bodyContainsNonAscii) {
            $mailFromCommand += ' BODY=8BITMIME'
        }

        $cmdParams = @{
            Writer        = $writer
            Stream        = $activeStream
            Command       = $mailFromCommand
            ExpectedCodes = @(250)
        }

        $null = Send-SmtpCommand @cmdParams
        #endregion

        #region RCPT TO
        $recipientResults = [System.Collections.Generic.List[object]]::new()

        foreach ($recipient in $envelopeRecipients) {
            Assert-SmtpPath -Address $recipient.Address -FieldName 'Recipient'

            $rcptCommand = "RCPT TO:<$($recipient.Address)>"

            Write-Verbose -Message "SMTP C: $rcptCommand"

            try {
                $rcptBytes = $utf8NoBom.GetByteCount($rcptCommand)

                if (($rcptBytes + 2) -gt 512) {
                    throw [System.FormatException]::new(
                        'SMTP RCPT TO command exceeds the 512-octet limit.'
                    )
                }

                $writer.WriteLine($rcptCommand)
                $writer.Flush()
            } catch {
                throw [System.IO.IOException]::new(
                    "Failed to send RCPT TO for '$($recipient.Address)': " +
                    $_.Exception.Message,
                    $_.Exception
                )
            }

            $response = Read-SmtpResponse -Stream $activeStream

            Write-Verbose -Message "SMTP S: $($response.Text)"

            if ($response.Code -eq 250 -or $response.Code -eq 251) {
                $recipientResults.Add(
                    [PSCustomObject]@{
                        Address  = $recipient.Address
                        Accepted = $true
                        Code     = $response.Code
                        Response = $response.Text
                    }
                )
            } elseif ($response.Code -eq 421) {
                throw [System.Net.Mail.SmtpException]::new(
                    "SMTP server closed the session during RCPT TO for " +
                    "'$($recipient.Address)': $($response.Text)"
                )
            } elseif ($response.Code -ge 400 -and $response.Code -le 599) {
                Write-Verbose -Message (
                    "Destinatário '$($recipient.Address)' rejeitado: $($response.Text)"
                )

                $recipientResults.Add(
                    [PSCustomObject]@{
                        Address  = $recipient.Address
                        Accepted = $false
                        Code     = $response.Code
                        Response = $response.Text
                    }
                )
            } else {
                throw [System.Net.Mail.SmtpException]::new(
                    "Unexpected SMTP RCPT TO response for '$($recipient.Address)': " +
                    $response.Text
                )
            }
        }

        $acceptedRecipients = @($recipientResults | Where-Object { $_.Accepted })

        if ($acceptedRecipients.Count -eq 0) {
            $rejectedSummary = $recipientResults |
                ForEach-Object {
                    "$($_.Address) [$($_.Code)] $($_.Response)"
                }

            throw [System.Net.Mail.SmtpException]::new(
                "SMTP server rejected all recipients: $($rejectedSummary -join '; ')"
            )
        }
        #endregion

        #region DATA
        $cmdParams = @{
            Writer        = $writer
            Stream        = $activeStream
            Command       = 'DATA'
            ExpectedCodes = @(354)
        }

        $null = Send-SmtpCommand @cmdParams

        Write-SmtpDataLine -Writer $writer -Line "From: <$($Message.From.Address)>"

        Write-SmtpAddressHeader -Writer $writer -FieldName 'To'  -Recipients $Message.To

        Write-SmtpAddressHeader -Writer $writer -FieldName 'Cc'  -Recipients $Message.CC

        # Bcc is intentionally not emitted as a header.
        $subjectLines = ConvertTo-MimeHeaderLine -FieldName 'Subject' -Value $Message.Subject

        foreach ($subjectLine in $subjectLines) {
            Write-SmtpDataLine -Writer $writer -Line $subjectLine
        }

        $dateHeader = [System.DateTimeOffset]::UtcNow.ToString(
            'ddd, dd MMM yyyy HH:mm:ss +0000',
            [System.Globalization.CultureInfo]::InvariantCulture
        )

        Write-SmtpDataLine -Writer $writer -Line "Date: $dateHeader"

        $messageIdDomain = $Message.From.Address
        $atIndex = $messageIdDomain.LastIndexOf('@')

        if ($atIndex -gt 0 -and $atIndex -lt ($messageIdDomain.Length - 1)) {
            $messageIdDomain = $messageIdDomain.Substring($atIndex + 1)
        } else {
            $messageIdDomain = $Server
        }

        Assert-NoCrLf -Value $messageIdDomain -FieldName 'Message-ID domain'

        if ($messageIdDomain -match '[<>\s]') {
            throw [System.FormatException]::new(
                'Message-ID domain contains invalid characters.'
            )
        }

        $messageId = "$([Guid]::NewGuid().ToString('N'))@$messageIdDomain"

        Write-SmtpDataLine -Writer $writer -Line "Message-ID: <$messageId>"

        Write-SmtpDataLine -Writer $writer -Line 'MIME-Version: 1.0'

        $contentType = if ($Message.IsBodyHtml) {
            'text/html; charset=utf-8'
        } else {
            'text/plain; charset=utf-8'
        }

        Write-SmtpDataLine -Writer $writer -Line "Content-Type: $contentType"

        $contentTransferEncoding = if ($bodyContainsNonAscii) {
            '8bit'
        } else {
            '7bit'
        }

        Write-SmtpDataLine -Writer $writer -Line "Content-Transfer-Encoding: $contentTransferEncoding"

        # Header/body separator.
        Write-SmtpDataLine -Writer $writer -Line [string]::Empty

        foreach ($line in $bodyLines) {
            Write-SmtpDataLine -Writer $writer -Line $line
        }

        # DATA terminator.
        $writer.WriteLine('.')
        $writer.Flush()

        $dataResponse = Read-SmtpResponse -Stream $activeStream

        Write-Verbose -Message "SMTP S: $($dataResponse.Text)"

        if ($dataResponse.Code -ne 250) {
            throw [System.Net.Mail.SmtpException]::new(
                "SMTP server rejected the message after DATA: $($dataResponse.Text)"
            )
        }
        #endregion

        #region QUIT
        try {
            Write-Verbose -Message 'SMTP C: QUIT'

            $writer.WriteLine('QUIT')
            $writer.Flush()

            $quitResponse = Read-SmtpResponse -Stream $activeStream

            Write-Verbose -Message "SMTP S: $($quitResponse.Text)"

            if ($quitResponse.Code -ne 221) {
                Write-Verbose -Message (
                    "Resposta inesperada ao QUIT (não fatal): $($quitResponse.Text)"
                )
            }
        } catch {
            # DATA returned 250: the server accepted responsibility for the message.
            # A subsequent QUIT failure must not convert successful delivery into failure.
            Write-Verbose -Message "SMTP QUIT falhou (não fatal): $($_.Exception.Message)"
        }
        #endregion

    } finally {

        if ($null -ne $usernameBytes) {
            [array]::Clear($usernameBytes, 0, $usernameBytes.Length)
        }

        if ($null -ne $passwordBytes) {
            [array]::Clear($passwordBytes, 0, $passwordBytes.Length)
        }

        $usernameBytes  = $null
        $passwordBytes  = $null
        $usernameBase64 = $null
        $passwordBase64 = $null

        # Disposal order: writer -> SslStream -> NetworkStream -> TcpClient.
        # StreamWriter was created with leaveOpen=$true.
        if ($null -ne $writer) {
            try {
                $writer.Dispose()
            } catch {
                Write-Verbose -Message "Falha ao descartar writer SMTP: $($_.Exception.Message)"
            }
        }

        if ($null -ne $sslStream) {
            try {
                $sslStream.Dispose()
            } catch {
                Write-Verbose -Message "Falha ao descartar SslStream: $($_.Exception.Message)"
            }
        }

        if ($null -ne $networkStream) {
            try {
                $networkStream.Dispose()
            } catch {
                Write-Verbose -Message "Falha ao descartar NetworkStream: $($_.Exception.Message)"
            }
        }

        if ($null -ne $tcpClient) {
            try {
                $tcpClient.Dispose()
            } catch {
                Write-Verbose -Message "Falha ao descartar TcpClient: $($_.Exception.Message)"
            }
        }
    }
}
