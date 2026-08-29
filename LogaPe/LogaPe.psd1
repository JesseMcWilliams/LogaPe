@{
    RootModule        = 'LogaPe.psm1'
    ModuleVersion     = '0.3.0'
    GUID              = '810cc8af-9e19-429e-9388-55eb6b387b1e'
    Author            = 'Jesse McWilliams'
    Copyright         = '(c) Jesse McWilliams. Licensed under the MIT License.'
    Description       = 'Thread- and process-safe logging to the console, a file, and additional sinks (e.g. Windows Event Log), with configurable levels, rotation, output format, and tailing.'
    PowerShellVersion = '5.1'

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
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Logging', 'Log', 'Logger', 'Mutex', 'ThreadSafe', 'Console')
            LicenseUri = 'https://github.com/JesseMcWilliams/LogaPe/blob/main/LICENSE'
            ProjectUri = 'https://github.com/JesseMcWilliams/LogaPe'
            ReleaseNotes = 'v0.3.0: Get-LoggerContent for reading/tailing log files, sink support (Add-LoggerEventLogSink/Get-LoggerSink/Remove-LoggerSink) for independent outputs like Windows Event Log. v0.2.0: log rotation/retention, independent console/file levels, opt-in native PowerShell stream output, JSON output format, exception-aware Write-Log, Remove-Logger for mutex cleanup. v0.1.0: initial Gallery-standard release with function-based API and active-logger support.'
        }
    }
}
