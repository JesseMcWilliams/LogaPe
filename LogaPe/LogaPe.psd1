@{
    RootModule        = 'LogaPe.psm1'
    ModuleVersion     = '0.6.0'
    GUID              = '810cc8af-9e19-429e-9388-55eb6b387b1e'
    Author            = 'Jesse McWilliams'
    Copyright         = '(c) Jesse McWilliams. Licensed under the MIT License.'
    Description       = 'Thread- and process-safe logging to the console, a file, and additional sinks (e.g. Windows Event Log), with configurable levels, rotation, output format, and tailing.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport = @(
        'New-Logger'
        'Remove-Logger'
        'Add-LoggerEventLogSink'
        'Get-LoggerSink'
        'Remove-LoggerSink'
        'Write-Log'
        'Get-ActiveLogger'
        'Set-ActiveLogger'
        'Get-LoggerLevel'
        'Set-LoggerLevel'
        'Get-LoggerDestination'
        'Set-LoggerDestination'
        'Get-LoggerPath'
        'Set-LoggerPath'
        'Get-LoggerFile'
        'Set-LoggerFile'
        'Get-LoggerFullPath'
        'Get-LoggerContent'
        'Get-LoggerTimeout'
        'Set-LoggerTimeout'
        'Get-LoggerRotation'
        'Set-LoggerRotation'
        'Get-LoggerOutputFormat'
        'Set-LoggerOutputFormat'
        'Get-LoggerMessageFormat'
        'Set-LoggerMessageFormat'
        'Get-LoggerNativeStreamMode'
        'Set-LoggerNativeStreamMode'
        'Add-LoggerMaskRule'
        'Get-LoggerMaskRule'
        'Remove-LoggerMaskRule'
        'Add-LoggerMaskField'
        'Get-LoggerMaskField'
        'Remove-LoggerMaskField'
        'Get-LoggerMaskReplacement'
        'Set-LoggerMaskReplacement'
        'Add-LoggerDefaultMaskRule'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Logging', 'Log', 'Logger', 'Mutex', 'ThreadSafe', 'Console')
            LicenseUri = 'https://github.com/JesseMcWilliams/LogaPe/blob/main/LICENSE'
            ProjectUri = 'https://github.com/JesseMcWilliams/LogaPe'
            ReleaseNotes = 'v0.6.0: PowerShell 7 (Windows) support - the Event Log sink now calls [System.Diagnostics.EventLog] directly, since PowerShell 7 removed New-EventLog/Write-EventLog. New-Logger now works on FIPS-enforcing hosts: the per-file mutex name uses SHA-256 (SHA256CryptoServiceProvider) instead of MD5. Because the mutex name changed, writers on 0.5.0 or older and writers on 0.6.0 do not serialize writes to the same log file; upgrade every writer of a shared log together. v0.5.0: Masking support so sensitive values (passwords, tokens, API keys) can be scrubbed from logged output - Add-LoggerMaskRule/Add-LoggerMaskField (plus Get-/Remove- counterparts and Set-LoggerMaskReplacement) for custom rules, and Add-LoggerDefaultMaskRule for a ready-made preset. Add-LoggerMaskField supports wildcards (e.g. "*token*"); New-Logger -EnableDefaultMasking applies the default preset at creation time; Write-Log -SkipMasking bypasses masking for one call. v0.4.0: Examples/ folder with runnable, smoke-tested sample scripts; fixed a no-op PSScriptAnalyzer suppression for PSAvoidUsingWriteHost. v0.3.0: Get-LoggerContent for reading/tailing log files, sink support (Add-LoggerEventLogSink/Get-LoggerSink/Remove-LoggerSink) for independent outputs like Windows Event Log. v0.2.0: log rotation/retention, independent console/file levels, opt-in native PowerShell stream output, JSON output format, exception-aware Write-Log, Remove-Logger for mutex cleanup. v0.1.0: initial Gallery-standard release with function-based API and active-logger support.'
        }
    }
}
