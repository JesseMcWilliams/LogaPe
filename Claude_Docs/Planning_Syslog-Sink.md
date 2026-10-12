# Plan: Syslog sink

> **Stage: Planning.** Proposed design for sending LogaPe output to a syslog server. Nothing here
> is implemented yet. Once it ships, move the design into a new numbered section of
> `Design_Architecture.md` and rename this file `Archive_Planning_Syslog-Sink.md`.

Status: **Final, 2026-10-12.** Questions 1–7 are answered (§9): every *(proposed)* choice was
accepted, and the user asked for current best practice throughout, which added §3.2's TLS
requirements (RFC 9662, mutual TLS, certificate pinning). The live test runs against a collector
VM deployed by LABaPe (§6).

Progress: phases 1–6 (§7) are built and tested on loopback on both editions; what shipped is
in `Design_Architecture.md` §12. Phase 7 (the lab live test) is next. Archive this plan once it
passes.

## 1. Goal

Add a second sink type, next to the Windows Event Log sink, that sends log records to a remote
syslog collector (rsyslog, syslog-ng, a SIEM, Graylog, Splunk). It works the same way as the
existing sinks:

- An `Add-LoggerSyslogSink` function returns a sink Id. `Get-LoggerSink` lists the sink and
  `Remove-LoggerSink` removes it.
- The sink has its own minimum level, independent of the Console/File levels.
- Masking applies to it exactly as it does to every other output.
- A failed send never throws into the caller's script.
- It works on Windows PowerShell 5.1 and PowerShell 7, using only .NET types available on both
  (`UdpClient`, `TcpClient`, `SslStream`). It needs no external modules.

Out of scope: receiving syslog, reading syslog back (`Get-LoggerContent` stays file-only), and
the PowerShell Gallery.

## 2. Where it fits in the current code

All of this is in `LogaPe/LogaPe.psm1`, which stays one file (§10 of the design doc).

| Piece today | Line (approx.) | Change |
|---|---|---|
| `class LoggingSink`: `Id`, `Type`, `Level` and a `Config` hashtable | 76 | Add a `hidden [object] $Transport` and a `[void]Dispose()`. `Config` keeps holding only plain settings, so `Get-LoggerSink` never shows a socket. |
| `Logger.RemoveSink()` | 512 | Call `Dispose()` on the sink before removing it. |
| `Logger.Close()` disposes only the file mutex | 500 | Also dispose every sink, so `Remove-Logger` closes sockets. |
| `Logger._WriteOutput()` formats once, then fans out | 764 | The syslog sink needs the masked message and fields *before* text formatting (§4.4). Compute them once and pass them to the sinks. |
| `Logger.WriteToSink()`: `if ($Sink.Type -eq 'EventLog')` | 875 | Add an `elseif ($Sink.Type -eq 'Syslog')` branch that delegates to the transport class. Use `if`/`elseif`, not `switch` (Lessons-Learned § PowerShell Classes). |
| `Add-LoggerEventLogSink` | 2070 | The model for `Add-LoggerSyslogSink`: `SupportsShouldProcess`, `Resolve-TargetLogger`, then `AddSink`. |

New classes, placed after `LoggingSink`:

- **`SyslogFormatter`**: builds the RFC 5424 or RFC 3164 message bytes. It's a pure function of
  its inputs, so it can be unit-tested without a network.
- **`SyslogTransport`**: owns the socket. It sends one message, handles framing, reconnects, and
  rate-limits warnings.

## 3. Protocol choices

### 3.1 Message formats

| Format | Wire layout | Use |
|---|---|---|
| **RFC 5424** (default, *proposed*) | `<PRI>1 TIMESTAMP HOSTNAME APP-NAME PROCID MSGID STRUCTURED-DATA MSG` | Modern collectors. Timestamp in RFC 3339 with offset and milliseconds, UTF-8 body. |
| **RFC 3164** (legacy BSD) | `<PRI>Mmm dd HH:mm:ss HOSTNAME TAG[PID]: MSG` | Old appliances and relays that reject 5424. Local time, no year, no zone. Day is space-padded (`Oct  2`). |

Header field rules for RFC 5424, enforced by the formatter:

