@{
    RootModule        = 'LogaPe.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '810cc8af-9e19-429e-9388-55eb6b387b1e'
    Author            = 'Jesse McWilliams'
    Copyright         = '(c) Jesse McWilliams. Licensed under the MIT License.'
    Description       = 'Thread- and process-safe logging to the console and/or a file, with configurable levels, destinations, rotation, and output format.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'New-Logger'
        'Remove-Logger'
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
            LicenseUri = 'https://github.com/JesseMcWilliams/PowerShell-Logger/blob/main/LICENSE'
            ProjectUri = 'https://github.com/JesseMcWilliams/PowerShell-Logger'
            ReleaseNotes = 'v0.2.0: log rotation/retention, independent console/file levels, opt-in native PowerShell stream output, JSON output format, exception-aware Write-Log, Remove-Logger for mutex cleanup. v0.1.0: initial Gallery-standard release with function-based API and active-logger support.'
        }
    }
}
