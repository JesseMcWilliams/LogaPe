class LoggingLevel
{
    [ValidateSet('None', 'Critical', 'Error', 'Warning', 'Information', 'Debug', 'Verbose', 'Trace')]
    [string]
    $LoggingLevelName

    [ValidateRange(0, 6)]
    [int]
    $LoggingLevelInt

    LoggingLevel() {}

    LoggingLevel([string]$LevelName)
    {
        $this.LoggingLevelName = $LevelName
        $this.LoggingLevelInt = $this.LevelToInt($LevelName)
    }

    # Verbose and Trace share rank 0 by design - Trace is the more granular alias.
    hidden [int]LevelToInt([string]$LevelName)
    {
        switch ($LevelName)
        {
            'Verbose'     { return 0 }
            'Trace'       { return 0 }
            'Debug'       { return 1 }
            'Information' { return 2 }
            'Warning'     { return 3 }
            'Error'       { return 4 }
            'Critical'    { return 5 }
            'None'        { return 6 }
        }
        return -1
    }

    [int]Level()
    {
        return $this.LoggingLevelInt
    }

    [string]Name()
    {
        return $this.LoggingLevelName
    }
}

class LoggingDestination
{
    [ValidateSet('Console', 'File', 'Both')]
    [string]
    $LogDestination

    LoggingDestination()
    {
        $this.LogDestination = 'Both'
    }

    LoggingDestination([string]$Destination)
    {
        $this.LogDestination = $Destination
    }

    [bool]Console()
    {
        return ($this.LogDestination -ieq 'Console') -or ($this.LogDestination -ieq 'Both')
    }

    [bool]File()
    {
        return ($this.LogDestination -ieq 'File') -or ($this.LogDestination -ieq 'Both')
    }
}

class LoggingObject
{
    hidden [string] $LoggingFile
    hidden [string] $LoggingMutexName
    hidden [System.Threading.Mutex] $loggingMutex
    hidden [timespan] $Timeout

    LoggingObject() {}

    LoggingObject([string]$LogFileUNC, [int]$TimeOutSeconds)
    {
        $this.Timeout = New-TimeSpan -Seconds $TimeOutSeconds
        $this.LoggingFile = $LogFileUNC
        $this.LoggingMutexName = ConvertTo-LogMutexName -Path $LogFileUNC

        try
        {
            $this.loggingMutex = [System.Threading.Mutex]::OpenExisting($this.LoggingMutexName)
            $this.loggingMutex.ReleaseMutex()
            Write-Debug 'Opened EXISTING mutex handle.'
        }
        catch
        {
            $this.loggingMutex = New-Object System.Threading.Mutex($false, $this.LoggingMutexName)
            Write-Debug 'Opened NEW mutex handle.'
        }
    }

    [string]GetLoggingFile()
    {
        return $this.LoggingFile
    }

    [void]SetLoggingFile([string]$LogFileUNC)
    {
        $this.LoggingFile = $LogFileUNC
        $this.LoggingMutexName = ConvertTo-LogMutexName -Path $LogFileUNC

        try
        {
            $this.loggingMutex = [System.Threading.Mutex]::OpenExisting($this.LoggingMutexName)
            $this.loggingMutex.ReleaseMutex()
        }
        catch
        {
            $this.loggingMutex = New-Object System.Threading.Mutex($false, $this.LoggingMutexName)
        }
    }

    [System.Threading.Mutex]GetLoggingMutex()
    {
        return $this.loggingMutex
    }

    [string]GetLoggingMutexName()
    {
        return $this.LoggingMutexName
    }

    [void]SetTimeOutSeconds([int]$TimeOutSeconds)
    {
        $this.Timeout = New-TimeSpan -Seconds $TimeOutSeconds
    }

