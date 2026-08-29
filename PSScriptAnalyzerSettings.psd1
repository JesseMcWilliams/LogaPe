@{
    IncludeDefaultRules = $true

    Rules = @{
        # This module's job is colored console output, so PSAvoidUsingWriteHost is a false
        # positive here - Write-Information/Write-Verbose can't set foreground/background
        # colors, and Write-Log's own console/file routing already replaces Write-Host for
        # ordinary script use elsewhere.
        PSAvoidUsingWriteHost = @{
            Enable = $false
        }

        # This flags 'Name' and 'WriteFile' (PowerShell class *methods* on LoggingLevel /
        # LoggingObject, not functions - a known ScriptAnalyzer/class-parsing false positive)
        # and 'Write-Log' (this module's actual, deliberately-named public function).
        PSAvoidOverwritingBuiltInCmdlets = @{
            Enable = $false
        }
    }
}
