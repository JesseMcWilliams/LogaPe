# LogaPe

Thread- and process-safe logging for PowerShell scripts: write to the console, a log file,
and additional sinks (e.g. Windows Event Log), with configurable levels, rotation, structured
(JSON) output, and masking of sensitive values. Concurrent writers to the same file are
serialized with a named mutex so lines don't interleave or get lost.

Targets Windows PowerShell 5.1.

## Features

- Console, file, and pluggable sinks (Windows Event Log built in), each with its own minimum
  level
- Independent console/file logging levels
- Size- and date-based log rotation, with retention/archive-count pruning
- Text or structured JSON output, with a customizable message template
- Exception-aware logging (`-ErrorRecord`/`-Exception` append type, message, and stack trace)
- Masking: scrub passwords, tokens, and other sensitive values out of logged messages and
  structured `-Fields` before they're written
- Reading and tailing the log file, including parsing JSON lines back into objects
- A module-scoped "active logger" so most calls don't need an explicit `-Logger` argument

## Install

Clone or download this repo, then copy the `LogaPe` folder into one of your module paths, e.g.:

```
C:\Users\<you>\Documents\WindowsPowerShell\Modules\LogaPe
```

so that `LogaPe\LogaPe.psd1` exists at that location. Then:

```powershell
Import-Module LogaPe
```

## Quick start

```powershell
Import-Module LogaPe

# Creates a logger and makes it the active one for this session.
New-Logger -Level Verbose -Destination Both -SetActive | Out-Null

Write-Log 'Starting import' -Level Information
Write-Log 'Cache miss, falling back to source' -Level Warning
Write-Log 'Unhandled exception in worker thread' -Level Error
```

## Documentation

- **[USAGE.md](USAGE.md)** — the full usage guide: every feature (multiple loggers, levels,
  rotation, JSON output, exceptions, native streams, tailing, sinks, masking) with examples,
  plus the complete function reference.
- **[Examples/](Examples/)** — runnable scripts covering the same ground as USAGE.md.
- **[DESIGN.md](DESIGN.md)** — the module's architecture, the bugs found and fixed during its
  rewrite, and the reasoning behind its API shape (including masking's design, §11).
- **[LESSONS-LEARNED.md](LESSONS-LEARNED.md)** — recurring bugs and failure points hit along
  the way; check it before debugging something that feels like it should already work.
- **[CHANGELOG.md](CHANGELOG.md)** — release history.

## License

MIT — see [LICENSE](LICENSE).
