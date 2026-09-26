# LogaPe: Claude Code project notes

LogaPe is a thread- and process-safe (mutex-guarded) PowerShell logging
module for console/file/Event-Log output, with configurable levels,
rotation, JSON output, and field/value masking of sensitive data. Runtime
target is Windows PowerShell 5.1 only (`PowerShellVersion = '5.1'` in
`LogaPe/LogaPe.psd1`); no `Set-StrictMode` or `#Requires` is used anywhere
in the module, tests, or examples, so strict mode is not enabled.

## Folder map
- `LogaPe/` — the module: `LogaPe.psd1` (manifest) and `LogaPe.psm1` (all code — classes, private helpers, public functions in one 2706-line file by design, see DESIGN.md §10). Over 1,000 lines: grep for the function/class name and read a line range; don't read the whole file.
- `Tests/` — Pester tests: `LogaPe.Tests.ps1` (492 lines) and `Examples.Tests.ps1` (39 lines, smoke-tests each `Examples/*.ps1` script as its own PS 5.1 subprocess).
- `Examples/` — runnable, smoke-tested usage scripts (`01-GettingStarted.ps1` … `07-EventLogSink.ps1`) plus a `README.md` index.
- `DESIGN.md` — design doc; §1-9 the original module rewrite, §10 what actually shipped, §11 the masking feature (v0.5.0).
- `CHANGELOG.md` — version history, `[Unreleased]` at top.
- `USAGE.md` — usage guide; includes "Masking sensitive values" and a function reference.
- `LESSONS-LEARNED.md` — categorized bug/gotcha log: PowerShell Classes, PowerShell Language Gotchas, Testing (Pester), PSScriptAnalyzer/Linting, Design bugs.
- `PSScriptAnalyzerSettings.psd1` — lint config; suppressions have inline rationale comments.
- Gitignored, don't read: `*.log`, `testResults.xml`, `*.local.md`, `*.csv`, `*.cred`, `*.clixml`, `Secrets/`.
- External references are in `C:\Code\References\`. Check there before guessing at API behavior.

## Tests
- Run all: `Invoke-Pester -Path .\Tests`
- Run one file: `Invoke-Pester -Path .\Tests\LogaPe.Tests.ps1` (or `.\Tests\Examples.Tests.ps1`)
- PS 5.1 check: `Tests\Examples.Tests.ps1` runs each `Examples/*.ps1` script as its own Windows PowerShell 5.1 subprocess — running that file IS the PS 5.1 check.
- Redirect test output to a file and read only the summary or failures. Don't stream full test output into the conversation.
- The suite must stay at 100% pass. Run the single test file while iterating and the full suite before you commit.

## Code rules (details in the linked sections, not repeated here)
- Classes and functions referencing them as a type constraint must live in one physical file (`LogaPe.psm1`) — don't reintroduce a `Public`/`Private` split. See DESIGN.md §10 and LESSONS-LEARNED.md § PowerShell Classes.
- Don't use `switch`/`break` inside a PowerShell class method — use `if`/`elseif` instead. See LESSONS-LEARNED.md § PowerShell Classes.
- Public API is approved-verb function wrappers (`New-`, `Get-`, `Set-`, `Add-`, `Remove-`) over the underlying classes. See DESIGN.md §3.
- State-changing functions declare `[CmdletBinding(SupportsShouldProcess)]` and gate mutation behind `$PSCmdlet.ShouldProcess(...)`. See DESIGN.md §10.
- Never mix `+` and `-f` in the same expression. See LESSONS-LEARNED.md § PowerShell Language Gotchas.
- Pester: assign any variable an `It` body needs inside `BeforeAll`, not at top level. See LESSONS-LEARNED.md § Testing (Pester).
- Verify a PSScriptAnalyzer suppression actually suppresses something before relying on it. See LESSONS-LEARNED.md § PSScriptAnalyzer/Linting.

## Documentation layout
This repo predates the Claude_Docs/User_Docs convention and uses flat
root-level docs instead:
- `DESIGN.md` — how the current system works, in numbered sections. Keep current.
- `CHANGELOG.md` — version history, newest/`[Unreleased]` at top.
- `USAGE.md` — end-user usage guide and function reference.
- `LESSONS-LEARNED.md` — categorized gotchas/bugs, filed by category, never deleted.
- Rename docs with `git mv`, and update every link to them in the same change.

## Docs: what to update for each kind of change
| Change | Update |
|---|---|
| New feature | `DESIGN.md` (add/extend a numbered section) + `CHANGELOG.md` (`[Unreleased]`) + `USAGE.md` if user-facing |
| Bug fix | `CHANGELOG.md` (`[Unreleased]`) + `LESSONS-LEARNED.md` if it's a reusable gotcha |
| Design decision | `DESIGN.md` (relevant section) |
| New gotcha | `LESSONS-LEARNED.md`, filed under the matching category |

- For "verify the docs are updated", use a subagent to diff the branch against this checklist and report the gaps only.

## Git
- Don't work directly on `main`. Create a topic branch named `YYYY-MM-DD-<topic>` and open a PR into `main` with `gh`.
- Commit, push, open a PR or merge only when asked. "Commit and push" means both.

## Live testing
- Lab environment details are in `Live-Testing.local.md` in the project root. That file is gitignored. **Read it only when a task involves live testing.** Never copy its contents into tracked files, commit messages or PR descriptions.
- If `Live-Testing.local.md` is missing, ask for the details. Don't guess.
- Never write secrets into any file, log or commit message, including `Live-Testing.local.md`. That file names *where* the credentials live, not the credentials themselves.
- When an example, doc or test needs a password placeholder, use `ThisIsMy_FAKE_Password6!`. It's obviously fake, and it satisfies typical complexity rules.
