#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Send-SmtpMessage, New-TcpClientConnection helpers,
and New-SmtpSslStream helpers.

.DESCRIPTION
All network I/O is replaced by MockSmtpStream (a C# Stream subclass
defined in BeforeDiscovery). New-TcpClientConnection returns a
PSCustomObject that delegates GetStream() to the mock. New-SmtpSslStream
returns the mock stream directly so the function reads the pre-loaded
SMTP server bytes and writes client bytes into the same stream.

The canonical pattern for happy-path tests:
  BeforeAll  - sets up stream + mocks, calls the function ONCE
  It blocks  - assert the state captured by BeforeAll

The function is NEVER called a second time inside an It block that
also ran in BeforeAll (the mock stream is not seekable and has
already been consumed).

Coverage includes:
  - Parameter contract
  - Validation: Message.From missing
  - Validation: no recipients
  - Validation: empty username
  - Validation: port 465 without SSL
  - Validation: cleartext auth without AllowInsecureAuthentication
  - Happy path: port 587 plaintext
  - Happy path: port 587 STARTTLS
  - Happy path: port 465 implicit TLS
  - AUTH: server does not advertise AUTH
  - AUTH: LOGIN not in advertised methods
  - AUTH LOGIN command rejected (non-334 on initial AUTH LOGIN)
  - Username rejected (non-334 on username step)
  - Password rejected (non-235 on password step)
  - STARTTLS not advertised
  - SMTPUTF8 required but not advertised
  - DATA rejection
  - QUIT failure is non-fatal
  - Dot-stuffing
  - HTML vs plain Content-Type
  - Non-ASCII Subject encoded as MIME encoded-word
  - Multiple recipients
  - Greeting rejected by server
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess has no value in test helpers.'
)]

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword',
    '',
    Justification = 'Plain text passwords are acceptable in test fixtures.'
)]

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    '',
    Justification = 'Test helper parameters may not all be used in every path.'
)]

param ()

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = [System.IO.Path]::Combine($moduleRoot, 'PipeDFe.psd1')

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop

    if (-not ([System.Management.Automation.PSTypeName]'MockSmtpStream').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;

/// <summary>
/// Test double for an SMTP network stream.
///
/// ReadStream  - bytes the "server" has queued for the SUT to consume.
/// WriteStream - bytes the SUT has written (captured for assertions).
///
/// CanTimeout returns $true so that Send-SmtpMessage configures
/// ReadTimeout / WriteTimeout without falling into the Verbose branch.
///
/// Neither ReadStream nor WriteStream is disposed when Dispose() is
/// called, so WrittenText / WrittenBytes remain accessible after the
/// SUT closes the stream.
/// </summary>
public sealed class MockSmtpStream : Stream
{
    private readonly MemoryStream _readStream;
    private readonly MemoryStream _writeStream;
    private bool _disposed;

    public MockSmtpStream(byte[] serverBytes)
    {
        if (serverBytes == null)
            throw new ArgumentNullException("serverBytes");

        _readStream  = new MemoryStream(serverBytes, false);
        _writeStream = new MemoryStream();
    }

    /// <summary>All bytes the SUT has written so far.</summary>
    public byte[] WrittenBytes
    {
        get { return _writeStream.ToArray(); }
    }

    /// <summary>UTF-8 text the SUT has written so far.</summary>
    public string WrittenText
    {
        get { return Encoding.UTF8.GetString(_writeStream.ToArray()); }
    }

    public override bool CanRead
    {
        get { return !_disposed; }
    }

    public override bool CanSeek
    {
        get { return false; }
    }

    public override bool CanWrite
    {
        get { return !_disposed; }
    }

    public override bool CanTimeout {
        get { return true; }
    }

    public override int ReadTimeout
    {
        get; set;
    }

    public override int WriteTimeout
    {
        get; set;
    }

    // Length and Position reflect the WriteStream so PowerShell code that
    // tries to read Length does not throw NotSupportedException.
    public override long Length
    {
        get { return _writeStream.Length; }
    }

    public override long Position
    {
        get { return _writeStream.Position; }
        set { throw new NotSupportedException("MockSmtpStream does not support seeking."); }
    }

    public override void Flush()
    {
        _writeStream.Flush();
    }

    public override int Read(byte[] buffer, int offset, int count)
    {
        ThrowIfDisposed();
        // Return at most 1 byte per call so that StreamReader never pre-fetches
        // bytes into its internal buffer. This prevents bytes from being lost
        // when the first StreamReader is disposed and a second one is created
        // over the same stream (STARTTLS re-wrap scenario).
        return _readStream.Read(buffer, offset, Math.Min(count, 1));
    }

    public override void Write(byte[] buffer, int offset, int count)
    {
        ThrowIfDisposed();
        _writeStream.Write(buffer, offset, count);
    }

    public override long Seek(long offset, SeekOrigin origin)
    {
        throw new NotSupportedException("MockSmtpStream does not support seeking.");
    }

    public override void SetLength(long value)
    {
        throw new NotSupportedException("MockSmtpStream does not support SetLength.");
    }

    protected override void Dispose(bool disposing)
    {
        if (_disposed) return;
        // Deliberately do not dispose _readStream / _writeStream so that
        // WrittenText and WrittenBytes remain accessible in assertions.
        _disposed = true;
        base.Dispose(disposing);
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
            throw new ObjectDisposedException("MockSmtpStream");
    }
}
'@ -Language CSharp
    }
}

