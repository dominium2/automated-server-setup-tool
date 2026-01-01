# Logging Module for Automated Server Setup Tool
# Provides centralized logging functionality with file and console output

# Module-level variables
$script:LogFilePath = $null
$script:LogLevel = "Info"
$script:LogToFile = $true
$script:LogToConsole = $true
$script:MaxLogFileSizeMB = 10
$script:MaxLogFiles = 5

# Log levels (ordered from lowest to highest priority)
$script:LogLevels = @{
    "Debug"   = 0
    "Info"    = 1
    "Warning" = 2
    "Error"   = 3
    "Success" = 1  # Same as Info but with different color
}

function Initialize-Logging {
    <#
    .SYNOPSIS
        Initializes the logging system with specified configuration.

    .DESCRIPTION
        Sets up the logging directory, log file, and configuration options.
        Should be called at the start of the application.

    .PARAMETER LogDirectory
        The directory where log files will be stored. Defaults to "logs" in script root.

    .PARAMETER LogLevel
        Minimum log level to record. Options: Debug, Info, Warning, Error.

    .PARAMETER LogToFile
        Whether to write logs to file. Default: $true

    .PARAMETER LogToConsole
        Whether to write logs to console. Default: $true

    .PARAMETER MaxLogFileSizeMB
        Maximum size of a single log file in MB before rotation. Default: 10

    .PARAMETER MaxLogFiles
        Maximum number of log files to keep. Default: 5

    .EXAMPLE
        Initialize-Logging -LogLevel "Debug" -LogToFile $true
    #>
    param(
        [string]$LogDirectory = $null,
        
        [ValidateSet("Debug", "Info", "Warning", "Error")]
        [string]$LogLevel = "Info",
        
        [bool]$LogToFile = $true,
        
        [bool]$LogToConsole = $true,
        
        [int]$MaxLogFileSizeMB = 10,
        
        [int]$MaxLogFiles = 5
    )
    
    # Set module configuration
    $script:LogLevel = $LogLevel
    $script:LogToFile = $LogToFile
    $script:LogToConsole = $LogToConsole
    $script:MaxLogFileSizeMB = $MaxLogFileSizeMB
    $script:MaxLogFiles = $MaxLogFiles
    
    # Determine log directory
    if ([string]::IsNullOrEmpty($LogDirectory)) {
        $LogDirectory = Join-Path $PSScriptRoot "..\logs"
    }
    
    # Create log directory if it doesn't exist
    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    
    # Create log file name with timestamp
    $timestamp = Get-Date -Format "yyyy-MM-dd"
    $logFileName = "automated-setup_$timestamp.log"
    $script:LogFilePath = Join-Path $LogDirectory $logFileName
    
    # Perform log rotation if needed
    Invoke-LogRotation
    
    # Write initialization message
    Write-Log -Message "Logging initialized" -Level "Info" -Component "Logging"
    Write-Log -Message "Log Level: $LogLevel, Log to File: $LogToFile, Log to Console: $LogToConsole" -Level "Debug" -Component "Logging"
    
    return $script:LogFilePath
}

function Invoke-LogRotation {
    <#
    .SYNOPSIS
        Performs log file rotation based on size and file count limits.
    #>
    
    if (-not $script:LogToFile -or [string]::IsNullOrEmpty($script:LogFilePath)) {
        return
    }
    
    $logDir = Split-Path $script:LogFilePath -Parent
    
    # Check if current log file exceeds size limit
    if (Test-Path $script:LogFilePath) {
        $fileSize = (Get-Item $script:LogFilePath).Length / 1MB
        
        if ($fileSize -ge $script:MaxLogFileSizeMB) {
            # Rename current log file with timestamp
            $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($script:LogFilePath)
            $extension = [System.IO.Path]::GetExtension($script:LogFilePath)
            $rotatedName = "${baseName}_$timestamp$extension"
            $rotatedPath = Join-Path $logDir $rotatedName
            
            Rename-Item -Path $script:LogFilePath -NewName $rotatedName -Force
        }
    }
    
    # Remove old log files if exceeding max count
    $logFiles = Get-ChildItem -Path $logDir -Filter "automated-setup_*.log" | 
                Sort-Object LastWriteTime -Descending
    
    if ($logFiles.Count -gt $script:MaxLogFiles) {
        $filesToDelete = $logFiles | Select-Object -Skip $script:MaxLogFiles
        foreach ($file in $filesToDelete) {
            Remove-Item -Path $file.FullName -Force
        }
    }
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes a log message to file and/or console.

    .DESCRIPTION
        Central logging function that formats and outputs log messages
        to configured destinations based on log level settings.

    .PARAMETER Message
        The log message to write.

    .PARAMETER Level
        The log level: Debug, Info, Warning, Error, Success.

    .PARAMETER Component
        The component or module generating the log message.

    .PARAMETER Exception
        Optional exception object to include in error logs.

    .EXAMPLE
        Write-Log -Message "Connection successful" -Level "Success" -Component "RemoteConnection"

    .EXAMPLE
        Write-Log -Message "Failed to connect" -Level "Error" -Component "SSH" -Exception $_.Exception
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [ValidateSet("Debug", "Info", "Warning", "Error", "Success")]
        [string]$Level = "Info",
        
        [string]$Component = "General",
        
        [System.Exception]$Exception = $null
    )
    
    # Check if this log level should be recorded
    $configuredLevel = $script:LogLevels[$script:LogLevel]
    $messageLevel = $script:LogLevels[$Level]
    
    if ($messageLevel -lt $configuredLevel) {
        return
    }
    
    # Format timestamp
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    
    # Format log message
    $logMessage = "[$timestamp] [$Level] [$Component] $Message"
    
    # Add exception details if provided
    if ($null -ne $Exception) {
        $logMessage += "`n  Exception: $($Exception.Message)"
        if ($Exception.InnerException) {
            $logMessage += "`n  Inner Exception: $($Exception.InnerException.Message)"
        }
    }
    
    # Write to file
    if ($script:LogToFile -and -not [string]::IsNullOrEmpty($script:LogFilePath)) {
        try {
            Add-Content -Path $script:LogFilePath -Value $logMessage -Encoding UTF8
        }
        catch {
            # Silently fail file logging - don't cause issues in main application
        }
    }
    
    # Write to console with color
    if ($script:LogToConsole) {
        $color = switch ($Level) {
            "Debug"   { "Gray" }
            "Info"    { "White" }
            "Warning" { "Yellow" }
            "Error"   { "Red" }
            "Success" { "Green" }
            default   { "White" }
        }
        
        # Format console message (shorter format)
        $consoleMessage = "[$Level] [$Component] $Message"
        Write-Host $consoleMessage -ForegroundColor $color
        
        if ($null -ne $Exception) {
            Write-Host "  Exception: $($Exception.Message)" -ForegroundColor $color
        }
    }
}

