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