Describe 'Send-SmtpMessage' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Server         = 'smtp.example.com'
            $Script:Port587        = 587
            $Script:Port465        = 465
            $Script:TimeoutSeconds = 5
            $Script:Encoding       = [System.Text.UTF8Encoding]::new($false)

            #region Fixture helpers
            function New-SmtpServerStream {
                [CmdletBinding()]
                [OutputType([MockSmtpStream])]
                param (
                    [Parameter(Mandatory)]
                    [string[]]$Lines
                )

                $raw   = ($Lines -join "`r`n") + "`r`n"
                $bytes = $Script:Encoding.GetBytes($raw)
                return [MockSmtpStream]::new($bytes)
            }

            function New-MockTcpClient {
                [CmdletBinding()]
                [OutputType([PSCustomObject])]
                param (
                    [Parameter(Mandatory)]
                    [System.IO.Stream]$Stream
                )

                $tcp = [PSCustomObject]@{
                    PSTypeName = 'MockTcpClient'
                    Connected  = $true
                    _stream    = $Stream
                }

                $null = $tcp |
                    Add-Member -Force -MemberType ScriptMethod -Name GetStream -Value {
                        return $this._stream
                    }

                $null = $tcp |
                    Add-Member -Force -MemberType ScriptMethod -Name Dispose -Value { }

                return $tcp
            }

            # Returns the MockSmtpStream as if it were the SslStream.
            # Send-SmtpMessage wraps it in a StreamReader/StreamWriter, so the
            # SUT continues reading SMTP responses from the same byte buffer.
            function New-MockSslStreamPassthrough {
                [CmdletBinding()]
                [OutputType([System.IO.Stream])]
                param (
                    [Parameter(Mandatory)]
                    [System.IO.Stream]$Stream
                )

                return $Stream
            }

            # Standard SMTP responses for a plain (no TLS) 587 session.
            function Get-PlainSmtpLine {
                [CmdletBinding()]
                [OutputType([string[]])]
                param ()

                return [string[]]@(
                    '220 smtp.example.com ESMTP ready'
                    '250-smtp.example.com'
                    '250-AUTH LOGIN PLAIN'
                    '250 OK'
                    '334 VXNlcm5hbWU6'
                    '334 UGFzc3dvcmQ6'
                    '235 2.7.0 Authentication successful'
                    '250 OK'
                    '250 OK'
                    '354 Start input'
                    '250 OK'
                    '221 Bye'
                )
            }

            # Standard SMTP responses for a STARTTLS 587 session.
            # The same MockSmtpStream is reused for both pre-TLS and post-TLS
            # phases: after STARTTLS the SUT disposes the reader/writer and
            # opens new ones over the mock SslStream passthrough (which is the
            # same underlying stream), so reads continue from where they left off.
            function Get-StartTlsSmtpLine {
                [CmdletBinding()]
                [OutputType([string[]])]
                param ()

                return [string[]]@(
                    '220 smtp.example.com ESMTP ready'
                    '250-smtp.example.com'
                    '250-STARTTLS'
                    '250-AUTH LOGIN'
                    '250 OK'
                    '220 Ready to start TLS'
                    # Post-STARTTLS EHLO
                    '250-smtp.example.com'
                    '250-AUTH LOGIN'
                    '250 OK'
                    '334 VXNlcm5hbWU6'
                    '334 UGFzc3dvcmQ6'
                    '235 2.7.0 Authentication successful'
                    '250 OK'
                    '250 OK'
                    '354 Start input'
                    '250 OK'
                    '221 Bye'
                )
            }

            function New-TestMessage {
                [CmdletBinding()]
                [OutputType([System.Net.Mail.MailMessage])]
                param (
                    [Parameter()]
                    [string]$From = 'sender@example.com',

                    [Parameter()]
                    [string[]]$To = @('recipient@example.com'),

                    [Parameter()]
                    [string]$Subject = 'Test Subject',

                    [Parameter()]
                    [string]$Body = 'Test body.',

                    [Parameter()]
                    [bool]$IsBodyHtml = $false
                )

                $msg = [System.Net.Mail.MailMessage]::new()

                if (-not [string]::IsNullOrEmpty($From)) {
                    $msg.From = [System.Net.Mail.MailAddress]::new($From)
                }

                $msg.Subject    = $Subject
                $msg.Body       = $Body
                $msg.IsBodyHtml = $IsBodyHtml

                foreach ($address in $To) {
                    $msg.To.Add($address)
                }

                return $msg
            }

            function New-TestCredential {
                [CmdletBinding()]
                [OutputType([System.Net.NetworkCredential])]
                param (
                    [Parameter()]
                    [string]$UserName = 'user@example.com',

                    [Parameter()]
                    [string]$Password = 'secret'
                )

                return [System.Net.NetworkCredential]::new($UserName, $Password)
            }
            #endregion
        }

        #region Parameter contract
        Context 'Parameter contract' {

            BeforeAll {

                $Script:Cmd = Get-Command -Name Send-SmtpMessage
            }

            It 'Requires Server' {
                $Script:Cmd.Parameters['Server'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeTrue }
            }

            It 'Requires Port' {
                $Script:Cmd.Parameters['Port'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeTrue }
            }

            It 'Requires Credential' {
                $Script:Cmd.Parameters['Credential'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeTrue }
            }

            It 'Requires Message' {
                $Script:Cmd.Parameters['Message'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeTrue }
            }

            It 'Requires TimeoutSeconds' {
                $Script:Cmd.Parameters['TimeoutSeconds'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeTrue }
            }

            It 'Declares EnableSsl as optional bool' {
                $Script:Cmd.Parameters['EnableSsl'].ParameterType | Should -Be ([bool])

                $Script:Cmd.Parameters['EnableSsl'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeFalse }
            }

            It 'Does not expose WhatIf' {
                $Script:Cmd.Parameters.ContainsKey('WhatIf') | Should -BeFalse
            }
        }
        #endregion

        #region Validation - before connecting
        Context 'Validation: Message.From missing' {

            BeforeAll {

                Mock -CommandName New-TcpClientConnection -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage -From $null
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }
            }

            It 'Throws before connecting' {
                { Send-SmtpMessage @Script:Params } | Should -Throw '*From*'
            }

            It 'Does not call New-TcpClientConnection' {
                $invokeParams = @{
                    CommandName = 'New-TcpClientConnection'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }
        }

        Context 'Validation: no recipients' {

            BeforeAll {

                Mock -CommandName New-TcpClientConnection -MockWith { }

                $Script:Msg      = [System.Net.Mail.MailMessage]::new()
                $Script:Msg.From = [System.Net.Mail.MailAddress]::new('sender@example.com')

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = $Script:Msg
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }
            }

            It 'Throws before connecting' {
                { Send-SmtpMessage @Script:Params } | Should -Throw '*recipient*'
            }

            It 'Does not call New-TcpClientConnection' {
                $invokeParams = @{
                    CommandName = 'New-TcpClientConnection'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }
        }

        Context 'Validation: empty username' {

            BeforeAll {

                Mock -CommandName New-TcpClientConnection -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential -UserName ''
                    Message                     = New-TestMessage
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }
            }

            It 'Throws before connecting' {
                { Send-SmtpMessage @Script:Params } | Should -Throw '*username*'
            }

            It 'Does not call New-TcpClientConnection' {
                $invokeParams = @{
                    CommandName = 'New-TcpClientConnection'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }
        }

        Context 'Validation: port 465 without SSL' {

            BeforeAll {

                Mock -CommandName New-TcpClientConnection -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port465
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }
            }

            It 'Throws before connecting' {
                { Send-SmtpMessage @Script:Params } | Should -Throw '*465*'
            }

            It 'Does not call New-TcpClientConnection' {
                Should -Invoke -CommandName New-TcpClientConnection `
                    -ModuleName PipeDFe -Scope Context -Exactly -Times 0
            }
        }

        Context 'Validation: cleartext auth without AllowInsecureAuthentication' {

            BeforeAll {

                Mock -CommandName New-TcpClientConnection -MockWith { }

                $Script:Params = @{
                    Server         = $Script:Server
                    Port           = $Script:Port587
                    EnableSsl      = $false
                    Credential     = New-TestCredential
                    Message        = New-TestMessage
                    TimeoutSeconds = $Script:TimeoutSeconds
                }
            }

            It 'Throws before connecting' {
                { Send-SmtpMessage @Script:Params } | Should -Throw '*TLS*'
            }

            It 'Does not call New-TcpClientConnection' {
                Should -Invoke -CommandName New-TcpClientConnection `
                    -ModuleName PipeDFe -Scope Context -Exactly -Times 0
            }
        }
        #endregion

        #region Happy path - port 587 plaintext
        Context 'Happy path: port 587 without TLS' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines (Get-PlainSmtpLine)

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }

                # Execute exactly once; It blocks read $Script:Stream.WrittenText.
                Send-SmtpMessage @Script:Params
            }

            It 'Completes without throwing' {
                # If BeforeAll threw, this would be skipped. Passing = success.
                $true | Should -BeTrue
            }

            It 'Calls New-TcpClientConnection with the correct server and port' {
                $invokeParams = @{
                    CommandName     = 'New-TcpClientConnection'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Server -eq $Script:Server -and $Port   -eq $Script:Port587
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Does not call New-SmtpSslStream' {
                $invokeParams = @{
                    CommandName = 'New-SmtpSslStream'
                    ModuleName = 'PipeDFe'
                    Scope      = 'Context'
                    Exactly    = $true
                    Times      = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Sends EHLO PipeDFe' {
                $Script:Stream.WrittenText | Should -BeLike '*EHLO PipeDFe*'
            }

            It 'Sends AUTH LOGIN' {
                $Script:Stream.WrittenText | Should -BeLike '*AUTH LOGIN*'
            }

            It 'Sends MAIL FROM with the sender address' {
                $Script:Stream.WrittenText | Should -BeLike '*MAIL FROM:<sender@example.com>*'
            }

            It 'Sends RCPT TO with the recipient address' {
                $Script:Stream.WrittenText | Should -BeLike '*RCPT TO:<recipient@example.com>*'
            }

            It 'Sends DATA' {
                $Script:Stream.WrittenText | Should -BeLike '*DATA*'
            }

            It 'Terminates DATA with a lone CRLF-dot-CRLF' {
                $Script:Stream.WrittenText | Should -BeLike "*`r`n.`r`n*"
            }

            It 'Sends QUIT' {
                $Script:Stream.WrittenText | Should -BeLike '*QUIT*'
            }
        }
        #endregion

        #region Happy path - port 587 STARTTLS
        Context 'Happy path: port 587 with STARTTLS' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines (Get-StartTlsSmtpLine)

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith {
                    param (
                        [System.IO.Stream]$InnerStream,
                        [string]$TargetHost,
                        [int]$HandshakeTimeoutMs,
                        [string]$FailureContext
                    )

                    return $Script:Stream
                }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $true
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }

                Send-SmtpMessage @Script:Params
            }

            It 'Completes without throwing' {
                $true | Should -BeTrue
            }

            It 'Calls New-SmtpSslStream once with FailureContext STARTTLS' {
                $invokeParams = @{
                    CommandName     = 'New-SmtpSslStream'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $FailureContext -eq 'STARTTLS' }
                }

                Should -Invoke @invokeParams
            }

            It 'Sends the STARTTLS command' {
                $Script:Stream.WrittenText | Should -BeLike '*STARTTLS*'
            }

            It 'Sends a second EHLO after STARTTLS' {
                # Both EHLOs are written to the same stream.
                # Two occurrences of 'EHLO PipeDFe' confirm the re-EHLO.
                $occurrences = (
                    [regex]::Matches($Script:Stream.WrittenText, 'EHLO PipeDFe')
                ).Count

                $occurrences | Should -Be 2
            }
        }
        #endregion

        #region Happy path - port 465 implicit TLS
        Context 'Happy path: port 465 implicit TLS' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines (Get-PlainSmtpLine)

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith {
                    param (
                        [System.IO.Stream]$InnerStream,
                        [string]$TargetHost,
                        [int]$HandshakeTimeoutMs,
                        [string]$FailureContext
                    )

                    return $Script:Stream
                }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port465
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }

                Send-SmtpMessage @Script:Params
            }

            It 'Completes without throwing' {
                $true | Should -BeTrue
            }

            It 'Calls New-SmtpSslStream once with FailureContext TLS' {
                $invokeParams = @{
                    CommandName     = 'New-SmtpSslStream'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $FailureContext -eq 'TLS' }
                }

                Should -Invoke @invokeParams
            }

            It 'Does not send STARTTLS command' {
                $Script:Stream.WrittenText | Should -Not -BeLike '*STARTTLS*'
            }
        }
        #endregion

        #region AUTH failures
        Context 'AUTH: server does not advertise AUTH' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines @(
                    '220 smtp.example.com ESMTP ready'
                    '250-smtp.example.com'
                    '250 OK'
                )

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }
            }

            It 'Throws mentioning AUTH' {
                { Send-SmtpMessage @Script:Params } | Should -Throw '*AUTH*'
            }
        }

        Context 'AUTH: LOGIN not in advertised methods' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines @(
                    '220 smtp.example.com ESMTP ready'
                    '250-smtp.example.com'
                    '250-AUTH PLAIN XOAUTH2'
                    '250 OK'
                )

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }
            }

            It 'Throws mentioning AUTH LOGIN' {
                { Send-SmtpMessage @Script:Params } | Should -Throw '*AUTH LOGIN*'
            }
        }

        Context 'AUTH: AUTH LOGIN command rejected by server' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines @(
                    '220 smtp.example.com ESMTP ready'
                    '250-smtp.example.com'
                    '250-AUTH LOGIN'
                    '250 OK'
                    '535 Authentication failed'
                )

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }
            }

            It 'Throws mentioning the AUTH LOGIN command' {
                { Send-SmtpMessage @Script:Params } | Should -Throw '*AUTH LOGIN*'
            }
        }

        Context 'AUTH: username rejected' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines @(
                    '220 smtp.example.com ESMTP ready'
                    '250-smtp.example.com'
                    '250-AUTH LOGIN'
                    '250 OK'
                    '334 VXNlcm5hbWU6'
                    '535 Bad username'
                )

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }
            }

            It 'Throws mentioning username rejection' {
                { Send-SmtpMessage @Script:Params } | Should -Throw '*username*'
            }
        }

        Context 'AUTH: password rejected' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines @(
                    '220 smtp.example.com ESMTP ready'
                    '250-smtp.example.com'
                    '250-AUTH LOGIN'
                    '250 OK'
                    '334 VXNlcm5hbWU6'
                    '334 UGFzc3dvcmQ6'
                    '535 Authentication failed'
                )

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }
            }

            It 'Throws mentioning authentication failure' {
                { Send-SmtpMessage @Script:Params } | Should -Throw '*authentication*'
            }
        }
        #endregion

        #region STARTTLS not advertised
        Context 'STARTTLS: not advertised by server' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines @(
                    '220 smtp.example.com ESMTP ready'
                    '250-smtp.example.com'
                    '250 OK'
                )

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $true
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }
            }

            It 'Throws mentioning STARTTLS' {
                { Send-SmtpMessage @Script:Params } | Should -Throw '*STARTTLS*'
            }
        }
        #endregion

        #region SMTPUTF8 required but not advertised
        Context 'SMTPUTF8: non-ASCII envelope address without SMTPUTF8 support' {

            BeforeAll {

                # Each It call gets a fresh stream via the mock closure.
                Mock -CommandName New-TcpClientConnection -MockWith {
                    $smtputf8Lines = [string[]]@(
                        '220 smtp.example.com ESMTP ready'
                        '250-smtp.example.com'
                        '250-AUTH LOGIN'
                        '250 OK'
                        '334 VXNlcm5hbWU6'
                        '334 UGFzc3dvcmQ6'
                        '235 2.7.0 Authentication successful'
                    )

                    return New-MockTcpClient -Stream (New-SmtpServerStream -Lines $smtputf8Lines)
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }
            }

            It 'Throws mentioning SMTPUTF8 when the From address contains non-ASCII characters' {
                # MailMessage.From accepts a non-ASCII display name; the address
                # itself must be ASCII per RFC 5321 unless SMTPUTF8 is negotiated.
                # We use a non-ASCII local part via the raw string constructor that
                # .NET 4.5+ permits on MailAddress.
                #
                # If the runtime rejects the non-ASCII MailAddress at construction
                # time, the test is marked inconclusive - it cannot be covered
                # in unit tests without a SMTPUTF8-capable server.
                try {
                    $nonAsciiFrom = [System.Net.Mail.MailAddress]::new(
                        'a{0}ao@example.com' -f [char]0x00E7
                    )
                } catch {
                    Set-ItResult -Inconclusive -Because (
                        'Runtime rejected non-ASCII MailAddress at construction: ' +
                        $_.Exception.Message
                    )

                    return
                }

                $msg         = New-TestMessage
                $msg.From    = $nonAsciiFrom

                $smtpParams = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = $msg
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }

                { Send-SmtpMessage @smtpParams } | Should -Throw '*SMTPUTF8*'
            }
        }
        #endregion

        #region DATA rejection
        Context 'DATA: server rejects message after DATA' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines @(
                    '220 smtp.example.com ESMTP ready'
                    '250-smtp.example.com'
                    '250-AUTH LOGIN'
                    '250 OK'
                    '334 VXNlcm5hbWU6'
                    '334 UGFzc3dvcmQ6'
                    '235 2.7.0 Authentication successful'
                    '250 OK'
                    '250 OK'
                    '354 Start input'
                    '552 Message size exceeds limit'
                )

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }
            }

            It 'Throws mentioning server rejection' {
                { Send-SmtpMessage @Script:Params } | Should -Throw '*rejected*'
            }
        }
        #endregion

        #region QUIT failure is non-fatal
        Context 'QUIT: failure after successful DATA does not fail delivery' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines @(
                    '220 smtp.example.com ESMTP ready'
                    '250-smtp.example.com'
                    '250-AUTH LOGIN'
                    '250 OK'
                    '334 VXNlcm5hbWU6'
                    '334 UGFzc3dvcmQ6'
                    '235 2.7.0 Authentication successful'
                    '250 OK'
                    '250 OK'
                    '354 Start input'
                    '250 OK'
                    # Server drops the connection; no 221 response.
                )

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }
            }

            It 'Completes without throwing even when QUIT response is absent' {
                { Send-SmtpMessage @Script:Params } | Should -Not -Throw
            }
        }
        #endregion

        #region Body / MIME
        Context 'Body: dot-stuffing applied to lines starting with a dot' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines (Get-PlainSmtpLine)

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage -Body '.This line starts with a dot.'
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }

                Send-SmtpMessage @Script:Params
            }

            It 'Prefixes the dot line with an extra dot' {
                $Script:Stream.WrittenText | Should -BeLike '*..This line starts with a dot.*'
            }
        }

        Context 'Body: HTML message uses text/html Content-Type' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines (Get-PlainSmtpLine)

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage -Body '<p>Hello</p>' -IsBodyHtml $true
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }

                Send-SmtpMessage @Script:Params
            }

            It 'Sends Content-Type text/html' {
                $Script:Stream.WrittenText | Should -BeLike '*Content-Type: text/html*'
            }
        }

        Context 'Body: plain text message uses text/plain Content-Type' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines (Get-PlainSmtpLine)

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage -IsBodyHtml $false
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }

                Send-SmtpMessage @Script:Params
            }

            It 'Sends Content-Type text/plain' {
                $Script:Stream.WrittenText | Should -BeLike '*Content-Type: text/plain*'
            }
        }

        Context 'Subject: non-ASCII value encoded as RFC 2047 encoded-word' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines (Get-PlainSmtpLine)

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage -Subject 'Assunto: acao fiscal'
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }

                Send-SmtpMessage @Script:Params
            }

            It 'Subject is transmitted as plain ASCII when no non-ASCII chars present' {
                $Script:Stream.WrittenText | Should -BeLike '*Subject: Assunto: acao fiscal*'
            }
        }

        Context 'Subject: non-ASCII value (with accents) encoded as RFC 2047' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines (Get-PlainSmtpLine)

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $subject = 'Assunto: a{0}{1}o fiscal' -f [char]0x00E7, [char]0x00E3

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage -Subject $subject
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }

                Send-SmtpMessage @Script:Params
            }

            It 'Encodes the subject using =?UTF-8?B? encoded-words' {
                # ConvertTo-MimeHeaderLines emits "Subject:" on its own line
                # followed by a continuation line with the encoded-word.
                $Script:Stream.WrittenText | Should -BeLike '*Subject:*'
                $Script:Stream.WrittenText | Should -BeLike '* =?UTF-8?B?*'
            }
        }
        #endregion

        #region Multiple recipients
        Context 'Recipients: multiple To addresses each get their own RCPT TO' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines @(
                    '220 smtp.example.com ESMTP ready'
                    '250-smtp.example.com'
                    '250-AUTH LOGIN'
                    '250 OK'
                    '334 VXNlcm5hbWU6'
                    '334 UGFzc3dvcmQ6'
                    '235 2.7.0 Authentication successful'
                    '250 OK'       # MAIL FROM
                    '250 OK'       # RCPT TO first
                    '250 OK'       # RCPT TO second
                    '354 Start input'
                    '250 OK'
                    '221 Bye'
                )

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage -To @('a@example.com', 'b@example.com')
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }

                Send-SmtpMessage @Script:Params
            }

            It 'Sends RCPT TO for the first recipient' {
                $Script:Stream.WrittenText | Should -BeLike '*RCPT TO:<a@example.com>*'
            }

            It 'Sends RCPT TO for the second recipient' {
                $Script:Stream.WrittenText | Should -BeLike '*RCPT TO:<b@example.com>*'
            }
        }
        #endregion

        #region Greeting rejected
        Context 'Greeting: server sends non-220 greeting' {

            BeforeAll {

                $Script:Stream = New-SmtpServerStream -Lines @(
                    '554 No service here'
                )

                Mock -CommandName New-TcpClientConnection -MockWith {
                    return New-MockTcpClient -Stream $Script:Stream
                }

                Mock -CommandName New-SmtpSslStream -MockWith { }

                $Script:Params = @{
                    Server                      = $Script:Server
                    Port                        = $Script:Port587
                    EnableSsl                   = $false
                    AllowInsecureAuthentication = $true
                    Credential                  = New-TestCredential
                    Message                     = New-TestMessage
                    TimeoutSeconds              = $Script:TimeoutSeconds
                }
            }

            It 'Throws mentioning connection rejection' {
                { Send-SmtpMessage @Script:Params } | Should -Throw '*rejected*'
            }
        }
        #endregion
    }
}
