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
