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