function Write-LogDebug {
    <#
    .SYNOPSIS
        Writes a debug-level log message.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [string]$Component = "General"
    )
    Write-Log -Message $Message -Level "Debug" -Component $Component
}

function Write-LogInfo {
    <#
    .SYNOPSIS
        Writes an info-level log message.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [string]$Component = "General"
    )
    Write-Log -Message $Message -Level "Info" -Component $Component
}

function Write-LogWarning {
    <#
    .SYNOPSIS
        Writes a warning-level log message.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [string]$Component = "General"
    )
    Write-Log -Message $Message -Level "Warning" -Component $Component
}

function Write-LogError {
    <#
    .SYNOPSIS
        Writes an error-level log message.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [string]$Component = "General",
        [System.Exception]$Exception = $null
    )
    Write-Log -Message $Message -Level "Error" -Component $Component -Exception $Exception
}

function Write-LogSuccess {
    <#
    .SYNOPSIS
        Writes a success-level log message.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [string]$Component = "General"
    )
    Write-Log -Message $Message -Level "Success" -Component $Component
}

function Get-LogFilePath {
    <#
    .SYNOPSIS
        Returns the current log file path.
    #>
    return $script:LogFilePath
}

function Get-LogContent {
    <#
    .SYNOPSIS
        Returns the content of the current log file.

    .PARAMETER Tail
        Number of lines to return from end of file.

    .PARAMETER Level
        Filter by log level.
    #>
    param(
        [int]$Tail = 0,
        [string]$Level = $null
    )
    
    if ([string]::IsNullOrEmpty($script:LogFilePath) -or -not (Test-Path $script:LogFilePath)) {
        return @()
    }
    
    $content = if ($Tail -gt 0) {
        Get-Content -Path $script:LogFilePath -Tail $Tail
    } else {
        Get-Content -Path $script:LogFilePath
    }
    
    if (-not [string]::IsNullOrEmpty($Level)) {
        $content = $content | Where-Object { $_ -match "\[$Level\]" }
    }
    
    return $content
}

function Clear-OldLogs {
    <#
    .SYNOPSIS
        Clears log files older than specified days.

    .PARAMETER DaysToKeep
        Number of days of logs to keep.
    #>
    param(
        [int]$DaysToKeep = 30
    )
    
    if ([string]::IsNullOrEmpty($script:LogFilePath)) {
        return
    }
    
    $logDir = Split-Path $script:LogFilePath -Parent
    $cutoffDate = (Get-Date).AddDays(-$DaysToKeep)
    
    $oldFiles = Get-ChildItem -Path $logDir -Filter "automated-setup_*.log" |
                Where-Object { $_.LastWriteTime -lt $cutoffDate }
    
    $deletedCount = 0
    foreach ($file in $oldFiles) {
        Remove-Item -Path $file.FullName -Force
        $deletedCount++
    }
    
    if ($deletedCount -gt 0) {
        Write-Log -Message "Cleared $deletedCount old log files" -Level "Info" -Component "Logging"
    }
    
    return $deletedCount
}

function Write-SessionSeparator {
    <#
    .SYNOPSIS
        Writes a visual separator in the log file to mark session boundaries.
    #>
    param(
        [string]$SessionName = "New Session"
    )
    
    $separator = @"

================================================================================
=== $SessionName - $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
================================================================================

"@
    
    if ($script:LogToFile -and -not [string]::IsNullOrEmpty($script:LogFilePath)) {
        Add-Content -Path $script:LogFilePath -Value $separator -Encoding UTF8
    }
}

# Export module functions
Export-ModuleMember -Function @(
    'Initialize-Logging',
    'Write-Log',
    'Write-LogDebug',
    'Write-LogInfo',
    'Write-LogWarning',
    'Write-LogError',
    'Write-LogSuccess',
    'Get-LogFilePath',
    'Get-LogContent',
    'Clear-OldLogs',
    'Write-SessionSeparator'
)
