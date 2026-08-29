@{
    IncludeDefaultRules = $true

    # PSAvoidUsingWriteHost does not honor Rules.<Name>.Enable (verified: it stays enabled
    # regardless), unlike most other rules - it must be disabled via the top-level ExcludeRules
    # list instead. This module's job (and its Examples/) is colored/narrated console output;
    # Write-Information/Write-Verbose can't set foreground/background colors, and Write-Log's
    # own console/file routing already replaces Write-Host for ordinary script use elsewhere.
    ExcludeRules = @('PSAvoidUsingWriteHost')

    Rules = @{
        # This flags 'Name' and 'WriteFile' (PowerShell class *methods* on LoggingLevel /
        # LoggingObject, not functions - a known ScriptAnalyzer/class-parsing false positive)
        # and 'Write-Log' (this module's actual, deliberately-named public function). Verified
        # this one *does* honor Rules.<Name>.Enable, unlike PSAvoidUsingWriteHost above.
        PSAvoidOverwritingBuiltInCmdlets = @{
            Enable = $false
        }
    }
}
