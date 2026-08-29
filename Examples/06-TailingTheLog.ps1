<#
    Reading and tailing a log file. Get-LoggerContent wraps Get-Content, so it supports the
    same -Tail/-Wait parameters without you having to look up the log's path yourself.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LogaPe\LogaPe.psd1') -Force

$logFolder = Join-Path $env:TEMP 'LogaPeExamples\06-TailingTheLog'
Remove-Item -Path $logFolder -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $logFolder | Out-Null

New-Logger -FileName 'activity.log' -UseFileNameAsIs -Folder $logFolder -Destination File -SetActive | Out-Null

1..10 | ForEach-Object { Write-Log "Processed item $_" -Bare }

Write-Host '--- Full content ---'
Get-LoggerContent

Write-Host "`n--- Last 3 lines (-Tail 3) ---"
Get-LoggerContent -Tail 3

# -Wait keeps the file open and streams new lines as they're written, like `tail -f`. It
# blocks until you press Ctrl+C (or the pipeline is stopped), so it isn't run here - but this
# is exactly what you'd type interactively to watch a script's log live while it runs:
#
#     Get-LoggerContent -Wait
#
# or, targeting a specific logger instance from another session/script:
#
#     Get-LoggerContent -Logger $logger -Wait
Write-Host "`n(Skipping a live demo of -Wait since it blocks forever - see the comment above.)"

Write-Host "`n[OK] Example completed successfully."