- HOSTNAME up to 255 printable US-ASCII characters, APP-NAME up to 48, PROCID up to 128, MSGID
  up to 32.
- An empty value is written as the nil value `-`.
- Spaces and non-ASCII characters are removed from header fields, not escaped.
- MSG is UTF-8. When it contains any non-ASCII character it starts with a byte order mark, as
  RFC 5424 §6.4 requires for UTF-8 messages. A pure-ASCII MSG is sent without one (valid as
  `MSG-ANY`), so most messages look the same on every collector.

RFC 3164 rules: HOSTNAME is the short host name (no domain, as §4.1.2 requires), TAG is at most
32 alphanumeric characters, and the month names are always English.

### 3.2 Transports

| Transport | Default port | Framing | Notes |
|---|---|---|---|
| **UDP** (RFC 5426), default | 514 | One message per datagram | Fire-and-forget. No error if nobody is listening. Delivery isn't guaranteed. |
| **TCP** (RFC 6587) | 514 | Octet-counting (`LEN SP MSG`) by default; LF-terminated ("non-transparent") as an option | Reliable while connected. Multi-line messages are only safe with octet-counting. |
| **TLS** (RFC 5425) | 6514 | Octet-counting (required by RFC 5425) | `SslStream` over TCP. The server certificate is validated by default. |

TLS details (current best practice: RFC 5425 as updated by RFC 9662, and RFC 9325):

- **Protocols.** TLS 1.2 and TLS 1.3 only. SSL 3, TLS 1.0 and TLS 1.1 are never offered.
  TLS 1.3 is requested only where the `SslProtocols.Tls13` enum value exists, and the OS
  negotiates the highest version both ends support. Naming the versions explicitly matters on
  .NET Framework, whose default `SslProtocols` can exclude TLS 1.2, depending on registry
  settings.
- **Cipher suites.** Left to the OS (Schannel), which prefers forward-secret AEAD suites such as
  `TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256`, the suite RFC 9662 makes mandatory. Schannel is
  FIPS-validated, so the sink works on FIPS-enforcing hosts.
- **Server authentication, default.** The certificate chain must validate to a trusted root,
  and the certificate must match `-Server` (subject alternative name). Schannel checks both.
- **Revocation.** `-CheckCertificateRevocation` also checks CRL/OCSP. It's off by default,
  because many private and lab CAs publish no revocation information, and then every connection
  would fail.
- **Certificate pinning.** `-ServerCertificateThumbprint` accepts the server only if its
  certificate's SHA-256 fingerprint matches one of the given values. This is RFC 5425 §5.2's
  fingerprint authentication, and it works with self-signed certificates. It replaces chain and
  name validation.
- **Mutual TLS.** `-ClientCertificate` (an `X509Certificate2` with a private key, e.g. from
  `Cert:\CurrentUser\My`) is offered to collectors that ask for one (RFC 5425 §4.2.1).
- **`-SkipCertificateCheck`.** Accepts any server certificate. Lab use only; adding the sink
  writes a warning.
- **The validation callback** is a small C# class compiled with `Add-Type` the first time a TLS
  sink connects, not a PowerShell scriptblock. A scriptblock delegate needs a runspace on the
  calling thread and can deadlock when another runspace is busy. The callback also records why a
  certificate was rejected, so the warning can say so.

### 3.3 Severity and facility mapping

PRI = facility × 8 + severity.

| LogaPe level | Syslog severity |
|---|---|
| Critical | 2 `crit` |
| Error | 3 `err` |
| Warning | 4 `warning` |
| Information | 6 `info` |
| Debug | 7 `debug` |
| Verbose / Trace | 7 `debug` |
| None (used as a message level) | 6 `info` |

LogaPe has no levels that map to `emerg` (0), `alert` (1) or `notice` (5), so those severities
are never sent.

`-Facility` accepts the RFC 5424 names `kern` through `local7`. The default is `user` (1)
*(proposed, §9 Q6)*.

## 4. Behaviour

### 4.1 Header values and their defaults