    [void]WriteConsole([string]$Message, [LoggingLevel]$Level)
    {
        # Avoid 'break' here - inside a class method's switch it can escape as an unhandled
        # BreakException instead of just exiting the switch (a known PowerShell class quirk).
        $levelName = $Level.Name()
        if ($levelName -eq 'Trace')
        {
            Write-Host $Message -ForegroundColor Green -BackgroundColor DarkGray
        }
        elseif ($levelName -eq 'Verbose')
        {
            Write-Host $Message -ForegroundColor Green -BackgroundColor Black
        }
        elseif ($levelName -eq 'Debug')
        {
            Write-Host $Message -ForegroundColor DarkBlue -BackgroundColor Black
        }
        elseif ($levelName -eq 'Information')
        {
            Write-Host $Message -ForegroundColor Gray -BackgroundColor Black
        }
        elseif ($levelName -eq 'Warning')
        {
            Write-Host $Message -ForegroundColor DarkYellow -BackgroundColor DarkGray
        }
        elseif ($levelName -eq 'Error')
        {
            Write-Host $Message -ForegroundColor DarkRed -BackgroundColor White
        }
        elseif ($levelName -eq 'Critical')
        {
            Write-Host $Message -ForegroundColor White -BackgroundColor DarkRed
        }
        elseif ($levelName -eq 'None')
        {
            Write-Host $Message -ForegroundColor Blue -BackgroundColor Black
        }
        else
        {
            Write-Host $Message
        }
    }

    [void]WriteFile([string]$Message)
    {
        # The mutex serializes writes from cooperating LogaPe loggers (same process or
        # different processes/threads). The retry loop absorbs transient external locks
        # (e.g. an editor or tail tool briefly opening the file) up to $this.Timeout.
        $deadline = (Get-Date) + $this.Timeout
        $acquired = $false

        try
        {
            while (-not ($acquired = $this.loggingMutex.WaitOne(200)))
            {
                if ((Get-Date) -ge $deadline)
                {
                    throw 'Timed out waiting for the log file mutex.'
                }
            }

            while ($true)
            {
                if (-not (Test-IsFileLocked -Path $this.LoggingFile))
                {
                    try
                    {
                        Add-Content -Path $this.LoggingFile -Value $Message -ErrorAction Stop
                        return
                    }
                    catch
                    {
                        # Fall through to the timeout/retry check below.
                        Write-Debug "Add-Content attempt failed, will retry: $($_.Exception.Message)"
                    }
                }

                if ((Get-Date) -ge $deadline)
                {
                    throw "Timed out writing to log file: $($this.LoggingFile)"
                }

                Start-Sleep -Milliseconds 50
            }
        }
        catch
        {
            Write-Warning "Failed to write to: $($this.LoggingFile)"
            throw "Could not write to log file: $($_.Exception.Message)"
        }
        finally
        {
            if ($acquired)
            {
                $this.loggingMutex.ReleaseMutex()
            }
        }
    }
}

class Logger
{
    hidden [LoggingLevel] $TargetLogLevel
    hidden [LoggingObject] $LogFileObj
    hidden [string] $LogFileName
    hidden [string] $LogFilePath
    hidden [int] $TimeOut

    [LoggingDestination] $LogDestination

    Logger([string]$LevelName, [string]$FileName, [string]$FolderPath, [int]$TimeOutSeconds, [string]$Destination)
    {
        $this.TargetLogLevel = [LoggingLevel]::new($LevelName)
        $this.LogFileName = $FileName
        $this.LogFilePath = $FolderPath
        $this.TimeOut = $TimeOutSeconds
        $this.LogFileObj = [LoggingObject]::new((Join-Path $FolderPath $FileName), $TimeOutSeconds)
        $this.LogDestination = [LoggingDestination]::new($Destination)
    }

    [void]SetLoggingLevel([LoggingLevel]$LoggingLevel)
    {
        $this.TargetLogLevel = $LoggingLevel
    }

    [string]GetLoggingLevel()
    {
        return $this.TargetLogLevel.Name()
    }

    [void]SetLoggingPath([string]$FolderPath)
    {
        if ([System.IO.Path]::IsPathRooted($FolderPath))
        {
            $this.LogFilePath = $FolderPath
        }
        else
        {
            $this.LogFilePath = Join-Path (Get-Location).Path $FolderPath
        }

        $this.LogFileObj.SetLoggingFile((Join-Path $this.LogFilePath $this.LogFileName))
    }

    [string]GetLoggingPath()
    {
        return $this.LogFilePath
    }

    [string]GetLogDestination()
    {
        return $this.LogDestination.LogDestination
    }

    [void]SetLogDestination([string]$Destination)
    {
        $this.LogDestination = [LoggingDestination]::new($Destination)
    }

    [void]SetLoggingFile([string]$FileName)
    {
        $this.LogFileName = $FileName
        $this.LogFileObj.SetLoggingFile((Join-Path $this.LogFilePath $this.LogFileName))
    }

