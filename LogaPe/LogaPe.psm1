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

# An independent output beyond Console/File (e.g. Event Log), each with its own minimum level
# so a logger can, say, send only Critical/Error to a sink while File still captures Verbose.
class LoggingSink
{
    [string] $Id
    [string] $Type
    [LoggingLevel] $Level
    [hashtable] $Config

    LoggingSink([string]$Type, [LoggingLevel]$Level, [hashtable]$Config)
    {
        $this.Id = [guid]::NewGuid().ToString()
        $this.Type = $Type
        $this.Level = $Level
        $this.Config = $Config
    }
}

# A regex-based scrub rule applied to message text before it reaches any destination or
# sink. -Pattern can mark a literal prefix (e.g. 'password=') to keep unmasked with a named
# '(?<Prefix>...)' group - MaskMessage() preserves that group's text and replaces only the
# rest of the match. Without a 'Prefix' group, the entire match is replaced.
class MaskRule
{
    [string] $Id
    [string] $Pattern
    [string] $Replacement
    hidden [regex] $Regex

    MaskRule([string]$Pattern, [string]$Replacement)
    {
        $this.Id = [guid]::NewGuid().ToString()
        $this.Pattern = $Pattern
        $this.Replacement = $Replacement
        $this.Regex = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
}

class LoggingObject
{
    hidden [string] $LoggingFile
    hidden [string] $LoggingMutexName
    hidden [System.Threading.Mutex] $loggingMutex
    hidden [timespan] $Timeout
    hidden [double] $MaxSizeMB = 0
    hidden [bool] $RotateDaily = $false
    hidden [int] $RetentionDays = 0
    hidden [int] $MaxArchivedFiles = 0

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

    [void]SetRotation([double]$MaxSizeMB, [bool]$RotateDaily, [int]$RetentionDays, [int]$MaxArchivedFiles)
    {
        $this.MaxSizeMB = $MaxSizeMB
        $this.RotateDaily = $RotateDaily
        $this.RetentionDays = $RetentionDays
        $this.MaxArchivedFiles = $MaxArchivedFiles
    }

    [hashtable]GetRotation()
    {
        return @{
            MaxSizeMB        = $this.MaxSizeMB
            RotateDaily      = $this.RotateDaily
            RetentionDays    = $this.RetentionDays
            MaxArchivedFiles = $this.MaxArchivedFiles
        }
    }

    # Called with the mutex already held (from WriteFile), so concurrent writers never race
    # to rotate the same file.
    hidden [void]RotateIfNeeded()
    {
        if ($this.MaxSizeMB -le 0 -and -not $this.RotateDaily)
        {
            return
        }

        if (-not (Test-Path -LiteralPath $this.LoggingFile -PathType Leaf))
        {
            return
        }

        $file = Get-Item -LiteralPath $this.LoggingFile
        $needsRotation = $false

        if ($this.MaxSizeMB -gt 0 -and ($file.Length / 1MB) -ge $this.MaxSizeMB)
        {
            $needsRotation = $true
        }

        if ($this.RotateDaily -and $file.LastWriteTime.Date -lt (Get-Date).Date)
        {
            $needsRotation = $true
        }

        if (-not $needsRotation)
        {
            return
        }

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($this.LoggingFile)
        $extension = [System.IO.Path]::GetExtension($this.LoggingFile)
        $folder = Split-Path -Parent $this.LoggingFile
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'

        # Millisecond timestamps can still collide under fast, repeated rotation (e.g. a tiny
        # -MaxSizeMB in a tight loop), so fall back to a numeric suffix rather than overwriting
        # a previous archive.
        $archiveName = '{0}.{1}{2}' -f $baseName, $stamp, $extension
        $suffix = 1
        while (Test-Path -LiteralPath (Join-Path $folder $archiveName))
        {
            $archiveName = '{0}.{1}-{2}{3}' -f $baseName, $stamp, $suffix, $extension
            $suffix++
        }

        Rename-Item -LiteralPath $this.LoggingFile -NewName $archiveName -ErrorAction Stop

        $this.PruneArchivedFiles($folder, $baseName, $extension)
    }

    hidden [void]PruneArchivedFiles([string]$Folder, [string]$BaseName, [string]$Extension)
    {
        if ($this.RetentionDays -le 0 -and $this.MaxArchivedFiles -le 0)
        {
            return
        }

        $pattern = "$BaseName.*$Extension"
        $archived = Get-ChildItem -Path $Folder -Filter $pattern -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending

        if ($this.RetentionDays -gt 0)
        {
            $cutoff = (Get-Date).AddDays(-$this.RetentionDays)
            $expired = $archived | Where-Object { $_.LastWriteTime -lt $cutoff }
            if ($expired)
            {
                $expired | Remove-Item -Force -ErrorAction SilentlyContinue
                $archived = $archived | Where-Object { $_.LastWriteTime -ge $cutoff }
            }
        }

        if ($this.MaxArchivedFiles -gt 0 -and $archived.Count -gt $this.MaxArchivedFiles)
        {
            $archived | Select-Object -Skip $this.MaxArchivedFiles | Remove-Item -Force -ErrorAction SilentlyContinue
        }
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

            $this.RotateIfNeeded()

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

    [void]Dispose()
    {
        if ($this.loggingMutex)
        {
            $this.loggingMutex.Dispose()
        }
    }
}

class Logger
{
    hidden [LoggingLevel] $ConsoleLevel
    hidden [LoggingLevel] $FileLevel
    hidden [LoggingObject] $LogFileObj
    hidden [string] $LogFileName
    hidden [string] $LogFilePath
    hidden [int] $TimeOut
    hidden [string] $OutputFormat = 'Text'
    hidden [string] $MessageFormat = '{Timestamp} | {Level} | {Message}'
    hidden [string] $TimestampFormat = 'yyyy-MM-dd HH:mm:ss'
    hidden [bool] $UseNativeStreams = $false
    hidden [System.Collections.Generic.List[LoggingSink]] $Sinks = [System.Collections.Generic.List[LoggingSink]]::new()
    hidden [System.Collections.Generic.List[MaskRule]] $MaskRules = [System.Collections.Generic.List[MaskRule]]::new()
    hidden [System.Collections.Generic.List[string]] $MaskedFieldNames = [System.Collections.Generic.List[string]]::new()
    hidden [string] $MaskReplacement = '***'

    [LoggingDestination] $LogDestination

