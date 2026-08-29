# LogaPe Examples

Runnable, self-contained scripts demonstrating LogaPe's features. Each one imports the module
from this repo directly (no install needed) and writes to its own folder under
`$env:TEMP\LogaPeExamples\`, so running them is safe and side-effect-free outside of that temp
location.

Run any of them directly, e.g.:

```powershell
.\01-GettingStarted.ps1
```

| Script | Demonstrates |
|---|---|
| [01-GettingStarted.ps1](01-GettingStarted.ps1) | Creating a logger, writing at different levels, the active logger, native-stream output |
| [02-MultipleLoggers.ps1](02-MultipleLoggers.ps1) | Multiple explicit loggers, independent console/file levels |
| [03-RotationAndRetention.ps1](03-RotationAndRetention.ps1) | Size-based rotation, `-MaxArchivedFiles`, adjusting rotation settings later |
| [04-StructuredJsonLogging.ps1](04-StructuredJsonLogging.ps1) | `-OutputFormat Json`, custom `-Fields`, reading logs back as objects |
| [05-ExceptionHandling.ps1](05-ExceptionHandling.ps1) | `-ErrorRecord` and `-Exception` on `Write-Log` |
| [06-TailingTheLog.ps1](06-TailingTheLog.ps1) | `Get-LoggerContent`, including `-Tail` (and where `-Wait` fits in) |
| [07-EventLogSink.ps1](07-EventLogSink.ps1) | Adding/removing a Windows Event Log sink with its own level |

These are examples first - they're written to be read, not just run. They're also smoke-tested
by [`Tests/Examples.Tests.ps1`](../Tests/Examples.Tests.ps1), which just runs each one and
checks it completes without error, so they don't silently rot as the module's API evolves.
That test suite is where actual behavior assertions live - these scripts intentionally don't
contain any `Should`/assertion logic of their own.
