@{
    RootModule        = 'LogaPe.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '810cc8af-9e19-429e-9388-55eb6b387b1e'
    Author            = 'Jesse McWilliams'
    Copyright         = '(c) Jesse McWilliams. Licensed under the MIT License.'
    Description       = 'Thread- and process-safe logging to the console and/or a file, with configurable levels and destinations.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'New-Logger'
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
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Logging', 'Log', 'Logger', 'Mutex', 'ThreadSafe', 'Console')
            LicenseUri = 'https://github.com/JesseMcWilliams/PowerShell-Logger/blob/main/LICENSE'
            ProjectUri = 'https://github.com/JesseMcWilliams/PowerShell-Logger'
            ReleaseNotes = 'Initial Gallery-standard release: function-based API (New-Logger, Write-Log, Get-/Set-Logger*), active-logger support, MIT license.'
        }
    }
}
