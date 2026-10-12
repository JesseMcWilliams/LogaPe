Describe 'LogaPe' {

    BeforeAll {
        # Computed here (Run phase) rather than as a top-level script variable, since
        # variables set outside any block run only during Pester's Discovery phase and are
        # not visible to BeforeAll/It scriptblocks during the later Run phase.
        $script:ModuleManifest = Join-Path $PSScriptRoot '..\LogaPe\LogaPe.psd1'
        Import-Module $script:ModuleManifest -Force
        $script:LogFolder = Join-Path $TestDrive 'logs'
        New-Item -ItemType Directory -Path $script:LogFolder -Force | Out-Null
    }

    AfterAll {
        Remove-Module LogaPe -ErrorAction SilentlyContinue
    }

    BeforeEach {
        InModuleScope LogaPe { $script:ActiveLogger = $null }
    }

    Context 'Level filtering' {
        It 'does not write messages below the configured level' {
            $logger = New-Logger -Level Warning -Folder $script:LogFolder -FileName 'level-below.log' -UseFileNameAsIs -Destination File
            Write-Log 'should be filtered out' -Logger $logger -Level Information

            (Get-LoggerFullPath -Logger $logger) | Should -Not -Exist
        }

        It 'writes messages at or above the configured level' {
            $logger = New-Logger -Level Warning -Folder $script:LogFolder -FileName 'level-above.log' -UseFileNameAsIs -Destination File
            Write-Log 'should be written' -Logger $logger -Level Error

            Get-Content (Get-LoggerFullPath -Logger $logger) -Raw | Should -Match 'should be written'
        }
    }

    Context 'Destination routing' {
        It 'honors a per-call -Destination override without changing the logger default' {
            $logger = New-Logger -Level Verbose -Folder $script:LogFolder -FileName 'destination-override.log' -UseFileNameAsIs -Destination File
            Write-Log 'console only' -Logger $logger -Level Information -Destination Console

            (Get-LoggerFullPath -Logger $logger) | Should -Not -Exist
            Get-LoggerDestination -Logger $logger | Should -Be 'File'
        }
    }

    Context 'Default path resolution' {
        It 'does not default the log folder to the module''s own install folder' {
            $logger = New-Logger -Level Verbose
            $moduleFolder = (Get-Module LogaPe).ModuleBase

            (Get-LoggerPath -Logger $logger) | Should -Not -Be $moduleFolder
        }
    }

    Context 'Get-LoggerFullPath' {
        It 'combines the configured folder and file name' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'combined.log' -UseFileNameAsIs
            Get-LoggerFullPath -Logger $logger | Should -Be (Join-Path $script:LogFolder 'combined.log')
        }
    }

    Context 'Mutex naming' {
        It 'names the mutex with a SHA256 hash of the lower-cased full path' {
            InModuleScope LogaPe {
                $path = 'C:\Temp\LogaPe-Mutex\App.log'
                $sha256 = New-Object System.Security.Cryptography.SHA256CryptoServiceProvider
                $expectedHash = -join ($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($path.ToLowerInvariant())) | ForEach-Object { $_.ToString('x2') })
                $sha256.Dispose()

                ConvertTo-LogMutexName -Path $path | Should -Be "LogaPe_$expectedHash"
            }
        }

        It 'resolves the same name regardless of path casing' {
            InModuleScope LogaPe {
                ConvertTo-LogMutexName -Path 'C:\Temp\LogaPe-Mutex\App.log' | Should -Be (ConvertTo-LogMutexName -Path 'c:\temp\logape-mutex\APP.LOG')
            }
        }

        It 'resolves different names for the same file name in different folders' {
            InModuleScope LogaPe {
                ConvertTo-LogMutexName -Path 'C:\Temp\A\app.log' | Should -Not -Be (ConvertTo-LogMutexName -Path 'C:\Temp\B\app.log')
            }
        }
    }

    Context 'Active logger fallback' {
        It 'throws a clear error when no active logger has been set and none is passed' {
            { Write-Log 'no logger' } | Should -Throw '*No active logger*'
        }

        It 'uses the active logger when -Logger is omitted' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'active.log' -UseFileNameAsIs -Destination File -SetActive
            Write-Log 'via active logger'

            Get-Content (Get-LoggerFullPath -Logger $logger) -Raw | Should -Match 'via active logger'
        }
    }

    Context 'Per-destination levels' {
        It 'a message below the console level but at/above the file level still reaches the file' {
            $logger = New-Logger -Level Verbose -Folder $script:LogFolder -FileName 'per-dest.log' -UseFileNameAsIs -Destination Both
            Set-LoggerLevel -Level Warning -Destination Console -Logger $logger
            Set-LoggerLevel -Level Verbose -Destination File -Logger $logger

            Write-Log 'debug detail' -Logger $logger -Level Debug *> $null

            Get-Content (Get-LoggerFullPath -Logger $logger) -Raw | Should -Match 'debug detail'
        }

        It 'Get-LoggerLevel returns a single value when both destinations match' {
            $logger = New-Logger -Level Information -Folder $script:LogFolder -FileName 'same-level.log' -UseFileNameAsIs
            Get-LoggerLevel -Logger $logger | Should -Be 'Information'
        }

        It 'Get-LoggerLevel returns an object with Console/File properties when they differ' {
            $logger = New-Logger -Level Information -Folder $script:LogFolder -FileName 'diff-level.log' -UseFileNameAsIs
            Set-LoggerLevel -Level Error -Destination Console -Logger $logger

            $result = Get-LoggerLevel -Logger $logger
            $result.Console | Should -Be 'Error'
            $result.File | Should -Be 'Information'
        }
    }

    Context 'JSON output format' {
        It 'writes a parseable JSON line with the message and custom fields' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'json.log' -UseFileNameAsIs -Destination File -OutputFormat Json
            Write-Log 'structured message' -Logger $logger -Level Warning -Fields @{ UserId = 42 }

            $line = Get-Content (Get-LoggerFullPath -Logger $logger) -Raw
            $parsed = $line | ConvertFrom-Json
            $parsed.Message | Should -Be 'structured message'
            $parsed.Level | Should -Be 'Warning'
            $parsed.UserId | Should -Be 42
        }
    }

    Context 'Rotation and retention' {
        It 'rolls the file over once it exceeds -MaxSizeMB and prunes to -MaxArchivedFiles' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'rotate.log' -UseFileNameAsIs -Destination File -MaxSizeMB 0.0001 -MaxArchivedFiles 2
            1..5 | ForEach-Object { Write-Log ('x' * 200) -Logger $logger -Bare }

            $archived = Get-ChildItem $script:LogFolder -Filter 'rotate.*.log'
            $archived.Count | Should -Be 2
            (Get-LoggerFullPath -Logger $logger) | Should -Exist
        }

        It 'Set-LoggerRotation updates settings incrementally, leaving unspecified ones alone' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'rotation-settings.log' -UseFileNameAsIs -MaxSizeMB 5 -RetentionDays 10

            Set-LoggerRotation -MaxArchivedFiles 3 -Logger $logger

            $settings = Get-LoggerRotation -Logger $logger
            $settings.MaxSizeMB | Should -Be 5
            $settings.RetentionDays | Should -Be 10
            $settings.MaxArchivedFiles | Should -Be 3
        }
    }

    Context 'Exception-aware logging' {
        It 'appends ErrorRecord details and defaults the level to Error' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'exception.log' -UseFileNameAsIs -Destination File -Level Verbose

            try { throw 'boom' } catch { Write-Log 'operation failed' -Logger $logger -ErrorRecord $_ }

            $content = Get-Content (Get-LoggerFullPath -Logger $logger) -Raw
            $content | Should -Match 'operation failed'
            $content | Should -Match 'boom'
            $content | Should -Match '\|\s+Error\s+\|'
        }

        It 'requires -Message, -ErrorRecord, or -Exception' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'exception-required.log' -UseFileNameAsIs
            { Write-Log -Logger $logger } | Should -Throw '*Message*'
        }
    }

    Context 'Native stream output' {
        It 'routes Warning-level messages through Write-Warning instead of Write-Host' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'native.log' -UseFileNameAsIs -Destination Console
            Set-LoggerNativeStreamMode -Enabled $true -Logger $logger

            $captured = Write-Log 'native warning' -Logger $logger -Level Warning -WarningAction Continue 3>&1

            [string]$captured | Should -Match 'native warning'
        }
    }

    Context 'Remove-Logger' {
        It 'disposes the mutex handle' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'dispose.log' -UseFileNameAsIs -Destination File
            $mutex = $logger.GetLoggingMutex()

            Remove-Logger -Logger $logger -Confirm:$false

            $disposed = $false
            try { $mutex.WaitOne(100) | Out-Null } catch [System.ObjectDisposedException] { $disposed = $true }
            $disposed | Should -BeTrue
        }

        It 'clears the active logger if the removed logger was active' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'dispose-active.log' -UseFileNameAsIs -Destination File -SetActive
            Remove-Logger -Logger $logger -Confirm:$false

            Get-ActiveLogger | Should -BeNullOrEmpty
        }
    }

    Context 'Event Log sink' {
        # Registering a real event source needs local admin rights, which the test runner may
        # or may not have - so these tests avoid asserting on whether Write-EventLog itself
        # succeeds or fails, and instead verify the parts that are deterministic regardless of
        # elevation: registration/listing/removal of the sink, that level filtering means the
        # sink is never invoked at all below its threshold, and that a write attempt (success
        # or the caught-and-warned failure path) never throws back to the caller.
        It 'adds a sink and lists it via Get-LoggerSink' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'eventlog.log' -UseFileNameAsIs -Destination File
            $sinkId = Add-LoggerEventLogSink -Source 'LogaPeTestSource' -Level Error -Logger $logger -WarningAction SilentlyContinue

            $sink = Get-LoggerSink -Logger $logger
            $sink.Id | Should -Be $sinkId
            $sink.Type | Should -Be 'EventLog'
            $sink.Level | Should -Be 'Error'
            $sink.Config.Source | Should -Be 'LogaPeTestSource'
            $sink.Config.LogName | Should -Be 'Application'
        }

        It 'never dispatches to the sink for messages below its level' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'eventlog-filter.log' -UseFileNameAsIs -Destination File
            Add-LoggerEventLogSink -Source 'LogaPeTestSourceFilter' -Level Error -Logger $logger -WarningAction SilentlyContinue | Out-Null

            Write-Log 'below sink threshold' -Logger $logger -Level Warning -WarningVariable belowWarnings -WarningAction SilentlyContinue

            ($belowWarnings | Where-Object { $_ -match 'Failed to write to Event Log sink' }) | Should -BeNullOrEmpty
        }

        It 'does not throw when writing at/above the sink level, whether the write succeeds or fails' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'eventlog-write.log' -UseFileNameAsIs -Destination File
            Add-LoggerEventLogSink -Source 'LogaPeTestSourceWrite' -Level Error -Logger $logger -WarningAction SilentlyContinue | Out-Null

            { Write-Log 'at sink threshold' -Logger $logger -Level Error -WarningAction SilentlyContinue } | Should -Not -Throw
        }

        It 'removes a sink so it no longer appears in Get-LoggerSink' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'eventlog-remove.log' -UseFileNameAsIs -Destination File
            $sinkId = Add-LoggerEventLogSink -Source 'LogaPeTestSourceRemove' -Level Error -Logger $logger -WarningAction SilentlyContinue

            Remove-LoggerSink -Id $sinkId -Logger $logger -Confirm:$false

            Get-LoggerSink -Logger $logger | Should -BeNullOrEmpty
            { Write-Log 'after removal' -Logger $logger -Level Error -WarningAction SilentlyContinue } | Should -Not -Throw
        }
    }

    Context 'Syslog sink: message format' {
        # The formatter is pure, so these check exact bytes with no network.
        BeforeAll {
            $script:FixedTime = [DateTimeOffset]::new(2026, 10, 2, 3, 4, 5, 678, [TimeSpan]::FromHours(-7))

            function New-TestSyslogConfig
            {
                param([hashtable]$Overrides = @{})
                $config = @{
                    Facility = 'user'; Format = 'Rfc5424'; Framing = 'None'; StructuredDataId = ''
                    HostName = 'host1.example.com'; AppName = 'app'; MessageId = ''; MaxMessageBytes = 2048
                }
                foreach ($key in $Overrides.Keys) { $config[$key] = $Overrides[$key] }
                return $config
            }

            function Invoke-TestSyslogFormat
            {
                param([hashtable]$Config, [string]$Level = 'Information', [string]$Message = 'hello',
                    [System.Collections.Specialized.OrderedDictionary]$Fields, [string]$OutputFormat = 'Text',
                    [DateTimeOffset]$Time = $script:FixedTime)
                InModuleScope LogaPe -Parameters @{ C = $Config; L = $Level; M = $Message; F = $Fields; O = $OutputFormat; T = $Time } {
                    param($C, $L, $M, $F, $O, $T)
                    , [SyslogFormatter]::new().Format($C, [LoggingLevel]::new($L), @{ Message = $M; Fields = $F }, $O, $T)
                }
            }

            function ConvertFrom-Utf8([byte[]]$Bytes)
            {
                return [System.Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
            }
        }

        It 'writes an RFC 5424 header with PRI, RFC 3339 timestamp, host, app, PID and nil MSGID/SD' {
            $text = ConvertFrom-Utf8 (Invoke-TestSyslogFormat -Config (New-TestSyslogConfig))
            $text | Should -Match ('^<14>1 2026-10-02T03:04:05\.678000-07:00 host1\.example\.com app \d+ - - hello$')
        }

        It 'computes PRI as facility * 8 + severity for <Level> on <Facility>' -ForEach @(
            @{ Level = 'Critical'; Facility = 'user'; Pri = 10 }
            @{ Level = 'Error'; Facility = 'local3'; Pri = 155 }
            @{ Level = 'Warning'; Facility = 'daemon'; Pri = 28 }
            @{ Level = 'Information'; Facility = 'local7'; Pri = 190 }
            @{ Level = 'Debug'; Facility = 'kern'; Pri = 7 }
            @{ Level = 'Verbose'; Facility = 'auth'; Pri = 39 }
            @{ Level = 'Trace'; Facility = 'user'; Pri = 15 }
        ) {
            $text = ConvertFrom-Utf8 (Invoke-TestSyslogFormat -Config (New-TestSyslogConfig @{ Facility = $Facility }) -Level $Level)
            $text | Should -Match ('^<{0}>1 ' -f $Pri)
        }

        It 'removes spaces and non-ASCII from header fields, cuts them to length, and writes nil for empty ones' {
            $config = New-TestSyslogConfig @{ HostName = 'my host'; AppName = ('a' * 60) + [char]0xE9; MessageId = '' }
            $text = ConvertFrom-Utf8 (Invoke-TestSyslogFormat -Config $config)
            $fields = $text.Split(' ')
            $fields[2] | Should -Be 'myhost'
            $fields[3] | Should -Be ('a' * 48)
            $fields[5] | Should -Be '-'
        }

        It 'puts fields in the body by default, in the Text layout' {
            $fields = [ordered]@{ UserId = 42; Source = 'CLI' }
            $text = ConvertFrom-Utf8 (Invoke-TestSyslogFormat -Config (New-TestSyslogConfig) -Fields $fields)
            $text | Should -Match ' - - hello \| UserId=42, Source=CLI$'
        }

        It 'puts the message and fields in a compact JSON body in Json output, without timestamp or level' {
            $fields = [ordered]@{ UserId = 42 }
            $text = ConvertFrom-Utf8 (Invoke-TestSyslogFormat -Config (New-TestSyslogConfig) -Fields $fields -OutputFormat Json)
            $body = $text.Substring($text.IndexOf(' - - ') + 5)
            $body | Should -Be '{"Message":"hello","UserId":42}'
        }

        It 'sends fields as escaped RFC 5424 structured data when -StructuredDataId is set' {
            $fields = [ordered]@{ 'na me=' = 'x"y\z]'; plain = 'v' }
            $config = New-TestSyslogConfig @{ StructuredDataId = 'test@32473' }
            $text = ConvertFrom-Utf8 (Invoke-TestSyslogFormat -Config $config -Fields $fields)
            $text.EndsWith(' - [test@32473 name="x\"y\\z\]" plain="v"] hello') | Should -BeTrue -Because $text
        }

        It 'starts a non-ASCII message with a UTF-8 BOM and an ASCII one without' {
            $ascii = Invoke-TestSyslogFormat -Config (New-TestSyslogConfig) -Message 'plain'
            $unicode = Invoke-TestSyslogFormat -Config (New-TestSyslogConfig) -Message ('caf' + [char]0xE9)

            $asciiText = ConvertFrom-Utf8 $ascii
            $asciiText.EndsWith(' plain') | Should -BeTrue
            $bomAt = [System.Text.Encoding]::ASCII.GetString($unicode).IndexOf(' - - ') + 5
            $unicode[$bomAt..($bomAt + 2)] | Should -Be @(0xEF, 0xBB, 0xBF)
        }

        It 'truncates at a UTF-8 character boundary and marks the cut' {
            $config = New-TestSyslogConfig @{ MaxMessageBytes = 1000 }
            $bytes = Invoke-TestSyslogFormat -Config $config -Message ([string][char]0xE9 * 2000)
            $bytes.Length | Should -BeLessOrEqual 1000
            # Strict decoding throws if a multi-byte character was split.
            $text = ConvertFrom-Utf8 $bytes
            $text.EndsWith('...[truncated]') | Should -BeTrue
        }

        It 'writes RFC 3164 with a space-padded day, short host name and TAG[PID]:' {
            $local = [DateTimeOffset]::new([datetime]::new(2026, 10, 2, 3, 4, 5, [DateTimeKind]::Local))
            $config = New-TestSyslogConfig @{ Format = 'Rfc3164'; AppName = 'My App!' }
            $text = ConvertFrom-Utf8 (Invoke-TestSyslogFormat -Config $config -Time $local -Level Error)
            $text | Should -Match '^<11>Oct  2 03:04:05 host1 MyApp\[\d+\]: hello$'
        }

        It 'caps RFC 3164 messages at 1024 bytes whatever -MaxMessageBytes says' {
            $config = New-TestSyslogConfig @{ Format = 'Rfc3164'; MaxMessageBytes = 8192 }
            $bytes = Invoke-TestSyslogFormat -Config $config -Message ('x' * 5000)
            $bytes.Length | Should -Be 1024
        }

        It 'replaces line breaks with spaces for LineFeed framing' {
            $config = New-TestSyslogConfig @{ Framing = 'LineFeed' }
            $text = ConvertFrom-Utf8 (Invoke-TestSyslogFormat -Config $config -Message "one`r`ntwo`nthree")
            $text | Should -Match ' one two three$'
        }
    }

    Context 'Syslog sink: delivery' {
        # Everything runs against loopback listeners; no external collector is needed.
        BeforeAll {
            function New-UdpReceiver
            {
                $udp = [System.Net.Sockets.UdpClient]::new([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, 0))
                $udp.Client.ReceiveTimeout = 3000
                return $udp
            }

            function Receive-UdpText
            {
                param($Receiver, [int]$TimeoutMs = 3000)
                $Receiver.Client.ReceiveTimeout = $TimeoutMs
                $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                try
                {
                    return [System.Text.Encoding]::UTF8.GetString($Receiver.Receive([ref]$remote))
                }
                catch
                {
                    return $null
                }
            }

            function New-TcpTestListener
            {
                $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
                $listener.Start()
                return $listener
            }

            function Get-ClosedTcpPort
            {
                $listener = New-TcpTestListener
                $port = $listener.LocalEndpoint.Port
                $listener.Stop()
                return $port
            }

            # 'LEN SP MSG' (RFC 6587 octet-counting); $null when the connection closes first.
            function Read-OctetFrame
            {
                param([System.IO.Stream]$Stream)
                $length = ''
                while ($true)
                {
                    $b = $Stream.ReadByte()
                    if ($b -lt 0) { return $null }
                    if ($b -eq 0x20) { break }
                    $length += [char]$b
                }
                $buffer = [byte[]]::new([int]$length)
                $offset = 0
                while ($offset -lt $buffer.Length)
                {
                    $read = $Stream.Read($buffer, $offset, $buffer.Length - $offset)
                    if ($read -le 0) { return $null }
                    $offset += $read
                }
                return [System.Text.Encoding]::UTF8.GetString($buffer)
            }

            function Read-LineFrame
            {
                param([System.IO.Stream]$Stream)
                $buffer = [System.IO.MemoryStream]::new()
                while (($b = $Stream.ReadByte()) -ne 0x0A)
                {
                    if ($b -lt 0) { return $null }
                    $buffer.WriteByte([byte]$b)
                }
                return [System.Text.Encoding]::UTF8.GetString($buffer.ToArray())
            }
        }

        It 'sends over UDP with the default app name (file name without the date prefix)' {
            $receiver = New-UdpReceiver
            try
            {
                $logger = New-Logger -Folder $script:LogFolder -FileName 'udpapp' -Destination File
                Add-LoggerSyslogSink -Server 127.0.0.1 -Port $receiver.Client.LocalEndPoint.Port -Logger $logger | Out-Null

                Write-Log 'disk almost full' -Level Warning -Logger $logger

                $text = Receive-UdpText $receiver
                $text | Should -Match '^<12>1 \S+ \S+ udpapp \d+ - - disk almost full$'
                Remove-Logger -Logger $logger -Confirm:$false
            }
            finally
            {
                $receiver.Dispose()
            }
        }

        It 'sends nothing below the sink''s level' {
            $receiver = New-UdpReceiver
            try
            {
                $logger = New-Logger -Folder $script:LogFolder -FileName 'syslog-level.log' -UseFileNameAsIs -Destination File
                Add-LoggerSyslogSink -Server 127.0.0.1 -Port $receiver.Client.LocalEndPoint.Port -Level Error -Logger $logger | Out-Null

                Write-Log 'only a warning' -Level Warning -Logger $logger
                Receive-UdpText $receiver -TimeoutMs 500 | Should -BeNullOrEmpty

                Write-Log 'an error' -Level Error -Logger $logger
                Receive-UdpText $receiver | Should -Match 'an error$'
                Remove-Logger -Logger $logger -Confirm:$false
            }
            finally
            {
                $receiver.Dispose()
            }
        }

        It 'masks secrets in the <Mode> body' -ForEach @(
            @{ Mode = 'Text'; OutputFormat = 'Text'; SdId = $null }
            @{ Mode = 'Json'; OutputFormat = 'Json'; SdId = $null }
            @{ Mode = 'structured-data'; OutputFormat = 'Text'; SdId = 'logape@32473' }
        ) {
            $receiver = New-UdpReceiver
            try
            {
                $logger = New-Logger -Folder $script:LogFolder -FileName "syslog-mask-$Mode.log" -UseFileNameAsIs -Destination File -OutputFormat $OutputFormat -EnableDefaultMasking
                $sinkArgs = @{ Server = '127.0.0.1'; Port = $receiver.Client.LocalEndPoint.Port; Level = 'Information'; Logger = $logger }
                if ($SdId) { $sinkArgs.StructuredDataId = $SdId }
                Add-LoggerSyslogSink @sinkArgs | Out-Null

                Write-Log 'login password=ThisIsMy_FAKE_Password6!' -Logger $logger -Fields @{ api_token = 'tok-123'; user = 'bob' }

                $text = Receive-UdpText $receiver
                $text | Should -Not -Match 'ThisIsMy_FAKE_Password6'
                $text | Should -Not -Match 'tok-123'
                $text | Should -Match 'bob'
                Remove-Logger -Logger $logger -Confirm:$false
            }
            finally
            {
                $receiver.Dispose()
            }
        }

        It 'sends the value unmasked with Write-Log -SkipMasking' {
            $receiver = New-UdpReceiver
            try
            {
                $logger = New-Logger -Folder $script:LogFolder -FileName 'syslog-skipmask.log' -UseFileNameAsIs -Destination File -EnableDefaultMasking
                Add-LoggerSyslogSink -Server 127.0.0.1 -Port $receiver.Client.LocalEndPoint.Port -Level Information -Logger $logger | Out-Null

                Write-Log 'password=ThisIsMy_FAKE_Password6!' -Logger $logger -SkipMasking

                Receive-UdpText $receiver | Should -Match 'ThisIsMy_FAKE_Password6!'
                Remove-Logger -Logger $logger -Confirm:$false
            }
            finally
            {
                $receiver.Dispose()
            }
        }

        It 'sends a multi-line message over TCP as one octet-counted frame' {
            $listener = New-TcpTestListener
            try
            {
                $logger = New-Logger -Folder $script:LogFolder -FileName 'syslog-tcp.log' -UseFileNameAsIs -Destination File
                Add-LoggerSyslogSink -Server 127.0.0.1 -Port $listener.LocalEndpoint.Port -Protocol Tcp -Level Information -Logger $logger | Out-Null

                Write-Log "first line`nsecond line" -Logger $logger
                Write-Log 'next message' -Logger $logger

                $client = $listener.AcceptTcpClient()
                $stream = $client.GetStream()
                $stream.ReadTimeout = 3000
                Read-OctetFrame $stream | Should -Match " - - first line`nsecond line$"
                Read-OctetFrame $stream | Should -Match ' - - next message$'
                Remove-Logger -Logger $logger -Confirm:$false
                $client.Dispose()
            }
            finally
            {
                $listener.Stop()
            }
        }

        It 'sends LF-terminated frames with -Framing LineFeed' {
            $listener = New-TcpTestListener
            try
            {
                $logger = New-Logger -Folder $script:LogFolder -FileName 'syslog-lf.log' -UseFileNameAsIs -Destination File
                Add-LoggerSyslogSink -Server 127.0.0.1 -Port $listener.LocalEndpoint.Port -Protocol Tcp -Framing LineFeed -Level Information -Logger $logger | Out-Null

                Write-Log "first line`nsecond line" -Logger $logger

                $client = $listener.AcceptTcpClient()
                $stream = $client.GetStream()
                $stream.ReadTimeout = 3000
                Read-LineFrame $stream | Should -Match '^<14>1 .* - - first line second line$'
                Remove-Logger -Logger $logger -Confirm:$false
                $client.Dispose()
            }
            finally
            {
                $listener.Stop()
            }
        }

        It 'does not throw when the collector is down, warns once, and drops quickly while backed off' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'syslog-down.log' -UseFileNameAsIs -Destination File
            Add-LoggerSyslogSink -Server 127.0.0.1 -Port (Get-ClosedTcpPort) -Protocol Tcp -TimeoutSeconds 1 -Level Information -Logger $logger | Out-Null

            # Called directly, not in a Should -Not -Throw scriptblock, so -WarningVariable lands
            # in this scope; a throw would fail the test anyway.
            Write-Log 'first' -Logger $logger -WarningVariable +downWarnings -WarningAction SilentlyContinue
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            1..5 | ForEach-Object { Write-Log "more $_" -Logger $logger -WarningVariable +downWarnings -WarningAction SilentlyContinue }
            $timer.Stop()

            $timer.ElapsedMilliseconds | Should -BeLessThan 500
            @($downWarnings).Count | Should -Be 1
            "$($downWarnings[0])" | Should -Match 'dropped until it''s reachable again'
            Remove-Logger -Logger $logger -Confirm:$false
        }

        It 'reconnects after the backoff and warns that the collector is back' {
            $port = Get-ClosedTcpPort
            $logger = New-Logger -Folder $script:LogFolder -FileName 'syslog-recover.log' -UseFileNameAsIs -Destination File
            Add-LoggerSyslogSink -Server 127.0.0.1 -Port $port -Protocol Tcp -TimeoutSeconds 1 -Level Information -Logger $logger | Out-Null
            Write-Log 'lost' -Logger $logger -WarningAction SilentlyContinue

            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
            $listener.Start()
            try
            {
                Start-Sleep -Milliseconds 1200
                Write-Log 'back' -Logger $logger -WarningVariable backWarnings -WarningAction SilentlyContinue

                "$backWarnings" | Should -Match 'reachable again; 1 message\(s\) were dropped'
                $client = $listener.AcceptTcpClient()
                $stream = $client.GetStream()
                $stream.ReadTimeout = 3000
                Read-OctetFrame $stream | Should -Match ' - - back$'
                Remove-Logger -Logger $logger -Confirm:$false
                $client.Dispose()
            }
            finally
            {
                $listener.Stop()
            }
        }

        It 'closes the connection on <Action>' -ForEach @(
            @{ Action = 'Remove-LoggerSink' }
            @{ Action = 'Remove-Logger' }
        ) {
            $listener = New-TcpTestListener
            try
            {
                $logger = New-Logger -Folder $script:LogFolder -FileName "syslog-close-$Action.log" -UseFileNameAsIs -Destination File
                $sinkId = Add-LoggerSyslogSink -Server 127.0.0.1 -Port $listener.LocalEndpoint.Port -Protocol Tcp -Level Information -Logger $logger
                Write-Log 'open it' -Logger $logger

                $client = $listener.AcceptTcpClient()
                $stream = $client.GetStream()
                $stream.ReadTimeout = 3000
                Read-OctetFrame $stream | Should -Match 'open it$'

                if ($Action -eq 'Remove-LoggerSink')
                {
                    Remove-LoggerSink -Id $sinkId -Logger $logger -Confirm:$false
                    Get-LoggerSink -Logger $logger | Should -BeNullOrEmpty
                }
                else
                {
                    Remove-Logger -Logger $logger -Confirm:$false
                }

                # A read returning 0 bytes means the client closed its end.
                $stream.Read([byte[]]::new(16), 0, 16) | Should -Be 0
                $client.Dispose()
            }
            finally
            {
                $listener.Stop()
            }
        }

        It 'lists the sink''s settings, without its socket, in Get-LoggerSink' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'syslog-list.log' -UseFileNameAsIs -Destination File
            $sinkId = Add-LoggerSyslogSink -Server 127.0.0.1 -Protocol Tcp -Facility local4 -Level Error -AppName 'myapp' -Logger $logger

            $sink = Get-LoggerSink -Logger $logger
            $sink.Id | Should -Be $sinkId
            $sink.Type | Should -Be 'Syslog'
            $sink.Level | Should -Be 'Error'
            $sink.Config.Server | Should -Be '127.0.0.1'
            $sink.Config.Port | Should -Be 514
            $sink.Config.Protocol | Should -Be 'Tcp'
            $sink.Config.Framing | Should -Be 'OctetCounting'
            $sink.Config.Facility | Should -Be 'local4'
            $sink.Config.AppName | Should -Be 'myapp'
            $sink.Config.MaxMessageBytes | Should -Be 8192
            $sink.Config.Values | ForEach-Object { $_ | Should -Not -BeOfType [System.Net.Sockets.TcpClient] }
            Remove-Logger -Logger $logger -Confirm:$false
        }

        It 'rejects <Case>' -ForEach @(
            @{ Case = 'LineFeed framing with TLS'; Arguments = @{ Protocol = 'Tls'; Framing = 'LineFeed' } }
            @{ Case = 'a TLS-only switch without TLS'; Arguments = @{ Protocol = 'Tcp'; SkipCertificateCheck = $true } }
            @{ Case = 'a SHA-1 thumbprint for pinning'; Arguments = @{ Protocol = 'Tls'; ServerCertificateThumbprint = ('A' * 40) } }
            @{ Case = 'skipping the check while pinning'; Arguments = @{ Protocol = 'Tls'; SkipCertificateCheck = $true; ServerCertificateThumbprint = ('a' * 64) } }
            @{ Case = 'a structured-data ID without an enterprise number'; Arguments = @{ StructuredDataId = 'logape' } }
            @{ Case = 'structured data with RFC 3164'; Arguments = @{ Format = 'Rfc3164'; StructuredDataId = 'logape@32473' } }
        ) {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'syslog-reject.log' -UseFileNameAsIs -Destination File
            { Add-LoggerSyslogSink -Server 127.0.0.1 -Logger $logger @Arguments } | Should -Throw
            Get-LoggerSink -Logger $logger | Should -BeNullOrEmpty
        }

        It 'keeps every frame intact when several runspaces log to one collector' {
            $runspaceCount = 4
            $messagesPerRunspace = 50
            $listener = New-TcpTestListener
            $pool = [runspacefactory]::CreateRunspacePool(1, $runspaceCount)
            $pool.Open()
            try
            {
                $handles = for ($r = 0; $r -lt $runspaceCount; $r++)
                {
                    $ps = [powershell]::Create()
                    $ps.RunspacePool = $pool
                    [void]$ps.AddScript({
                            param($ModulePath, $Folder, $Port, $RunspaceId, $Count)
                            Import-Module $ModulePath -Force
                            $logger = New-Logger -Folder $Folder -FileName "syslog-concurrent-$RunspaceId.log" -UseFileNameAsIs -Destination File
                            Add-LoggerSyslogSink -Server 127.0.0.1 -Port $Port -Protocol Tcp -Level Information -Logger $logger | Out-Null
                            for ($i = 0; $i -lt $Count; $i++)
                            {
                                Write-Log "runspace $RunspaceId message $i" -Logger $logger
                            }
                            Remove-Logger -Logger $logger -Confirm:$false
                        }).AddArgument($script:ModuleManifest).AddArgument($script:LogFolder).AddArgument($listener.LocalEndpoint.Port).AddArgument($r).AddArgument($messagesPerRunspace)
                    [pscustomobject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
                }

                # Each runspace closes its connection when done, so read each one to the end.
                $frames = for ($r = 0; $r -lt $runspaceCount; $r++)
                {
                    $client = $listener.AcceptTcpClient()
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 10000
                    while ($null -ne ($frame = Read-OctetFrame $stream)) { $frame }
                    $client.Dispose()
                }

                foreach ($h in $handles)
                {
                    $h.PowerShell.EndInvoke($h.Handle)
                    $h.PowerShell.Dispose()
                }
            }
            finally
            {
                $pool.Close()
                $pool.Dispose()
                $listener.Stop()
            }

            @($frames).Count | Should -Be ($runspaceCount * $messagesPerRunspace)
            @($frames | Where-Object { $_ -notmatch '^<14>1 \S+ \S+ \S+ \d+ - - runspace \d message \d+$' }).Count | Should -Be 0
        }
    }

    Context 'Syslog sink: TLS' {
        # A self-signed certificate made in memory (no certificate store is touched) and an
        # SslStream server in a background runspace. The server's own validation callback is a
        # scriptblock, which is fine there: the synchronous handshake runs it on that
        # runspace's own thread.
        BeforeAll {
            function New-TestCertificate
            {
                param([string]$Subject, [string]$Usage)
                $rsa = [System.Security.Cryptography.RSA]::Create(2048)
                $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
                    "CN=$Subject", $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
                $oid = if ($Usage -eq 'Server') { '1.3.6.1.5.5.7.3.1' } else { '1.3.6.1.5.5.7.3.2' }
                $usages = [System.Security.Cryptography.OidCollection]::new()
                [void]$usages.Add([System.Security.Cryptography.Oid]::new($oid))
                $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($usages, $false))
                if ($Usage -eq 'Server')
                {
                    $san = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
                    $san.AddDnsName($Subject)
                    $request.CertificateExtensions.Add($san.Build())
                }
                $now = [DateTimeOffset]::UtcNow
                $ephemeral = $request.CreateSelfSigned($now.AddMinutes(-5), $now.AddDays(1))
                # Schannel can't use an ephemeral key; a PFX round trip gives it a real key container.
                $pfxPassword = [guid]::NewGuid().ToString()
                $pfx = $ephemeral.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $pfxPassword)
                return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, $pfxPassword,
                    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
            }

            function Get-TestFingerprint
            {
                param($Certificate)
                $sha = [System.Security.Cryptography.SHA256CryptoServiceProvider]::new()
                try { return -join ($sha.ComputeHash($Certificate.RawData) | ForEach-Object { $_.ToString('x2') }) }
                finally { $sha.Dispose() }
            }

            # Starts a one-connection TLS server; Stop-TestTlsServer returns what it saw.
            function Start-TestTlsServer
            {
                param($Certificate, [switch]$RequireClientCertificate)
                $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
                $listener.Start()
                $ps = [powershell]::Create()
                [void]$ps.AddScript({
                        param($Listener, $Certificate, $RequireClient)
                        $result = @{ Error = $null; Protocol = $null; ClientFingerprint = $null; Frame = $null }
                        $accept = $Listener.AcceptTcpClientAsync()
                        if (-not $accept.Wait(15000)) { $result.Error = 'no connection'; return $result }
                        $client = $accept.Result
                        $ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false, { $true })
                        $ssl.ReadTimeout = 10000
                        try
                        {
                            $protocols = [System.Security.Authentication.SslProtocols]::Tls12
                            if ([enum]::IsDefined([System.Security.Authentication.SslProtocols], 'Tls13'))
                            {
                                $protocols = $protocols -bor [System.Security.Authentication.SslProtocols]'Tls13'
                            }
                            $ssl.AuthenticateAsServer($Certificate, [bool]$RequireClient, $protocols, $false)
                            $result.Protocol = $ssl.SslProtocol.ToString()
                            if ($ssl.RemoteCertificate)
                            {
                                $sha = [System.Security.Cryptography.SHA256CryptoServiceProvider]::new()
                                $result.ClientFingerprint = -join ($sha.ComputeHash($ssl.RemoteCertificate.GetRawCertData()) | ForEach-Object { $_.ToString('x2') })
                            }
                            $length = ''
                            while (($b = $ssl.ReadByte()) -ne 0x20)
                            {
                                if ($b -lt 0) { throw 'connection closed before a frame' }
                                $length += [char]$b
                            }
                            $buffer = [byte[]]::new([int]$length)
                            $offset = 0
                            while ($offset -lt $buffer.Length) { $offset += $ssl.Read($buffer, $offset, $buffer.Length - $offset) }
                            $result.Frame = [System.Text.Encoding]::UTF8.GetString($buffer)
                        }
                        catch
                        {
                            $result.Error = $_.Exception.GetBaseException().Message
                        }
                        finally
                        {
                            $ssl.Dispose()
                            $client.Dispose()
                        }
                        return $result
                    }).AddArgument($listener).AddArgument($Certificate).AddArgument($RequireClientCertificate.IsPresent)
                return [pscustomobject]@{ Listener = $listener; PowerShell = $ps; Handle = $ps.BeginInvoke(); Port = $listener.LocalEndpoint.Port }
            }

            function Stop-TestTlsServer
            {
                param($Server)
                try
                {
                    return $Server.PowerShell.EndInvoke($Server.Handle) | Select-Object -Last 1
                }
                finally
                {
                    $Server.PowerShell.Dispose()
                    $Server.Listener.Stop()
                }
            }

            $script:ServerCertificate = New-TestCertificate -Subject 'localhost' -Usage Server
            $script:ClientCertificate = New-TestCertificate -Subject 'logape-test-client' -Usage Client
            $script:ServerFingerprint = Get-TestFingerprint $script:ServerCertificate
        }

        AfterAll {
            $script:ServerCertificate.Dispose()
            $script:ClientCertificate.Dispose()
        }

        It 'rejects an untrusted server certificate by default and says why' {
            $server = Start-TestTlsServer -Certificate $script:ServerCertificate
            $logger = New-Logger -Folder $script:LogFolder -FileName 'syslog-tls-reject.log' -UseFileNameAsIs -Destination File
            Add-LoggerSyslogSink -Server localhost -Port $server.Port -Protocol Tls -TimeoutSeconds 10 -Level Information -Logger $logger | Out-Null

            Write-Log 'should not arrive' -Logger $logger -WarningVariable tlsWarnings -WarningAction SilentlyContinue
            Remove-Logger -Logger $logger -Confirm:$false
            $result = Stop-TestTlsServer $server

            "$tlsWarnings" | Should -Match 'certificate'
            $result.Frame | Should -BeNullOrEmpty
        }

        It 'accepts any certificate with -SkipCertificateCheck (and warns when the sink is added), over TLS 1.2 or 1.3' {
            $server = Start-TestTlsServer -Certificate $script:ServerCertificate
            $logger = New-Logger -Folder $script:LogFolder -FileName 'syslog-tls-skip.log' -UseFileNameAsIs -Destination File
            Add-LoggerSyslogSink -Server localhost -Port $server.Port -Protocol Tls -SkipCertificateCheck -TimeoutSeconds 10 -Level Information -Logger $logger -WarningVariable addWarnings -WarningAction SilentlyContinue | Out-Null

            Write-Log 'over tls' -Logger $logger
            $result = Stop-TestTlsServer $server
            Remove-Logger -Logger $logger -Confirm:$false

            "$addWarnings" | Should -Match 'accepts any server certificate'
            $result.Error | Should -BeNullOrEmpty
            $result.Protocol | Should -BeIn @('Tls12', 'Tls13')
            $result.Frame | Should -Match ' - - over tls$'
        }

        It 'accepts a pinned certificate and rejects one that does not match the pin' {
            $server = Start-TestTlsServer -Certificate $script:ServerCertificate
            $logger = New-Logger -Folder $script:LogFolder -FileName 'syslog-tls-pin.log' -UseFileNameAsIs -Destination File
            $pin = ($script:ServerFingerprint -replace '(..)(?!$)', '$1:').ToUpperInvariant()
            Add-LoggerSyslogSink -Server localhost -Port $server.Port -Protocol Tls -ServerCertificateThumbprint $pin -TimeoutSeconds 10 -Level Information -Logger $logger | Out-Null
            Write-Log 'pinned' -Logger $logger
            $result = Stop-TestTlsServer $server
            Remove-Logger -Logger $logger -Confirm:$false
            $result.Frame | Should -Match ' - - pinned$'

            $server = Start-TestTlsServer -Certificate $script:ServerCertificate
            $logger = New-Logger -Folder $script:LogFolder -FileName 'syslog-tls-badpin.log' -UseFileNameAsIs -Destination File
            Add-LoggerSyslogSink -Server localhost -Port $server.Port -Protocol Tls -ServerCertificateThumbprint ('0' * 64) -TimeoutSeconds 10 -Level Information -Logger $logger | Out-Null
            Write-Log 'wrong pin' -Logger $logger -WarningVariable pinWarnings -WarningAction SilentlyContinue
            Remove-Logger -Logger $logger -Confirm:$false
            $result = Stop-TestTlsServer $server
            "$pinWarnings" | Should -Match 'fingerprint'
            $result.Frame | Should -BeNullOrEmpty
        }

        It 'presents -ClientCertificate to a server that requires one (mutual TLS)' {
            $server = Start-TestTlsServer -Certificate $script:ServerCertificate -RequireClientCertificate
            $logger = New-Logger -Folder $script:LogFolder -FileName 'syslog-tls-mutual.log' -UseFileNameAsIs -Destination File
            Add-LoggerSyslogSink -Server localhost -Port $server.Port -Protocol Tls -ServerCertificateThumbprint $script:ServerFingerprint -ClientCertificate $script:ClientCertificate -TimeoutSeconds 10 -Level Information -Logger $logger | Out-Null

            Write-Log 'mutual' -Logger $logger
            $result = Stop-TestTlsServer $server
            Remove-Logger -Logger $logger -Confirm:$false

            $result.Error | Should -BeNullOrEmpty
            $result.ClientFingerprint | Should -Be (Get-TestFingerprint $script:ClientCertificate)
            $result.Frame | Should -Match ' - - mutual$'
        }
    }

    Context 'Get-LoggerContent' {
        It 'returns the full file content by default' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'content.log' -UseFileNameAsIs -Destination File
            Write-Log 'line one' -Logger $logger -Bare
            Write-Log 'line two' -Logger $logger -Bare

            $lines = Get-LoggerContent -Logger $logger
            $lines | Should -Be @('line one', 'line two')
        }

        It 'returns only the last N lines with -Tail' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'content-tail.log' -UseFileNameAsIs -Destination File
            1..5 | ForEach-Object { Write-Log "line $_" -Logger $logger -Bare }

            Get-LoggerContent -Logger $logger -Tail 2 | Should -Be @('line 4', 'line 5')
        }

        It 'parses JSON lines into objects with -AsObject' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'content-json.log' -UseFileNameAsIs -Destination File -OutputFormat Json
            Write-Log 'structured' -Logger $logger -Level Warning -Fields @{ UserId = 7 }

            $result = Get-LoggerContent -Logger $logger -AsObject
            $result.Message | Should -Be 'structured'
            $result.Level | Should -Be 'Warning'
            $result.UserId | Should -Be 7
        }

        It 'returns raw text with a warning for a non-JSON line when -AsObject is used' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'content-not-json.log' -UseFileNameAsIs -Destination File
            Write-Log 'plain text line' -Logger $logger -Bare

            $result = Get-LoggerContent -Logger $logger -AsObject -WarningVariable warnings -WarningAction SilentlyContinue
            $result | Should -Be 'plain text line'
            $warnings | Should -Match 'not valid JSON'
        }

        It 'emits new lines as they are written with -Wait' {
            $fileName = 'content-tail-wait.log'
            $writerLogger = New-Logger -Folder $script:LogFolder -FileName $fileName -UseFileNameAsIs -Destination File
            Write-Log 'existing line' -Logger $writerLogger -Bare

            $ps = [powershell]::Create()
            [void]$ps.AddScript({
                    param($ModulePath, $Folder, $FileName)
                    Import-Module $ModulePath -Force
                    $logger = New-Logger -Folder $Folder -FileName $FileName -UseFileNameAsIs -Destination File
                    Get-LoggerContent -Logger $logger -Wait
                }).AddArgument($script:ModuleManifest).AddArgument($script:LogFolder).AddArgument($fileName)

            # BeginInvoke's generic overloads need both arguments strongly typed to resolve -
            # passing $null for "no input" fails overload resolution.
            $inputCollection = [System.Management.Automation.PSDataCollection[psobject]]::new()
            $inputCollection.Complete()
            $outputCollection = [System.Management.Automation.PSDataCollection[psobject]]::new()
            $asyncResult = $ps.BeginInvoke($inputCollection, $outputCollection)

            try
            {
                # Give the background tail time to reach Get-Content -Wait before writing.
                Start-Sleep -Milliseconds 500
                Write-Log 'tailed line' -Logger $writerLogger -Bare

                $deadline = (Get-Date).AddSeconds(5)
                while ((Get-Date) -lt $deadline -and -not ($outputCollection -contains 'tailed line'))
                {
                    Start-Sleep -Milliseconds 100
                }
            }
            finally
            {
                $ps.Stop() | Out-Null
                try { $ps.EndInvoke($asyncResult) } catch { }
                $ps.Dispose()
            }

            $outputCollection | Should -Contain 'tailed line'
        }
    }

    Context 'Masking' {
        It 'masks a message-text pattern added via Add-LoggerMaskRule, keeping the prefix intact' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'mask-rule.log' -UseFileNameAsIs -Destination File
            Add-LoggerMaskRule -Pattern '(?i)(?<Prefix>password\s*[:=]\s*)\S+' -Logger $logger

            Write-Log 'login with password=hunter2' -Logger $logger -Bare

            $content = Get-Content (Get-LoggerFullPath -Logger $logger) -Raw
            $content | Should -Match 'password=\*\*\*'
            $content | Should -Not -Match 'hunter2'
        }

        It 'masks a -Fields value whose key was added via Add-LoggerMaskField, in Text output' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'mask-field-text.log' -UseFileNameAsIs -Destination File
            Add-LoggerMaskField -FieldName Password -Logger $logger

            Write-Log 'login attempt' -Logger $logger -Fields @{ Password = 'hunter2'; UserId = 42 }

            $content = Get-Content (Get-LoggerFullPath -Logger $logger) -Raw
            $content | Should -Match 'Password=\*\*\*'
            $content | Should -Match 'UserId=42'
            $content | Should -Not -Match 'hunter2'
        }

        It 'masks a -Fields value whose key was added via Add-LoggerMaskField, in Json output' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'mask-field-json.log' -UseFileNameAsIs -Destination File -OutputFormat Json
            Add-LoggerMaskField -FieldName Password -Logger $logger

            Write-Log 'login attempt' -Logger $logger -Fields @{ Password = 'hunter2'; UserId = 42 }

            $parsed = (Get-Content (Get-LoggerFullPath -Logger $logger) -Raw) | ConvertFrom-Json
            $parsed.Password | Should -Be '***'
            $parsed.UserId | Should -Be 42
        }

        It 'uses a custom replacement set via Set-LoggerMaskReplacement' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'mask-replacement.log' -UseFileNameAsIs -Destination File
            Set-LoggerMaskReplacement -Replacement '[REDACTED]' -Logger $logger
            Add-LoggerMaskField -FieldName Secret -Logger $logger

            Write-Log 'token issued' -Logger $logger -Fields @{ Secret = 'topsecret' }

            (Get-Content (Get-LoggerFullPath -Logger $logger) -Raw) | Should -Match 'Secret=\[REDACTED\]'
        }

        It 'Add-LoggerDefaultMaskRule masks common password/token patterns and fields out of the box' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'mask-default.log' -UseFileNameAsIs -Destination File
            Add-LoggerDefaultMaskRule -Logger $logger

            Write-Log 'connecting with password=hunter2 and apiKey=abc123' -Logger $logger -Bare
            Write-Log 'login attempt' -Logger $logger -Fields @{ Token = 'xyz' }

            $content = Get-Content (Get-LoggerFullPath -Logger $logger) -Raw
            $content | Should -Not -Match 'hunter2'
            $content | Should -Not -Match 'abc123'
            $content | Should -Not -Match 'xyz'
        }

        It 'no longer masks a field after Remove-LoggerMaskField' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'mask-field-remove.log' -UseFileNameAsIs -Destination File
            Add-LoggerMaskField -FieldName Password -Logger $logger
            Remove-LoggerMaskField -FieldName Password -Logger $logger

            Write-Log 'login attempt' -Logger $logger -Fields @{ Password = 'hunter2' }

            (Get-Content (Get-LoggerFullPath -Logger $logger) -Raw) | Should -Match 'hunter2'
        }

        It 'no longer applies a rule after Remove-LoggerMaskRule' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'mask-rule-remove.log' -UseFileNameAsIs -Destination File
            $ruleId = Add-LoggerMaskRule -Pattern '(?i)(?<Prefix>password\s*[:=]\s*)\S+' -Logger $logger
            Remove-LoggerMaskRule -Id $ruleId -Logger $logger

            Write-Log 'login with password=hunter2' -Logger $logger -Bare

            (Get-Content (Get-LoggerFullPath -Logger $logger) -Raw) | Should -Match 'hunter2'
        }

        It 'Get-LoggerMaskRule and Get-LoggerMaskField reflect what was added' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'mask-get.log' -UseFileNameAsIs -Destination File
            Add-LoggerMaskRule -Pattern '(?i)(?<Prefix>password\s*[:=]\s*)\S+' -Logger $logger | Out-Null
            Add-LoggerMaskField -FieldName Password -Logger $logger

            (Get-LoggerMaskRule -Logger $logger).Pattern | Should -Match 'password'
            Get-LoggerMaskField -Logger $logger | Should -Contain 'Password'
        }

        It 'a wildcard field pattern masks any key that matches it' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'mask-field-wildcard.log' -UseFileNameAsIs -Destination File
            Add-LoggerMaskField -FieldName '*token*' -Logger $logger

            Write-Log 'refreshed' -Logger $logger -Fields @{ AccessToken = 'abc123'; UserId = 7 }

            $content = Get-Content (Get-LoggerFullPath -Logger $logger) -Raw
            $content | Should -Match 'AccessToken=\*\*\*'
            $content | Should -Match 'UserId=7'
            $content | Should -Not -Match 'abc123'
        }

        It 'a plain (non-wildcard) field name only matches that exact key' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'mask-field-exact.log' -UseFileNameAsIs -Destination File
            Add-LoggerMaskField -FieldName Token -Logger $logger

            Write-Log 'refreshed' -Logger $logger -Fields @{ AccessToken = 'abc123' }

            (Get-Content (Get-LoggerFullPath -Logger $logger) -Raw) | Should -Match 'abc123'
        }

        It 'New-Logger -EnableDefaultMasking applies the default preset at creation time' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'mask-enable-default.log' -UseFileNameAsIs -Destination File -EnableDefaultMasking

            Write-Log 'connecting with password=hunter2' -Logger $logger -Bare
            Write-Log 'refreshed' -Logger $logger -Fields @{ AccessToken = 'abc123' }

            $content = Get-Content (Get-LoggerFullPath -Logger $logger) -Raw
            $content | Should -Not -Match 'hunter2'
            $content | Should -Not -Match 'abc123'
        }

        It 'Write-Log -SkipMasking bypasses masking for that call only' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'mask-skip.log' -UseFileNameAsIs -Destination File
            Add-LoggerMaskField -FieldName Password -Logger $logger
            Add-LoggerMaskRule -Pattern '(?i)(?<Prefix>password\s*[:=]\s*)\S+' -Logger $logger

            Write-Log 'password=hunter2' -Logger $logger -Bare -SkipMasking
            Write-Log 'masked attempt' -Logger $logger -Fields @{ Password = 'hunter2' } -SkipMasking
            Write-Log 'password=hunter2' -Logger $logger -Bare

            $lines = Get-Content (Get-LoggerFullPath -Logger $logger)
            $lines[0] | Should -Match 'hunter2'
            $lines[1] | Should -Match 'hunter2'
            $lines[2] | Should -Match '\*\*\*'
        }
    }

    Context 'Concurrent writes' {
        It 'serializes writes from multiple runspaces without losing or interleaving lines' {
            $logger = New-Logger -Folder $script:LogFolder -FileName 'concurrent.log' -UseFileNameAsIs -Destination File -TimeoutSeconds 10
            $logPath = Get-LoggerFullPath -Logger $logger

            $runspaceCount = 5
            $messagesPerRunspace = 20

            $pool = [runspacefactory]::CreateRunspacePool(1, $runspaceCount)
            $pool.Open()
            $handles = @()

            for ($r = 0; $r -lt $runspaceCount; $r++)
            {
                $ps = [powershell]::Create()
                $ps.RunspacePool = $pool
                [void]$ps.AddScript({
                        param($ModulePath, $LogPath, $RunspaceId, $Count)
                        Import-Module $ModulePath -Force
                        for ($i = 0; $i -lt $Count; $i++)
                        {
                            $logger = New-Logger -Folder (Split-Path -Parent $LogPath) -FileName (Split-Path -Leaf $LogPath) -UseFileNameAsIs -Destination File
                            Write-Log "runspace $RunspaceId message $i" -Logger $logger -Bare
                        }
                    }).AddArgument($script:ModuleManifest).AddArgument($logPath).AddArgument($r).AddArgument($messagesPerRunspace)

                $handles += [pscustomobject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
            }

            foreach ($h in $handles)
            {
                $h.PowerShell.EndInvoke($h.Handle)
                $h.PowerShell.Dispose()
            }
            $pool.Close()
            $pool.Dispose()

            $lines = Get-Content $logPath
            $lines.Count | Should -Be ($runspaceCount * $messagesPerRunspace)

            for ($r = 0; $r -lt $runspaceCount; $r++)
            {
                ($lines | Where-Object { $_ -match "^runspace $r message \d+$" }).Count | Should -Be $messagesPerRunspace
            }
        }
    }
}