    Logger([string]$LevelName, [string]$FileName, [string]$FolderPath, [int]$TimeOutSeconds, [string]$Destination)
    {
        $this.ConsoleLevel = [LoggingLevel]::new($LevelName)
        $this.FileLevel = [LoggingLevel]::new($LevelName)
        $this.LogFileName = $FileName
        $this.LogFilePath = $FolderPath
        $this.TimeOut = $TimeOutSeconds
        $this.LogFileObj = [LoggingObject]::new((Join-Path $FolderPath $FileName), $TimeOutSeconds)
        $this.LogDestination = [LoggingDestination]::new($Destination)
    }

    [void]SetLoggingLevel([LoggingLevel]$LoggingLevel)
    {
        $this.ConsoleLevel = $LoggingLevel
        $this.FileLevel = $LoggingLevel
    }

    [void]SetConsoleLevel([LoggingLevel]$LoggingLevel)
    {
        $this.ConsoleLevel = $LoggingLevel
    }

    [void]SetFileLevel([LoggingLevel]$LoggingLevel)
    {
        $this.FileLevel = $LoggingLevel
    }

    [string]GetLoggingLevel()
    {
        return $this.ConsoleLevel.Name()
    }

    [string]GetConsoleLevel()
    {
        return $this.ConsoleLevel.Name()
    }

    [string]GetFileLevel()
    {
        return $this.FileLevel.Name()
    }

    [void]SetOutputFormat([string]$Format)
    {
        $this.OutputFormat = $Format
    }

    [string]GetOutputFormat()
    {
        return $this.OutputFormat
    }

    [void]SetMessageFormat([string]$Format)
    {
        $this.MessageFormat = $Format
    }

    [string]GetMessageFormat()
    {
        return $this.MessageFormat
    }

    [void]SetTimestampFormat([string]$Format)
    {
        $this.TimestampFormat = $Format
    }

    [string]GetTimestampFormat()
    {
        return $this.TimestampFormat
    }

    [void]SetUseNativeStreams([bool]$Value)
    {
        $this.UseNativeStreams = $Value
    }

    [bool]GetUseNativeStreams()
    {
        return $this.UseNativeStreams
    }

    [void]SetRotation([double]$MaxSizeMB, [bool]$RotateDaily, [int]$RetentionDays, [int]$MaxArchivedFiles)
    {
        $this.LogFileObj.SetRotation($MaxSizeMB, $RotateDaily, $RetentionDays, $MaxArchivedFiles)
    }

    [hashtable]GetRotation()
    {
        return $this.LogFileObj.GetRotation()
    }

    [void]Close()
    {
        $this.LogFileObj.Dispose()
    }

    [string]AddSink([string]$Type, [LoggingLevel]$Level, [hashtable]$Config)
    {
        $sink = [LoggingSink]::new($Type, $Level, $Config)
        $this.Sinks.Add($sink)
        return $sink.Id
    }

    [void]RemoveSink([string]$Id)
    {
        $match = $this.Sinks | Where-Object { $_.Id -eq $Id }
        if ($match)
        {
            [void]$this.Sinks.Remove($match)
        }
    }

    [System.Collections.Generic.List[LoggingSink]]GetSinks()
    {
        return $this.Sinks
    }

    [string]AddMaskRule([string]$Pattern, [string]$Replacement)
    {
        $rule = [MaskRule]::new($Pattern, $Replacement)
        $this.MaskRules.Add($rule)
        return $rule.Id
    }

    [void]RemoveMaskRule([string]$Id)
    {
        $match = $this.MaskRules | Where-Object { $_.Id -eq $Id }
        if ($match)
        {
            [void]$this.MaskRules.Remove($match)
        }
    }

    [System.Collections.Generic.List[MaskRule]]GetMaskRules()
    {
        return $this.MaskRules
    }

    # $FieldName may be a PowerShell wildcard pattern (e.g. '*token*'); stored and matched
    # case-insensitively as-is. Adding a pattern already on the list (compared as literal
    # text, not by what it currently matches) is a no-op.
    [void]AddMaskField([string]$FieldName)
    {
        foreach ($name in $this.MaskedFieldNames)
        {
            if ($name -ieq $FieldName)
            {
                return
            }
        }
        $this.MaskedFieldNames.Add($FieldName)
    }

    # Removes a pattern previously passed to AddMaskField, matched as literal text - not a
    # re-evaluation of which field names it currently matches.
    [void]RemoveMaskField([string]$FieldName)
    {
        $matchingNames = @($this.MaskedFieldNames | Where-Object { $_ -ieq $FieldName })
        foreach ($name in $matchingNames)
        {
            [void]$this.MaskedFieldNames.Remove($name)
        }
    }

    [string[]]GetMaskFields()
    {
        return $this.MaskedFieldNames.ToArray()
    }

    [void]SetMaskReplacement([string]$Replacement)
    {
        $this.MaskReplacement = $Replacement
    }

    [string]GetMaskReplacement()
    {
        return $this.MaskReplacement
    }

    # Applied to the fully-assembled message (including any -ErrorRecord/-Exception detail)
    # before FormatMessage builds Text/Json output, so every destination and sink sees the
    # same scrubbed text.
    hidden [string]MaskMessage([string]$Text)
    {
        if ($this.MaskRules.Count -eq 0 -or -not $Text)
        {
            return $Text
        }

        foreach ($rule in $this.MaskRules)
        {
            $replacement = if ($rule.Replacement) { $rule.Replacement } else { $this.MaskReplacement }
            $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
                param($match)
                $prefixGroup = $match.Groups['Prefix']
                if ($prefixGroup.Success)
                {
                    return $prefixGroup.Value + $replacement
                }
                return $replacement
            }
            $Text = $rule.Regex.Replace($Text, $evaluator)
        }
        return $Text
    }

    # Replaces a -Fields value wholesale when its key matches an entry on the masked-field
    # list, regardless of the value's original type - more reliable than a text regex for
    # structured values. Entries support PowerShell wildcards (e.g. '*token*'), matched
    # case-insensitively; a plain name with no wildcard characters behaves as an exact match.
    hidden [object]MaskFieldValue([string]$Key, [object]$Value)
    {
        foreach ($pattern in $this.MaskedFieldNames)
        {
            if ($Key -ilike $pattern)
            {
                return $this.MaskReplacement
            }
        }
        return $Value
    }