    [string]GetLoggingFile()
    {
        return $this.LogFileName
    }

    [string]GetLoggingFullPath()
    {
        return Join-Path $this.LogFilePath $this.LogFileName
    }

    [System.Threading.Mutex]GetLoggingMutex()
    {
        return $this.LogFileObj.GetLoggingMutex()
    }

    [int]GetTimeOutSeconds()
    {
        return $this.TimeOut
    }

    [void]SetTimeOutSeconds([int]$TimeOutSeconds)
    {
        $this.TimeOut = $TimeOutSeconds
        $this.LogFileObj.SetTimeOutSeconds($this.TimeOut)
    }

    [string]ToString()
    {
        return "`r`n`tLevel        | $($this.TargetLogLevel.Name())" +
               "`r`n`tFileName     | $($this.LogFileName)" +
               "`r`n`tPath         | $($this.LogFilePath)" +
               "`r`n`tDestination  | $($this.LogDestination.LogDestination)" +
               "`r`n`tMutexName    | $($this.LogFileObj.GetLoggingMutexName())"
    }

    # Method overloads collapse onto the 4-argument form so the level-filter check and the
    # write path each exist in exactly one place.
    [void]Write([string]$Message)
    {
        $this.Write($Message, [LoggingLevel]::new('Information'), $this.LogDestination, $false)
    }

    [void]Write([string]$Message, [LoggingLevel]$Level)
    {
        $this.Write($Message, $Level, $this.LogDestination, $false)
    }

    [void]Write([string]$Message, [LoggingLevel]$Level, [LoggingDestination]$Destination)
    {
        $this.Write($Message, $Level, $Destination, $false)
    }

    [void]Write([string]$Message, [LoggingLevel]$Level, [LoggingDestination]$Destination, [bool]$Bare)
    {
        if ($this.TargetLogLevel.Level() -le $Level.Level())
        {
            $this._WriteOutput($Message, $Level, $Destination, $Bare)
        }
    }

    hidden [void]_WriteOutput([string]$Message, [LoggingLevel]$Level, [LoggingDestination]$Destination, [bool]$Bare)
    {
        if ($Bare)
        {
            $writeString = $Message
        }
        else
        {
            $writeString = '{0} | {1} | {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.Name().PadLeft(11, ' '), $Message
        }

        if ($Destination.Console())
        {
            $this.LogFileObj.WriteConsole($writeString, $Level)
        }

        if ($Destination.File())
        {
            $this.LogFileObj.WriteFile($writeString)
        }
    }
}

$script:ActiveLogger = $null

#region Private helpers

function ConvertTo-LogMutexName
{
    <#
    .SYNOPSIS
    Derives a stable, collision-resistant mutex name for a log file path.

    .DESCRIPTION
    Named mutexes are global to the Windows session, so naming one after just the log file's
    leaf name (e.g. "app.log") would unintentionally synchronize unrelated scripts that happen
    to share a file name in different folders. Hashing the full, normalized path avoids that
    while still resolving to the same name for the same file across processes.

    .PARAMETER Path
    The log file path (need not exist yet).

    .OUTPUTS
    System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).ToLowerInvariant()
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try
    {
        $hashBytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($fullPath))
    }
    finally
    {
        $md5.Dispose()
    }

    $hash = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return "LogaPe_$hash"
}

function Resolve-TargetLogger
{
    <#
    .SYNOPSIS
    Resolves which Logger instance a public function should act on.

    .DESCRIPTION
    Every Get-Logger*/Set-Logger*/Write-Log function accepts an optional -Logger instance and
    falls back to the module's active logger (set via New-Logger -SetActive or
    Set-ActiveLogger) when none is supplied. This centralizes that fallback and the
    no-active-logger error so it exists in exactly one place.

    .PARAMETER Logger
    An explicit Logger instance, or $null to use the active logger.

    .OUTPUTS
    Logger
    #>
    [CmdletBinding()]
    [OutputType([Logger])]
    param(
        [Parameter()]
        [Logger]$Logger
    )

    if ($Logger)
    {
        return $Logger
    }

    if ($script:ActiveLogger)
    {
        return $script:ActiveLogger
    }

    throw 'No active logger is set. Call New-Logger (optionally -SetActive) or pass -Logger explicitly.'
}

