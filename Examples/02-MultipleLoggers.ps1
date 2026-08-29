<#
    You don't have to rely on a single "active" logger. Create as many Logger instances as you
    need and pass -Logger explicitly - useful for separating concerns (e.g. an audit trail vs.
    a debug log) or giving the console and file independently tuned levels.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LogaPe\LogaPe.psd1') -Force

$logFolder = Join-Path $env:TEMP 'LogaPeExamples\02-MultipleLoggers'
Remove-Item -Path $logFolder -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $logFolder | Out-Null

# Two independent loggers, each writing to its own file, neither one "active".
$audit = New-Logger -FileName 'audit.log' -UseFileNameAsIs -Folder $logFolder -Destination File
$debug = New-Logger -FileName 'debug.log' -UseFileNameAsIs -Folder $logFolder -Destination File -Level Verbose

Write-Log 'admin logged in' -Logger $audit -Bare
Write-Log 'admin changed a setting' -Logger $audit -Bare
Write-Log 'cache lookup for key 42 took 3ms' -Logger $debug -Level Debug

Write-Host '--- audit.log ---'
Get-LoggerContent -Logger $audit
Write-Host "`n--- debug.log ---"
Get-LoggerContent -Logger $debug

# A single logger can also filter console and file independently - e.g. a quiet terminal
# paired with a verbose file, which is handy for a long-running script you're watching live.
Write-Host "`n--- Independent console/file levels ---"
$mixed = New-Logger -FileName 'mixed.log' -UseFileNameAsIs -Folder $logFolder -Destination Both -Level Verbose
Set-LoggerLevel -Level Warning -Destination Console -Logger $mixed
Set-LoggerLevel -Level Verbose -Destination File -Logger $mixed

Write-Log 'this only reaches the file, not the console' -Logger $mixed -Level Debug
Write-Log 'this reaches both' -Logger $mixed -Level Warning

Write-Host "Console/file levels: $(Get-LoggerLevel -Logger $mixed | Out-String)"
Write-Host '--- mixed.log ---'
Get-LoggerContent -Logger $mixed

Write-Host "`n[OK] Example completed successfully."