    # Registers the built-in preset of common secret keywords (password, pwd, secret, token,
    # apikey/api_key, connectionstring) as both message-text rules and wildcard-matched
    # -Fields entries. Factored out of Add-LoggerDefaultMaskRule so New-Logger
    # -EnableDefaultMasking can apply the same preset at construction time.
    [void]AddDefaultMaskRules()
    {
        $keywords = 'password', 'pwd', 'secret', 'token', 'apikey', 'api_key', 'connectionstring'
        foreach ($keyword in $keywords)
        {
            # Matches key=value / key: value / "key": "value" text. The 'Prefix' group covers
            # the key, separator, and any opening quote, so only the value itself is replaced.
            $pattern = '(?i)(?<Prefix>"?' + $keyword + '"?\s*[:=]\s*"?)[^\s",}]+'
            $this.AddMaskRule($pattern, $null)
            $this.AddMaskField('*' + $keyword + '*')
        }
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
        return "`r`n`tConsoleLevel | $($this.ConsoleLevel.Name())" +
               "`r`n`tFileLevel    | $($this.FileLevel.Name())" +
               "`r`n`tFileName     | $($this.LogFileName)" +
               "`r`n`tPath         | $($this.LogFilePath)" +
               "`r`n`tDestination  | $($this.LogDestination.LogDestination)" +
               "`r`n`tOutputFormat | $($this.OutputFormat)" +
               "`r`n`tSinks        | $($this.Sinks.Count)" +
               "`r`n`tMaskRules    | $($this.MaskRules.Count)" +
               "`r`n`tMaskFields   | $($this.MaskedFieldNames.Count)" +
               "`r`n`tMutexName    | $($this.LogFileObj.GetLoggingMutexName())"
    }

    # Method overloads collapse onto the 6-argument form so the level-filter check and the
    # write path each exist in exactly one place.
    [void]Write([string]$Message)
    {
        $this.Write($Message, [LoggingLevel]::new('Information'), $this.LogDestination, $false, $null, $false)
    }

    [void]Write([string]$Message, [LoggingLevel]$Level)
    {
        $this.Write($Message, $Level, $this.LogDestination, $false, $null, $false)
    }

    [void]Write([string]$Message, [LoggingLevel]$Level, [LoggingDestination]$Destination)
    {
        $this.Write($Message, $Level, $Destination, $false, $null, $false)
    }

    [void]Write([string]$Message, [LoggingLevel]$Level, [LoggingDestination]$Destination, [bool]$Bare)
    {
        $this.Write($Message, $Level, $Destination, $Bare, $null, $false)
    }

    [void]Write([string]$Message, [LoggingLevel]$Level, [LoggingDestination]$Destination, [bool]$Bare, [hashtable]$Fields)
    {
        $this.Write($Message, $Level, $Destination, $Bare, $Fields, $false)
    }

    [void]Write([string]$Message, [LoggingLevel]$Level, [LoggingDestination]$Destination, [bool]$Bare, [hashtable]$Fields, [bool]$SkipMasking)
    {
        $writeConsole = $Destination.Console() -and ($this.ConsoleLevel.Level() -le $Level.Level())
        $writeFile = $Destination.File() -and ($this.FileLevel.Level() -le $Level.Level())
        $activeSinks = @($this.Sinks | Where-Object { $_.Level.Level() -le $Level.Level() })

        if (-not $writeConsole -and -not $writeFile -and $activeSinks.Count -eq 0)
        {
            return
        }

        $this._WriteOutput($Message, $Level, $writeConsole, $writeFile, $Bare, $Fields, $activeSinks, $SkipMasking)
    }

    hidden [void]_WriteOutput([string]$Message, [LoggingLevel]$Level, [bool]$WriteConsole, [bool]$WriteFile, [bool]$Bare, [hashtable]$Fields, [array]$ActiveSinks, [bool]$SkipMasking)
    {
        $formatted = $this.FormatMessage($Message, $Level, $Bare, $Fields, $SkipMasking)

        if ($WriteConsole)
        {
            if ($this.UseNativeStreams)
            {
                $this.WriteNativeStream($formatted, $Level)
            }
            else
            {
                $this.LogFileObj.WriteConsole($formatted, $Level)
            }
        }

        if ($WriteFile)
        {
            $this.LogFileObj.WriteFile($formatted)
        }

        foreach ($sink in $ActiveSinks)
        {
            $this.WriteToSink($sink, $formatted, $Level)
        }
    }

    hidden [string]FormatMessage([string]$Message, [LoggingLevel]$Level, [bool]$Bare, [hashtable]$Fields, [bool]$SkipMasking)
    {
        $maskedMessage = if ($SkipMasking) { $Message } else { $this.MaskMessage($Message) }

        if ($this.OutputFormat -eq 'Json')
        {
            $record = [ordered]@{}
            if (-not $Bare)
            {
                $record['Timestamp'] = Get-Date -Format $this.TimestampFormat
                $record['Level'] = $Level.Name()
            }
            $record['Message'] = $maskedMessage

            if ($Fields)
            {
                foreach ($key in $Fields.Keys)
                {
                    $record[$key] = if ($SkipMasking) { $Fields[$key] } else { $this.MaskFieldValue($key, $Fields[$key]) }
                }
            }

            return ($record | ConvertTo-Json -Compress)
        }

        if ($Bare)
        {
            $text = $maskedMessage
        }
        else
        {
            $text = $this.MessageFormat.
                Replace('{Timestamp}', (Get-Date -Format $this.TimestampFormat)).
                Replace('{Level}', $Level.Name().PadLeft(11, ' ')).
                Replace('{Message}', $maskedMessage)
        }

        if ($Fields)
        {
            $fieldText = ($Fields.Keys | ForEach-Object {
                    $value = if ($SkipMasking) { $Fields[$_] } else { $this.MaskFieldValue($_, $Fields[$_]) }
                    "$_=$value"
                }) -join ', '
            $text = "$text | $fieldText"
        }

        return $text
    }

    # Emits through PowerShell's real Warning/Error/Verbose/Debug/Information streams instead
    # of colored Write-Host, so -WarningAction/-ErrorAction/$WarningPreference/transcripts see
    # it. There is no native stream for Critical, so it's emitted as an Error with a prefix.
    hidden [void]WriteNativeStream([string]$FormattedMessage, [LoggingLevel]$Level)
    {
        $levelName = $Level.Name()
        if ($levelName -eq 'Trace' -or $levelName -eq 'Verbose')
        {
            Write-Verbose $FormattedMessage
        }
        elseif ($levelName -eq 'Debug')
        {
            Write-Debug $FormattedMessage
        }
        elseif ($levelName -eq 'Warning')
        {
            Write-Warning $FormattedMessage
        }
        elseif ($levelName -eq 'Error')
        {
            Write-Error $FormattedMessage
        }
        elseif ($levelName -eq 'Critical')
        {
            Write-Error "[CRITICAL] $FormattedMessage"
        }
        else
        {
            Write-Information $FormattedMessage
        }
    }

