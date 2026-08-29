<#
    Smoke-tests the scripts in Examples/: each one just needs to run to completion without an
    unhandled error. This is deliberately not where behavior assertions live - see
    LogaPe.Tests.ps1 for those. Keeping the two separate lets Examples/ stay readable as plain
    usage demonstrations while still catching the day an API change silently breaks one of them.

    Each example is run as its own Windows PowerShell 5.1 process (LogaPe's target runtime,
    matching how a user would actually run it), rather than in-process here, so examples can't
    leak module state (e.g. the active logger) between each other or into this test run.
#>

Describe 'Examples' {
    # -ForEach's argument is evaluated during Pester's Discovery phase (which runs this Describe
    # body directly), so the file list for it has to be computed here, at the top level.
    $examplesFolder = Join-Path $PSScriptRoot '..\Examples'
    $exampleScripts = Get-ChildItem -Path $examplesFolder -Filter '*.ps1' | Sort-Object Name

    # A plain It's body runs later, during Run phase - in practice (confirmed by this exact test
    # failing the first time it was written) that is NOT the same script scope as the Discovery
    # pass above, so $script:-scoping the variable above did not make it visible here either.
    # Recomputing it inside BeforeAll (which itself runs during Run phase) is what actually
    # works - see LESSONS-LEARNED.md's Discovery-vs-Run entry.
    BeforeAll {
        $script:exampleScriptsAtRunTime = Get-ChildItem -Path (Join-Path $PSScriptRoot '..\Examples') -Filter '*.ps1'
    }

    It 'has at least one example script' {
        $script:exampleScriptsAtRunTime.Count | Should -BeGreaterThan 0
    }

    It 'runs <_.Name> to completion without error' -ForEach $exampleScripts {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $_.FullName 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $output | Out-String

        $exitCode | Should -Be 0 -Because "the script's own output was:`n$outputText"
        $outputText | Should -Match '\[OK\] Example completed successfully\.'
    }
}
