# LogaPe

Thread- and process-safe logging for PowerShell scripts: write to the console and/or a log
file, with configurable levels and destinations. Concurrent writers to the same file are
serialized with a named mutex so lines don't interleave or get lost.

Targets Windows PowerShell 5.1.

## Install

Clone or download this repo, then copy the `LogaPe` folder into one of your module paths, e.g.:

```
C:\Users\<you>\Documents\WindowsPowerShell\Modules\LogaPe
```

so that `LogaPe\LogaPe.psd1` exists at that location. Then:

```powershell
Import-Module LogaPe
```

## Quick Start

```powershell
Import-Module LogaPe

# Creates a logger and makes it the active one for this session.
New-Logger -Level Verbose -Destination Both -SetActive | Out-Null

Write-Log 'Starting import' -Level Information
Write-Log 'Cache miss, falling back to source' -Level Warning
Write-Log 'Unhandled exception in worker thread' -Level Error
```

By default, `New-Logger` writes console-only and names the log file after the calling script
(`<yyyy-MM-dd>_<script name>.log`) in the script's own folder. Use `-FileName`, `-Folder`, and
`-Destination` to override.

### Multiple loggers

You don't have to rely on the active logger — pass `-Logger` explicitly to target a specific
instance, e.g. to log to two files at once:

```powershell
$audit = New-Logger -FileName 'audit.log' -UseFileNameAsIs -Destination File
$debug = New-Logger -FileName 'debug.log' -UseFileNameAsIs -Destination File

Write-Log 'User admin logged in' -Logger $audit -Bare
Write-Log 'Cache hit for key 42' -Logger $debug -Level Debug
```

## Levels

From lowest to highest severity: `Verbose`/`Trace` (same rank), `Debug`, `Information`,
`Warning`, `Error`, `Critical`, `None` (matches nothing — effectively disables logging).
A logger only writes messages at or above its configured level.

Console and file can be filtered independently:

```powershell
$logger = New-Logger -Destination Both -SetActive
Set-LoggerLevel -Level Warning -Destination Console   # quiet terminal
Set-LoggerLevel -Level Verbose -Destination File       # detailed file
```

## Log rotation and retention

```powershell
New-Logger -Destination File -MaxSizeMB 10 -RotateDaily -RetentionDays 30 -MaxArchivedFiles 20 -SetActive
```

The file rolls over once it exceeds `-MaxSizeMB` and/or on the first write of a new calendar
day (`-RotateDaily`), whichever comes first. Rolled-over files are named
`<name>.<yyyyMMdd-HHmmss>.<extension>` next to the active log; `-RetentionDays` and/or
`-MaxArchivedFiles` prune them (never the active file). Adjust settings later with
`Set-LoggerRotation` (any parameter you omit keeps its current value) or read them back with
`Get-LoggerRotation`.

## Structured (JSON) output

```powershell
New-Logger -Destination File -OutputFormat Json -SetActive
Write-Log 'user logged in' -Fields @{ UserId = 42; Source = 'CLI' }
# {"Timestamp":"2026-08-28 19:00:00","Level":"Information","Message":"user logged in","UserId":42,"Source":"CLI"}
```

`-Fields` works in `Text` mode too, appended as `key=value` pairs. Switch formats later with
`Set-LoggerOutputFormat`; customize the `Text` template and timestamp format with
`Set-LoggerMessageFormat` (tokens: `{Timestamp}`, `{Level}`, `{Message}`).

## Exception-aware logging

```powershell
try
{
    Import-CsvData $path
}
catch
{
    Write-Log 'Import failed' -ErrorRecord $_   # appends exception type, message, and stack trace; defaults -Level to Error
}
```

`-Exception` works the same way for a bare `[System.Exception]`. If `-Level` isn't specified
explicitly, both default it to `Error` rather than `Information`.

## Native PowerShell streams

By default, console output is colored `Write-Host` text. Opt into routing it through
`Write-Verbose`/`-Debug`/`-Warning`/`-Error`/`-Information` instead (chosen by message level),
so `-WarningAction`/`-ErrorAction`/`$WarningPreference`/transcripts see it:

```powershell
New-Logger -Destination Console -UseNativeStreams -SetActive
```

`Write-Information` is silent by default unless `$InformationPreference`/`-InformationAction`
says otherwise — that's native PowerShell behavior for `Information`-level messages, not a
LogaPe quirk. Toggle this later with `Set-LoggerNativeStreamMode`.

## Reading and tailing the log

```powershell
Get-LoggerContent -Tail 20        # last 20 lines
Get-LoggerContent -Wait           # follow, like `tail -f` (Ctrl+C to stop)
Get-LoggerContent -AsObject | Where-Object Level -eq 'Error'   # parse Json-format lines
```

`-AsObject` parses each line as JSON (for loggers using `-OutputFormat Json`); a line that
isn't valid JSON comes back as its raw string with a warning instead of aborting the read.

## Additional sinks (Windows Event Log)

A sink is an independent output alongside Console/File, with its own minimum level - e.g. only
send Critical/Error to the Event Log while the file keeps capturing everything at Verbose:

```powershell
$sinkId = Add-LoggerEventLogSink -Source 'MyApp' -Level Error
Write-Log 'disk nearly full' -Level Warning   # console/file only, below the sink's level
Write-Log 'unrecoverable failure' -Level Error   # console/file, and the Event Log
Remove-LoggerSink -Id $sinkId
```

If `-Source` isn't already a registered event source, `Add-LoggerEventLogSink` tries to
register it via `New-EventLog`, which needs local administrator rights. Without them, it warns
and explains how to pre-register the source manually — the sink is still added, and later
writes fail individually (with their own warning) rather than throwing. `Get-LoggerSink` lists
every sink registered on a logger.

## Cleaning up

Each logger opens a named mutex that otherwise lives for the process's lifetime. If you create
many short-lived loggers in a long-running session, dispose them when done:

```powershell
Remove-Logger -Logger $logger
```

## Reference

| Function | Purpose |
|---|---|
| `New-Logger` | Create a logger |
| `Remove-Logger` | Dispose a logger's mutex handle |
| `Write-Log` | Write a message |
| `Get-ActiveLogger` / `Set-ActiveLogger` | Read/set the module's active logger |
| `Get-LoggerLevel` / `Set-LoggerLevel` | Read/set the minimum level (optionally per-destination) |
| `Get-LoggerDestination` / `Set-LoggerDestination` | Read/set Console/File/Both |
| `Get-LoggerPath` / `Set-LoggerPath` | Read/set the log folder |
| `Get-LoggerFile` / `Set-LoggerFile` | Read/set the log file name |
| `Get-LoggerFullPath` | Read the full log file path |
| `Get-LoggerContent` | Read or tail (`-Wait`) the log file, optionally parsing JSON lines (`-AsObject`) |
| `Get-LoggerTimeout` / `Set-LoggerTimeout` | Read/set the write-retry timeout (seconds) |
| `Get-LoggerRotation` / `Set-LoggerRotation` | Read/set size/date rotation and retention |
| `Get-LoggerOutputFormat` / `Set-LoggerOutputFormat` | Read/set Text/Json |
| `Get-LoggerMessageFormat` / `Set-LoggerMessageFormat` | Read/set the Text template and timestamp format |
| `Get-LoggerNativeStreamMode` / `Set-LoggerNativeStreamMode` | Read/set native-stream console output |
| `Add-LoggerEventLogSink` | Add a Windows Event Log sink with its own minimum level |
| `Get-LoggerSink` / `Remove-LoggerSink` | List / remove a logger's sinks |

Run `Get-Help <function> -Full` for parameters and examples.

## Design

See [DESIGN.md](DESIGN.md) for the module's architecture, the bugs found and fixed during its
rewrite, and the reasoning behind its API shape. See [LESSONS-LEARNED.md](LESSONS-LEARNED.md)
for recurring bugs and failure points hit along the way - check it before debugging something
that feels like it should already work.

## License

MIT — see [LICENSE](LICENSE).
