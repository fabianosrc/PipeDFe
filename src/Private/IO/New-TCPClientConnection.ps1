<#
.SYNOPSIS
Creates and connects a TcpClient to the specified server and port.

.DESCRIPTION
Creates a TcpClient and establishes an asynchronous TCP connection to the
specified server and port.

The connection is subject to a configurable timeout. If the connection
does not complete within the specified timeout, the operation fails with
a TimeoutException and the TcpClient is disposed automatically.

On success, ownership of the connected TcpClient is transferred to the
caller. The caller is responsible for disposing the returned TcpClient.

.PARAMETER Server
SMTP server hostname or IP address.

.PARAMETER Port
TCP port number. Valid values are 1 through 65535.

.PARAMETER TimeoutMs
Maximum time, in milliseconds, allowed for the TCP connection to complete.
Must be greater than zero.

.OUTPUTS
System.Net.Sockets.TcpClient

.EXAMPLE
PS C:\> $tcp = New-TcpClientConnection -Server 'smtp.example.com'
>> -Port 587 -TimeoutMs 15000

try {
    # Use $tcp here.
} finally {
    $tcp.Dispose()
}

.NOTES
Designed for use by Send-SmtpMessage and for unit testing without
requiring a real SMTP connection.

On success, ownership of the returned TcpClient is transferred to the
caller.

On failure, the TcpClient created by this function is disposed before
the exception is propagated.

Throws:
    System.TimeoutException
        The connection did not complete within TimeoutMs.

    System.Net.Sockets.SocketException
        The TCP connection failed or the resulting client was not
        connected.

    Other exceptions may be wrapped in a SocketException to provide
    additional connection context.
#>
function New-TcpClientConnection {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Creates a transient TcpClient connection - no persistent system state is changed.'
    )]
    [CmdletBinding()]
    [OutputType([System.Net.Sockets.TcpClient])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$Port,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$TimeoutMs
    )

    $tcpClient = [System.Net.Sockets.TcpClient]::new()

    try {
        $connectTask = $tcpClient.ConnectAsync($Server, $Port)

        # Wait() provides the connection timeout. It returns false when the
        # timeout expires; otherwise the task has completed and its result
        # must still be observed to propagate any connection failure.
        if (-not $connectTask.Wait($TimeoutMs)) {
            throw [System.TimeoutException]::new(
                "TCP connection to '${Server}:$Port' timed out after " +
                "$([System.Math]::Ceiling($TimeoutMs / 1000)) second(s)."
            )
        }

        # Force propagation of any exception raised by ConnectAsync().
        # GetAwaiter().GetResult() exposes the underlying exception rather
        # than requiring callers to handle an AggregateException themselves.
        $connectTask.GetAwaiter().GetResult()

        # A successfully completed connection task should result in a
        # connected TcpClient. Keep this explicit check as a defensive
        # validation of the function's output contract.
        if (-not $tcpClient.Connected) {
            throw [System.Net.Sockets.SocketException]::new(
                [System.Net.Sockets.SocketError]::NotConnected
            )
        }

        # Transfer ownership to the caller. Setting the local reference to
        # $null prevents the finally block from disposing the returned client.
        $result = $tcpClient
        $tcpClient = $null

        return $result
    } catch [System.TimeoutException] {
        # Preserve TimeoutException so callers can distinguish a timeout
        # from other connection failures.
        throw
    } catch [System.AggregateException] {
        # Handle AggregateException defensively in case a faulted task is
        # surfaced through Task.Wait() rather than GetResult().
        $innerException = $_.Exception.Flatten().InnerExceptions |
            Where-Object {
                $null -ne $_
            } |

            Select-Object -First 1

        if ($null -ne $innerException) {
            throw [System.Net.Sockets.SocketException]::new(
                $innerException.Message,
                $innerException
            )
        }

        throw
    } catch [System.Net.Sockets.SocketException] {
        # Preserve SocketException so callers can reliably identify
        # TCP/network failures.
        throw
    } catch {
        # Add connection context while preserving the original exception
        # as the inner exception for diagnostics.
        $message = "TCP connection to '${Server}:$Port' failed: $($_.Exception.Message)"

        throw [System.InvalidOperationException]::new($message, $_.Exception)
    } finally {
        # Dispose only when ownership was not transferred to the caller.
        if ($null -ne $tcpClient) {
            $tcpClient.Dispose()
        }
    }
}
