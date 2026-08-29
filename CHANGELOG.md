# Changelog

All notable changes to this project are documented in this file.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/), versioning follows [SemVer](https://semver.org/).

## [0.1.0] - 2026-08-28

### Changed
- Renamed the module from `Logger` to `LogaPe` and restructured it into a standard
  `LogaPe/LogaPe.psd1` + `LogaPe/LogaPe.psm1` module layout, replacing the flat
  `Logger.psm1`/`Logger.ps1` files. The classes, private helpers, and public functions all
  live in the single `LogaPe.psm1` (see Notes) rather than separate `Public`/`Private` files.
- Added a module manifest with explicit `FunctionsToExport`, versioning, and Gallery metadata.
- Replaced the class-only API (`using module`, `[Logger]::new(...)`) with an approved-verb
  function API (`New-Logger`, `Write-Log`, `Get-/Set-Logger*`, `Get-/Set-ActiveLogger`) as the
  primary, documented surface; the classes remain available underneath for advanced use via
  `using module`.
- Added support for a module-scoped "active logger" so `Write-Log` and the `Get-/Set-Logger*`
  functions can be called without passing `-Logger` explicitly.
- Switched the license from GPLv3 to MIT.
- Collapsed the `Logger` class's five overlapping constructors into one, with default
  file-name/folder resolution moved into `New-Logger` (see Fixed).
- Simplified `LoggingObject.WriteFile()`'s mutex-wait/retry loop.
- `New-Logger` and every `Set-Logger*`/`Set-ActiveLogger` function now support
  `-WhatIf`/`-Confirm` (`SupportsShouldProcess`), per `PSScriptAnalyzer`.

### Fixed
- Default log path no longer resolves to the module's own install folder. The original code
  read `$PSCommandPath` from inside a class method living in `Logger.psm1`, so it pointed at
  the module file itself rather than the calling script. `New-Logger` now resolves the
  caller's script path from the call stack instead.
- Fixed a type-cast bug in the `Write()` level-comparison overloads that called `.Level()` on
  a `string` (via `.Name()`) instead of the `LoggingLevel` object, which would have thrown at
  runtime for the destination/bare overloads.
- Removed reliance on implicit string-to-`LoggingLevel` constructor coercion between the
  `Write()` overloads and `_WriteOutput`; the level object is now passed consistently.
- `Logger.GetLoggingFile()` and `LoggingObject.GetLoggingFile()` returned different things
  (file name vs. full path) under the same method name. `Logger.GetLoggingFile()` now
  consistently returns the file name; `Get-LoggerFullPath` was added for the full path.
- Mutex names are now derived from a hash of the full, normalized log file path instead of
  just its leaf name, so two unrelated scripts using the same log file *name* in different
  folders no longer unintentionally synchronize on the same named mutex.
- `Test-IsFileLocked`'s probe now opens the file with `FileShare.ReadWrite` instead of the
  default (`None`), so it no longer reports a false lock against a process that merely has the
  file open for reading (e.g. a `Get-Content -Wait` tail).
- `Set-LoggerPath`'s relative-path resolution no longer depends on `$PSCommandPath` (same root
  cause as the default-path bug above); it now resolves against the current working directory.
- The log line timestamp format was `yyyy-dd-MM hh:mm:ss` (day/month swapped from the file
  name's `yyyy-MM-dd`, and using a 12-hour clock with no AM/PM marker). Now `yyyy-MM-dd
  HH:mm:ss` throughout.
- Removed a leftover `Write-Information ("Starting Output")` debug statement that fired on
  every write.
- Removed `Write-Test`, an unrelated scratch function that was being exported from the module.
- Removed `Logger.ps1`, a non-functional one-line `using module Logger` stub.
- Rewrote `WriteConsole`'s level-to-color dispatch as an `if`/`elseif` chain instead of a
  `switch` with `break`. A `break` inside a `switch` statement inside a PowerShell class
  method can escape as an unhandled exception rather than just exiting the switch - a real
  PowerShell/class interaction quirk found while adding test coverage (see DESIGN.md §10).
- Fixed `PSAvoidUsingEmptyCatchBlock` on `WriteFile`'s retry loop by logging the swallowed
  exception via `Write-Debug` instead of silently discarding it.

### Notes
- Classes and functions that use them as parameter types must live in the same file - a
  dot-sourced `Public`/`Private` folder split (as originally planned) fails with
  `Unable to find type [Logger]`, since PowerShell resolves a class type literal by parsing
  the *same file*, not the whole loaded module. See DESIGN.md §10 for details.
