<#
    Structured (JSON) output: one JSON object per line, with custom fields for anything a log
    aggregator or a later query might care about. Get-LoggerContent -AsObject parses it back.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LogaPe\LogaPe.psd1') -Force

$logFolder = Join-Path $env:TEMP 'LogaPeExamples\04-StructuredJsonLogging'
Remove-Item -Path $logFolder -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $logFolder | Out-Null

$logger = New-Logger -FileName 'events.log' -UseFileNameAsIs -Folder $logFolder -Destination File -OutputFormat Json -SetActive

Write-Log 'user signed in' -Level Information -Fields @{ UserId = 42; Source = 'CLI' }
Write-Log 'rate limit exceeded' -Level Warning -Fields @{ UserId = 42; Endpoint = '/api/widgets' }
Write-Log 'payment failed' -Level Error -Fields @{ UserId = 7; OrderId = 'ORD-1001' }

Write-Host '--- Raw file contents ---'
Get-LoggerContent -Logger $logger

Write-Host "`n--- Parsed back as objects ---"
$events = Get-LoggerContent -Logger $logger -AsObject
$events | Format-Table Timestamp, Level, Message, UserId -AutoSize

Write-Host "--- Only warnings and errors ---"
$events | Where-Object { $_.Level -in 'Warning', 'Error' } | Format-Table Level, Message -AutoSize

Write-Host "`n[OK] Example completed successfully."
