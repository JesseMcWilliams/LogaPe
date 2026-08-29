<#
    Sinks are independent outputs alongside Console/File, each with its own minimum level.
    This example adds a Windows Event Log sink that only receives Warning and above, while the
    file keeps capturing everything.

    Registering a brand-new event source needs local administrator rights. If this script
    isn't running elevated, Add-LoggerEventLogSink will emit a warning explaining how to
    pre-register the source manually, and later writes to the sink will warn individually
    instead of throwing - the rest of the script (and your own logging) is unaffected either
    way, which is the point of this example.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LogaPe\LogaPe.psd1') -Force

$logFolder = Join-Path $env:TEMP 'LogaPeExamples\07-EventLogSink'
Remove-Item -Path $logFolder -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $logFolder | Out-Null

$logger = New-Logger -FileName 'app.log' -UseFileNameAsIs -Folder $logFolder -Destination File -Level Verbose -SetActive

$sinkId = Add-LoggerEventLogSink -Source 'LogaPeExample' -Level Warning -Logger $logger -WarningAction Continue

Write-Host "`n--- Registered sinks ---"
Get-LoggerSink -Logger $logger | Format-List

Write-Log 'routine status update' -Level Information   # file only - below the sink's level
Write-Log 'disk usage above 90%' -Level Warning -WarningAction Continue   # file, and the sink

Write-Host "`n--- app.log (both messages land here) ---"
Get-LoggerContent -Logger $logger

Remove-LoggerSink -Id $sinkId -Logger $logger -Confirm:$false
Write-Host "`nSink removed. Remaining sinks: $((Get-LoggerSink -Logger $logger | Measure-Object).Count)"

Write-Host "`n[OK] Example completed successfully."