function Test-IsFileLocked
{
    <#
    .SYNOPSIS
    Checks whether a file can currently be opened for writing.

    .DESCRIPTION
    Internal helper used by LoggingObject.WriteFile() to skip a write attempt when the file
    is held open elsewhere, reducing (but not eliminating) wasted Add-Content failures. It is
    not exported - correctness of concurrent writes comes from the mutex plus WriteFile's own
    retry loop, not from this check.

    .PARAMETER Path
    Full path to the file to probe.

    .OUTPUTS
    System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        return $false
    }

    try
    {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $stream.Close()
        $stream.Dispose()
        return $false
    }
    catch [System.UnauthorizedAccessException]
    {
        return $true
    }
    catch
    {
        return $true
    }
}

#endregion

#region Public functions

function Get-ActiveLogger
{
    <#
    .SYNOPSIS
    Returns the module's current active logger, if any.

    .DESCRIPTION
    Returns $null if no logger has been created with -SetActive (or as the first logger of
    the session) and none has been set via Set-ActiveLogger.

    .OUTPUTS
    Logger
    #>
    [CmdletBinding()]
    [OutputType([Logger])]
    param()

    return $script:ActiveLogger
}

function Get-LoggerDestination
{
    <#
    .SYNOPSIS
    Gets a logger's configured destination.

    .PARAMETER Logger
    The Logger instance to query. Defaults to the active logger.

    .OUTPUTS
    System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [Logger]$Logger
    )

    (Resolve-TargetLogger -Logger $Logger).GetLogDestination()
}

function Get-LoggerFile
{
    <#
    .SYNOPSIS
    Gets a logger's log file name (not the full path - see Get-LoggerFullPath).

    .PARAMETER Logger
    The Logger instance to query. Defaults to the active logger.

    .OUTPUTS
    System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [Logger]$Logger
    )

    (Resolve-TargetLogger -Logger $Logger).GetLoggingFile()
}

function Get-LoggerFullPath
{
    <#
    .SYNOPSIS
    Gets the full path (folder + file name) of a logger's log file.

    .PARAMETER Logger
    The Logger instance to query. Defaults to the active logger.

    .OUTPUTS
    System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [Logger]$Logger
    )

    (Resolve-TargetLogger -Logger $Logger).GetLoggingFullPath()
}

function Get-LoggerLevel
{
    <#
    .SYNOPSIS
    Gets a logger's minimum logging level.

    .PARAMETER Logger
    The Logger instance to query. Defaults to the active logger.

    .OUTPUTS
    System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [Logger]$Logger
    )

    (Resolve-TargetLogger -Logger $Logger).GetLoggingLevel()
}

function Get-LoggerPath
{
    <#
    .SYNOPSIS
    Gets the folder a logger writes its log file into.

    .PARAMETER Logger
    The Logger instance to query. Defaults to the active logger.

    .OUTPUTS
    System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [Logger]$Logger
    )

    (Resolve-TargetLogger -Logger $Logger).GetLoggingPath()
}

function Get-LoggerTimeout
{
    <#
    .SYNOPSIS
    Gets a logger's write-retry timeout, in seconds.

    .PARAMETER Logger
    The Logger instance to query. Defaults to the active logger.

    .OUTPUTS
    System.Int32
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Position = 0)]
        [Logger]$Logger
    )

    (Resolve-TargetLogger -Logger $Logger).GetTimeOutSeconds()
}

