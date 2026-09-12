<#
.SYNOPSIS
Tests TCP connectivity to an SMTP server.

.DESCRIPTION
Attempts a TCP connection to the specified server and port within the
given timeout. Returns $true when the connection succeeds, $false when
it times out.

Throws when the connection fails with a network error (e.g. host not
found, connection refused).

Intended as a pre-flight check in Test-PipeSmtp to distinguish network
and firewall failures from SMTP/TLS protocol failures without waiting
for the full SMTP timeout.

.PARAMETER Server
SMTP server hostname or IP address.

.PARAMETER Port
SMTP server port number.

.PARAMETER TimeoutMs
Connection timeout in milliseconds.

.OUTPUTS
System.Boolean

.EXAMPLE
PS C:\> $connected = Test-SmtpTcpConnection -Server
>> 'smtp.example.com' -Port 587 -TimeoutMs 15000
#>
function Test-SmtpTcpConnection {
    [CmdletBinding()]
    [OutputType([bool])]
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

    $tcpClient = $null

    try {
        $tcpClient = [System.Net.Sockets.TcpClient]::new()

        return $tcpClient.ConnectAsync($Server, $Port).Wait($TimeoutMs)
    } finally {
        if ($null -ne $tcpClient) {
            $tcpClient.Dispose()
        }
    }
}
