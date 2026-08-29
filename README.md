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

## Reference

| Function | Purpose |
|---|---|
| `New-Logger` | Create a logger |
| `Write-Log` | Write a message |
| `Get-ActiveLogger` / `Set-ActiveLogger` | Read/set the module's active logger |
| `Get-LoggerLevel` / `Set-LoggerLevel` | Read/set the minimum level |
| `Get-LoggerDestination` / `Set-LoggerDestination` | Read/set Console/File/Both |
| `Get-LoggerPath` / `Set-LoggerPath` | Read/set the log folder |
| `Get-LoggerFile` / `Set-LoggerFile` | Read/set the log file name |
| `Get-LoggerFullPath` | Read the full log file path |
| `Get-LoggerTimeout` / `Set-LoggerTimeout` | Read/set the write-retry timeout (seconds) |

Run `Get-Help <function> -Full` for parameters and examples.

## Design

See [DESIGN.md](DESIGN.md) for the module's architecture, the bugs found and fixed during its
rewrite, and the reasoning behind its API shape.

## License

MIT — see [LICENSE](LICENSE).