function New-Logger
{
    <#
    .SYNOPSIS
    Creates a new Logger instance.

    .DESCRIPTION
    Creates a Logger that can write to the console and/or a log file, guarded by a named
    mutex so concurrent threads/processes writing to the same file don't interleave or clobber
    each other's lines.

    By default, the log file is named after the calling script and placed next to it (the
    caller's location is resolved from the call stack, not from the module's own path). The
    first logger created in a session automatically becomes the active logger unless one is
    already set; pass -SetActive to force it.

    .PARAMETER Level
    The minimum level that will be written. Messages below this level are filtered out.
    Defaults to 'Verbose' (writes everything).

    .PARAMETER FileName
    Log file name. Defaults to "<yyyy-MM-dd>_<calling script name>.log". Unless
    -UseFileNameAsIs is specified, a supplied name is still prefixed with the current date.

    .PARAMETER UseFileNameAsIs
    Use -FileName exactly as given, without the automatic date prefix.

    .PARAMETER Folder
    Folder for the log file. Relative paths are resolved against the calling script's folder
    (or the current directory, if called interactively). Defaults to the calling script's
    folder.

    .PARAMETER Destination
    Where messages are written: 'Console', 'File', or 'Both'. Defaults to 'Console' so that
    creating a logger never writes a file until you opt in.

    .PARAMETER TimeoutSeconds
    How long WriteLog will retry acquiring the mutex / writing the file before throwing.
    Defaults to 5 seconds.

    .PARAMETER SetActive
    Make this the module's active logger, so Write-Log and the Get-/Set-Logger* functions can
    be called without passing -Logger explicitly.

    .EXAMPLE
    $logger = New-Logger -Level Verbose -Destination Both -SetActive
    Write-Log 'Hello world'

    .OUTPUTS
    Logger
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([Logger])]
    param(
        [Parameter()]
        [ValidateSet('None', 'Critical', 'Error', 'Warning', 'Information', 'Debug', 'Verbose', 'Trace')]
        [string]$Level = 'Verbose',

        [Parameter()]
        [string]$FileName,

        [Parameter()]
        [switch]$UseFileNameAsIs,

        [Parameter()]
        [string]$Folder,

        [Parameter()]
        [ValidateSet('Console', 'File', 'Both')]
        [string]$Destination = 'Console',

        [Parameter()]
        [int]$TimeoutSeconds = 5,

        [Parameter()]
        [switch]$SetActive
    )

    $callerScript = (Get-PSCallStack)[1].ScriptName
    if ($callerScript)
    {
        $callerName = [System.IO.Path]::GetFileNameWithoutExtension($callerScript)
        $callerFolder = Split-Path -Parent $callerScript
    }
    else
    {
        $callerName = 'Interactive'
        $callerFolder = (Get-Location).Path
    }

    if (-not $FileName)
    {
        $FileName = '{0}_{1}.log' -f (Get-Date -Format 'yyyy-MM-dd'), $callerName
    }
    elseif (-not $UseFileNameAsIs)
    {
        $FileName = '{0}_{1}.log' -f (Get-Date -Format 'yyyy-MM-dd'), $FileName
    }

    if (-not $Folder)
    {
        $Folder = $callerFolder
    }
    elseif (-not [System.IO.Path]::IsPathRooted($Folder))
    {
        $Folder = Join-Path $callerFolder $Folder
    }

    $fullPath = Join-Path $Folder $FileName
    if ($PSCmdlet.ShouldProcess($fullPath, 'Create logger (and its file mutex)'))
    {
        $logger = [Logger]::new($Level, $FileName, $Folder, $TimeoutSeconds, $Destination)

        if ($SetActive -or (-not $script:ActiveLogger))
        {
            $script:ActiveLogger = $logger
        }

        return $logger
    }
    return $null
}

function Set-ActiveLogger
{
    <#
    .SYNOPSIS
    Makes an existing Logger instance the module's active logger.

    .DESCRIPTION
    Write-Log and the Get-/Set-Logger* functions use the active logger whenever -Logger isn't
    supplied explicitly.

    .PARAMETER Logger
    The Logger instance to make active.

    .EXAMPLE
    $fileLogger = New-Logger -Destination File
    Set-ActiveLogger -Logger $fileLogger
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [Logger]$Logger
    )

    if ($PSCmdlet.ShouldProcess('module active logger', 'Set'))
    {
        $script:ActiveLogger = $Logger
    }
}

function Set-LoggerDestination
{
    <#
    .SYNOPSIS
    Sets a logger's destination.

    .PARAMETER Destination
    'Console', 'File', or 'Both'.

    .PARAMETER Logger
    The Logger instance to update. Defaults to the active logger.

    .EXAMPLE
    Set-LoggerDestination -Destination Both
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('Console', 'File', 'Both')]
        [string]$Destination,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), "Set destination to '$Destination'"))
    {
        $target.SetLogDestination($Destination)
    }
}

function Set-LoggerFile
{
    <#
    .SYNOPSIS
    Changes a logger's log file name.

    .DESCRIPTION
    Changes the file name only; the folder (see Set-LoggerPath) is unaffected. The mutex is
    re-acquired for the new file automatically.

    .PARAMETER FileName
    The new file name, used exactly as given (no automatic date prefix).

    .PARAMETER Logger
    The Logger instance to update. Defaults to the active logger.

    .EXAMPLE
    Set-LoggerFile -FileName 'import-run.log'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$FileName,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), "Rename log file to '$FileName'"))
    {
        $target.SetLoggingFile($FileName)
    }
}

