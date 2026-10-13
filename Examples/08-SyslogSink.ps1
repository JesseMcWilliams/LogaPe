<#
    A syslog sink sends messages to a syslog collector (rsyslog, syslog-ng, a SIEM) over UDP,
    TCP or TLS, with its own minimum level. This example needs no real collector: it starts a
    small UDP listener on this machine, points the sink at it, and prints what arrived.

    Messages are RFC 5424. The syslog header carries the timestamp, severity, host and app name,
    so the body is just the (masked) message and its fields.

    Against a real collector you would usually use TLS, which validates the server certificate
    by default:

        Add-LoggerSyslogSink -Server 'syslog.example.com' -Protocol Tls -Level Information

    See User_Docs/Usage.md, "Syslog sink", for TCP framing, certificate pinning, mutual TLS
    and structured data.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\LogaPe\LogaPe.psd1') -Force

$logFolder = Join-Path $env:TEMP 'LogaPeExamples\08-SyslogSink'
Remove-Item -Path $logFolder -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $logFolder | Out-Null

# A stand-in collector: a UDP socket on an unused loopback port.
$listener = [System.Net.Sockets.UdpClient]::new([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, 0))
$listener.Client.ReceiveTimeout = 2000
$port = $listener.Client.LocalEndPoint.Port

try
{
    $logger = New-Logger -FileName 'app.log' -UseFileNameAsIs -Folder $logFolder -Destination File -Level Verbose -EnableDefaultMasking -SetActive

    $sinkId = Add-LoggerSyslogSink -Server 127.0.0.1 -Port $port -Facility local0 -Level Information -AppName 'example-app' -Logger $logger

    Write-Host "`n--- Registered sinks ---"
    Get-LoggerSink -Logger $logger |
        Select-Object Type, Level,
            @{ Name = 'Collector'; Expression = { '{0}://{1}:{2}' -f $_.Config.Protocol, $_.Config.Server, $_.Config.Port } },
            @{ Name = 'Format'; Expression = { $_.Config.Format } },
            @{ Name = 'Facility'; Expression = { $_.Config.Facility } },
            @{ Name = 'AppName'; Expression = { $_.Config.AppName } } |
        Format-List | Out-String | Write-Host

    Write-Log 'verbose detail' -Level Verbose                                   # file only - below the sink's level
    Write-Log 'user signed in' -Level Information -Fields @{ UserId = 42 }
    Write-Log 'retrying with password=ThisIsMy_FAKE_Password6!' -Level Warning   # masked before it's sent
    Write-Log 'import failed' -Level Error

    Write-Host "`n--- What the collector received ---"
    $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
    for ($i = 0; $i -lt 3; $i++)
    {
        Write-Host ([System.Text.Encoding]::UTF8.GetString($listener.Receive([ref]$remote)))
    }

    Write-Host "`n<PRI> is facility * 8 + severity: local0 (16) * 8 + info (6) = 134, warning (4) = 132, err (3) = 131."

    Remove-LoggerSink -Id $sinkId -Logger $logger -Confirm:$false
    Remove-Logger -Logger $logger -Confirm:$false
}
finally
{
    $listener.Dispose()
}

Write-Host "`n[OK] Example completed successfully."
