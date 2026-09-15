<#
.SYNOPSIS
Creates and authenticates an SslStream over an existing stream.

.DESCRIPTION
Wraps InnerStream in a System.Net.Security.SslStream and performs
TLS client authentication against TargetHost.

Certificate validation is strict. The TLS handshake succeeds only
when the .NET TLS stack reports SslPolicyErrors.None.

The TLS handshake is bounded by HandshakeTimeoutMs. A timeout limits
how long this function waits for authentication to complete; it does
not provide cancellation of the underlying asynchronous operation.

The returned SslStream remains open and ownership is transferred to
the caller after successful authentication.

InnerStream ownership always remains with the caller. The SslStream
is created with leaveInnerStreamOpen = $true, therefore disposing the
returned SslStream does not dispose InnerStream.

.PARAMETER InnerStream
The underlying network or memory stream to wrap.

.PARAMETER TargetHost
The server hostname used for TLS authentication, SNI, and certificate
hostname validation.

.PARAMETER HandshakeTimeoutMs
Maximum time, in milliseconds, that this function waits for the TLS
handshake to complete.

.PARAMETER FailureContext
Short context included in exception messages, for example 'TLS' or 'STARTTLS'.

.OUTPUTS
System.Net.Security.SslStream

.EXAMPLE
PS C:\> $sslStream = New-SmtpSslStream -InnerStream $networkStream
>> -TargetHost 'smtp.example.com'
>> -HandshakeTimeoutMs 15000 -FailureContext 'TLS'

try {
    # Use $sslStream here.
} finally {
    $sslStream.Dispose()
}

.NOTES
The caller owns the returned SslStream and is responsible for disposing it.

The caller also owns InnerStream.

InnerStream remains open when the SslStream is disposed.

This function intentionally does not use a custom certificate
trust policy. Certificate validation is delegated to the .NET TLS
stack and succeeds only when no SSL policy errors are reported.

The function is designed to be compatible with Windows PowerShell 5.1.
#>
function New-SmtpSslStream {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Creates a transient SslStream and does not modify persistent system state.'
    )]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter',
        '',
        Justification = 'Callback parameters are required by RemoteCertificateValidationCallback.'
    )]
    [CmdletBinding()]
    [OutputType([System.Net.Security.SslStream])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.IO.Stream]$InnerStream,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetHost,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$HandshakeTimeoutMs,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FailureContext
    )

    $sslStream = $null

    try {
        # Certificate validation is intentionally strict:
        # any SSL policy error causes authentication to fail.
        $certificateValidationCallback = {
            param (
                [object]$CallbackSender,
                [System.Security.Cryptography.X509Certificates.X509Certificate]$Certificate,
                [System.Security.Cryptography.X509Certificates.X509Chain]$Chain,
                [System.Net.Security.SslPolicyErrors]$SslPolicyErrors
            )

            if ($SslPolicyErrors -ne [System.Net.Security.SslPolicyErrors]::None) {
                Write-Verbose -Message (
                    "$FailureContext certificate validation failed: $SslPolicyErrors"
                )

                return $false
            }

            return $true
        }

        # Keep ownership of InnerStream with the caller.
        $sslStream = [System.Net.Security.SslStream]::new(
            $InnerStream,
            $true,
            $certificateValidationCallback
        )

        # Let the operating system / .NET negotiate the strongest mutually
        # supported TLS protocol.
        $authenticationTask = $sslStream.AuthenticateAsClientAsync(
            $TargetHost,
            $null,
            [System.Security.Authentication.SslProtocols]::None,
            $true
        )

        # Wait for the asynchronous TLS handshake, bounded by the requested
        # timeout. Wait() does not cancel the underlying operation.
        if (-not $authenticationTask.Wait($HandshakeTimeoutMs)) {
            throw [System.TimeoutException]::new(
                "$FailureContext TLS handshake with '$TargetHost' " +
                "timed out after $([System.Math]::Ceiling($HandshakeTimeoutMs / 1000)) second(s)."
            )
        }

        # Propagate the original exception from the asynchronous operation
        # rather than exposing AggregateException to the caller.
        $authenticationTask.GetAwaiter().GetResult()

        if (-not $sslStream.IsAuthenticated) {
            throw [System.Security.Authentication.AuthenticationException]::new(
                "$FailureContext TLS handshake with '$TargetHost' failed: " +
                'the stream is not authenticated.'
            )
        }

        if (-not $sslStream.IsEncrypted) {
            throw [System.Security.Authentication.AuthenticationException]::new(
                "$FailureContext TLS handshake with '$TargetHost' failed: " +
                'the stream is not encrypted.'
            )
        }

        # Authentication succeeded. Transfer ownership to the caller.
        $result = $sslStream
        $sslStream = $null

        return $result
    } catch [System.TimeoutException] {
        throw
    } catch [System.Security.Authentication.AuthenticationException] {
        throw
    } catch [System.AggregateException] {
        $innerException = $_.Exception.Flatten().InnerExceptions |
            Where-Object {
                $null -ne $_
            } |

            Select-Object -First 1

        if ($null -ne $innerException) {
            throw [System.Security.Authentication.AuthenticationException]::new(
                "$FailureContext TLS handshake with '$TargetHost' failed: " +
                $innerException.Message,
                $innerException
            )
        }

        throw [System.Security.Authentication.AuthenticationException]::new(
            "$FailureContext TLS handshake with '$TargetHost' failed.",
            $_.Exception
        )
    } catch {
        throw [System.Security.Authentication.AuthenticationException]::new(
            "$FailureContext TLS handshake with '$TargetHost' failed: " +
            $_.Exception.Message,
            $_.Exception
        )
    } finally {
        # Ownership is transferred only after successful authentication.
        # If an exception occurs before that point, dispose the SslStream.
        #
        # leaveInnerStreamOpen = $true guarantees that InnerStream remains
        # owned by the caller.
        if ($null -ne $sslStream) {
            $sslStream.Dispose()
        }
    }
}