| Field | Default | Override |
|---|---|---|
| HOSTNAME | FQDN, computed once when the sink is added: `$env:COMPUTERNAME` plus `IPGlobalProperties.DomainName`. Not a DNS lookup on every write. | `-HostName` |
| APP-NAME / TAG | The logger's file base name without `New-Logger`'s `yyyy-MM-dd_` prefix (usually the calling script's name) | `-AppName` |
| PROCID | `$PID` | none |
| MSGID | `-` | `-MessageId` |

### 4.2 Message size

`-MaxMessageBytes` sets the size limit:

- The defaults are 2048 bytes for UDP (the RFC 5424 "SHOULD support" size) and 8192 bytes for
  TCP and TLS.
- RFC 3164 messages are capped at 1024 bytes.
- An oversized message is cut at a UTF-8 character boundary, so no multi-byte character is
  split.
- Truncation is never silent: the end of the message is replaced with `...[truncated]`.

### 4.3 Connections, failures and thread safety

- **Connection lifetime.** One socket per sink, opened lazily on the first write and kept open.
  The server name is resolved once and re-resolved after an error. UDP sends to the resolved
  endpoint without `Connect()`: on Windows, a connected UDP socket turns a collector's ICMP
  "port unreachable" into an exception on the next send. Before each TCP/TLS send, a closed
  connection (the collector restarted) is detected with `Socket.Poll` and reopened, so the
  message isn't written into a dead socket.
- **Timeouts.** `-TimeoutSeconds` (default 2) limits the TCP connect, the TLS handshake and
  each send, so a stalled collector can't hang the caller indefinitely.
- **Backoff after a failure.** After a failed connect or send, the transport is marked down until
  a retry time. Writes during that window are dropped immediately instead of each one waiting
  for a timeout. The backoff doubles from 1 s up to 60 s, and the next write after the window
  tries again.
- **Warnings.** There is one `Write-Warning` per outage, not one per message, plus one when the
  connection comes back. This differs from the Event Log sink, which warns on every failed write.
  For a network sink, per-message warnings would flood the console.
- **Thread safety.** Each send runs inside `[System.Threading.Monitor]::Enter/Exit` on the
  transport's lock object, so two threads sharing a sink can't interleave TCP frames. Each UDP
  datagram is already atomic. Sharing one `Logger` object across runspaces isn't a supported
  pattern in LogaPe (PowerShell class methods have affinity to the runspace that created the
  object), so the concurrency test gives each runspace its own logger, as the file test does.
- **Process safety.** Each process has its own socket. The collector sees independent streams,
  so the per-file mutex isn't involved.
- **Delivery model.** v1 sends synchronously (§9 Q5). A background queue would hide latency but
  could lose messages on exit, and it would need a flush when the logger is removed.

### 4.4 Message body, masking and fields

Today, `FormatMessage` produces one string, and that string already includes the logger's
`{Timestamp} | {Level} |` prefix. Syslog carries the timestamp and severity in its header, so
sending the formatted string would duplicate both. *Proposed* (§9 Q4):

1. **Masking stays in one place.** Split the masking step out of `FormatMessage` into a small
   helper that returns the masked message and the masked fields. `FormatMessage` and the syslog
   sink both use its output, so masking still runs once per write, and `-SkipMasking` behaves
   the same everywhere. This is the one refactor of existing code, and the masking tests cover
   it.
2. **The body depends on `OutputFormat`.**
   - `Text`: the masked message, followed by ` | key=value, ...` if there are fields. This is the
     same layout the file uses, without the timestamp and level prefix.
   - `Json`: the same compact JSON record as the file, without `Timestamp` and `Level`.
3. **Structured data is opt-in** (§9 Q3). RFC 5424 STRUCTURED-DATA needs an SD-ID of the form
   `name@<IANA Private Enterprise Number>`, and LogaPe has no enterprise number. So:
   - By default, STRUCTURED-DATA is `-` and fields go in the body.
   - `-StructuredDataId 'logape@12345'` writes the fields as `[logape@12345 key="value" ...]`
     instead, with `"`, `\` and `]` escaped as RFC 5424 §6.3.3 requires.
   - The documentation example uses 32473, the enterprise number reserved for documentation
     (RFC 5612).

## 5. Public API

```powershell
Add-LoggerSyslogSink
    [-Server] <string>                    # host name or IP address
    [-Port <int>]                         # default by protocol: 514 / 514 / 6514
    [-Protocol <Udp|Tcp|Tls>]             # default Udp
    [-Format <Rfc5424|Rfc3164>]           # default Rfc5424
    [-Framing <OctetCounting|LineFeed>]   # TCP only; TLS is always OctetCounting
    [-Facility <kern..local7>]            # default user
    [-Level <LoggingLevel name>]          # default Warning, matching the Event Log sink
    [-AppName <string>] [-HostName <string>] [-MessageId <string>]
    [-StructuredDataId <string>]
    [-MaxMessageBytes <int>]
    [-TimeoutSeconds <int>]               # connect, handshake and send; default 2
    [-ClientCertificate <X509Certificate2>]       # TLS only: mutual TLS
    [-ServerCertificateThumbprint <string[]>]     # TLS only: SHA-256 pinning
    [-CheckCertificateRevocation]                 # TLS only
    [-SkipCertificateCheck]               # TLS only; warns when used
    [-Logger <Logger>]
    [-WhatIf] [-Confirm]