    # A write failure here (e.g. the Event Log source was never successfully registered)
    # shouldn't take down the caller's script - warn and move on, same as WriteFile's own
    # failure handling philosophy.
    hidden [void]WriteToSink([LoggingSink]$Sink, [string]$FormattedMessage, [LoggingLevel]$Level)
    {
        if ($Sink.Type -eq 'EventLog')
        {
            $levelName = $Level.Name()
            $entryType = if ($levelName -eq 'Critical' -or $levelName -eq 'Error')
            {
                'Error'
            }
            elseif ($levelName -eq 'Warning')
            {
                'Warning'
            }
            else
            {
                'Information'
            }

            try
            {
                Write-EventLog -LogName $Sink.Config.LogName -Source $Sink.Config.Source `
                    -EventId $Sink.Config.EventId -EntryType $entryType -Message $FormattedMessage -ErrorAction Stop
            }
            catch
            {
                Write-Warning "Failed to write to Event Log sink '$($Sink.Config.Source)': $($_.Exception.Message)"
            }
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

function Get-LoggerContent
{
    <#
    .SYNOPSIS
    Reads, or follows, a logger's log file.

    .DESCRIPTION
    A thin wrapper over Get-Content pointed at the logger's file, so you don't have to look up
    the path yourself. Supports the same -Tail/-Wait semantics as Get-Content.

    .PARAMETER Tail
    Only return the last N lines. Omit to return the whole file.

    .PARAMETER Wait
    Keep the file open and emit new lines as they're written (like `tail -f`), blocking until
    interrupted (e.g. Ctrl+C) or the pipeline is stopped.

    .PARAMETER AsObject
    Parse each line as JSON and emit the resulting object instead of the raw string. Intended
    for loggers using -OutputFormat Json (see Set-LoggerOutputFormat). A line that isn't valid
    JSON is returned as its raw string, with a warning, rather than aborting the read.

    .PARAMETER Logger
    The Logger instance to read. Defaults to the active logger.

    .EXAMPLE
    Get-LoggerContent -Tail 20

    .EXAMPLE
    Get-LoggerContent -Wait

    .EXAMPLE
    Get-LoggerContent -AsObject | Where-Object Level -eq 'Error'

    .OUTPUTS
    System.String, or a parsed object per line when -AsObject is used.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [int]$Tail,

        [Parameter()]
        [Alias('Follow')]
        [switch]$Wait,

        [Parameter()]
        [switch]$AsObject,

        [Parameter()]
        [Logger]$Logger
    )

    $path = (Resolve-TargetLogger -Logger $Logger).GetLoggingFullPath()

    $getContentParams = @{
        LiteralPath = $path
        Wait        = $Wait.IsPresent
    }
    if ($PSBoundParameters.ContainsKey('Tail'))
    {
        $getContentParams['Tail'] = $Tail
    }

    Get-Content @getContentParams | ForEach-Object {
        $line = $_
        if (-not $AsObject)
        {
            return $line
        }

        try
        {
            $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch
        {
            # $_ here is the caught error, not the pipeline item - use $line instead.
            Write-Warning "Line is not valid JSON, returning raw text: $line"
            $line
        }
    }
}

function Get-LoggerLevel
{
    <#
    .SYNOPSIS
    Gets a logger's minimum logging level.

    .DESCRIPTION
    Console and file can be configured at different levels (see Set-LoggerLevel -Destination).
    With -Destination Both (the default), this returns a single string when both destinations
    share the same level, or a [pscustomobject] with Console/File properties when they differ.

    .PARAMETER Destination
    Which destination's level to return: 'Console', 'File', or 'Both' (default).

    .PARAMETER Logger
    The Logger instance to query. Defaults to the active logger.

    .OUTPUTS
    System.String, or a [pscustomobject] with Console/File properties when they differ and
    -Destination Both was used.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('Console', 'File', 'Both')]
        [string]$Destination = 'Both',

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger

    if ($Destination -eq 'Console')
    {
        return $target.GetConsoleLevel()
    }

    if ($Destination -eq 'File')
    {
        return $target.GetFileLevel()
    }

    $consoleLevel = $target.GetConsoleLevel()
    $fileLevel = $target.GetFileLevel()
    if ($consoleLevel -eq $fileLevel)
    {
        return $consoleLevel
    }

    return [pscustomobject]@{
        Console = $consoleLevel
        File    = $fileLevel
    }
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

    .PARAMETER MaxSizeMB
    Roll the log file over once it reaches this size, in megabytes. 0 (default) disables
    size-based rotation. Can be combined with -RotateDaily.

    .PARAMETER RotateDaily
    Roll the log file over the first time it's written to on a new calendar day.

    .PARAMETER RetentionDays
    Delete rolled-over (archived) log files older than this many days. 0 (default) disables
    age-based cleanup. Only affects archived files, never the current log file.

    .PARAMETER MaxArchivedFiles
    Keep at most this many rolled-over (archived) log files, deleting the oldest first once
    exceeded. 0 (default) disables count-based cleanup.

    .PARAMETER OutputFormat
    'Text' (default) writes human-readable lines. 'Json' writes one JSON object per line
    (Timestamp, Level, Message, plus any -Fields passed to Write-Log) to every active
    destination, including the console.

    .PARAMETER MessageFormat
    Template for 'Text' output. Supports {Timestamp}, {Level}, {Message} tokens. Defaults to
    '{Timestamp} | {Level} | {Message}'. Ignored in 'Json' mode and by -Bare writes.

    .PARAMETER TimestampFormat
    .NET date format string used for the {Timestamp} token and the Json 'Timestamp' field.
    Defaults to 'yyyy-MM-dd HH:mm:ss'.

    .PARAMETER UseNativeStreams
    Route console output through PowerShell's real Write-Verbose/-Debug/-Warning/-Error/
    -Information cmdlets (chosen by message level) instead of colored Write-Host. This makes
    -WarningAction/-ErrorAction/$WarningPreference/transcripts see the messages, but Write-
    Information is silent by default unless $InformationPreference/-InformationAction says
    otherwise - that's native Write-Information behavior, not a bug.

    .PARAMETER EnableDefaultMasking
    Apply the same curated masking preset as Add-LoggerDefaultMaskRule (common secret
    keywords - password, pwd, secret, token, apikey/api_key, connectionstring - as both
    message-text rules and wildcard-matched -Fields entries) at creation time, instead of
    calling it separately afterwards.

    .EXAMPLE
    $logger = New-Logger -Level Verbose -Destination Both -SetActive
    Write-Log 'Hello world'

    .EXAMPLE
    New-Logger -Destination File -MaxSizeMB 10 -RetentionDays 30 -SetActive

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
        [switch]$SetActive,

        [Parameter()]
        [double]$MaxSizeMB = 0,

        [Parameter()]
        [switch]$RotateDaily,

        [Parameter()]
        [int]$RetentionDays = 0,

        [Parameter()]
        [int]$MaxArchivedFiles = 0,

        [Parameter()]
        [ValidateSet('Text', 'Json')]
        [string]$OutputFormat = 'Text',

        [Parameter()]
        [string]$MessageFormat,

        [Parameter()]
        [string]$TimestampFormat,

        [Parameter()]
        [switch]$UseNativeStreams,

        [Parameter()]
        [switch]$EnableDefaultMasking
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

        if ($MaxSizeMB -gt 0 -or $RotateDaily -or $RetentionDays -gt 0 -or $MaxArchivedFiles -gt 0)
        {
            $logger.SetRotation($MaxSizeMB, $RotateDaily.IsPresent, $RetentionDays, $MaxArchivedFiles)
        }

        $logger.SetOutputFormat($OutputFormat)

        if ($PSBoundParameters.ContainsKey('MessageFormat'))
        {
            $logger.SetMessageFormat($MessageFormat)
        }

        if ($PSBoundParameters.ContainsKey('TimestampFormat'))
        {
            $logger.SetTimestampFormat($TimestampFormat)
        }

        if ($UseNativeStreams)
        {
            $logger.SetUseNativeStreams($true)
        }

        if ($EnableDefaultMasking)
        {
            $logger.AddDefaultMaskRules()
        }

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

    .DESCRIPTION
    Console and file can be filtered independently - e.g. a quiet console at Warning while the
    file captures everything at Verbose - by calling this twice with different -Destination
    values.

    .PARAMETER Level
    The new minimum level. Messages below this level will be filtered out.

    .PARAMETER Destination
    Which destination to apply this to: 'Console', 'File', or 'Both' (default - matches the
    original single-level behavior).

    .PARAMETER Logger
    The Logger instance to update. Defaults to the active logger.

    .EXAMPLE
    Set-LoggerLevel -Level Debug

    .EXAMPLE
    Set-LoggerLevel -Level Warning -Destination Console
    Set-LoggerLevel -Level Verbose -Destination File
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('None', 'Critical', 'Error', 'Warning', 'Information', 'Debug', 'Verbose', 'Trace')]
        [string]$Level,

        [Parameter(Position = 1)]
        [ValidateSet('Console', 'File', 'Both')]
        [string]$Destination = 'Both',

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), "Set $Destination level to '$Level'"))
    {
        $levelObj = [LoggingLevel]::new($Level)
        if ($Destination -eq 'Console' -or $Destination -eq 'Both')
        {
            $target.SetConsoleLevel($levelObj)
        }
        if ($Destination -eq 'File' -or $Destination -eq 'Both')
        {
            $target.SetFileLevel($levelObj)
        }
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

function Get-LoggerRotation
{
    <#
    .SYNOPSIS
    Gets a logger's rotation and retention settings.

    .PARAMETER Logger
    The Logger instance to query. Defaults to the active logger.

    .OUTPUTS
    A [pscustomobject] with MaxSizeMB, RotateDaily, RetentionDays, and MaxArchivedFiles.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Logger]$Logger
    )

    [pscustomobject](Resolve-TargetLogger -Logger $Logger).GetRotation()
}

function Set-LoggerRotation
{
    <#
    .SYNOPSIS
    Configures a logger's rotation and retention settings.

    .DESCRIPTION
    Rotation is checked on each write (under the file mutex, so concurrent writers never race
    to rotate the same file). Rolled-over files are named
    '<name>.<yyyyMMdd-HHmmss><extension>' next to the active log file. Any parameter you omit
    keeps its current value - this updates settings incrementally rather than requiring all
    four every time.

    .PARAMETER MaxSizeMB
    Roll the file over once it reaches this size, in megabytes. 0 disables size-based rotation.

    .PARAMETER RotateDaily
    Roll the file over the first time it's written to on a new calendar day.

    .PARAMETER RetentionDays
    Delete archived files older than this many days. 0 disables age-based cleanup.

    .PARAMETER MaxArchivedFiles
    Keep at most this many archived files, deleting the oldest first. 0 disables count-based
    cleanup.

    .PARAMETER Logger
    The Logger instance to update. Defaults to the active logger.

    .EXAMPLE
    Set-LoggerRotation -MaxSizeMB 10 -RetentionDays 30
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [double]$MaxSizeMB,

        [Parameter()]
        [bool]$RotateDaily,

        [Parameter()]
        [int]$RetentionDays,

        [Parameter()]
        [int]$MaxArchivedFiles,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    $current = $target.GetRotation()

    $effectiveMaxSizeMB = if ($PSBoundParameters.ContainsKey('MaxSizeMB')) { $MaxSizeMB } else { $current.MaxSizeMB }
    $effectiveRotateDaily = if ($PSBoundParameters.ContainsKey('RotateDaily')) { $RotateDaily } else { $current.RotateDaily }
    $effectiveRetentionDays = if ($PSBoundParameters.ContainsKey('RetentionDays')) { $RetentionDays } else { $current.RetentionDays }
    $effectiveMaxArchivedFiles = if ($PSBoundParameters.ContainsKey('MaxArchivedFiles')) { $MaxArchivedFiles } else { $current.MaxArchivedFiles }

    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), 'Set rotation settings'))
    {
        $target.SetRotation($effectiveMaxSizeMB, $effectiveRotateDaily, $effectiveRetentionDays, $effectiveMaxArchivedFiles)
    }
}

function Get-LoggerOutputFormat
{
    <#
    .SYNOPSIS
    Gets a logger's output format ('Text' or 'Json').

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

    (Resolve-TargetLogger -Logger $Logger).GetOutputFormat()
}

function Set-LoggerOutputFormat
{
    <#
    .SYNOPSIS
    Sets a logger's output format.

    .DESCRIPTION
    'Text' (default) writes human-readable lines using the logger's message format (see
    Set-LoggerMessageFormat). 'Json' writes one JSON object per line (Timestamp, Level,
    Message, plus any -Fields passed to Write-Log) to every active destination.

    .PARAMETER Format
    'Text' or 'Json'.

    .PARAMETER Logger
    The Logger instance to update. Defaults to the active logger.

    .EXAMPLE
    Set-LoggerOutputFormat -Format Json
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('Text', 'Json')]
        [string]$Format,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), "Set output format to '$Format'"))
    {
        $target.SetOutputFormat($Format)
    }
}

function Get-LoggerMessageFormat
{
    <#
    .SYNOPSIS
    Gets a logger's text message template and timestamp format.

    .PARAMETER Logger
    The Logger instance to query. Defaults to the active logger.

    .OUTPUTS
    A [pscustomobject] with Format and TimestampFormat.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    [pscustomobject]@{
        Format          = $target.GetMessageFormat()
        TimestampFormat = $target.GetTimestampFormat()
    }
}

function Set-LoggerMessageFormat
{
    <#
    .SYNOPSIS
    Sets a logger's text message template and/or timestamp format.

    .DESCRIPTION
    Only applies to 'Text' output (see Set-LoggerOutputFormat) and is ignored by -Bare writes.
    Any parameter you omit keeps its current value.

    .PARAMETER Format
    Template supporting {Timestamp}, {Level}, {Message} tokens.

    .PARAMETER TimestampFormat
    .NET date format string used for the {Timestamp} token.

    .PARAMETER Logger
    The Logger instance to update. Defaults to the active logger.

    .EXAMPLE
    Set-LoggerMessageFormat -Format '[{Timestamp}][{Level}] {Message}' -TimestampFormat 'o'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string]$Format,

        [Parameter()]
        [string]$TimestampFormat,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), 'Set message format'))
    {
        if ($PSBoundParameters.ContainsKey('Format'))
        {
            $target.SetMessageFormat($Format)
        }
        if ($PSBoundParameters.ContainsKey('TimestampFormat'))
        {
            $target.SetTimestampFormat($TimestampFormat)
        }
    }
}

function Get-LoggerNativeStreamMode
{
    <#
    .SYNOPSIS
    Gets whether a logger routes console output through native PowerShell streams.

    .PARAMETER Logger
    The Logger instance to query. Defaults to the active logger.

    .OUTPUTS
    System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)]
        [Logger]$Logger
    )

    (Resolve-TargetLogger -Logger $Logger).GetUseNativeStreams()
}

function Set-LoggerNativeStreamMode
{
    <#
    .SYNOPSIS
    Enables or disables native-PowerShell-stream console output for a logger.

    .DESCRIPTION
    When enabled, console messages are routed through Write-Verbose/-Debug/-Warning/-Error/
    -Information (chosen by level) instead of colored Write-Host, so -WarningAction/
    -ErrorAction/$WarningPreference/transcripts see them. Write-Information is silent by
    default unless $InformationPreference/-InformationAction says otherwise - that's native
    behavior, not a bug.

    .PARAMETER Enabled
    $true to use native streams, $false to use colored Write-Host (the default).

    .PARAMETER Logger
    The Logger instance to update. Defaults to the active logger.

    .EXAMPLE
    Set-LoggerNativeStreamMode -Enabled $true
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [bool]$Enabled,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), "Set native streams to $Enabled"))
    {
        $target.SetUseNativeStreams($Enabled)
    }
}

function Remove-Logger
{
    <#
    .SYNOPSIS
    Disposes a logger's file mutex handle.

    .DESCRIPTION
    Each Logger opens a named Mutex that is never otherwise released for the life of the
    process. Call this when you're done with a logger in a long-running session (e.g. a
    service that creates many short-lived loggers) to avoid accumulating open handles. If the
    logger being removed is the active logger, the active logger is cleared.

    .PARAMETER Logger
    The Logger instance to dispose. Defaults to the active logger.

    .EXAMPLE
    Remove-Logger -Logger $logger
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), 'Dispose logger mutex handle'))
    {
        $target.Close()
        if ($script:ActiveLogger -eq $target)
        {
            $script:ActiveLogger = $null
        }
    }
}

function Add-LoggerEventLogSink
{
    <#
    .SYNOPSIS
    Sends a logger's messages to the Windows Event Log as well.

    .DESCRIPTION
    Registers an independent sink with its own minimum level, separate from the logger's
    Console/File levels - e.g. only send Critical/Error to the Event Log while File keeps
    capturing everything at Verbose. A logger can have any number of sinks.

    If -Source isn't already a registered event source, this attempts to register it via
    New-EventLog, which requires local administrator rights. On failure, it emits a warning
    explaining how to pre-register the source manually and still adds the sink - later writes
    will retry and fail individually (with their own warning) rather than the registration
    failure blocking your script.

    .PARAMETER Source
    The event source name to write under.

    .PARAMETER LogName
    The Windows Event Log to write to. Defaults to 'Application'.

    .PARAMETER Level
    Minimum level that reaches this sink. Defaults to 'Warning' - Event Logs are usually for
    things worth someone's attention, not routine Verbose/Debug/Information noise.

    .PARAMETER EventId
    Numeric event ID recorded with each entry. Defaults to 1.

    .PARAMETER Logger
    The Logger instance to add this sink to. Defaults to the active logger.

    .EXAMPLE
    Add-LoggerEventLogSink -Source 'MyApp' -Level Error

    .OUTPUTS
    System.String - the new sink's Id, for use with Remove-LoggerSink.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Source,

        [Parameter()]
        [string]$LogName = 'Application',

        [Parameter()]
        [ValidateSet('None', 'Critical', 'Error', 'Warning', 'Information', 'Debug', 'Verbose', 'Trace')]
        [string]$Level = 'Warning',

        [Parameter()]
        [int]$EventId = 1,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger

    if (-not $PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), "Add Event Log sink (Source '$Source')"))
    {
        return $null
    }

    try
    {
        if (-not [System.Diagnostics.EventLog]::SourceExists($Source))
        {
            New-EventLog -LogName $LogName -Source $Source -ErrorAction Stop
        }
    }
    catch
    {
        # The -f operator binds tighter than +, so the format string must be fully parenthesized
        # before formatting - otherwise it silently only formats the last concatenated fragment.
        $template = "Could not register event source '{0}' automatically (requires local " +
            "administrator rights): {1}. Pre-register it manually as Administrator: " +
            "New-EventLog -LogName '{2}' -Source '{0}'. The sink is still added; writes will " +
            'fail individually (with their own warning) until the source exists.'
        Write-Warning ($template -f $Source, $_.Exception.Message, $LogName)
    }

    $config = @{ Source = $Source; LogName = $LogName; EventId = $EventId }
    $target.AddSink('EventLog', [LoggingLevel]::new($Level), $config)
}

function Get-LoggerSink
{
    <#
    .SYNOPSIS
    Lists the sinks registered on a logger.

    .PARAMETER Logger
    The Logger instance to query. Defaults to the active logger.

    .EXAMPLE
    Get-LoggerSink

    .OUTPUTS
    A [pscustomobject] per sink, with Id, Type, Level, and Config.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    foreach ($sink in $target.GetSinks())
    {
        [pscustomobject]@{
            Id     = $sink.Id
            Type   = $sink.Type
            Level  = $sink.Level.Name()
            Config = $sink.Config
        }
    }
}

function Remove-LoggerSink
{
    <#
    .SYNOPSIS
    Removes a sink previously added with an Add-Logger*Sink function (e.g.
    Add-LoggerEventLogSink).

    .PARAMETER Id
    The sink's Id, as returned by the function that added it, or from Get-LoggerSink.

    .PARAMETER Logger
    The Logger instance to remove it from. Defaults to the active logger.

    .EXAMPLE
    $sinkId = Add-LoggerEventLogSink -Source 'MyApp'
    Remove-LoggerSink -Id $sinkId
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Id,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), "Remove sink '$Id'"))
    {
        $target.RemoveSink($Id)
    }
}

function Add-LoggerMaskRule
{
    <#
    .SYNOPSIS
    Adds a regex-based masking rule that scrubs sensitive values out of logged message text.

    .DESCRIPTION
    Applied to every message (including any -ErrorRecord/-Exception detail) before it's
    written to any destination or sink, regardless of -OutputFormat. To exclude a literal
    prefix (e.g. 'password=') from being replaced, wrap it in a named '(?<Prefix>...)' group in
    -Pattern - that group's text is preserved and only the remainder of the match is replaced.
    Without a 'Prefix' group, the entire match is replaced.

    To mask a named key in -Fields hashtables instead of free text, use Add-LoggerMaskField.
    See also Add-LoggerDefaultMaskRule for a ready-made preset covering common secrets.

    .PARAMETER Pattern
    A .NET regex (matched case-insensitively). Whatever it matches is replaced by
    -Replacement, except for the text captured by an optional named '(?<Prefix>...)' group.

    .PARAMETER Replacement
    Text to substitute for each match (after any 'Prefix' group). Defaults to the logger's
    mask replacement (see Set-LoggerMaskReplacement, itself defaulting to '***').

    .PARAMETER Logger
    The Logger instance to add this rule to. Defaults to the active logger.

    .EXAMPLE
    Add-LoggerMaskRule -Pattern '(?i)(?<Prefix>password\s*[:=]\s*)\S+'

    .OUTPUTS
    System.String - the new rule's Id, for use with Remove-LoggerMaskRule.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Pattern,

        [Parameter()]
        [string]$Replacement,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), "Add mask rule for pattern '$Pattern'"))
    {
        $target.AddMaskRule($Pattern, $Replacement)
    }
}

function Get-LoggerMaskRule
{
    <#
    .SYNOPSIS
    Lists the message-text masking rules registered on a logger.

    .PARAMETER Logger
    The Logger instance to query. Defaults to the active logger.

    .EXAMPLE
    Get-LoggerMaskRule

    .OUTPUTS
    A [pscustomobject] per rule, with Id, Pattern, and Replacement.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    foreach ($rule in $target.GetMaskRules())
    {
        [pscustomobject]@{
            Id          = $rule.Id
            Pattern     = $rule.Pattern
            Replacement = if ($rule.Replacement) { $rule.Replacement } else { $target.GetMaskReplacement() }
        }
    }
}

function Remove-LoggerMaskRule
{
    <#
    .SYNOPSIS
    Removes a masking rule previously added with Add-LoggerMaskRule.

    .PARAMETER Id
    The rule's Id, as returned by Add-LoggerMaskRule or from Get-LoggerMaskRule.

    .PARAMETER Logger
    The Logger instance to remove it from. Defaults to the active logger.

    .EXAMPLE
    $ruleId = Add-LoggerMaskRule -Pattern '(?i)password\s*[:=]\s*\K\S+'
    Remove-LoggerMaskRule -Id $ruleId
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Id,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), "Remove mask rule '$Id'"))
    {
        $target.RemoveMaskRule($Id)
    }
}

function Add-LoggerMaskField
{
    <#
    .SYNOPSIS
    Marks a -Fields key (see Write-Log) as sensitive, so its value is always masked.

    .DESCRIPTION
    Unlike Add-LoggerMaskRule, which pattern-matches free text, this replaces the entire value
    of any -Fields entry whose key matches -FieldName - in both 'Text' and 'Json' output.
    Useful for structured values like `-Fields @{ Password = $plainText }` that a text regex
    could miss depending on formatting.

    .PARAMETER FieldName
    The -Fields key to mask, matched case-insensitively. Supports PowerShell wildcards (e.g.
    '*token*' matches AccessToken, RefreshToken, ApiTokenValue, ...); a plain name with no
    wildcard characters matches only that exact key. Adding a pattern that's already present
    (compared as literal text) is a no-op.

    .PARAMETER Logger
    The Logger instance to update. Defaults to the active logger.

    .EXAMPLE
    Add-LoggerMaskField -FieldName Password
    Write-Log 'login attempt' -Fields @{ Password = $plainText }

    .EXAMPLE
    Add-LoggerMaskField -FieldName '*token*'
    Write-Log 'refreshed' -Fields @{ AccessToken = $token }   # AccessToken matches '*token*'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$FieldName,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), "Mask field '$FieldName'"))
    {
        $target.AddMaskField($FieldName)
    }
}

function Get-LoggerMaskField
{
    <#
    .SYNOPSIS
    Lists the -Fields key patterns being masked on a logger.

    .DESCRIPTION
    Returns the patterns as registered by Add-LoggerMaskField, which may include wildcards
    (e.g. '*token*') rather than only exact key names.

    .PARAMETER Logger
    The Logger instance to query. Defaults to the active logger.

    .OUTPUTS
    System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [Logger]$Logger
    )

    (Resolve-TargetLogger -Logger $Logger).GetMaskFields()
}

function Remove-LoggerMaskField
{
    <#
    .SYNOPSIS
    Stops masking a -Fields key pattern previously added with Add-LoggerMaskField.

    .PARAMETER FieldName
    The exact pattern to remove, as originally passed to Add-LoggerMaskField (case-insensitive
    literal match - this does not re-evaluate a wildcard against current field names).

    .PARAMETER Logger
    The Logger instance to update. Defaults to the active logger.

    .EXAMPLE
    Remove-LoggerMaskField -FieldName Password
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$FieldName,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), "Unmask field '$FieldName'"))
    {
        $target.RemoveMaskField($FieldName)
    }
}

function Get-LoggerMaskReplacement
{
    <#
    .SYNOPSIS
    Gets a logger's default mask replacement text.

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

    (Resolve-TargetLogger -Logger $Logger).GetMaskReplacement()
}

function Set-LoggerMaskReplacement
{
    <#
    .SYNOPSIS
    Sets the text substituted for masked values.

    .DESCRIPTION
    Used by Add-LoggerMaskField, and by any Add-LoggerMaskRule that didn't specify its own
    -Replacement. Defaults to '***'.

    .PARAMETER Replacement
    The replacement text.

    .PARAMETER Logger
    The Logger instance to update. Defaults to the active logger.

    .EXAMPLE
    Set-LoggerMaskReplacement -Replacement '[REDACTED]'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Replacement,

        [Parameter()]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), "Set mask replacement to '$Replacement'"))
    {
        $target.SetMaskReplacement($Replacement)
    }
}

function Add-LoggerDefaultMaskRule
{
    <#
    .SYNOPSIS
    Adds a curated set of masking rules/fields covering common secrets (passwords, tokens,
    API keys, connection strings).

    .DESCRIPTION
    A convenience preset over Add-LoggerMaskRule/Add-LoggerMaskField for the common case of
    "don't let credentials reach the log". Covers 'key=value', 'key: value', and
    '"key": "value"' style text (e.g. 'password=hunter2', '"apiKey": "abc123"') as well as
    -Fields keys containing password, pwd, secret, token, apikey/api_key, or connectionstring
    (matched with wildcards, e.g. 'AccessToken' and 'ApiTokenValue' both match 'token').

    Review Get-LoggerMaskRule/Get-LoggerMaskField afterwards, and add more with
    Add-LoggerMaskRule/Add-LoggerMaskField for anything specific to your application that this
    preset doesn't cover. See also New-Logger -EnableDefaultMasking to apply this preset at
    logger creation time instead of calling it separately.

    .PARAMETER Logger
    The Logger instance to update. Defaults to the active logger.

    .EXAMPLE
    Add-LoggerDefaultMaskRule
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [Logger]$Logger
    )

    $target = Resolve-TargetLogger -Logger $Logger
    if ($PSCmdlet.ShouldProcess($target.GetLoggingFullPath(), 'Add default mask rules'))
    {
        $target.AddDefaultMaskRules()
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

    .PARAMETER ErrorRecord
    An $ErrorRecord (e.g. $_ in a catch block) whose exception type, message, category, and
    script stack trace are appended to the message. If -Level isn't explicitly specified, it
    defaults to 'Error' instead of 'Information' when this is used.

    .PARAMETER Exception
    An exception whose type, message, and .NET stack trace are appended to the message. If
    -Level isn't explicitly specified, it defaults to 'Error' instead of 'Information' when
    this is used.

    .PARAMETER Fields
    Extra structured data for this message. In 'Json' output mode (see Set-LoggerOutputFormat)
    these become additional JSON properties; in 'Text' mode they're appended as 'key=value'
    pairs.

    .PARAMETER SkipMasking
    Bypass the target logger's mask rules/fields (see Add-LoggerMaskRule/Add-LoggerMaskField)
    for this call only - useful when debugging a value you deliberately need to see unmasked.
    The logger's rules/fields are untouched; this only affects the current write.

    .PARAMETER Logger
    The Logger instance to write through. Defaults to the active logger.

    .EXAMPLE
    Write-Log 'Starting import' -Level Information

    .EXAMPLE
    'line one', 'line two' | Write-Log -Level Debug

    .EXAMPLE
    try { ... } catch { Write-Log 'Import failed' -ErrorRecord $_ }

    .EXAMPLE
    Write-Log 'User logged in' -Fields @{ UserId = 42; Source = 'CLI' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Message = '',

        [Parameter()]
        [ValidateSet('None', 'Critical', 'Error', 'Warning', 'Information', 'Debug', 'Verbose', 'Trace')]
        [string]$Level = 'Information',

        [Parameter()]
        [ValidateSet('Console', 'File', 'Both')]
        [string]$Destination,

        [Parameter()]
        [switch]$Bare,

        [Parameter()]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter()]
        [System.Exception]$Exception,

        [Parameter()]
        [hashtable]$Fields,

        [Parameter()]
        [switch]$SkipMasking,

        [Parameter()]
        [Logger]$Logger
    )

    process
    {
        $effectiveMessage = $Message

        if ($PSBoundParameters.ContainsKey('ErrorRecord'))
        {
            $detail = "{0}: {1}`nCategory: {2}`nScriptStackTrace:`n{3}" -f `
                $ErrorRecord.Exception.GetType().FullName, $ErrorRecord.Exception.Message, `
                $ErrorRecord.CategoryInfo.ToString(), $ErrorRecord.ScriptStackTrace
            $effectiveMessage = if ($Message) { "$Message`n$detail" } else { $detail }
            if (-not $PSBoundParameters.ContainsKey('Level')) { $Level = 'Error' }
        }
        elseif ($PSBoundParameters.ContainsKey('Exception'))
        {
            $detail = "{0}: {1}`nStackTrace:`n{2}" -f `
                $Exception.GetType().FullName, $Exception.Message, $Exception.StackTrace
            $effectiveMessage = if ($Message) { "$Message`n$detail" } else { $detail }
            if (-not $PSBoundParameters.ContainsKey('Level')) { $Level = 'Error' }
        }
        elseif (-not $Message)
        {
            throw 'Write-Log requires -Message, -ErrorRecord, or -Exception.'
        }

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

        $target.Write($effectiveMessage, $levelObj, $destinationObj, $Bare.IsPresent, $Fields, $SkipMasking.IsPresent)
    }
}

#endregion

Export-ModuleMember -Function @(
    'New-Logger'
    'Remove-Logger'
    'Add-LoggerEventLogSink'
    'Get-LoggerSink'
    'Remove-LoggerSink'
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
    'Get-LoggerContent'
    'Get-LoggerTimeout'
    'Set-LoggerTimeout'
    'Get-LoggerRotation'
    'Set-LoggerRotation'
    'Get-LoggerOutputFormat'
    'Set-LoggerOutputFormat'
    'Get-LoggerMessageFormat'
    'Set-LoggerMessageFormat'
    'Get-LoggerNativeStreamMode'
    'Set-LoggerNativeStreamMode'
    'Add-LoggerMaskRule'
    'Get-LoggerMaskRule'
    'Remove-LoggerMaskRule'
    'Add-LoggerMaskField'
    'Get-LoggerMaskField'
    'Remove-LoggerMaskField'
    'Get-LoggerMaskReplacement'
    'Set-LoggerMaskReplacement'
    'Add-LoggerDefaultMaskRule'
)
