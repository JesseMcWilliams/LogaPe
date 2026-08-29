<#
    Exception-aware logging: -ErrorRecord (for $_ in a catch block) and -Exception (for a bare
    .NET exception) both append the exception's details and default the level to 'Error'.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LogaPe\LogaPe.psd1') -Force

$logFolder = Join-Path $env:TEMP 'LogaPeExamples\05-ExceptionHandling'
Remove-Item -Path $logFolder -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $logFolder | Out-Null

New-Logger -FileName 'errors.log' -UseFileNameAsIs -Folder $logFolder -Destination File -SetActive | Out-Null

function Invoke-RiskyImport
{
    throw [System.IO.FileNotFoundException]::new('Could not find the source file.', 'data.csv')
}

try
{
    Invoke-RiskyImport
}
catch
{
    # -Level isn't specified here - it defaults to 'Error' automatically because -ErrorRecord
    # was used.
    Write-Log 'Import failed' -ErrorRecord $_
}

try
{
    [int]::Parse('not-a-number')
}
catch
{
    Write-Log 'Could not parse a required numeric value' -ErrorRecord $_ -Level Critical
}

# -Exception works the same way for a bare exception you constructed yourself, without a catch
# block's $_.
Write-Log 'Manual exception example' -Exception ([System.InvalidOperationException]::new('Config was already locked.'))

Write-Host '--- errors.log ---'
Get-LoggerContent

Write-Host "`n[OK] Example completed successfully."
