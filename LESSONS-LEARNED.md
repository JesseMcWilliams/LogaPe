# Lessons Learned

A running log of bugs and failure points hit while building LogaPe, kept so the same mistake
doesn't get made twice. Organized by category; newest entries go at the top of their category.
When you hit something here again, that's a sign it deserves a Pester test or a code comment,
not just a line in this file.

## PowerShell Classes

### A `class` type used as a parameter/return type must live in the same file as the code that references it

**Symptom:** `Unable to find type [Logger]` when importing a module that dot-sources separate
`Public/*.ps1` files, even though the class is defined earlier in the same module's load
sequence.

**Root cause:** PowerShell resolves a class type literal (e.g. `[Logger]$Logger` in a param
block) by scanning the *same file's* parsed AST for `class Logger {...}` at parse time. A
function dot-sourced from a separate `.ps1` file is parsed independently and never sees the
class, regardless of module-scope function visibility working normally.

**Rule:** Classes, and every function that references them as a type constraint, must live in
one physical file. `LogaPe.psm1` is a single file for exactly this reason - don't reintroduce a
`Public`/`Private` folder split without solving this first (e.g. `using module` per file, if
that's ever proven to work reliably here).

### `break` inside a `switch` inside a class method can escape as an unhandled exception

**Symptom:** Pester aborted an entire run with `A 'break' or 'continue' statement with a label
that does not match any enclosing loop escaped from your code`
([pester/Pester#2669](https://github.com/pester/Pester/issues/2669)), even though the actual
bug was in module code, not the test file, and there was no literal label mismatch anywhere.

**Root cause:** `LoggingObject.WriteConsole()` used a `switch ($Level.Name()) { 'X' { ...;
break } }` inside a class method. A bare `break` that would cleanly exit a `switch` at script
scope can escape as a raw `BreakException` when the `switch` is inside a class method body -
a real PowerShell/class interaction quirk.

**Rule:** Don't use `switch`/`break` inside a class method. Use an `if`/`elseif` chain instead
(see `WriteConsole` and `WriteNativeStream`). A `switch` using `return` instead of `break` (see
`LoggingLevel.LevelToInt`) is fine - it's specifically `break` that's the problem.

## PowerShell Language Gotchas

### `-f` (format) binds tighter than `+` (concatenation)

**Symptom:** A warning message built from several concatenated string literals, with the `-f`
operator applied at the end, printed `{0}`/`{1}`/`{2}` literally instead of substituting values
- but only in the *earlier* fragments; the last fragment (the only one `-f` actually bound to)
was fine if it happened to have a placeholder, and silently ignored if it didn't.

**Root cause:** `"a" + "b" -f $x` parses as `"a" + ("b" -f $x)`, not `("a" + "b") -f $x`. Only
the last operand before `-f` gets formatted.

**Rule:** Build the full template as one string (or one set of concatenations) first, assign it
to a variable, then apply `-f` to that variable on its own line. Never mix `+` and `-f` in the
same expression.

### `$_` inside a `catch` block shadows the outer `$_` from an enclosing `ForEach-Object`

**Symptom:** `Get-LoggerContent -AsObject`'s fallback for a malformed JSON line returned the
JSON parser's *error message* instead of the original line - the exact opposite of what the
warning text claimed it was doing.

**Root cause:** Inside `catch`, `$_` is rebound to the caught `ErrorRecord`. If that `catch` is
nested inside a `ForEach-Object { ... }` scriptblock, the pipeline item's `$_` from the outer
scope is no longer reachable under that name.

**Rule:** The moment you're inside a `try`/`catch` that's itself inside a `ForEach-Object` (or
any scriptblock using `$_`), capture the outer value into a named variable (`$line = $_`)
*before* the `try`, and use that name everywhere inside, including inside `catch`.

### `[powershell]::BeginInvoke()`'s generic overloads need every argument strongly typed

**Symptom:** `MethodException: Cannot find an overload for "BeginInvoke" and the argument
count: "2"` when calling `$ps.BeginInvoke($null, $outputCollection)` to get live streaming
output from a background runspace.

**Root cause:** `BeginInvoke` is a generic method (`BeginInvoke<TInput,TOutput>(...)`).
Passing `$null` for "no input" gives PowerShell nothing to infer the generic type from, so
overload resolution fails outright.

**Rule:** When you need to observe a `[powershell]` pipeline's output while it's still running
(not just after `EndInvoke`), create real, strongly-typed `PSDataCollection[psobject]` objects
for *both* input and output, call `$inputCollection.Complete()` if there's genuinely no input,
and pass both to `BeginInvoke`. See the `Get-LoggerContent -Wait` test for the working pattern.

## Testing (Pester)

### A variable set at the top of a test file, outside any block, isn't visible in `BeforeAll`/`It`

**Symptom:** `Import-Module $moduleManifest -Force` inside `BeforeAll` behaved as if
`$moduleManifest` were `$null`/empty, even though it was clearly assigned at the top of the
file - and the actual failure surfaced as the confusing "break/continue" error above, not a
clean "variable not found."

**Root cause:** Pester runs a test file in two phases: **Discovery** (executes top-level code
and every `Describe`/`Context`/`It` *call* to register the test tree, but not `It` bodies) and
**Run** (actually executes `BeforeAll`/`BeforeEach`/`It` bodies, later, in a different
scope/session). A bare top-level `$x = ...` only exists during Discovery.

**Rule:** Compute anything an `It`/`BeforeAll` needs - especially `$PSScriptRoot`-derived paths
- *inside* `BeforeAll`, assigned to `$script:something`, not at the top of the file.

### Testing `-Wait`/`tail -f`-style streaming needs a background runspace, not a sleep-and-check

Covered above (`BeginInvoke`), but as a standalone testing pattern: don't try to test a
blocking/streaming cmdlet by running it in the foreground with a timeout guess. Run it in a
background `[powershell]` instance against a live `PSDataCollection` output buffer, write to
the file from the foreground, then poll the collection with a real deadline before calling
`.Stop()`. See the `Get-LoggerContent -Wait` and `Concurrent writes` tests.

### When a sink/output's success depends on the environment (e.g. admin rights), test what's deterministic, not the happy path

**Context:** `Add-LoggerEventLogSink` needs local administrator rights to auto-register a new
event source. A test asserting "writing at the sink's level produces an Event Log warning"
would pass on a non-elevated CI runner and silently start failing the day someone runs it
elevated (the write would just succeed instead).

**Rule:** When a feature's success genuinely depends on privileges/environment you don't
control in tests, assert on the parts that don't vary: registration/listing/removal of state,
that filtering means the code path is never reached at all below a threshold, and that a write
attempt never throws back to the caller regardless of whether it internally succeeded or
failed-and-warned. Don't assert on which of those two outcomes occurred.

## Design bugs worth remembering (root causes, not just the fix)

### A class cannot know who called into it - `$PSCommandPath`/`$MyInvocation` inside a class method resolve to the file the class is defined in, not the caller's script

This was the very first and most impactful bug in the original `Logger` module: the default
log file location silently resolved to the module's own install folder. The fix wasn't a
one-line patch - it required moving all "what's the caller's context" logic out of the class
entirely and into the `New-Logger` *function*, which can legitimately inspect
`(Get-PSCallStack)[1]` to see who called it. **Whenever a class needs caller context, that
context has to be captured by a function and passed in - never inferred from inside the class.**

### Named OS primitives (mutexes, event sources, etc.) are global by name - never derive a name from something as narrow as a file's leaf name

The original mutex was named after the log file's leaf name only, so two unrelated scripts
using the same file name (e.g. `app.log`) in different folders would unintentionally
synchronize on each other's mutex. Fixed by hashing the full, normalized path. **Any time you
name a system-wide object after user-supplied data, ask what happens when two unrelated
callers pick the same short name - and prefer deriving the name from something that's actually
unique to the resource (a full path, a GUID), not something merely convenient.**
