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
        'PSAvoidUsingAdd-Type',
        '',
        Justification = 'Compiled delegate avoids the Runspace dependency that PS scriptblocks have when invoked from .NET TLS threads.'
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
        # The RemoteCertificateValidationCallback is invoked by the .NET TLS
        # stack on a thread that has no PowerShell Runspace. A scriptblock
        # delegate would therefore throw "There is no Runspace available to
        # run scripts in this thread." A compiled C# type avoids that
        # entirely: it runs as pure .NET code with no Runspace dependency.
        if (-not ([System.Management.Automation.PSTypeName]'PipeDFe.StrictCertificateValidator').Type) {
            Add-Type -TypeDefinition @'
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

namespace PipeDFe {
    public static class StrictCertificateValidator {
        /// <summary>
        /// Returns true only when no SSL policy errors are present.
        /// Safe to use as a RemoteCertificateValidationCallback: runs on
        /// .NET threads with no PowerShell Runspace required.
        /// </summary>
        public static bool Validate(
            object sender,
            X509Certificate certificate,
            X509Chain chain,
            SslPolicyErrors sslPolicyErrors
        ) {
            return sslPolicyErrors == SslPolicyErrors.None;
        }
    }
}
'@
        }

        $certificateValidationCallback = [System.Delegate]::CreateDelegate(
            [System.Net.Security.RemoteCertificateValidationCallback],
            [PipeDFe.StrictCertificateValidator],
            'Validate'
        )

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
        [void]$authenticationTask.GetAwaiter().GetResult()

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
            Where-Object { $null -ne $_ } |
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
