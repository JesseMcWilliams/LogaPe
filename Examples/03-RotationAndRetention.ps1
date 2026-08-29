<#
    Log rotation and retention: roll the file over by size and/or calendar day, and clean up
    old rolled-over files automatically. This example uses a tiny -MaxSizeMB so you can see
    several rotations happen in a few lines of output instead of waiting for a real file to
    grow.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LogaPe\LogaPe.psd1') -Force

$logFolder = Join-Path $env:TEMP 'LogaPeExamples\03-RotationAndRetention'
Remove-Item -Path $logFolder -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $logFolder | Out-Null

# In real use you'd pick a realistic size, e.g. -MaxSizeMB 10. 0.0001 MB (~100 bytes) is used
# here purely so this example rotates multiple times without writing megabytes of output.
$logger = New-Logger -FileName 'app.log' -UseFileNameAsIs -Folder $logFolder -Destination File `
    -MaxSizeMB 0.0001 -MaxArchivedFiles 2

1..6 | ForEach-Object {
    Write-Log ("Message number $_ - " + ('x' * 80)) -Logger $logger -Bare
}

Write-Host '--- Files in the log folder ---'
Get-ChildItem $logFolder | Select-Object Name, Length | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "(Only 2 archived files were kept, per -MaxArchivedFiles 2, even though more rotations happened.)"

Write-Host "`n--- Adjusting rotation settings later ---"
Write-Host "Before: $(Get-LoggerRotation -Logger $logger | Out-String)"
Set-LoggerRotation -RetentionDays 30 -Logger $logger   # -MaxSizeMB/-MaxArchivedFiles are left as they were
Write-Host "After:  $(Get-LoggerRotation -Logger $logger | Out-String)"

Write-Host "`n[OK] Example completed successfully."