function Set-LoggerLevel
{
    <#
    .SYNOPSIS
    Sets a logger's minimum logging level.

    .PARAMETER Level
    The new minimum level. Messages below this level will be filtered out.

    .PARAMETER Logger
    The Logger instance to update. Defaults to the active logger.

    .EXAMPLE
    Set-LoggerLevel -Level Debug
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('None', 'Critical', 'Error', 'Warning', 'Information', 'Debug', 'Verbose', 'Trace')]
        [string]$Level,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), "Set level to '$Level'"))
    {
        $target.SetLoggingLevel([LoggingLevel]::new($Level))
    }
}

function Set-LoggerPath
{
    <#
    .SYNOPSIS
    Changes the folder a logger writes its log file into.

    .DESCRIPTION
    A relative -Path is resolved against the current working directory. The mutex is
    re-acquired for the new file location automatically.

    .PARAMETER Path
    The new folder, absolute or relative.

    .PARAMETER Logger
    The Logger instance to update. Defaults to the active logger.

    .EXAMPLE
    Set-LoggerPath -Path 'C:\Logs\MyApp'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), "Move log folder to '$Path'"))
    {
        $target.SetLoggingPath($Path)
    }
}

function Set-LoggerTimeout
{
    <#
    .SYNOPSIS
    Sets how long a logger retries acquiring the mutex / writing the file before giving up.

    .PARAMETER Seconds
    Timeout in seconds.

    .PARAMETER Logger
    The Logger instance to update. Defaults to the active logger.

    .EXAMPLE
    Set-LoggerTimeout -Seconds 10
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [int]$Seconds,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), "Set write-retry timeout to $Seconds second(s)"))
    {
        $target.SetTimeOutSeconds($Seconds)
    }
}

function Write-Log
{
    <#
    .SYNOPSIS
    Writes a message through a Logger.

    .DESCRIPTION
    Writes to the console and/or log file according to the target logger's configured level
    and destination. Uses the module's active logger (see New-Logger -SetActive /
    Set-ActiveLogger) unless -Logger is supplied explicitly.

    .PARAMETER Message
    The message to write. Accepts pipeline input.

    .PARAMETER Level
    The severity of this message. Filtered against the logger's configured minimum level.
    Defaults to 'Information'.

    .PARAMETER Destination
    Overrides the logger's configured destination for this call only: 'Console', 'File', or
    'Both'.

    .PARAMETER Bare
    Write the message with no timestamp/level prefix.

    .PARAMETER Logger
    The Logger instance to write through. Defaults to the active logger.

    .EXAMPLE
    Write-Log 'Starting import' -Level Information

    .EXAMPLE
    'line one', 'line two' | Write-Log -Level Debug
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('None', 'Critical', 'Error', 'Warning', 'Information', 'Debug', 'Verbose', 'Trace')]
        [string]$Level = 'Information',

        [Parameter()]
        [ValidateSet('Console', 'File', 'Both')]
        [string]$Destination,

        [Parameter()]
        [switch]$Bare,

        [Parameter()]
        [Logger]$Logger
    )

    process
    {
        $target = Resolve-TargetLogger -Logger $Logger

        $levelObj = [LoggingLevel]::new($Level)
        $destinationObj = if ($PSBoundParameters.ContainsKey('Destination'))
        {
            [LoggingDestination]::new($Destination)
        }
        else
        {
            $target.LogDestination
        }

        $target.Write($Message, $levelObj, $destinationObj, $Bare.IsPresent)
    }
}

#endregion

Export-ModuleMember -Function @(
    'New-Logger'
    'Write-Log'
    'Get-ActiveLogger'
    'Set-ActiveLogger'
    'Get-LoggerLevel'
    'Set-LoggerLevel'
    'Get-LoggerDestination'
    'Set-LoggerDestination'
    'Get-LoggerPath'
    'Set-LoggerPath'
    'Get-LoggerFile'
    'Set-LoggerFile'
    'Get-LoggerFullPath'
    'Get-LoggerTimeout'
    'Set-LoggerTimeout'
)
