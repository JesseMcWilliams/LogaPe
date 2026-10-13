# LogaPe — Design Document

Status: **Implemented** (v0.1.0 through v0.6.0). §1-9 cover the original module rewrite; §10
records what shipped for that rewrite. §11 covers the masking feature added in v0.5.0.
v0.6.0 added PowerShell 7 support (§3) and a FIPS-safe mutex name.

## 1. Purpose

Bring the existing `Logger` module up to PowerShell Gallery publishing standards and current
PowerShell module best practices, while preserving its core value: thread/process-safe
(mutex-guarded) logging to console and/or file, with configurable levels and destinations.

## 2. Current State

| File | Role |
|---|---|
| `Logger.psm1` | Everything: `Test-IsFileLocked` function, `LoggingLevel`, `LoggingDestination`, `LoggingObject`, `Logger` classes, a leftover `Write-Test` function. |
| `Logger.ps1` | Just `using module Logger` — a one-line stub. |
| `README.md` | Two lines; says to drop the psm1/ps1 into a `WindowsPowerShell\Modules\Logger` folder. |
| `LICENSE` | GPLv3. |

There is **no module manifest (`.psd1`)**, no version, no tests, no linting config, and no
comment-based help discoverable via `Get-Help` (classes don't support it; the one doc-comment
block in `Logger.psm1` sits *after* the class's last method, so it's inert).

The public surface today is entirely PowerShell classes, consumed via
`using module Logger; $Logger = [Logger]::new("Verbose")`. `Write-Test` is exported but is
unrelated scratch/test code, not part of the logging API.

## 3. Decisions Already Made

These came out of the initial review discussion:

| Decision | Choice |
|---|---|
| Module name | **`LogaPe`** (renamed from generic "Logger", see §6) |
| PowerShell target | Originally **Windows PowerShell 5.1 only**. Since 2026-10-09: **5.1 and PowerShell 7 on Windows** (`CompatiblePSEditions = Desktop, Core`), because aPeDiscovery moved to PowerShell 7. Event Log access uses `[System.Diagnostics.EventLog]` directly, since PowerShell 7 has no `*-EventLog` cmdlets. |
| Public API shape | **Add approved-verb function wrappers** (`New-Logger`, `Write-Log`, etc.) as the primary, exported, documented API; keep the classes underneath |
| Default/active logger | **Supported** — `Write-Log` works without an explicit `-Logger` argument (see §7) |
| Publish to Gallery now? | **Not yet** — build to Gallery quality, wire up real publishing later |
| License | **Switch to MIT** |
| Testing | **Pester tests + PSScriptAnalyzer linting**, both in scope |
| Known bugs found in review | **Document now, fix during implementation** (see §4) |
| Mutex/retry timing in `WriteFile` | **Flexible** — free to redesign, not required to preserve exact current timing (see §4, item 5/6) |

## 4. Bugs / Issues Found During Review

These are functional defects, not style nits — they should be fixed as part of the
implementation work, not carried forward.

