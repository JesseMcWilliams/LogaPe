<#
    Getting started with LogaPe: create a logger, write at a few levels, and see where the
    output went. Run this script directly - it doesn't require the module to be installed.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LogaPe\LogaPe.psd1') -Force

$logFolder = Join-Path $env:TEMP 'LogaPeExamples\01-GettingStarted'
Remove-Item -Path $logFolder -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $logFolder | Out-Null

# -SetActive makes this the logger that Write-Log and the Get-/Set-Logger* functions use by
# default, so you don't have to pass -Logger on every call.
New-Logger -Level Verbose -Destination Both -Folder $logFolder -SetActive | Out-Null

Write-Log 'Starting the example script' -Level Information
Write-Log 'This is a verbose diagnostic detail' -Level Verbose
Write-Log 'Cache miss, falling back to source' -Level Warning
Write-Log 'Something went wrong, but it was handled' -Level Error
Write-Log 'A message with no timestamp/level prefix' -Bare

Write-Host "`nLog file: $(Get-LoggerFullPath)"
Write-Host '--- File contents ---'
Get-LoggerContent

# Bonus: -UseNativeStreams routes console output through Write-Warning/-Error/-Verbose/-Debug/
# -Information instead of colored Write-Host, so -WarningAction/$WarningPreference/transcripts
# see it. Useful when a script's own automation cares about PowerShell's real streams.
Write-Host "`n--- Native streams (opt-in) ---"
$nativeLogger = New-Logger -Destination Console -Folder $logFolder -UseNativeStreams
Write-Log 'Routed through Write-Warning, not Write-Host' -Logger $nativeLogger -Level Warning -WarningAction Continue

Write-Host "`n[OK] Example completed successfully."