# Returns the sink Id (string), like Add-LoggerEventLogSink.
```

- **Validation.** These are errors: `-Framing LineFeed` with `-Protocol Tls`; any TLS-only
  parameter without `-Protocol Tls`; `-SkipCertificateCheck` together with
  `-ServerCertificateThumbprint` or `-CheckCertificateRevocation`; a `-ClientCertificate`
  without a private key; a thumbprint that isn't 64 hex digits (colons and spaces are ignored);
  a `-StructuredDataId` that isn't `name@number`.
- **LineFeed framing** replaces CR and LF inside a message with spaces, since a newline ends the
  frame. Octet-counting keeps multi-line messages intact.
- **When the server is checked.** `Add-LoggerSyslogSink` doesn't connect. It only validates
  that `-Server` resolves, and warns if it doesn't, without failing. This matches the Event Log
  sink's "warn but still add" behaviour, and it means a collector that's down at startup can't
  block the script.
- **Listing.** `Get-LoggerSink` shows `Type = 'Syslog'`, and `Config` holds the settings above.
  It never holds the socket.
- **Removal.** `Remove-LoggerSink` and `Remove-Logger` close the socket.
- **Manifest.** Add the function to `FunctionsToExport` in `LogaPe.psd1`.

## 6. Tests

Everything below runs on loopback with no external server. It runs on 5.1 and under `pwsh`
(CLAUDE.md § Tests).

| Area | How |
|---|---|
| Formatter, RFC 5424 | Call the formatter directly. Check the PRI for each level and facility, the RFC 3339 timestamp, nil values, header field length limits, SD escaping, UTF-8 truncation at a character boundary, and the truncation marker. |
| Formatter, RFC 3164 | Check the space-padded day, the `TAG[PID]:` layout and the 1024-byte cap. |
| UDP end to end | A `UdpClient` bound to `127.0.0.1:0` (an ephemeral port), then `Add-LoggerSyslogSink -Port <that port>`, then `Write-Log`. Receive with a timeout and check the bytes. |
| TCP end to end | A `TcpListener` on loopback. Check both framings, and that a multi-line message arrives as one octet-counted frame. |
| TLS end to end | A self-signed certificate made in memory with `CertificateRequest` (no certificate store is touched), and an `SslStream` server in a background runspace. Check that the default validation rejects it, that `-SkipCertificateCheck` and a matching `-ServerCertificateThumbprint` accept it, that a wrong thumbprint rejects it, that the negotiated protocol is TLS 1.2 or 1.3, and that a server requiring a client certificate receives the one given by `-ClientCertificate`. |
| Level filtering | Nothing arrives below the sink's level. |
| Masking | A default-masking rule's secret never appears in the received bytes, for Text, Json and structured-data bodies. `-SkipMasking` sends the value unmasked. |
| Failure handling | A TCP sink pointed at a closed port: `Write-Log` doesn't throw, warns once over several writes, and returns quickly while backed off (measure the elapsed time). |
| Lifecycle | `Remove-LoggerSink` and `Remove-Logger` dispose the socket, and the listener sees the connection close. |
| Concurrency | Several runspaces, each with its own logger and TCP sink, write to one listener. Every frame parses and none are lost. |

Example `Examples/08-SyslogSink.ps1` starts a loopback UDP listener, adds a sink, logs a few
levels and prints what the listener received. That way `Examples.Tests.ps1` smoke-tests it on
both editions without a real collector. `Examples/README.md` gets a row for it.

**Live test (lab).** The lab has no syslog collector, so LABaPe deploys a Linux VM with a
syslog collector role (rsyslog listening on UDP 514, TCP 514 and TLS 6514, with a certificate
from LABaPe's platform CA). That role is LABaPe work and is tracked in the LABaPe repository.
LogaPe sends to it over UDP, TCP and TLS (with chain validation, pinning, and mutual TLS), and
the test confirms on the server that the severity, facility, host and app name parse correctly
(§9 Q7).

## 7. Implementation phases

Each phase leaves the full suite at 100% and works on both editions.

1. **Refactor.** Extract the masked-record helper from `FormatMessage`. Add
   `LoggingSink.Dispose()` and wire it into `RemoveSink` and `Close`. The existing tests must
   still pass unchanged.
2. **Formatter.** Add the `SyslogFormatter` class and its unit tests (RFC 5424, RFC 3164,
   truncation, SD escaping).
3. **UDP.** Add `SyslogTransport` (UDP), the `Syslog` branch in `WriteToSink`,
   `Add-LoggerSyslogSink`, the export, and the UDP end-to-end, level and masking tests.
4. **TCP.** Add both framings, connect and send timeouts, backoff with rate-limited warnings, and
   the locking, plus the failure-handling and concurrency tests.
5. **TLS.** Add `SslStream`, protocol selection, certificate validation and
   `-SkipCertificateCheck`, plus the TLS tests.
6. **Docs and example.**
   - `Design_Architecture.md` §12 (Syslog sink).
   - `User_Docs/Usage.md`: turn "Additional sinks" into a section with Event Log and Syslog
     subsections, and add a function reference entry.
   - The README feature list, `Examples/08-SyslogSink.ps1`, `Examples/README.md`, the
     `CHANGELOG.md` `[Unreleased]` entry, and `Reference_Lessons-Learned.md` for any gotchas
     found along the way.
   - Archive this plan.
7. **Live test** in the lab, then release as **0.7.0**: new feature, no breaking change.

## 8. Risks

| Risk | Mitigation |
|---|---|
| A slow or stalled collector slows every `Write-Log` | Short connect and send timeouts, plus backoff so an outage costs one timeout and not one per message. A background queue is available later if that isn't enough (§9 Q5). |
| Secrets leave the host | Masking runs before the sink, the same as for every output, and is covered by tests. Recommend TLS in the docs for anything off-host. |
| UDP silently drops messages | Documented. Recommend TCP or TLS when delivery matters. |
| `SslStream` behaves differently on .NET Framework and .NET 7+ (protocol defaults, the `Tls13` enum) | Choose protocols explicitly, and run the TLS tests on both editions. |
| A PowerShell scriptblock as the certificate-validation callback needs a runspace and can deadlock | The callback is a small C# class (`Add-Type`, compiled once per process on the first TLS connect), so it runs on any thread. `Add-Type` takes about a second on 5.1; only TLS sinks pay it. |
| More code in a 2,700-line file | Expected and accepted (§10). The two new classes stay self-contained. |

## 9. Open questions

All answered 2026-10-12 (questions 1–7 in [Planning_Questions.md](Planning_Questions.md)). The
user accepted every proposal and asked for current best practice throughout.

1. **Transports in v1.** UDP, TCP and TLS. Mutual TLS is in v1 too, as part of best practice
   (§3.2).
2. **Default format.** RFC 5424. RFC 3164 stays available with `-Format Rfc3164`.
3. **Fields.** In the body by default; structured data only through `-StructuredDataId`. There
   is no IANA enterprise number to use as a default.
4. **Body content.** The message and fields only, without LogaPe's timestamp and level prefix.
5. **Delivery model.** Synchronous, with timeouts and backoff.
6. **Default facility.** `user`.
7. **Live testing.** There is no collector in the lab. Deploy a VM with a collector role through
   LABaPe (§6).