1. **Default log path resolves to the module's own folder, not the caller's script.**
   [Logger.psm1:420](Logger.psm1#L420) (and the other constructors at lines 449, 483, 517, 567)
   use `Split-Path -Parent $PSCommandPath` *inside the class, which lives in `Logger.psm1`*.
   Inside a class method, `$PSCommandPath` resolves to the `.psm1` file itself, not the
   script that called `[Logger]::new()`. So by default, log files get written next to the
   installed module — almost certainly not what a caller expects.

2. **Type mismatch in the `Write()` level-comparison overloads.**
   [Logger.psm1:709](Logger.psm1#L709), [:722](Logger.psm1#L722), [:736](Logger.psm1#L736) all
   do:
   ```powershell
   if ($this.TargetLogLevel.Level() -le ([LoggingLevel]($Level).Name()).Level())
   ```
   `$Level` is already a `[LoggingLevel]`; casting it to `[LoggingLevel]` is a no-op, `.Name()`
   then returns a `string`, and `.Level()` is called *on that string* — which has no such
   method. This should simply be `$Level.Level()`.

3. **Inconsistent argument types passed into `_WriteOutput`.** The single-`Level`-arg overload
   ([Logger.psm1:711](Logger.psm1#L711)) passes the `[LoggingLevel]` object, but the
   destination/bare overloads ([:724](Logger.psm1#L724), [:738](Logger.psm1#L738)) pass
   `$Level.Name()` (a string) into a parameter typed `[LoggingLevel]`. This happens to work
   only because PowerShell will implicitly invoke `LoggingLevel([string])` — relying on that
   is fragile and should be made explicit and consistent.

4. **`Logger.GetLoggingFile()` returns just the file name**
   ([Logger.psm1:643](Logger.psm1#L643)), while `LoggingObject.GetLoggingFile()`
   ([Logger.psm1:205](Logger.psm1#L205)) returns the full path. Same method name, different
   meaning depending on which class you call it on — confusing and worth reconciling.

5. **Mutex name is derived only from the log file's leaf name**
   ([Logger.psm1:188](Logger.psm1#L188)). Named mutexes are global to the session/system on
   Windows, so two unrelated scripts that happen to use the same log *file name* in different
   folders will unintentionally synchronize on the same mutex. Worth deriving the mutex name
   from the full, normalized path (e.g. a hash of it) instead. Since the mutex/retry design is
   flexible (not required to match today's implementation exactly), this can be redesigned
   alongside item 6 rather than patched in place.

6. **`Test-IsFileLocked` opens the file with default `FileShare.None`**
   ([Logger.psm1:28](Logger.psm1#L28)), so it will report "locked" even against a reader that
   has the file open with share-read — and there's a check-then-act race between this probe
   and the subsequent `Add-Content` in `WriteFile`. It narrows the window but doesn't
   eliminate the race; `WriteFile`'s own retry loop is the actual safety net. Given the
   mutex/retry behavior is open to simplification, the implementation phase can consider
   dropping this pre-check entirely and relying solely on the mutex + a bounded `Add-Content`
   retry loop, which would remove the race rather than just narrow it.

7. **`Logger.ps1` is dead weight.** It contains only `using module Logger`, which only works
   if a module literally named `Logger` is resolvable on `$env:PSModulePath` — it doesn't
   `using module .\Logger.psm1` relatively. Once there's a real manifest-based module, this
   file has no purpose and should be removed.

8. **`Write-Test` is scratch code exported from the module** ([Logger.psm1:792](Logger.psm1#L792)-797)
   and should be deleted — it's not part of the logging API and pollutes the module's exported
   surface.

## 5. Gap Analysis vs. PowerShell Gallery / Best-Practice Standards

| Requirement | Current State | Target |
|---|---|---|
| Module manifest (`.psd1`) | Missing | Add, with explicit `ModuleVersion`, `GUID`, `Author`, `CompanyName`, `Copyright`, `PowerShellVersion = '5.1'`, `Description`, `Tags`, `ProjectUri`, `LicenseUri` |
| `FunctionsToExport` | N/A (no manifest) | Explicit list — never `'*'` |
| Folder layout | Flat repo root | `LogaPe/LogaPe.psd1`, `LogaPe/LogaPe.psm1`, `LogaPe/Public/`, `LogaPe/Private/` (or single psm1 if kept small) |
| Approved verbs | `Test-IsFileLocked`, `Write-Test` only; class-based API has no verbs | New function wrappers use `Get-Verb`-approved verbs (`New-`, `Write-`, `Get-`, `Set-`) |
| Comment-based help | None reachable via `Get-Help` | Every exported function gets `.SYNOPSIS`/`.DESCRIPTION`/`.PARAMETER`/`.EXAMPLE` |
| Tests | None | Pester test suite covering level filtering, destination routing, concurrent-write safety, path resolution |
| Linting | None | `PSScriptAnalyzer` + a `PSScriptAnalyzerSettings.psd1`; any deliberate `Write-Host` use (this module's job is console output) gets a documented rule suppression, not a blanket disable |
| Versioning | None | SemVer via manifest `ModuleVersion`, `CHANGELOG.md` |
| License | GPLv3 | MIT |
| README | 2 lines | Install instructions, quick-start example using the new function API, link to this design doc |

## 6. Module Name

**Decided: `LogaPe`.**

Before this is committed to the manifest, run `Find-Module LogaPe` (and check
`https://www.powershellgallery.com/packages/LogaPe`) to confirm it isn't already taken. Since
we're not publishing yet (§3), this isn't urgent, but it's cheap to verify now rather than
discover a collision later.

## 7. Proposed Public API (function wrappers)

The classes (`Logger`, `LoggingLevel`, `LoggingDestination`, `LoggingObject`) stay as the
internal implementation, reachable via `using module` for advanced use, but the
**documented, exported, primary API** becomes a set of approved-verb functions wrapping a
`Logger` instance:

| Function | Replaces |
|---|---|
| `New-Logger` | `[Logger]::new(...)` |
| `Write-Log` | `$Logger.Write(...)` |
| `Get-LoggerLevel` / `Set-LoggerLevel` | `$Logger.GetLoggingLevel()` / `.SetLoggingLevel()` |
| `Get-LoggerDestination` / `Set-LoggerDestination` | `$Logger.GetLogDestination()` / `.SetLogDestination()` |
| `Get-LoggerPath` / `Set-LoggerPath` | `$Logger.GetLoggingPath()` / `.SetLoggingPath()` |
| `Get-LoggerFile` / `Set-LoggerFile` | `$Logger.GetLoggingFile()` / `.SetLoggingFile()` |
| `Get-LoggerTimeout` / `Set-LoggerTimeout` | `$Logger.GetTimeOutSeconds()` / `.SetTimeOutSeconds()` |

`Test-IsFileLocked` becomes a private (non-exported) helper — it's an implementation detail
of `Write-Log`'s retry loop, not something a consumer should be calling directly.

**Decided: support a default/active logger.** All `-Logger` parameters below are
**optional**. Module-scoped state tracks one "active" logger:

| Function | Purpose |
|---|---|
| `New-Logger [-SetActive]` | Creates a logger instance. Returns it always; with `-SetActive` (or if no active logger exists yet) also stores it as the module's active logger. |
| `Set-ActiveLogger -Logger <Logger>` | Explicitly makes an existing instance the active one. |
| `Get-ActiveLogger` | Returns the current active logger instance (or `$null`/error if none set). |
| `Write-Log -Message <string> [-Logger <Logger>] [-Level <string>] [-Destination <string>] [-Bare]` | If `-Logger` is omitted, writes through the active logger; throws a clear error if neither was ever set. |

This keeps the multi-instance/multi-file case fully supported (pass `-Logger` explicitly)
while making the common single-logger-per-script case as simple as:
```powershell
New-Logger -Level Verbose -SetActive | Out-Null
Write-Log "Hello world" -Level Information
```

## 8. Proposed Implementation Plan

1. Restructure into a proper module folder (`LogaPe/LogaPe.psd1` + `LogaPe/LogaPe.psm1`),
   write the manifest, switch `LICENSE` to MIT, delete `Logger.ps1` and `Write-Test`.
2. Fix the bugs in §4 in the class implementation (path resolution, type mismatches,
   mutex/retry redesign, `GetLoggingFile` inconsistency).
3. Build the function-wrapper API in §7 (including `New-Logger`/`Set-ActiveLogger`/
   `Get-ActiveLogger`/`Write-Log`), each with comment-based help.
4. Add a Pester test suite (level filtering, destination routing, concurrent-write behavior,
   default-path behavior, active-logger fallback) and a `PSScriptAnalyzerSettings.psd1`.
5. Rewrite `README.md`: install steps, quick-start example, link to this doc.
6. Add `CHANGELOG.md` starting at `0.1.0`.

## 9. Remaining Open Items

Everything raised during design review has been decided (name, API shape, default-logger
support, license, testing scope, mutex/retry flexibility). Only mechanical verification is
left before implementation: confirm `LogaPe` isn't already in use on the PowerShell Gallery
(§6) before any real publish.

## 10. Implementation Notes (what actually shipped)

The plan in §8 was followed, with one structural change and several additional fixes found
while building and testing against real PowerShell 5.1:

### Folder layout: single `LogaPe.psm1`, not `Public`/`Private` folders

§5's proposed `Public/`/`Private/` dot-sourced layout turned out not to work: PowerShell
resolves a class type literal (e.g. `[Logger]` used as a parameter type) by scanning the
*same file's* parsed AST for `class Logger {...}`. A function dot-sourced from a separate
`.ps1` file is parsed independently, so `[Logger]$Logger` in that file fails with
`Unable to find type [Logger]` even though the class is defined earlier in the same module's
load sequence. The fix — and the standard workaround for PowerShell-classes-based modules —
is to keep the classes and every function that references them as a type constraint in one
physical file. `LogaPe.psm1` is now a single file with `#region` markers separating classes,
private helpers, and public functions; `Export-ModuleMember` lists the public functions
explicitly at the bottom, matching the manifest's `FunctionsToExport`.

### Additional bugs found and fixed during implementation

- **Log line timestamp format was `yyyy-dd-MM hh:mm:ss`** — day/month swapped relative to the
  file name's `yyyy-MM-dd`, and a 12-hour clock with no AM/PM marker. Now `yyyy-MM-dd
  HH:mm:ss` throughout.
- **A stray `Write-Information ("Starting Output")` fired on every single write** in the
  original `_WriteOutput` — removed.
- **`break` inside a `switch` statement inside a PowerShell class method can escape as an
  unhandled exception** instead of just exiting the switch — a real PowerShell/class
  interaction quirk (it surfaced as Pester misreporting it as a stray loop-label error, per
  [pester/Pester#2669](https://github.com/pester/Pester/issues/2669), but the root cause is in
  `WriteConsole`, not in Pester). Rewritten as an `if`/`elseif` chain instead of
  `switch`/`break`.
- **`Set-LoggerPath`'s relative-path resolution** used `$PSCommandPath` — same root cause as
  bug §4.1 — now resolves relative paths against the current working directory instead.
- The five overlapping `Logger` constructors (§4, general duplication concern) were collapsed
  into one; `New-Logger` now resolves the default file name/folder from the caller's call
  stack (`(Get-PSCallStack)[1]`) before invoking it.

### PSScriptAnalyzer follow-ups

Running `Invoke-ScriptAnalyzer` against the finished module surfaced three rule categories,
handled as follows:

- `PSAvoidUsingEmptyCatchBlock` on `WriteFile`'s retry loop — fixed for real by adding a
  `Write-Debug` of the swallowed exception, rather than suppressing the rule.
- `PSUseShouldProcessForStateChangingFunctions` on `New-Logger` and all `Set-Logger*`/
  `Set-ActiveLogger` functions — fixed for real: each now declares
  `[CmdletBinding(SupportsShouldProcess)]` and gates its mutation behind
  `$PSCmdlet.ShouldProcess(...)`, so `-WhatIf`/`-Confirm` work as expected.
- `PSAvoidOverwritingBuiltInCmdlets` on `Name`, `WriteFile` (PowerShell class *methods*,
  misidentified by the analyzer as function definitions of the same name — a known
  class-parsing limitation) and `Write-Log` (this module's actual, deliberately-chosen public
  function name) — suppressed in `PSScriptAnalyzerSettings.psd1` with a comment explaining
  why, since none of the three represent a real conflict.

### Test coverage

`Tests/LogaPe.Tests.ps1` (Pester) covers level filtering, a per-call destination override,
default-path resolution (regression test for bug §4.1 — asserts the default folder is not the
module's own install folder), `Get-LoggerFullPath`, the active-logger fallback (including the
no-active-logger error), and a concurrency test that spins up 5 runspaces writing 20 messages
each (100 total) through independent `Logger` instances pointed at the same file, then asserts
all 100 lines survive with none lost or interleaved — a direct regression test for the
mutex-safety guarantee that is this module's whole reason for existing.

One Pester-specific gotcha worth recording: a variable assigned at the top of a `.ps1` test
file, *outside* any `Describe`/`Context`/`It` block, is only visible during Pester's
Discovery phase — it reads as unset inside `BeforeAll`/`It` blocks, which run later in the
Run phase. The manifest path is instead computed inside `BeforeAll` itself
(`$script:ModuleManifest = Join-Path $PSScriptRoot ...`).

## 11. Masking (v0.5.0)

### Motivation

Nothing stopped a caller from writing a plaintext password, API key, or connection string
into a log line via `Write-Log` or `-Fields` — the message and field values were written
verbatim. Masking lets a logger scrub sensitive values before they ever reach a destination,
without requiring every call site to remember to redact its own arguments.

### Design goals

- **Uniform across every output path.** A masked value shouldn't leak through the console just
  because the file happened to be scrubbed, or through `Json` mode because a rule was written
  against `Text` formatting. Masking needed to apply once, upstream of all of it.
- **Two different shapes of "sensitive."** Free text (`"password=hunter2"` inside a message
  string) and structured data (`-Fields @{ Password = $plainText }`) need different matching
  strategies — a regex over free text is the wrong tool for a hashtable value, and a field-name
  check can't see inside an arbitrary message string.
- **Opt-in, like the rest of the module's extras.** Rotation, sinks, and native streams are all
  off until configured; masking follows the same pattern rather than silently rewriting output
  by default. A ready-made preset (`Add-LoggerDefaultMaskRule`) exists for the common case, but
  nothing is masked until a rule or field is registered.

### Injection point

`Logger._WriteOutput()` is the one place every write already converges — console, file, and
every active sink all receive the same string built by `Logger.FormatMessage()`. Masking the
message and `-Fields` values *inside* `FormatMessage`, before the `Text`/`Json` branch, means
every destination and sink is scrubbed identically with no per-destination duplication, and it
covers `-ErrorRecord`/`-Exception` detail too since `Write-Log` folds those into the message
before `Write()` is ever called.

*Changed in 0.7.0 (§12):* masking moved out of `FormatMessage` into
`Logger.GetMaskedRecord()`, which `_WriteOutput` calls once per write. It returns the masked
message and fields separately, because the syslog sink needs them before text formatting.
`FormatMessage` now receives values that are already masked. Masking still runs once per
write, upstream of every destination.

### Two masking mechanisms

- **`MaskRule`** (`Add-LoggerMaskRule`) — a case-insensitive .NET regex applied to the message
  text. A named `(?<Prefix>...)` group is optional: if present, that portion of the match is
  preserved and only the remainder is replaced (e.g. keeping `password=` visible while masking
  the value after it); without it, the whole match is replaced.
- **Masked field names** (`Add-LoggerMaskField`) — a case-insensitive list of `-Fields` keys
  (e.g. `Password`, `Token`) whose value is replaced wholesale, regardless of type, in both
  `Text`'s `key=value` output and `Json`'s object properties. This is more reliable than a text
  regex for structured values, since it doesn't depend on how the value happens to serialize.

Both share a single logger-level replacement token (`Set-LoggerMaskReplacement`, default
`'***'`); an individual `Add-LoggerMaskRule` call can override it per-rule.

### Why not `\K`?

The first implementation used PCRE's `\K` ("keep") to exclude a literal prefix like
`password=` from the match, e.g. `(?i)password\s*[:=]\s*\K\S+`. PowerShell's regex engine is
.NET's `System.Text.RegularExpressions`, which does **not** support `\K` — this only surfaced
once the Pester suite actually exercised `Add-LoggerMaskRule` (`ArgumentException: ... 
Unrecognized escape sequence \K`), not from a static read of the pattern. The fix was the
named `(?<Prefix>...)` group described above, applied via `Regex.Replace(string,
MatchEvaluator)` (a PowerShell scriptblock cast to `[System.Text.RegularExpressions.
MatchEvaluator]`) so the prefix group's text can be re-emitted ahead of the replacement token.

### API shape

Follows the existing `Add-Logger*Sink`/`Get-Logger*`/`Remove-Logger*` conventions (each
function accepts an optional `-Logger`, defaults to the active logger, and mutating functions
support `-WhatIf`/`-Confirm`):

| Function | Purpose |
|---|---|
| `Add-LoggerMaskRule` / `Get-LoggerMaskRule` / `Remove-LoggerMaskRule` | Regex-based message-text masking |
| `Add-LoggerMaskField` / `Get-LoggerMaskField` / `Remove-LoggerMaskField` | `-Fields` key-based masking |
| `Get-LoggerMaskReplacement` / `Set-LoggerMaskReplacement` | The default replacement token |
| `Add-LoggerDefaultMaskRule` | Preset: password/pwd/secret/token/apikey/connectionstring, as both text patterns and masked fields |

`Add-LoggerDefaultMaskRule` (not `-Rules`) is deliberately singular, per `PSScriptAnalyzer`'s
`PSUseSingularNouns` — it's a single logical action ("add the default rule set"), matching
this module's existing verb-noun conventions even though it registers multiple rules under
the hood.

### PSScriptAnalyzer follow-ups

- `PSUseSingularNouns` flagged the initial `Add-LoggerDefaultMaskRules` name — renamed to
  `Add-LoggerDefaultMaskRule` (see above) rather than suppressed.
- `PSAvoidAssignmentToAutomaticVariable` flagged a local `$matches` variable in
  `Logger.RemoveMaskField()` (PowerShell's regex-match automatic variable) — renamed to
  `$matchingNames`.

### Test coverage

`Tests/LogaPe.Tests.ps1`'s `Masking` context covers: a message-text rule preserving its prefix,
field masking in both `Text` and `Json` output, a custom replacement token, the
`Add-LoggerDefaultMaskRule` preset, that `Remove-LoggerMaskRule`/`Remove-LoggerMaskField`
actually stop masking, and the three follow-up enhancements below.

### Follow-up enhancements

Three gaps identified in review, addressed in the same feature:

- **Wildcard field-name matching.** `Add-LoggerMaskField -FieldName` originally required an
  exact key match, so `AccessToken`/`RefreshToken`/`ApiToken` each needed their own call.
  `MaskFieldValue` now matches with `-ilike` instead of `-ieq`; since a plain name with no
  wildcard characters behaves identically to an exact match under `-ilike`, this is a strict
  superset of the old behavior with no separate code path needed for the non-wildcard case.
  `Add-LoggerDefaultMaskRule`'s field list was updated to `'*password*'`, `'*token*'`, etc. to
  take advantage of this rather than only matching the literal keyword.
- **`New-Logger -EnableDefaultMasking`.** Applies the same preset as
  `Add-LoggerDefaultMaskRule` at construction time. The preset logic was factored out of the
  `Add-LoggerDefaultMaskRule` function into a `Logger.AddDefaultMaskRules()` method so both the
  function and `New-Logger` call the same implementation rather than duplicating it.
- **`Write-Log -SkipMasking`.** A per-call bypass for when a caller deliberately needs to see
  an unmasked value (e.g. while debugging), without touching the logger's registered rules.
  Threading this through required widening `Logger.Write()`'s master overload from 5 to 6
  arguments (`$SkipMasking`, defaulted to `$false` by every shorter overload) down through
  `_WriteOutput` to `FormatMessage`, where it short-circuits both the message-text and
  `-Fields` masking calls for that one write.

## 12. Syslog sink (v0.7.0)

`Add-LoggerSyslogSink` sends a logger's messages to a syslog collector. The plan, with the
reasoning behind each choice and the answered questions, is
[Archive_Planning_Syslog-Sink.md](Archive_Planning_Syslog-Sink.md). This section describes what was built.

### Pieces

| Piece | Role |
|---|---|
| `SyslogFormatter` (class) | Builds one message: RFC 5424 (default) or RFC 3164. No I/O. Maps levels to severities (Critical 2, Error 3, Warning 4, Information and None 6, Debug/Verbose/Trace 7), cleans header fields, builds structured data, adds a BOM to non-ASCII RFC 5424 bodies, and truncates at a UTF-8 character boundary with a `...[truncated]` marker. |
| `SyslogTransport` (class) | Owns the socket: UDP (unconnected, so an ICMP port-unreachable never throws), TCP with octet-counting or LF framing, or TLS. Opens lazily, keeps the connection, detects a closed connection with `Socket.Poll` before sending, and backs off 1 s doubling to 60 s after a failure. A `Monitor` lock serializes sends. |
| `LogaPe.SyslogCertificateValidator` (C#, `Add-Type`) | The TLS certificate validation and client certificate selection callbacks. Compiled on the first TLS connect, once per process. |
| `LoggingSink.Transport` / `.Formatter` | Hidden members, so `Get-LoggerSink` shows only the plain `Config` settings. `LoggingSink.Dispose()` closes the transport; `RemoveSink` and `Logger.Close()` (`Remove-Logger`) call it. |
| `Logger.WriteToSink` | A `Syslog` branch: format with the sink's formatter, then send. |

### Message body

Masking moved into `Logger.GetMaskedRecord()` (see §11), so the sink gets the masked message
and fields separately. The syslog header already has the timestamp and severity, so the body is
the message plus fields, in the logger's `Text` layout (`message | key=value, ...`) or `Json`
layout (`{"Message":...,"key":...}`), without LogaPe's own timestamp and level. With
`-StructuredDataId 'name@number'`, the fields go into RFC 5424 structured data instead, escaped
as §6.3.3 requires.

### TLS

TLS 1.2 and 1.3 only (RFC 9662). TLS 1.3 is requested only where the `SslProtocols.Tls13` value
exists, and the OS picks the version and cipher suite (Schannel prefers forward-secret AEAD
suites). Validation is chain plus name by default, with revocation as an option.
`-ServerCertificateThumbprint` pins SHA-256 fingerprints (RFC 5425 §5.2) instead: the handshake
accepts any certificate, and the fingerprint is checked before any message is sent.
`-ClientCertificate` provides mutual TLS. `-SkipCertificateCheck` accepts anything and warns
when the sink is added.

### Decisions made while building

- **No static methods in the new classes.** A static method of a PowerShell class is bound to
  the last runspace that imported the module. Once that runspace is gone, calling the method
  throws `NullReferenceException`. The existing `Get-LoggerContent -Wait` test imports the
  module in a background runspace and triggered exactly that. The formatter and transport use
  instance methods only, and the shared `key=value` text is a module function
  (`ConvertTo-LogFieldText`).
- **C# for the certificate callbacks.** A scriptblock delegate needs a PowerShell runspace on
  the calling thread and can deadlock. A compiled callback runs on any thread.
- **Sink warnings are queued and emitted by `Write-Log`.** `Write-Warning` inside a class method
  ignores the caller's `-WarningAction`, `-WarningVariable` and `$WarningPreference`. The
  transport returns its warning text, the logger queues it (`PendingWarnings`, capped at 100),
  and `Write-Log` writes it from its own context. The Event Log sink's per-write warning moved
  to the same queue, so `-WarningAction SilentlyContinue` now silences it too.
- **One warning per outage.** A failed send warns once and starts the backoff. Writes during the
  backoff are dropped without trying. The first successful send afterwards warns again with
  the number of dropped messages. An outage costs one timeout (`-TimeoutSeconds`, default 2),
  not one per message.
- **A collector that drops the client right after the TLS handshake is a failure.** rsyslog
  checks a required client certificate only after the handshake, then closes the connection,
  so the next write would vanish without an error. After each handshake the transport waits up
  to 100 ms for that close. If it comes, the send fails with a warning that names the likely
  cause (no client certificate, or a refused one). The alternative, asking whether the server
  requested a certificate, doesn't work: rsyslog requests one from every TLS client, even on
  a port that doesn't require it.
- **TLS connections end with close_notify** (`SslStream.ShutdownAsync`) before the socket
  closes, so the collector logs a clean close instead of a truncated connection.
- **Sharing a logger across runspaces isn't supported.** PowerShell class instances have
  affinity to the runspace that created them. The concurrency test gives each runspace its own
  logger and sink, the same as the file concurrency test.

### Test coverage

`Tests/LogaPe.Tests.ps1` has three syslog contexts, 42 tests, all on loopback with no external
collector:

- **Message format.** The RFC 5424 header, PRI for each level and several facilities,
  header-field cleaning and nil values, fields in the body in both `Text` and `Json`,
  structured-data escaping, the BOM rule, truncation at a character boundary, the RFC 3164
  layout and its 1024-byte cap, and LF framing.
- **Delivery.** UDP, including the default app name; level filtering; masking in `Text`, `Json`
  and structured-data bodies, and with `-SkipMasking`; TCP with octet-counting and LF framing;
  a collector that's down (one warning, writes stay fast while backed off); recovery; closing
  the socket on `Remove-LoggerSink` and `Remove-Logger`; the `Get-LoggerSink` listing;
  parameter validation; and four runspaces logging concurrently.
- **TLS.** An in-memory self-signed certificate and an `SslStream` server in a background
  runspace. The tests check that default validation rejects the certificate, that
  `-SkipCertificateCheck` accepts it (over TLS 1.2 or 1.3), that a matching pin accepts it and
  a wrong pin rejects it, that a server closing the connection right after the handshake gives a
  warning, and that mutual TLS presents the client certificate.

`Examples/08-SyslogSink.ps1` sends to a local UDP listener, so the example tests cover it on
both editions.

### Live test (2026-10-12)

Against a real collector: rsyslog 8.2510 on Rocky 9 (SELinux enforcing), deployed by LABaPe's
**Syslog collector** catalog service. It listens on UDP and TCP 514, TLS on 6514, and TLS with a
required client certificate on 6515, using a certificate from LABaPe's platform CA. The sender
was this development machine (Windows 10), on Windows PowerShell 5.1 and PowerShell 7.6.6.

| Case | Result (both editions) |
|---|---|
| UDP, RFC 5424, `local3`, Warning | Arrived as `local3.warning`, with app name, PID, MSGID and SD parsed |
| UDP, RFC 3164, `local4`, Error | Arrived as `local4.err` with the TAG and PID parsed |
| TCP, octet-counting, Critical | Arrived as `user.crit`, the line break intact (rsyslog shows it as `#012`) |
| TCP, LF framing | Arrived; the line break became a space |
| TLS, default validation | Refused, because the platform root isn't trusted on the sender: "a certificate chain could not be built to a trusted root authority" |
| TLS, pinned SHA-256 fingerprint, structured data | Arrived; `[logape@32473 case="tlspin" api_token="***"]` parsed as structured data |
| TLS, `-SkipCertificateCheck`, MSGID | Arrived with `msgid=SKIP` |
| Mutual TLS, client certificate from the platform CA | Arrived |
| Mutual TLS without a client certificate | Refused by the collector; LogaPe warns that the collector closed the connection after the handshake and probably requires a client certificate |

Every case masked `password=` and `api_token` before sending. TLS negotiated 1.2: the Windows
10 TLS client doesn't do TLS 1.3, which needs Windows 11 or Server 2022 or later, and the sink
then uses 1.3 by itself. Plain TCP messages first arrived seconds late. The cause was the
collector's reverse-DNS lookup of each new sender, not LogaPe, and LABaPe's collector role now
turns it off.
