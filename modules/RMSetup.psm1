#===============================================================================
# RMSetup.psm1 - Remote Management & Server Setup Module
# Automated Server Setup Tool
#===============================================================================

#region Module Variables
#-------------------------------------------------------------------------------
# Logging configuration
$script:LogFilePath = $null
$script:LogLevel = "Info"
$script:LogToFile = $true
$script:LogToConsole = $true
$script:MaxLogFileSizeMB = 10
$script:MaxLogFiles = 5

# Connection Configuration
$script:SSHPort = 22
$script:WinRMPort = 5985
$script:EnableSSH = $true
$script:EnableWinRM = $true

# Log levels (ordered from lowest to highest priority)
$script:LogLevels = @{
    "Debug"   = 0
    "Info"    = 1
    "Warning" = 2
    "Error"   = 3
    "Success" = 1  # Same as Info but with different color
}

# WSL2 reboot tracking (prevents infinite reboot loops)
$script:WSL2RebootCount = @{}
#endregion
#===============================================================================

#region LOGGING FUNCTIONS
#===============================================================================
<#
.SYNOPSIS
    Saves connection configurations into the module's script scope.
.DESCRIPTION
    WHAT IT DOES: Overwrites the default global variables for SSH and WinRM ports.
    HOW IT WORKS: Simple variable assignment overriding the `$script:` scope values.
    WHY IT IS NEEDED: Prevents the need to pass custom port parameters manually down through dozens of nested functions. This ensures that custom ports (e.g., SSH port 2222) and protocol toggles set in the GUI are globally respected by the module during threaded background execution.
.PARAMETER SSHPort
    The integer port to use for SSH connections. Default is 22.
.PARAMETER WinRMPort
    The integer port to use for WinRM HTTP connections. Default is 5985.
.PARAMETER EnableSSH
    Boolean indicating whether to attempt SSH connections. Default is $true.
.PARAMETER EnableWinRM
    Boolean indicating whether to attempt WinRM connections. Default is $true.
.OUTPUTS
    None.
#>
function Set-ConnectionConfig {
    param(
        [int]$SSHPort = 22,
        [int]$WinRMPort = 5985,
        [bool]$EnableSSH = $true,
        [bool]$EnableWinRM = $true
    )
    $script:SSHPort = $SSHPort
    $script:WinRMPort = $WinRMPort
    $script:EnableSSH = $EnableSSH
    $script:EnableWinRM = $EnableWinRM
}

<#
.SYNOPSIS
    Initializes the logging system and generates a timestamped log file.
.DESCRIPTION
    WHAT IT DOES: Creates the active log file for the session and configures logging limits.
    HOW IT WORKS: 
        1. Checks if the `logs/` directory exists. If not, it creates it.
        2. Generates a strict timestamped filename (e.g., `automated-setup_2024-01-01.log`).
        3. Calls `Invoke-LogRotation` to clean up old files.
        4. Writes an initial startup string to the file to confirm it is accessible.
    WHY IT IS NEEDED: Establishes a foundational file trace for debugging failed parallel deployments, ensuring backend PowerShell errors aren't lost when the GUI terminates.
.PARAMETER LogDirectory
    Path to the folder where logs should reside. Defaults to `../logs`.
.PARAMETER LogLevel
    The minimum severity level to record (Debug, Info, Warning, Error). Defaults to "Info".
.PARAMETER LogToFile
    Boolean indicating whether writing to disk is permitted.
.PARAMETER LogToConsole
    Boolean indicating whether to echo the log out to standard host output.
.PARAMETER MaxLogFileSizeMB
    Maximum allowable size of a log file before it is rotated. Defaults to 10MB.
.PARAMETER MaxLogFiles
    Maximum amount of old log files to retain. Defaults to 5.
.OUTPUTS
    String. The absolute file path to the newly generated log file.
#>
function Initialize-Logging {
    param(
        [string]$LogDirectory = $null,
        [ValidateSet("Debug", "Info", "Warning", "Error")]
        [string]$LogLevel = "Info",
        [bool]$LogToFile = $true,
        [bool]$LogToConsole = $true,
        [int]$MaxLogFileSizeMB = 10,
        [int]$MaxLogFiles = 5
    )
    
    $script:LogLevel = $LogLevel
    $script:LogToFile = $LogToFile
    $script:LogToConsole = $LogToConsole
    $script:MaxLogFileSizeMB = $MaxLogFileSizeMB
    $script:MaxLogFiles = $MaxLogFiles
    
    if ([string]::IsNullOrEmpty($LogDirectory)) {
        $LogDirectory = Join-Path $PSScriptRoot "..\logs"
    }
    
    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd"
    $logFileName = "automated-setup_$timestamp.log"
    $script:LogFilePath = Join-Path $LogDirectory $logFileName
    
    Invoke-LogRotation
    
    Write-Log -Message "Logging initialized" -Level "Info" -Component "Logging"
    Write-Log -Message "Log Level: $LogLevel, Log to File: $LogToFile, Log to Console: $LogToConsole" -Level "Debug" -Component "Logging"
    
    return $script:LogFilePath
}

<#
.SYNOPSIS
    Internal helper to clear bloated log files.
.DESCRIPTION
    WHAT IT DOES: Analyzes the current log directory and prunes outdated or overgrown log files.
    HOW IT WORKS: 
        1. Checks the current log file size against `$script:MaxLogFileSizeMB`. If it exceeds the limit, it appends a timestamp to the filename to "archive" it.
        2. Retrieves all log files in the directory sorted by creation date.
        3. If the total number of files exceeds `$script:MaxLogFiles`, it runs `Remove-Item` on the oldest ones until the limit is respected.
    WHY IT IS NEEDED: Executed automatically on `Initialize-Logging` to prevent the host machine from running out of disk space due to infinite log bloat.
.OUTPUTS
    None.
#>
function Invoke-LogRotation {
    if (-not $script:LogToFile -or [string]::IsNullOrEmpty($script:LogFilePath)) {
        return
    }
    
    $logDir = Split-Path $script:LogFilePath -Parent
    
    if (Test-Path $script:LogFilePath) {
        $fileSize = (Get-Item $script:LogFilePath).Length / 1MB
        
        if ($fileSize -ge $script:MaxLogFileSizeMB) {
            $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($script:LogFilePath)
            $extension = [System.IO.Path]::GetExtension($script:LogFilePath)
            $rotatedName = "${baseName}_$timestamp$extension"
            $rotatedPath = Join-Path $logDir $rotatedName
            
            Rename-Item -Path $script:LogFilePath -NewName $rotatedName -Force
        }
    }
    
    $logFiles = Get-ChildItem -Path $logDir -Filter "automated-setup_*.log" | 
                Sort-Object LastWriteTime -Descending 
                
    if ($logFiles.Count -gt $script:MaxLogFiles) {
        $filesToDelete = $logFiles | Select-Object -Skip $script:MaxLogFiles
        foreach ($file in $filesToDelete) {
            Remove-Item -Path $file.FullName -Force
        }
    }
}

<#
.SYNOPSIS
    Core logging utility that handles thread-safe file writes.
.DESCRIPTION
    WHAT IT DOES: Formats strings with timestamps, severity levels, and components, then writes them to the disk.
    HOW IT WORKS: 
        1. Compares the requested `$Level` against the globally configured `$script:LogLevel` dictionary. If the requested level is lower (e.g. Debug < Info), it silently discards the message.
        2. Unpacks nested exceptions if provided.
        3. Implements a `while` loop surrounding an `AppendAllText` method. If a background Runspace is currently locking the text file, it will `Start-Sleep` for a random 50-150 millisecond interval and try writing again (up to 5 times).
    WHY IT IS NEEDED: This is the backbone of the logging architecture. The thread-safe retry loop is completely mandatory, otherwise the parallel deployment execution would constantly throw "File is being used by another process" exceptions.
.PARAMETER Message
    The literal string to log.
.PARAMETER Level
    The severity flag (Debug, Info, Warning, Error, Success).
.PARAMETER Component
    A string identifier showing which module generated the log (e.g. "Deployment", "GUI", "HealthMonitor").
.PARAMETER Exception
    An optional C# or PowerShell Exception object to unpack and print to the log.
.OUTPUTS
    None. Modifies the log file.
#>
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("Debug", "Info", "Warning", "Error", "Success")]
        [string]$Level = "Info",
        [string]$Component = "General",
        [System.Exception]$Exception = $null
    )
    
    $configuredLevel = $script:LogLevels[$script:LogLevel]
    $messageLevel = $script:LogLevels[$Level]
    
    if ($messageLevel -lt $configuredLevel) {
        return
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logMessage = "[$timestamp] [$Level] [$Component] $Message"
    
    if ($null -ne $Exception) {
        $logMessage += "`n  Exception: $($Exception.Message)"
        if ($Exception.InnerException) {
            $logMessage += "`n  Inner Exception: $($Exception.InnerException.Message)"
        }
    }
    
    if ($script:LogToFile -and -not [string]::IsNullOrEmpty($script:LogFilePath)) {
        # THREAD-SAFE WRITING: Prevents file-lock crashes when parallel runspaces log concurrently
        $retryCount = 0
        $success = $false
        while (-not $success -and $retryCount -lt 5) {
            try {
                [System.IO.File]::AppendAllText($script:LogFilePath, $logMessage + "`r`n", [System.Text.Encoding]::UTF8)
                $success = $true
            }
            catch {
                $retryCount++
                Start-Sleep -Milliseconds (Get-Random -Minimum 50 -Maximum 150)
            }
        }
    }
    
    if ($script:LogToConsole) {
        $color = switch ($Level) {
            "Debug"   { "Gray" }
            "Info"    { "White" }
            "Warning" { "Yellow" }
            "Error"   { "Red" }
            "Success" { "Green" }
            default   { "White" }
        }
        
        $consoleMessage = "[$Level] [$Component] $Message"
        Write-Host $consoleMessage -ForegroundColor $color
        
        if ($null -ne $Exception) {
            Write-Host "  Exception: $($Exception.Message)" -ForegroundColor $color
        }
    }
}

<#
.SYNOPSIS
    Wrapper function for streamlined logging syntax.
.DESCRIPTION
    WHAT IT DOES: A syntactic shortcut to `Write-Log -Level "Debug"`.
    WHY IT IS NEEDED: Cleans up the codebase by drastically reducing parameter lengths in caller blocks.
#>
function Write-LogDebug {
    param([string]$Message, [string]$Component = "General")
    Write-Log -Message $Message -Level "Debug" -Component $Component
}

<#
.SYNOPSIS
    Wrapper function for streamlined logging syntax.
.DESCRIPTION
    WHAT IT DOES: A syntactic shortcut to `Write-Log -Level "Info"`.
    WHY IT IS NEEDED: Cleans up the codebase by drastically reducing parameter lengths in caller blocks.
#>
function Write-LogInfo {
    param([string]$Message, [string]$Component = "General")
    Write-Log -Message $Message -Level "Info" -Component $Component
}

<#
.SYNOPSIS
    Wrapper function for streamlined logging syntax.
.DESCRIPTION
    WHAT IT DOES: A syntactic shortcut to `Write-Log -Level "Warning"`.
    WHY IT IS NEEDED: Cleans up the codebase by drastically reducing parameter lengths in caller blocks.
#>
function Write-LogWarning {
    param([string]$Message, [string]$Component = "General")
    Write-Log -Message $Message -Level "Warning" -Component $Component
}

<#
.SYNOPSIS
    Wrapper function for streamlined logging syntax.
.DESCRIPTION
    WHAT IT DOES: A syntactic shortcut to `Write-Log -Level "Error"`. Allows passing the raw exception object.
    WHY IT IS NEEDED: Cleans up the codebase by drastically reducing parameter lengths in caller blocks.
#>
function Write-LogError {
    param([string]$Message, [string]$Component = "General", [System.Exception]$Exception = $null)
    Write-Log -Message $Message -Level "Error" -Component $Component -Exception $Exception
}

<#
.SYNOPSIS
    Wrapper function for streamlined logging syntax.
.DESCRIPTION
    WHAT IT DOES: A syntactic shortcut to `Write-Log -Level "Success"`.
    WHY IT IS NEEDED: Cleans up the codebase by drastically reducing parameter lengths in caller blocks.
#>
function Write-LogSuccess {
    param([string]$Message, [string]$Component = "General")
    Write-Log -Message $Message -Level "Success" -Component $Component
}

<#
.SYNOPSIS
    Returns the active log file path.
.DESCRIPTION
    WHAT IT DOES: Retrieves the global variable pointing to the currently active `.log` file on disk.
    WHY IT IS NEEDED: Required to safely pass the active log path into the disconnected background `Runspaces` during deployment.
.OUTPUTS
    String. The active log file path.
#>
function Get-LogFilePath {
    return $script:LogFilePath
}

<#
.SYNOPSIS
    Reads the content of the active log file.
.DESCRIPTION
    WHAT IT DOES: Retrieves the physical text from the active `.log` file.
    HOW IT WORKS: Utilizes `Get-Content` to read the path returned by `$script:LogFilePath`. Supports trailing tail counts and string-matching level filters (e.g. `[Error]`).
    WHY IT IS NEEDED: Primarily used by Pester unit tests to assert that expected outputs were successfully written to the log trace.
.PARAMETER Tail
    An integer representing the last `x` lines to read from the end of the file.
.PARAMETER Level
    A string (e.g., "Error") used to exclusively filter out specific log messages.
.OUTPUTS
    Array of Strings containing the log content.
#>
function Get-LogContent {
    param([int]$Tail = 0, [string]$Level = $null)
    if ([string]::IsNullOrEmpty($script:LogFilePath) -or -not (Test-Path $script:LogFilePath)) { return @() }
    $content = if ($Tail -gt 0) { Get-Content -Path $script:LogFilePath -Tail $Tail } else { Get-Content -Path $script:LogFilePath }
    if (-not [string]::IsNullOrEmpty($Level)) { $content = $content | Where-Object { $_ -match "\[$Level\]" } }
    return $content
}

<#
.SYNOPSIS
    Clears out expired logs according to a day-retention policy.
.DESCRIPTION
    WHAT IT DOES: Deletes older `.log` files in the directory.
    HOW IT WORKS: Selects files in the log directory whose `LastWriteTime` is older than `$DaysToKeep` and forces a deletion.
    WHY IT IS NEEDED: An alternative to the `MaxLogFiles` cap, useful for users doing high-frequency deployments who only want to retain a temporal record (e.g. "Only logs from the last week").
.PARAMETER DaysToKeep
    Integer representing the number of days to retain logs.
.OUTPUTS
    Integer representing how many files were successfully deleted.
#>
function Clear-OldLogs {
    param([int]$DaysToKeep = 30)
    if ([string]::IsNullOrEmpty($script:LogFilePath)) { return }
    $logDir = Split-Path $script:LogFilePath -Parent
    $cutoffDate = (Get-Date).AddDays(-$DaysToKeep)
    $oldFiles = Get-ChildItem -Path $logDir -Filter "automated-setup_*.log" | Where-Object { $_.LastWriteTime -lt $cutoffDate }
    $deletedCount = 0
    foreach ($file in $oldFiles) { Remove-Item -Path $file.FullName -Force; $deletedCount++ }
    if ($deletedCount -gt 0) { Write-Log -Message "Cleared $deletedCount old log files" -Level "Info" -Component "Logging" }
    return $deletedCount
}

<#
.SYNOPSIS
    Creates a visual separator block in the text log file.
.DESCRIPTION
    WHAT IT DOES: Simply appends a stylized banner string (`======...`) containing the session name and timestamp to the text file.
    WHY IT IS NEEDED: Since the log file rotates daily, closing and re-opening the GUI within the same day will write to the same file. The separator helps users distinguish between individual tool executions within the same text log.
.PARAMETER SessionName
    String title to inject into the separator block.
.OUTPUTS
    None. Modifies the log file.
#>
function Write-SessionSeparator {
    param([string]$SessionName = "New Session")
    $separator = @"

================================================================================
=== $SessionName - $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
================================================================================
"@
    if ($script:LogToFile -and -not [string]::IsNullOrEmpty($script:LogFilePath)) {
        Add-Content -Path $script:LogFilePath -Value $separator -Encoding UTF8
    }
}

<#
.SYNOPSIS
    Binds a background runspace to an existing log file.
.DESCRIPTION
    WHAT IT DOES: Overrides the module's script-level variables associated with logging logic.
    HOW IT WORKS: Sets `$script:LogFilePath` and forces `$script:LogToConsole` to false (since a background thread has no console to print to).
    WHY IT IS NEEDED: Background threads (`Runspaces`) do not inherit script-scoped variables from the main parent thread that launched them. Without this function, the deployment threads would try to create their own new log files instead of appending to the master log.
.PARAMETER LogPath
    The absolute string path of the master log file to target.
.PARAMETER LogLevel
    The verbosity level to use inside this specific thread.
.OUTPUTS
    None.
#>
function Set-LogConfiguration {
    param(
        [Parameter(Mandatory=$true)]
        [string]$LogPath,
        [string]$LogLevel = "Info"
    )
    $script:LogFilePath = $LogPath
    $script:LogLevel = $LogLevel
    $script:LogToFile = $true
    $script:LogToConsole = $false
}
#endregion

#===============================================================================
#region REMOTE CONNECTION FUNCTIONS
#===============================================================================
<#
.SYNOPSIS
    Detects if the remote server is running a Linux or Windows operating system.
.DESCRIPTION
    WHAT IT DOES: Determines the remote environment to dictate the transport protocol.
    HOW IT WORKS: 
        1. Utilizes `Test-NetConnection` to actively probe the globally configured SSH (default 22) and WinRM (default 5985) TCP ports on the target machine. 
        2. If the WinRM TCP probe succeeds, it returns "Windows". If the SSH TCP probe succeeds, it returns "Linux".
        3. If the TCP probe fails due to stealth firewalls, it falls back to analyzing the Time-To-Live (TTL) of an ICMP ping response (Windows typically returns TTL ~128, Linux typically returns TTL ~64).
    WHY IT IS NEEDED: This dynamically dictates which remote execution protocol (PuTTY/SSH or WinRM) the rest of the orchestration pipeline should use, preventing the user from manually specifying the OS for each server and preventing long TCP timeout hangs during subsequent commands.
.PARAMETER IP
    The IPv4 address or hostname of the target server to probe.
.OUTPUTS
    String. Returns "Windows", "Linux", or $null if the OS cannot be determined or the host is entirely unreachable.
#>
function Get-TargetOS {
    param ([string]$IP)
    Write-LogDebug -Message "Entering Get-TargetOS for IP: $IP" -Component "RemoteConnection"
    try {
        Write-LogDebug -Message "Detecting OS for $IP via TCP ports" -Component "RemoteConnection"
        
        if ($script:EnableWinRM) {
            $winRMPort = Test-NetConnection -ComputerName $IP -Port $script:WinRMPort -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if ($winRMPort.TcpTestSucceeded) {
                Write-LogInfo -Message "Detected Windows OS on $IP (WinRM port $($script:WinRMPort) open)" -Component "RemoteConnection"
                return "Windows"
            }
        }
        
        if ($script:EnableSSH) {
            $sshPort = Test-NetConnection -ComputerName $IP -Port $script:SSHPort -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if ($sshPort.TcpTestSucceeded) {
                Write-LogInfo -Message "Detected Linux OS on $IP (SSH port $($script:SSHPort) open)" -Component "RemoteConnection"
                return "Linux"
            }
        }
        
        # Ping TTL fallback
        $pingDetailed = Test-Connection -ComputerName $IP -Count 1 -ErrorAction SilentlyContinue
        if ($pingDetailed) {
            $ttl = $pingDetailed.ResponseTimeToLive
            if ($ttl -ge 120 -and $ttl -le 128 -and $script:EnableWinRM) { return "Windows" }
            elseif ($ttl -ge 60 -and $ttl -le 64 -and $script:EnableSSH) { return "Linux" }
        }
        Write-LogWarning -Message "Could not detect Target OS for $IP" -Component "RemoteConnection"
        return $null
    }
    catch {
        Write-LogError -Message "Error during OS detection for $IP" -Component "RemoteConnection" -Exception $_.Exception
        return $null
    }
}

<#
.SYNOPSIS
    Tests raw SSH connectivity.
.DESCRIPTION
    WHAT IT DOES: Verifies that a remote Linux host is ready to accept commands using the provided credentials.
    HOW IT WORKS: 
        1. Checks if the `plink` (PuTTY) binary is accessible on the host machine.
        2. Generates a temporary text file containing the letter "y".
        3. Pipes the "y" file into the `plink` command execution string: `& plink -P [Port] -pw [Password] [User]@[IP] "hostname"`. This automatically "accepts" the initial RSA/ED25519 host key prompt that SSH usually throws the very first time you connect to a new server.
        4. Analyzes the `$LASTEXITCODE` and standard output text to verify no authentication failures occurred.
    WHY IT IS NEEDED: Standard OpenSSH clients on Windows forcefully block non-interactive password automation. Bypassing this with `plink` allows true zero-touch deployment, and answering the host key prompt automatically prevents the deployment script from freezing indefinitely.
.PARAMETER IP
    Target IP address.
.PARAMETER User
    Target SSH Username.
.PARAMETER Password
    Target SSH Password.
.OUTPUTS
    Boolean. True if successful, False if failed.
#>
function Test-SSHConnection {
    param ([string]$IP, [string]$User, [string]$Password)
    Write-LogDebug -Message "Entering Test-SSHConnection for IP: $IP" -Component "RemoteConnection"
    try {
        if (Get-Command plink -ErrorAction SilentlyContinue) {
            $tempAnswerFile = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $tempAnswerFile -Value "y"
            try {
                $result = Get-Content $tempAnswerFile | & plink -P $script:SSHPort -pw $Password $User@$IP "hostname" 2>&1
                if ($LASTEXITCODE -eq 0 -and $result -and $result -notmatch "FATAL ERROR" -and $result -notmatch "Access denied") { 
                    Write-LogInfo -Message "SSH connection test successful for $IP" -Component "RemoteConnection"
                    return $true 
                }
                else { 
                    Write-LogWarning -Message "SSH connection test failed for $IP. Output: $result" -Component "RemoteConnection"
                    return $false 
                }
            } finally { if (Test-Path $tempAnswerFile) { Remove-Item $tempAnswerFile -Force } }
        } else { 
            Write-LogError -Message "plink binary not found on the host machine" -Component "RemoteConnection"
            return $false 
        }
    } catch { 
        Write-LogError -Message "Exception during Test-SSHConnection for $IP" -Component "RemoteConnection" -Exception $_
        return $false 
    }
}

<#
.SYNOPSIS
    Tests raw WinRM connectivity.
.DESCRIPTION
    WHAT IT DOES: Verifies that a remote Windows host is ready to accept remote PowerShell commands.
    HOW IT WORKS: 
        1. Optionally attempts to start the local `WinRM` service if it is stopped on the host.
        2. Casts the raw password string into a `SecureString` and builds a `PSCredential` object.
        3. Constructs a `PSSessionOption` object passing `-SkipCACheck`, `-SkipCNCheck`, and `-SkipRevocationCheck`.
        4. Invokes `New-PSSession`. If it generates successfully, the test passes.
    WHY IT IS NEEDED: Windows Remote Management natively blocks connections using self-signed certificates or IP addresses instead of FQDNs. Injecting the Skip check parameters forces WinRM to trust default Homelab environments.
.PARAMETER IP
    Target IP address.
.PARAMETER User
    Target Windows Local Administrator Username.
.PARAMETER Password
    Target Windows Local Administrator Password.
.OUTPUTS
    Boolean. True if successful, False if failed.
#>
function Test-WinRMConnection {
    param ([string]$IP, [string]$User, [string]$Password)
    Write-LogDebug -Message "Entering Test-WinRMConnection for IP: $IP" -Component "RemoteConnection"
    try {
        $winrmService = Get-Service -Name WinRM -ErrorAction SilentlyContinue
        if ($winrmService -and $winrmService.Status -ne 'Running') { 
            try { Start-Service -Name WinRM -ErrorAction Stop } 
            catch { Write-LogWarning -Message "Could not start local WinRM service" -Component "RemoteConnection" } 
        }
        
        $winSecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $winCredential = New-Object System.Management.Automation.PSCredential ($User, $winSecurePassword)
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        
        $winSession = New-PSSession -ComputerName $IP -Port $script:WinRMPort -Credential $winCredential -SessionOption $sessionOption -ErrorAction Stop
        if ($winSession) { 
            Remove-PSSession -Session $winSession
            Write-LogInfo -Message "WinRM connection test successful for $IP" -Component "RemoteConnection"
            return $true 
        }
    } catch { 
        Write-LogError -Message "Exception during Test-WinRMConnection for $IP" -Component "RemoteConnection" -Exception $_
        return $false 
    }
}

<#
.SYNOPSIS
    Validates global reachability.
.DESCRIPTION
    WHAT IT DOES: The master gating function for testing connectivity prior to deployment.
    HOW IT WORKS: 
        1. Issues 4 rapid ICMP Ping checks to the target machine via `Test-Connection`.
        2. If all 4 pings succeed, it calls `Get-TargetOS` to find the operating system.
        3. Routes the execution flow to either `Test-SSHConnection` or `Test-WinRMConnection` based on the detected OS.
    WHY IT IS NEEDED: Ensures the host is entirely stable on the network before delegating to the much heavier (and timeout-prone) TCP WinRM/SSH negotiation protocols.
.PARAMETER IP
    Target IP address.
.PARAMETER User
    Target Username.
.PARAMETER Password
    Target Password.
.OUTPUTS
    Boolean. True if fully reachable and authenticated, False otherwise.
#>
function Test-RemoteConnection {
    param ([string]$IP, [string]$User, [string]$Password)
    Write-LogDebug -Message "Entering Test-RemoteConnection for IP: $IP" -Component "RemoteConnection"
    try {
        $successfulPings = 0
        for ($i = 1; $i -le 4; $i++) {
            $pingResult = Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue
            if ($pingResult) { $successfulPings++ }
            Start-Sleep -Milliseconds 500
        }
        
        if ($successfulPings -eq 4) {
            $targetOS = Get-TargetOS -IP $IP
            if ($targetOS -eq "Windows") { return Test-WinRMConnection -IP $IP -User $User -Password $Password } 
            elseif ($targetOS -eq "Linux") { return Test-SSHConnection -IP $IP -User $User -Password $Password }
            else { return $false }
        } else { 
            Write-LogWarning -Message "Ping test failed for $IP (Successful Pings: $successfulPings/4)" -Component "RemoteConnection"
            return $false 
        }
    } catch { 
        Write-LogError -Message "Exception during Test-RemoteConnection for $IP" -Component "RemoteConnection" -Exception $_
        return $false 
    }
}

<#
.SYNOPSIS
    Executes a bash payload within a Windows Target's WSL2 environment.
.DESCRIPTION
    WHAT IT DOES: Acts as an inter-process bridge. Takes a raw Linux Bash script and executes it inside the Windows target via WinRM.
    HOW IT WORKS: 
        1. Establishes a WinRM `PSSession` using explicit bypass flags (`SkipCACheck`).
        2. Wraps the provided bash command (`$Command`) into a script block.
        3. Translates Windows carriage returns (`\r\n`) into UNIX line endings (`\n`) to prevent parser errors in Bash.
        4. Base64 encodes the entire payload on the host side.
        5. Sends the encoded payload over WinRM into `wsl.exe`, where it is decoded (`base64 -d`) and piped directly into the `bash` interpreter as the root user.
        6. Strips WinRM null terminators (`\x00`) from the returning output string to ensure it remains legible.
    WHY IT IS NEEDED: Windows machines don't understand bash commands natively. To automate Docker (which relies on bash), the commands must be tunneled seamlessly from the PowerShell transport layer straight into the nested Linux kernel. Encoding in Base64 ensures special characters or quotes in the bash script don't break the PowerShell pipeline parser.
.PARAMETER IP
    Target IP address.
.PARAMETER User
    Target Windows Username.
.PARAMETER Password
    Target Windows Password.
.PARAMETER Command
    The raw bash string to execute.
.OUTPUTS
    A Hashtable containing `Output` (the raw execution string) and `ExitCode`. Returns `$null` upon catastrophic error.
#>
function Invoke-WSLCommand {
    param ([string]$IP, [string]$User, [string]$Password, [string]$Command)
    Write-LogDebug -Message "Entering Invoke-WSLCommand for IP: $IP" -Component "RemoteConnection"
    try {
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        $session = New-PSSession -ComputerName $IP -Port $script:WinRMPort -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
        
        if (-not $session) { 
            Write-LogError -Message "Failed to create PSSession for WSLCommand on $IP" -Component "RemoteConnection"
            return $null 
        }
        
        $result = Invoke-Command -Session $session -ScriptBlock {
            param($Cmd)
            $ErrorActionPreference = "SilentlyContinue"
            $env:WSL_UTF8=1
            
            # Resolve exact WSL binary path to prevent 32-bit execution traps on 64-bit systems
            $wslExe = if (Test-Path "$env:windir\sysnative\wsl.exe") { "$env:windir\sysnative\wsl.exe" } else { "wsl.exe" }
            
            $distroListRaw = & $wslExe --list --quiet 2>&1 | ForEach-Object { $_.ToString() }
            $distroList = ($distroListRaw -join ' ') -replace "\x00", ""
            
            if ($distroList -match "not installed|is not installed|has no installed") { 
                return @{ Output = "WSL is not ready."; ExitCode = 1; WSLNotReady = $true } 
            }
            
            $CmdUnix = $Cmd -replace "`r`n", "`n"
            $b64Cmd = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($CmdUnix))
            
            # Explicitly executing against the default distribution
            $rawOutputRaw = & $wslExe -u root bash -c "echo '$b64Cmd' | base64 -d | bash" 2>&1 | ForEach-Object { $_.ToString() }
            $rawOutput = $rawOutputRaw -join "`n"
            
            $cleanOutput = $rawOutput -replace "\x00", ""
            $cleanOutput = $cleanOutput -replace "(?mi)^\s*wsl: Failed to start the systemd user session.*$\r?\n?", ""
            $cleanOutput = $cleanOutput -replace "(?mi)^\s* .*$\r?\n?", ""
            $cleanOutput = $cleanOutput.Trim()
            
            return @{ Output = $cleanOutput; ExitCode = 0; WSLNotReady = $false }
        } -ArgumentList $Command
        
        Remove-PSSession -Session $session
        if ($result.WSLNotReady) { 
            Write-LogWarning -Message "WSL is not ready on target $IP" -Component "RemoteConnection"
            return $null 
        }
        Write-LogDebug -Message "Invoke-WSLCommand executed successfully on $IP" -Component "RemoteConnection"
        return $result
    } catch { 
        Write-LogError -Message "Exception in Invoke-WSLCommand for $IP" -Component "RemoteConnection" -Exception $_
        return $null 
    }
}

<#
.SYNOPSIS
    The core transport router executing commands on remote targets.
.DESCRIPTION
    WHAT IT DOES: Takes a single bash command and pushes it to a server, returning the raw text output.
    HOW IT WORKS: 
        1. Checks the `OSType` (invokes `Get-TargetOS` if the OS string wasn't explicitly provided to cache the result).
        2. If the OS is Linux, it executes the command via `plink` using the `-batch` and `-pw` flags to enforce non-interactive automation. Evaluates `$LASTEXITCODE`.
        3. If the OS is Windows, it delegates the entire payload directly to the `Invoke-WSLCommand` pipeline.
    WHY IT IS NEEDED: This function abstracts away the protocol logic. Functions written further down the pipeline (like `Deploy-DockerService`) do not need to know or care if the target is Windows or Linux; they just hand a bash string to `Invoke-RemoteCommand`, which handles the heavy lifting of figuring out the transportation protocol.
.PARAMETER IP
    Target IP address.
.PARAMETER User
    Target Username.
.PARAMETER Password
    Target Password.
.PARAMETER Command
    The bash payload to execute.
.PARAMETER OSType
    (Optional) String "Windows" or "Linux". Passed to skip the 2-second TCP port probe.
.OUTPUTS
    The raw string output of the execution, or $null if a protocol failure occurred.
#>
function Invoke-RemoteCommand {
    param([string]$IP, [string]$User, [string]$Password, [string]$Command, [string]$OSType = $null)
    Write-LogDebug -Message "Entering Invoke-RemoteCommand for IP: $IP" -Component "RemoteConnection"
    try {
        $osType = if (-not [string]::IsNullOrEmpty($OSType)) { $OSType } else { Get-TargetOS -IP $IP }
        if ($osType -eq "Linux") {
            if (-not (Get-Command plink -ErrorAction SilentlyContinue)) { 
                Write-LogError -Message "plink binary not found on the host machine" -Component "RemoteConnection"
                return $null 
            }
            $result = Write-Output y | plink -P $script:SSHPort -batch -pw $Password "$User@$IP" $Command 2>&1
            if ($LASTEXITCODE -ne 0 -and $result -match "error|fatal|failed|denied|cannot|permission denied") { 
                Write-LogWarning -Message "Remote command failed on Linux $IP. Exit code: $LASTEXITCODE" -Component "RemoteConnection"
                return $null 
            }
            Write-LogDebug -Message "Remote command executed on Linux $IP" -Component "RemoteConnection"
            return $result
        }
        elseif ($osType -eq "Windows") {
            $wslResult = Invoke-WSLCommand -IP $IP -User $User -Password $Password -Command $Command
            if ($null -eq $wslResult) { 
                Write-LogWarning -Message "Remote command failed on Windows $IP" -Component "RemoteConnection"
                return $null 
            }
            Write-LogDebug -Message "Remote command executed on Windows $IP" -Component "RemoteConnection"
            return $wslResult.Output
        }
        else { 
            Write-LogError -Message "Could not determine OS for Invoke-RemoteCommand routing on $IP" -Component "RemoteConnection"
            return $null 
        }
    } catch { 
        Write-LogError -Message "Exception in Invoke-RemoteCommand for $IP" -Component "RemoteConnection" -Exception $_
        return $null 
    }
}
#endregion

#===============================================================================
#region HEALTH MONITORING FUNCTIONS
#===============================================================================
<#
.SYNOPSIS
    Fetches raw host machine hardware metrics.
.DESCRIPTION
    WHAT IT DOES: Wrapper function to determine the health metrics of a specific server.
    HOW IT WORKS: 
        1. Issues an ICMP Ping to ensure the server hasn't dropped off the network entirely. If it has, immediately returns an "Offline" object.
        2. Detects the OS and delegates the deep polling task to `Get-LinuxServerHealth` or `Get-WindowsServerHealth`.
    WHY IT IS NEEDED: Normalizes health data between Windows and Linux systems, returning a perfectly identical object map regardless of the underlying OS, allowing the WPF GUI to draw the health cards uniformly.
.PARAMETER IP
    Target IP address.
.PARAMETER User
    Target Username.
.PARAMETER Password
    Target Password.
.PARAMETER OSType
    (Optional) Target OS.
.OUTPUTS
    A `PSCustomObject` containing IP, Status, StatusColor, CPU, Memory, Disk, and Load telemetry.
#>
function Get-ServerHealth {
    param([string]$IP, [string]$User, [string]$Password, [string]$OSType = $null)
    Write-LogDebug -Message "Entering Get-ServerHealth for IP: $IP" -Component "HealthMonitor"
    try {
        $pingResult = Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue
        if (-not $pingResult) {
            Write-LogWarning -Message "Server $IP is offline during health check." -Component "HealthMonitor"
            return [PSCustomObject]@{ IP = $IP; Status = "Offline"; StatusColor = "Red"; CPU = $null; Memory = $null; Disk = $null; Uptime = $null; Load = $null; LastChecked = Get-Date; ErrorMessage = "Server not reachable" }
        }
        
        $osType = if (-not [string]::IsNullOrEmpty($OSType)) { $OSType } else { Get-TargetOS -IP $IP }
        if ($osType -eq "Linux") { return Get-LinuxServerHealth -IP $IP -User $User -Password $Password -OSType $osType }
        elseif ($osType -eq "Windows") { return Get-WindowsServerHealth -IP $IP -User $User -Password $Password }
        else { 
            Write-LogWarning -Message "OS Type unknown for $IP during health check." -Component "HealthMonitor"
            return [PSCustomObject]@{ IP = $IP; Status = "Unknown"; StatusColor = "Yellow"; CPU = $null; Memory = $null; Disk = $null; Uptime = $null; Load = $null; LastChecked = Get-Date; ErrorMessage = "Could not detect OS type" } 
        }
    }
    catch { 
        Write-LogError -Message "Exception in Get-ServerHealth for $IP" -Component "HealthMonitor" -Exception $_
        return [PSCustomObject]@{ IP = $IP; Status = "Error"; StatusColor = "Red"; CPU = $null; Memory = $null; Disk = $null; Uptime = $null; Load = $null; LastChecked = Get-Date; ErrorMessage = $_.Exception.Message } 
    }
}

<#
.SYNOPSIS
    Fetches hardware metrics from a Linux target.
.DESCRIPTION
    WHAT IT DOES: Retrieves system utilization (CPU, RAM, DISK) securely from the Debian/Ubuntu kernel.
    HOW IT WORKS: 
        1. Formats a massive single bash string wrapping `top`, `free`, `df`, and `uptime`.
        2. Applies deep `awk` and `grep` text-processing commands *on the remote server itself* to trim the output into tight numbers before returning them across the network.
        3. Analyzes the returned chunks, populating properties inside a PowerShell Custom Object.
        4. Calculates an overall Status string (`Healthy`, `Warning`, or `Critical`) based on usage percentages. E.g., > 90% CPU flags the server as Critical.
    WHY IT IS NEEDED: Consolidating these tools into one massive `echo` payload prevents the need for multiple heavy SSH connections per server, drastically reducing the time it takes the GUI to refresh.
.PARAMETER IP
    Target IP.
.PARAMETER User
    Target Username.
.PARAMETER Password
    Target Password.
.PARAMETER OSType
    String "Linux".
.OUTPUTS
    `PSCustomObject` containing organized telemetry metrics.
#>
function Get-LinuxServerHealth {
    param([string]$IP, [string]$User, [string]$Password, [string]$OSType = "Linux")
    Write-LogDebug -Message "Entering Get-LinuxServerHealth for IP: $IP" -Component "HealthMonitor"
    try {
        $healthCommand = @"
echo '===CPU===' && top -bn1 | grep 'Cpu(s)' | awk '{print 100 - `$8}' && \
echo '===MEMORY===' && free -m | awk 'NR==2{printf "%.1f %.1f %.1f", `$3, `$2, `$3*100/`$2}' && \
echo '===DISK===' && df -h / | awk 'NR==2{print `$5}' | tr -d '%' && \
echo '===UPTIME===' && uptime -p && \
echo '===LOAD===' && cat /proc/loadavg | awk '{print `$1, `$2, `$3}'
"@
        $result = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $healthCommand -OSType $OSType
        if ($null -eq $result) { throw "Failed to retrieve health metrics via SSH" }
        
        $resultLines = $result -split "`n"
        $cpuUsage = $null; $memoryUsed = $null; $memoryTotal = $null; $memoryPercent = $null; $diskPercent = $null; $uptime = $null; $load1 = $null; $load5 = $null; $load15 = $null
        
        $currentSection = ""
        foreach ($line in $resultLines) {
            $line = $line.Trim()
            if ($line -eq "===CPU===") { $currentSection = "CPU"; continue }
            if ($line -eq "===MEMORY===") { $currentSection = "MEMORY"; continue }
            if ($line -eq "===DISK===") { $currentSection = "DISK"; continue }
            if ($line -eq "===UPTIME===") { $currentSection = "UPTIME"; continue }
            if ($line -eq "===LOAD===") { $currentSection = "LOAD"; continue }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            
            switch ($currentSection) {
                "CPU" { 
                    if ($line -match '^-?\d+\.?\d*$') { 
                        $cpuUsage = [math]::Round([double]$line, 1) 
                    } 
                }
                "MEMORY" { 
                    $memParts = $line -split '\s+'
                    if ($memParts.Count -ge 3 -and $memParts[0] -match '^\d+\.?\d*$' -and $memParts[1] -match '^\d+\.?\d*$') { 
                        $memoryUsed = [double]$memParts[0]
                        $memoryTotal = [double]$memParts[1]
                        if ($memParts[2] -match '^\d+\.?\d*$') {
                            $memoryPercent = [math]::Round([double]$memParts[2], 1) 
                        }
                    } 
                }
                "DISK" { 
                    if ($line -match '^\d+\.?\d*$') { 
                        $diskPercent = [math]::Round([double]$line, 1) 
                    } 
                }
                "UPTIME" { 
                    if ($line -notmatch "^bash:") {
                        $uptime = $line -replace '^up\s+', '' 
                    }
                }
                "LOAD" { 
                    $loadParts = $line -split '\s+'
                    if ($loadParts.Count -ge 3 -and $loadParts[0] -match '^\d+\.?\d*$') { 
                        $load1 = $loadParts[0]; $load5 = $loadParts[1]; $load15 = $loadParts[2] 
                    } 
                }
            }
        }
        
        $status = "Healthy"; $statusColor = "Green"
        if (($cpuUsage -ne $null -and $cpuUsage -gt 90) -or ($memoryPercent -ne $null -and $memoryPercent -gt 90) -or ($diskPercent -ne $null -and $diskPercent -gt 90)) { 
            $status = "Critical"; $statusColor = "Red" 
        }
        elseif (($cpuUsage -ne $null -and $cpuUsage -gt 70) -or ($memoryPercent -ne $null -and $memoryPercent -gt 70) -or ($diskPercent -ne $null -and $diskPercent -gt 80)) { 
            $status = "Warning"; $statusColor = "Yellow" 
        }
        elseif ($cpuUsage -eq $null -and $memoryPercent -eq $null) {
            $status = "Degraded"; $statusColor = "Yellow"
        }
        
        return [PSCustomObject]@{ IP = $IP; OSType = "Linux"; Status = $status; StatusColor = $statusColor; CPU = [PSCustomObject]@{ UsagePercent = $cpuUsage }; Memory = [PSCustomObject]@{ UsedMB = $memoryUsed; TotalMB = $memoryTotal; UsagePercent = $memoryPercent }; Disk = [PSCustomObject]@{ UsagePercent = $diskPercent }; Uptime = $uptime; Load = [PSCustomObject]@{ Load1Min = $load1; Load5Min = $load5; Load15Min = $load15 }; LastChecked = Get-Date; ErrorMessage = $null }
    }
    catch { 
        Write-LogError -Message "Error in Get-LinuxServerHealth for $IP" -Component "HealthMonitor" -Exception $_
        return [PSCustomObject]@{ IP = $IP; OSType = "Linux"; Status = "Error"; StatusColor = "Red"; CPU = $null; Memory = $null; Disk = $null; Uptime = $null; Load = $null; LastChecked = Get-Date; ErrorMessage = $_.Exception.Message } 
    }
}

<#
.SYNOPSIS
    Fetches hardware metrics from a Windows target.
.DESCRIPTION
    WHAT IT DOES: Retrieves system utilization (CPU, RAM, DISK) securely from the Windows host Kernel.
    HOW IT WORKS: 
        1. Uses a native PowerShell runspace block executing on the target machine via WinRM.
        2. Retrieves the Host performance counters using `Get-CimInstance` WMI requests.
        3. Averages the load percentage of the `Win32_Processor` class, and parses `Win32_OperatingSystem` to deduce physical memory stats.
    WHY IT IS NEEDED: Gathering load values natively from the host Windows OS is vastly superior to tunneling a health-check command into the WSL kernel. Polling inside WSL would only report the internal VM's resources, neglecting the actual desktop workload occurring natively in Windows.
.PARAMETER IP
    Target IP.
.PARAMETER User
    Target Windows Username.
.PARAMETER Password
    Target Windows Password.
.OUTPUTS
    `PSCustomObject` containing organized telemetry metrics identical in structure to `Get-LinuxServerHealth`.
#>
function Get-WindowsServerHealth {
    param([string]$IP, [string]$User, [string]$Password)
    Write-LogDebug -Message "Entering Get-WindowsServerHealth for IP: $IP" -Component "HealthMonitor"
    try {
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        $session = New-PSSession -ComputerName $IP -Port $script:WinRMPort -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
        
        $healthData = Invoke-Command -Session $session -ScriptBlock {
            $cpuUsage = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
            $os = Get-CimInstance Win32_OperatingSystem
            $totalMemory = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
            $freeMemory = [math]::Round($os.FreePhysicalMemory / 1024, 0)
            return @{ CPU = $cpuUsage; MemoryUsed = ($totalMemory - $freeMemory); MemoryTotal = $totalMemory; MemoryPercent = [math]::Round((($totalMemory - $freeMemory) / $totalMemory) * 100, 1); DiskPercent = [math]::Round((((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").Size - (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace) / (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").Size) * 100, 1); Uptime = "{0} days, {1} hours, {2} minutes" -f ((Get-Date) - $os.LastBootUpTime).Days, ((Get-Date) - $os.LastBootUpTime).Hours, ((Get-Date) - $os.LastBootUpTime).Minutes; ProcessorQueueLength = (Get-CimInstance Win32_PerfFormattedData_PerfOS_System).ProcessorQueueLength }
        }
        Remove-PSSession -Session $session
        $status = "Healthy"; $statusColor = "Green"
        if (($healthData.CPU -gt 90) -or ($healthData.MemoryPercent -gt 90) -or ($healthData.DiskPercent -gt 90)) { $status = "Critical"; $statusColor = "Red" }
        elseif (($healthData.CPU -gt 70) -or ($healthData.MemoryPercent -gt 70) -or ($healthData.DiskPercent -gt 80)) { $status = "Warning"; $statusColor = "Yellow" }
        
        Write-LogDebug -Message "Successfully parsed Windows health stats for $IP" -Component "HealthMonitor"
        return [PSCustomObject]@{ IP = $IP; OSType = "Windows"; Status = $status; StatusColor = $statusColor; CPU = [PSCustomObject]@{ UsagePercent = $healthData.CPU }; Memory = [PSCustomObject]@{ UsedMB = $healthData.MemoryUsed; TotalMB = $healthData.MemoryTotal; UsagePercent = $healthData.MemoryPercent }; Disk = [PSCustomObject]@{ UsagePercent = $healthData.DiskPercent }; Uptime = $healthData.Uptime; Load = [PSCustomObject]@{ ProcessorQueueLength = $healthData.ProcessorQueueLength }; LastChecked = Get-Date; ErrorMessage = $null }
    } catch { 
        Write-LogError -Message "Error in Get-WindowsServerHealth for $IP" -Component "HealthMonitor" -Exception $_
        return [PSCustomObject]@{ IP = $IP; OSType = "Windows"; Status = "Error"; StatusColor = "Red"; ErrorMessage = $_.Exception.Message } 
    }
}

<#
.SYNOPSIS
    Queries Docker stats and metadata globally for a server.
.DESCRIPTION
    WHAT IT DOES: Collects the operational status, resource metrics, restart loops, and network ports for every single container.
    HOW IT WORKS: 
        1. Formats a deeply nested bash subshell utilizing Go templates (`--format "{{...}}"`) to extract precise data points from the Docker daemon.
        2. Specifically, it chains `docker ps -a`, `docker inspect`, and `docker stats --no-stream` separating them with delimiter strings (e.g. `===STATS===`).
        3. Once the output returns, it splits the payload by the custom delimiters and pushes the text arrays into three corresponding Hashtables mapping by `ContainerID`.
        4. It combines the Maps into an organized Array of `PSCustomObject`s for the GUI.
    WHY IT IS NEEDED: Previously, querying Docker stats was unoptimized and created an SSH connection per container, ballooning load times to >4 minutes per machine. Using inline bash Go formatting queries the complete container list, resources, and health checks concurrently in 3 seconds, preventing the UI from timing out.
.PARAMETER IP
    Target IP.
.PARAMETER User
    Target Username.
.PARAMETER Password
    Target Password.
.PARAMETER ContainerName
    (Optional) Filter by container name.
.PARAMETER OSType
    (Optional) Target OS.
.OUTPUTS
    `PSCustomObject` containing an array of `$Containers` and overall container system status.
#>
function Get-ContainerHealth {
    param([string]$IP, [string]$User, [string]$Password, [string]$ContainerName = $null, [string]$OSType = $null)
    Write-LogDebug -Message "Entering Get-ContainerHealth for IP: $IP" -Component "HealthMonitor"
    try {
        $osType = if (-not [string]::IsNullOrEmpty($OSType)) { $OSType } else { Get-TargetOS -IP $IP }
        $batchCommand = 'docker ps -a --format "{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}|{{.State}}" 2>/dev/null && echo "===INSPECT===" && (docker inspect --format "{{.ID}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}|{{.RestartCount}}" $(docker ps -aq 2>/dev/null) 2>/dev/null || true) && echo "===STATS===" && (docker stats --no-stream --format "{{.ID}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}" 2>/dev/null || true)'
        $result = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $batchCommand -OSType $osType
        
        $result = $result -join "`n"
        if ($null -eq $result -or [string]::IsNullOrWhiteSpace($result)) {
            Write-LogWarning -Message "Docker not accessible on $IP" -Component "HealthMonitor"
            return [PSCustomObject]@{ ServerIP = $IP; Status = "DockerNotAccessible"; StatusColor = "Red"; ErrorMessage = "Docker not accessible"; Containers = @() }
        }
        
        $sections = $result -split "===INSPECT==="
        $psOutput = $sections[0]
        
        $inspectOutput = ""
        $statsOutput = ""
        if ($sections.Count -gt 1) {
            $subSections = $sections[1] -split "===STATS==="
            $inspectOutput = $subSections[0]
            if ($subSections.Count -gt 1) { $statsOutput = $subSections[1] }
        }
        
        $inspectMap = @{}
        foreach ($line in ($inspectOutput -split "`n")) {
            $p = $line.Trim() -split '\|'
            if ($p.Count -ge 3) {
                $shortId = $p[0].Trim().Substring(0, [Math]::Min(12, $p[0].Trim().Length))
                $inspectMap[$shortId] = @{ Health = $p[1].Trim(); Restarts = [int]($p[2].Trim() -as [int]) }
            }
        }
        
        $statsMap = @{}
        foreach ($line in ($statsOutput -split "`n")) {
            $p = $line.Trim() -split '\|'
            if ($p.Count -ge 4) {
                $shortId = $p[0].Trim().Substring(0, [Math]::Min(12, $p[0].Trim().Length))
                $statsMap[$shortId] = @{ CPU = $p[1].Trim() -replace '%', ''; MemUsage = $p[2].Trim(); MemPerc = $p[3].Trim() -replace '%', '' }
            }
        }
        
        $containers = @()
        $containerLines = $psOutput -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        foreach ($line in $containerLines) {
            $parts = $line -split '\|'
            if ($parts.Count -lt 6) { continue }
            $cId = $parts[0].Trim()
            $cName = $parts[1].Trim()
            $cImage = $parts[2].Trim()
            $cStatus = $parts[3].Trim()
            $cPorts = $parts[4].Trim()
            $cState = $parts[5].Trim()
            if (-not [string]::IsNullOrEmpty($ContainerName) -and $cName -ne $ContainerName) { continue }
            
            $shortId = $cId.Substring(0, [Math]::Min(12, $cId.Length))
            $insp = if ($inspectMap.ContainsKey($shortId)) { $inspectMap[$shortId] } else { @{ Health = "N/A"; Restarts = 0 } }
            $stat = if ($statsMap.ContainsKey($shortId)) { $statsMap[$shortId] } else { @{ CPU = $null; MemUsage = $null; MemPerc = $null } }
            
            $containerStatusColor = "Green"
            if ($cState -ne "running" -or $insp.Health -eq "unhealthy") { $containerStatusColor = "Red" }
            elseif ($insp.Health -eq "starting" -or $insp.Restarts -gt 5) { $containerStatusColor = "Yellow" }
            $containers += [PSCustomObject]@{ 
                ContainerId = $cId
                Name = $cName
                Image = $cImage
                State = $cState
                Status = $cStatus
                Ports = $cPorts
                HealthCheck = $insp.Health
                CPUPercent = $stat.CPU
                MemoryUsage = $stat.MemUsage
                MemoryPercent = $stat.MemPerc
                NetworkIO = $null
                BlockIO = $null
                RestartCount = $insp.Restarts
                StatusColor = $containerStatusColor 
            }
        }
        
        $overallStatus = "Healthy"; $overallColor = "Green"
        $runningCount = ($containers | Where-Object { $_.State -eq "running" }).Count
        $totalCount = $containers.Count
        $unhealthyCount = ($containers | Where-Object { $_.HealthCheck -eq "unhealthy" -or $_.State -ne "running" }).Count
        if ($unhealthyCount -gt 0) { if ($runningCount -eq 0) { $overallStatus = "Critical"; $overallColor = "Red" } else { $overallStatus = "Warning"; $overallColor = "Yellow" } }
        
        Write-LogDebug -Message "Successfully parsed $($containers.Count) containers on $IP" -Component "HealthMonitor"
        return [PSCustomObject]@{ ServerIP = $IP; Status = $overallStatus; StatusColor = $overallColor; TotalContainers = $totalCount; RunningContainers = $runningCount; StoppedContainers = $totalCount - $runningCount; UnhealthyContainers = $unhealthyCount; ErrorMessage = $null; Containers = $containers; LastChecked = Get-Date }
    }
    catch { 
        Write-LogError -Message "Error in Get-ContainerHealth for $IP" -Component "HealthMonitor" -Exception $_
        return [PSCustomObject]@{ ServerIP = $IP; Status = "Error"; StatusColor = "Red"; TotalContainers = 0; RunningContainers = 0; StoppedContainers = 0; UnhealthyContainers = 0; ErrorMessage = $_.Exception.Message; Containers = @(); LastChecked = Get-Date } 
    }
}

<#
.SYNOPSIS
    Container Action: Restart.
.DESCRIPTION
    WHAT IT DOES: Actively bounces a remote container.
    HOW IT WORKS: Uses `Invoke-RemoteCommand` to run `docker restart` on the target host. It catches the stdout echo to verify the daemon responded successfully.
    WHY IT IS NEEDED: Tied to the dynamic Health Monitor GUI card buttons. Gives operators point-and-click control over broken containers.
.PARAMETER IP
    Target IP.
.PARAMETER User
    Target Username.
.PARAMETER Password
    Target Password.
.PARAMETER ContainerName
    String matching the target Docker Container name.
.OUTPUTS
    Boolean value confirming success or failure.
#>
function Restart-Container {
    param([string]$IP, [string]$User, [string]$Password, [string]$ContainerName)
    Write-LogDebug -Message "Entering Restart-Container for $ContainerName on $IP" -Component "DockerOps"
    try {
        $result = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command "docker restart $ContainerName 2>&1 && echo 'RESTART_SUCCESS' || echo 'RESTART_FAILED'"
        $success = ($result -match "RESTART_SUCCESS")
        if ($success) { Write-LogInfo -Message "Successfully restarted $ContainerName on $IP" -Component "DockerOps" }
        else { Write-LogWarning -Message "Failed to restart $ContainerName on $IP" -Component "DockerOps" }
        return $success
    } catch {
        Write-LogError -Message "Error in Restart-Container on $IP" -Component "DockerOps" -Exception $_
        return $false
    }
}

<#
.SYNOPSIS
    Container Action: Stop.
.DESCRIPTION
    WHAT IT DOES: Actively stops a remote container.
    HOW IT WORKS: Uses `Invoke-RemoteCommand` to run `docker stop` on the target host.
    WHY IT IS NEEDED: Tied to the dynamic Health Monitor GUI card buttons. Gives operators point-and-click control over active containers.
.PARAMETER IP
    Target IP.
.PARAMETER User
    Target Username.
.PARAMETER Password
    Target Password.
.PARAMETER ContainerName
    String matching the target Docker Container name.
.OUTPUTS
    Boolean value confirming success or failure.
#>
function Stop-Container {
    param([string]$IP, [string]$User, [string]$Password, [string]$ContainerName)
    Write-LogDebug -Message "Entering Stop-Container for $ContainerName on $IP" -Component "DockerOps"
    try {
        $result = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command "docker stop $ContainerName 2>&1 && echo 'STOP_SUCCESS' || echo 'STOP_FAILED'"
        $success = ($result -match "STOP_SUCCESS")
        if ($success) { Write-LogInfo -Message "Successfully stopped $ContainerName on $IP" -Component "DockerOps" }
        else { Write-LogWarning -Message "Failed to stop $ContainerName on $IP" -Component "DockerOps" }
        return $success
    } catch {
        Write-LogError -Message "Error in Stop-Container on $IP" -Component "DockerOps" -Exception $_
        return $false
    }
}

<#
.SYNOPSIS
    Container Action: Start.
.DESCRIPTION
    WHAT IT DOES: Actively boots an offline container.
    HOW IT WORKS: Uses `Invoke-RemoteCommand` to run `docker start` on the target host.
    WHY IT IS NEEDED: Tied to the dynamic Health Monitor GUI card buttons. Gives operators point-and-click control over stopped containers.
.PARAMETER IP
    Target IP.
.PARAMETER User
    Target Username.
.PARAMETER Password
    Target Password.
.PARAMETER ContainerName
    String matching the target Docker Container name.
.OUTPUTS
    Boolean value confirming success or failure.
#>
function Start-Container {
    param([string]$IP, [string]$User, [string]$Password, [string]$ContainerName)
    Write-LogDebug -Message "Entering Start-Container for $ContainerName on $IP" -Component "DockerOps"
    try {
        $result = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command "docker start $ContainerName 2>&1 && echo 'START_SUCCESS' || echo 'START_FAILED'"
        $success = ($result -match "START_SUCCESS")
        if ($success) { Write-LogInfo -Message "Successfully started $ContainerName on $IP" -Component "DockerOps" }
        else { Write-LogWarning -Message "Failed to start $ContainerName on $IP" -Component "DockerOps" }
        return $success
    } catch {
        Write-LogError -Message "Error in Start-Container on $IP" -Component "DockerOps" -Exception $_
        return $false
    }
}

<#
.SYNOPSIS
    Combines machine resources and docker resources into a single structured object.
.DESCRIPTION
    WHAT IT DOES: Generates a monolithic data object reflecting the entire state of a server.
    HOW IT WORKS: Sequentially invokes `Get-ServerHealth` and `Get-ContainerHealth` and maps the returns to `.Server` and `.Containers` sub-properties. Evaluates combined threshold criteria to establish an `.OverallStatus`.
    WHY IT IS NEEDED: Creates a highly structured, single-variable data entity that the `Format-HealthReport` function can easily serialize into a `.txt` file export.
.PARAMETER IP
    Target IP.
.PARAMETER User
    Target Username.
.PARAMETER Password
    Target Password.
.OUTPUTS
    PSCustomObject containing full hardware and software status maps.
#>
function Get-FullHealthReport {
    param([string]$IP, [string]$User, [string]$Password)
    try {
        $serverHealth = Get-ServerHealth -IP $IP -User $User -Password $Password
        $containerHealth = Get-ContainerHealth -IP $IP -User $User -Password $Password
        $overallStatus = "Healthy"; $overallColor = "Green"
        
        if ($serverHealth.Status -eq "Critical" -or $serverHealth.Status -eq "Error" -or $serverHealth.Status -eq "Offline" -or $containerHealth.Status -eq "Critical") { $overallStatus = "Critical"; $overallColor = "Red" }
        elseif ($serverHealth.Status -eq "Warning" -or $serverHealth.Status -eq "Degraded" -or $containerHealth.Status -eq "Warning") { $overallStatus = "Warning"; $overallColor = "Yellow" }
        
        return [PSCustomObject]@{ IP = $IP; OverallStatus = $overallStatus; OverallStatusColor = $overallColor; Server = $serverHealth; Containers = $containerHealth; ReportGeneratedAt = Get-Date }
    }
    catch { return [PSCustomObject]@{ IP = $IP; OverallStatus = "Error"; OverallStatusColor = "Red"; Server = $null; Containers = $null; ReportGeneratedAt = Get-Date; ErrorMessage = $_.Exception.Message } }
}

<#
.SYNOPSIS
    Formats a payload for export to a text file.
.DESCRIPTION
    WHAT IT DOES: Converts the complex object matrix from `Get-FullHealthReport` into a human-readable text block.
    HOW IT WORKS: Iterates through the properties of the PSCustomObject, mapping variables to neatly aligned string arrays using spacing paddings and separator lines.
    WHY IT IS NEEDED: Fulfills the GUI's "Export Report" button functionality, creating clean, standardized `.txt` audit reports.
.PARAMETER HealthReport
    The PSCustomObject returned from Get-FullHealthReport.
.PARAMETER OutputFormat
    Legacy parameter for future extension (e.g. JSON, HTML). Currently defaults to "Console".
.OUTPUTS
    A joined string.
#>
function Format-HealthReport {
    param([PSCustomObject]$HealthReport, [string]$OutputFormat = "Console")
    $output = @(); $output += "================================================================================"; $output += "  HEALTH REPORT: $($HealthReport.IP)"; $output += "  Generated: $($HealthReport.ReportGeneratedAt.ToString('yyyy-MM-dd HH:mm:ss'))"; $output += "  Overall Status: $($HealthReport.OverallStatus)"; $output += "================================================================================"
    if ($HealthReport.Server) { $s = $HealthReport.Server; $output += ""; $output += "  SERVER HEALTH"; $output += "  ------------------------------------------------------------------------------"; $output += "   Status: $($s.Status)"; if ($s.CPU) { $output += "   CPU Usage: $($s.CPU.UsagePercent)%" }; if ($s.Memory) { $output += "   Memory: $($s.Memory.UsedMB)MB / $($s.Memory.TotalMB)MB ($($s.Memory.UsagePercent)%)" }; if ($s.Disk) { $output += "   Disk Usage: $($s.Disk.UsagePercent)%" }; if ($s.Uptime) { $output += "   Uptime: $($s.Uptime)" }; if ($s.Load -and $s.Load.Load1Min) { $output += "   Load Average: $($s.Load.Load1Min) / $($s.Load.Load5Min) / $($s.Load.Load15Min)" }; $output += "  ------------------------------------------------------------------------------" }
    if ($HealthReport.Containers) { $c = $HealthReport.Containers; $output += ""; $output += "  CONTAINER HEALTH"; $output += "  ------------------------------------------------------------------------------"; $output += "   Status: $($c.Status)"; $output += "   Total: $($c.TotalContainers) | Running: $($c.RunningContainers) | Stopped: $($c.StoppedContainers)"; $output += "  ------------------------------------------------------------------------------"; if ($c.Containers -and $c.Containers.Count -gt 0) { foreach ($container in $c.Containers) { $stateIcon = if ($container.State -eq "running") { "[RUNNING]" } else { "[STOPPED]" }; $output += "   $stateIcon $($container.Name)"; $output += "     Image: $($container.Image)"; $output += "     Status: $($container.Status)"; if ($container.State -eq "running" -and $container.CPUPercent) { $output += "     CPU: $($container.CPUPercent)% | Memory: $($container.MemoryUsage) ($($container.MemoryPercent)%)" }; if ($container.RestartCount -gt 0) { $output += "     Restarts: $($container.RestartCount)" }; $output += "  ------------------------------------------------------------------------------" } } else { $output += "   No containers found" }; $output += "================================================================================" }
    $output += ""
    return ($output -join "`n")
}

<#
.SYNOPSIS
    Verifies HTTP and TCP connectivity for arbitrary ports on targets.
#>
function Test-ServiceHealth {
    param([string]$IP, [int]$Port, [string]$ServiceName = "Service", [string]$HttpPath = $null)
    try {
        $tcpResult = Test-NetConnection -ComputerName $IP -Port $Port -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if (-not $tcpResult.TcpTestSucceeded) { return [PSCustomObject]@{ ServiceName = $ServiceName; IP = $IP; Port = $Port; Status = "Unavailable"; StatusColor = "Red"; TcpConnected = $false; HttpStatus = $null; ResponseTime = $null } }
        $responseTime = $tcpResult.PingReplyDetails.RoundtripTime; $httpStatus = $null
        if (-not [string]::IsNullOrEmpty($HttpPath)) { try { $uri = "http://${IP}:${Port}${HttpPath}"; $stopwatch = [System.Diagnostics.Stopwatch]::StartNew(); $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop; $stopwatch.Stop(); $responseTime = $stopwatch.ElapsedMilliseconds; $httpStatus = [int]$response.StatusCode } catch { $httpStatus = "Error" } }
        $status = "Healthy"; $statusColor = "Green"
        if ($httpStatus -and $httpStatus -ne 200 -and $httpStatus -ne "Error") { if ($httpStatus -ge 500) { $status = "Critical"; $statusColor = "Red" } else { $status = "Warning"; $statusColor = "Yellow" } } elseif ($httpStatus -eq "Error") { $status = "Degraded"; $statusColor = "Yellow" }
        return [PSCustomObject]@{ ServiceName = $ServiceName; IP = $IP; Port = $Port; Status = $status; StatusColor = $statusColor; TcpConnected = $true; HttpStatus = $httpStatus; ResponseTime = $responseTime }
    }
    catch { return [PSCustomObject]@{ ServiceName = $ServiceName; IP = $IP; Port = $Port; Status = "Error"; StatusColor = "Red"; TcpConnected = $false; HttpStatus = $null; ResponseTime = $null; ErrorMessage = $_.Exception.Message } }
}

<#
.SYNOPSIS
    Automated network sweep.
#>
function Test-CommonServices {
    param([string]$IP)
    $commonServices = @( @{ Port = 22; Name = "SSH" }, @{ Port = 80; Name = "HTTP" }, @{ Port = 443; Name = "HTTPS" }, @{ Port = 8080; Name = "HTTP Alt" }, @{ Port = 9000; Name = "Portainer" }, @{ Port = 9090; Name = "Prometheus" }, @{ Port = 3000; Name = "Grafana" }, @{ Port = 8443; Name = "Traefik Dashboard" }, @{ Port = 53; Name = "DNS" }, @{ Port = 5985; Name = "WinRM" } )
    $results = @()
    foreach ($service in $commonServices) { $result = Test-ServiceHealth -IP $IP -Port $service.Port -ServiceName $service.Name; if ($result.TcpConnected) { $results += $result } }
    return $results
}
#endregion

#===============================================================================
#region SERVICE INSTALLATION FUNCTIONS
#===============================================================================
<#
.SYNOPSIS
    Universal Docker Compose deploying wrapper.
.DESCRIPTION
    WHAT IT DOES: Pushes the active Compose file to the target machine and executes it safely.
    HOW IT WORKS: 
        1. Employs regex matching (`[regex]::Matches`) to extract requested Volume mapped paths (e.g. `./data`) out of the Compose file.
        2. Automatically formats `mkdir -p` bash commands to create those directories so the container volumes don't crash from missing paths.
        3. If Port 53 is detected in the yaml, it injects a bash string to gracefully disable Ubuntu's internal `systemd-resolved` DNS stub listener, restarting systemd to free the port automatically.
        4. Base64 encodes the YAML text to protect syntax during SSH transport.
        5. Chains the directory creation, network provisioning, file decoding, teardown (`docker compose down`), and redeployment (`docker compose up`) commands using bash semicolons into a single massive command batch.
    WHY IT IS NEEDED: Instead of opening a new SSH connection for every single command—which would take upwards of two minutes—constructing a massive batched bash string separated by semicolons reduces a complex sequential setup into a single 10-second remote payload.
.PARAMETER IP
    Target IP.
.PARAMETER User
    Target Username.
.PARAMETER Password
    Target Password.
.PARAMETER ServiceName
    String Name identifying the deployment folder (e.g. "AdGuard").
.PARAMETER ComposeContent
    The full raw string of the `.yml` config.
.PARAMETER OSType
    (Optional) Target OS.
.OUTPUTS
    Boolean value confirming success or failure.
#>
function Deploy-DockerService {
    param (
        [string]$IP,
        [string]$User,
        [string]$Password,
        [string]$ServiceName,
        [string]$ComposeContent,
        [string]$OSType = $null
    )
    Write-LogDebug -Message "Entering Deploy-DockerService for $ServiceName on $IP" -Component "Deployment"
    try {
        $os = if (-not [string]::IsNullOrEmpty($OSType)) { $OSType } else { Get-TargetOS -IP $IP }
        Write-Host "`nStarting $ServiceName deployment on $IP..." -ForegroundColor Cyan
        
        # 0. SMART FIX: Free up Port 53 from systemd-resolved if the config requires it
        if ($ComposeContent -match '53:53') {
            Write-LogInfo -Message "Port 53 detected in config. Attempting systemd-resolved fix." -Component "Deployment"
            Write-Host "Port 53 detected in config. Freeing up port from systemd-resolved..." -ForegroundColor Yellow
            $dnsFixCmd = "sudo mkdir -p /etc/systemd/resolved.conf.d && echo '[Resolve]' | sudo tee /etc/systemd/resolved.conf.d/adguard-fix.conf > /dev/null && echo 'DNSStubListener=no' | sudo tee -a /etc/systemd/resolved.conf.d/adguard-fix.conf > /dev/null && sudo systemctl restart systemd-resolved 2>/dev/null || true"
            Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $dnsFixCmd -OSType $os | Out-Null
        }
        
        # 1. Map Directories
        $dirCommand = "mkdir -p /home/$User/$ServiceName"
        $matches = [regex]::Matches($ComposeContent, '-\s+"\./([^:]+):|-\s+\./([^:]+):')
        $dirs = @()
        foreach ($match in $matches) {
            $val = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
            if ($val -notmatch '\.(yml|yaml|json|txt|conf|ini|toml)$') { $dirs += $val }
        }
        $dirs = $dirs | Select-Object -Unique
        foreach ($dir in $dirs) { $dirCommand += " /home/$User/$ServiceName/$dir" }
        
        $composeBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ComposeContent))
        
        # BATCHED: Executes directories, compose file, teardown, networking, and deployment in a single SSH stream
        $batchCmd = "$dirCommand 2>/dev/null || true;"
        $batchCmd += " cd /home/$User/$ServiceName;"
        $batchCmd += " sudo docker compose down 2>/dev/null || true;"
        $batchCmd += " echo '$composeBase64' | base64 -d > docker-compose.yml;"
        if ($ComposeContent -match 'traefik-network') {
            $batchCmd += " sudo docker network create traefik-network 2>/dev/null || true;"
        }
        $batchCmd += " sudo docker compose up -d 2>&1"
        
        Write-Host "Deploying $ServiceName with Docker Compose..." -ForegroundColor Cyan
        $deployResult = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $batchCmd -OSType $os
        
        # Verify status
        Start-Sleep -Seconds 5
        $verifyResult = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command "cd /home/$User/$ServiceName && sudo docker compose ps" -OSType $os
        
        if ($verifyResult -match "Up|running") {
            Write-LogSuccess -Message "$ServiceName installed successfully on $IP" -Component "Deployment"
            Write-Host "$ServiceName installed successfully!" -ForegroundColor Green
            return $true
        } else {
            Write-LogWarning -Message "$ServiceName deployment failed on $IP. Output: $deployResult" -Component "Deployment"
            Write-Host "$ServiceName deployment failed. Output: $deployResult" -ForegroundColor Red
            return $false
        }
    } catch {
        Write-LogError -Message "Error during Deploy-DockerService for $ServiceName on $IP" -Component "Deployment" -Exception $_
        return $false
    }
}

<#
.SYNOPSIS
    Automated Docker Engine installer for native Linux servers.
.DESCRIPTION
    WHAT IT DOES: Implements the official Docker-CE remote installation scripts automatically.
    HOW IT WORKS: 
        1. Probes the server for an existing Docker instance (`docker --version`). Skips to success if found.
        2. Constructs a monolithic `apt-get` bash payload.
        3. Installs `curl`, downloads Docker's official GPG encryption key (`docker.asc`), and mounts it in `/etc/apt/keyrings`.
        4. Detects the host's release (`$VERSION_CODENAME`) and registers the `stable` Docker repository in the apt sources list.
        5. Installs `docker-ce`, `docker-compose-plugin`, enables the systemd service, and adds the current Linux User to the `docker` usergroup (so deployments don't need persistent sudo elevation).
    WHY IT IS NEEDED: Ensures a clean, identical, standardized version of Docker exists on the host machine before deploying infrastructure, entirely bypassing the need for manual setup.
.PARAMETER IP
    Target IP.
.PARAMETER User
    Target Username.
.PARAMETER Password
    Target Password.
.PARAMETER OSType
    (Optional) Target OS.
.OUTPUTS
    Boolean value confirming success or failure.
#>
function Install-DockerLinux {
    param([string]$IP, [string]$User, [string]$Password, [string]$OSType = $null)
    Write-LogDebug -Message "Entering Install-Docker for IP: $IP" -Component "Deployment"
    try {
        $os = if (-not [string]::IsNullOrEmpty($OSType)) { $OSType } else { Get-TargetOS -IP $IP }
        $dockerCheck = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command "docker --version" -OSType $os
        if ($null -ne $dockerCheck -and $dockerCheck -match "Docker version") { 
            Write-LogInfo -Message "Docker is already installed on $IP" -Component "Deployment"
            return $true 
        }
        
        # BATCHED INSTALL: Executes the entire Docker setup in a single SSH session
        $installCmd = "sudo apt-get update -y && sudo apt-get install -y ca-certificates curl && "
        $installCmd += "sudo install -m 0755 -d /etc/apt/keyrings && "
        $installCmd += "OS_ID=`$(. /etc/os-release && echo `$ID) && "
        $installCmd += "OS_CODE=`$(. /etc/os-release && echo `$VERSION_CODENAME) && "
        $installCmd += "sudo curl -fsSL https://download.docker.com/linux/`$OS_ID/gpg -o /etc/apt/keyrings/docker.asc && "
        $installCmd += "sudo chmod a+r /etc/apt/keyrings/docker.asc && sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.sources && "
        $installCmd += "echo `"Types: deb`nURIs: https://download.docker.com/linux/`$OS_ID`nSuites: `$OS_CODE`nComponents: stable`nSigned-By: /etc/apt/keyrings/docker.asc`" | sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null && "
        $installCmd += "sudo apt-get update -y && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin && "
        $installCmd += "sudo systemctl start docker && sudo systemctl enable docker && sudo usermod -aG docker $User"
        
        Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $installCmd -OSType $os | Out-Null
        
        $verifyResult = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command "docker --version" -OSType $os
        $success = ($null -ne $verifyResult -and $verifyResult -match "Docker version")
        if ($success) { Write-LogSuccess -Message "Docker successfully installed on $IP" -Component "Deployment" }
        else { Write-LogWarning -Message "Docker installation verification failed on $IP" -Component "Deployment" }
        
        return $success
    } catch { 
        Write-LogError -Message "Error during Install-Docker on $IP" -Component "Deployment" -Exception $_
        return $false 
    }
}

<#
.SYNOPSIS
    Automated Docker Engine installer for WSL2 environments.
.DESCRIPTION
    WHAT IT DOES: Replicates `Install-DockerLinux` but adds mandatory pre-flight checks and hardware optimizations designed strictly for the Windows Subsystem for Linux.
    HOW IT WORKS: 
        1. Issues an initial WinRM command to configure the WSL User Profile.
        2. Injects a custom `wsl.conf` file to forcefully enable `systemd` inside the subsystem (critical for running Docker natively in Windows without using Docker Desktop).
        3. Generates a `.wslconfig` on the host side, locking the VM hypervisor to 8GB of RAM and 4 Processors.
        4. Invokes `wsl --shutdown` to reboot the kernel, then pushes the standard Linux Docker-CE installation payload into the new Systemd environment.
    WHY IT IS NEEDED: WSL2 natively blocks raw Systemd initialization and limits system resources aggressively. The `.wslconfig` bump ensures containers don't crash from OOM (Out-of-Memory) errors during heavy IO tasks.
.PARAMETER IP
    Target IP.
.PARAMETER User
    Target Username.
.PARAMETER Password
    Target Password.
.PARAMETER OSType
    (Optional) Target OS.
.OUTPUTS
    Boolean value confirming success or failure.
#>
function Install-DockerWSL2 {
    param([string]$IP, [string]$User, [string]$Password, [string]$OSType = $null)
    Write-LogDebug -Message "Entering Install-Docker for IP: $IP" -Component "Deployment"
    try {
        $os = if (-not [string]::IsNullOrEmpty($OSType)) { $OSType } else { Get-TargetOS -IP $IP }
        
        if ($os -eq "Windows") {
            Write-LogInfo -Message "Enabling systemd and configuring WSL2 user profile on Windows host." -Component "Deployment"
            $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
            $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
            $session = New-PSSession -ComputerName $IP -Port $script:WinRMPort -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
            
            # CRITICAL FIX: Pipe the setup block to Out-Null to prevent WinRM from polluting the return value
            Invoke-Command -Session $session -ScriptBlock {
                param($LinuxUser)
                $env:WSL_UTF8=1
                $wslExe = if (Test-Path "$env:windir\sysnative\wsl.exe") { "$env:windir\sysnative\wsl.exe" } else { "wsl.exe" }
                
                & $wslExe -u root -- bash -c "id -u $LinuxUser &>/dev/null || useradd -m -G adm,cdrom,sudo,dip,plugdev,users -s /bin/bash $LinuxUser"
                
                $wslConf = "[boot]`nsystemd=true`n[user]`ndefault=$LinuxUser`n[network]`ngenerateResolvConf=false`ngenerateHosts=true"
                $wslConf | & $wslExe -u root -- tee /etc/wsl.conf > $null
                
                $wslConfig = "[wsl2]`nmemory=4GB`nprocessors=2`nswap=2GB"
                $wslConfig | Out-File -FilePath "$env:USERPROFILE\.wslconfig" -Encoding UTF8 -Force
                
                & $wslExe --shutdown
                Start-Sleep -Seconds 5
                
                & $wslExe -u root -- bash -c "sleep 2" *>$null
            } -ArgumentList $User | Out-Null
            
            Remove-PSSession -Session $session
        }
        $dockerCheck = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command "docker --version" -OSType $os
        if ($null -ne $dockerCheck -and $dockerCheck -match "Docker version") { 
            Write-LogInfo -Message "Docker is already installed on $IP" -Component "Deployment"
            return $true 
        }
        
        $installCmd = @"
export DEBIAN_FRONTEND=noninteractive
while [ "`$(systemctl is-system-running 2>/dev/null)" = "starting" ]; do sleep 1; done
sleep 15
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
echo 'nameserver 8.8.8.8' > /etc/resolv.conf
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=`$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu `$(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker || true
usermod -aG docker $User
"@
        Write-LogInfo -Message "Running Docker installation script on $IP..." -Component "Deployment"
        $dockerOutput = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $installCmd -OSType $os
        
        if (-not [string]::IsNullOrWhiteSpace($dockerOutput)) {
            Write-LogInfo -Message "Docker Install Output: $dockerOutput" -Component "Deployment"
            Write-Host "Docker Install Output: $dockerOutput" -ForegroundColor Gray
        }
        
        $verifyResult = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command "docker --version" -OSType $os
        $success = ($null -ne $verifyResult -and $verifyResult -match "Docker version")
        
        if ($success) { Write-LogSuccess -Message "Docker successfully installed on $IP" -Component "Deployment" }
        else { 
            Write-LogWarning -Message "Docker installation verification failed on $IP" -Component "Deployment"
            if (-not [string]::IsNullOrWhiteSpace($dockerOutput)) {
                Write-LogError -Message "DOCKER INSTALL LOGS: $dockerOutput" -Component "Deployment"
            }
        }
        
        return $success
    } catch { 
        Write-LogError -Message "Error during Install-Docker on $IP" -Component "Deployment" -Exception $_
        return $false 
    }
}

<#
.SYNOPSIS
    Deploys Traefik reverse proxy.
.DESCRIPTION
    WHAT IT DOES: Before invoking the standard `Deploy-DockerService`, this creates the required files for Let's Encrypt certificate acquisition.
    HOW IT WORKS: Uses a pre-formatted bash payload containing `touch` and `chmod 600` targeted at the `acme.json` file inside the Traefik deployment folder. Finally, passes execution to `Deploy-DockerService` to bring the proxy online.
    WHY IT IS NEEDED: Traefik's security model dictates that it will purposefully crash and refuse to run if its certificate storage file (`acme.json`) does not have strict Unix 600 (read/write for owner only) permissions prior to container execution. This step guarantees the permission structure.
.PARAMETER IP
    Target IP.
.PARAMETER User
    Target Username.
.PARAMETER Password
    Target Password.
.PARAMETER Email
    Email to use for Let's Encrypt generation.
.PARAMETER Domain
    Domain for routing.
.PARAMETER OSType
    (Optional) Target OS.
.PARAMETER ComposeContent
    Optional raw YAML string of the specific Traefik template.
.OUTPUTS
    Boolean value confirming success or failure.
#>
function Install-Traefik {
    param(
        [string]$IP, 
        [string]$User, 
        [string]$Password, 
        [string]$Email = "admin@localhost", 
        [string]$Domain = "localhost", 
        [string]$OSType = $null,
        [string]$ComposeContent = $null
    )
    Write-LogDebug -Message "Entering Install-Traefik for IP: $IP" -Component "Deployment"
    try {
        $os = if (-not [string]::IsNullOrEmpty($OSType)) { $OSType } else { Get-TargetOS -IP $IP }
        $traefikConfig = @"
api:
  dashboard: true
  insecure: true
entryPoints:
  web:
    address: ':80'
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ':443'
    http:
      tls:
        certResolver: letsencrypt
providers:
  docker:
    endpoint: 'unix:///var/run/docker.sock'
    exposedByDefault: false
    network: traefik-network
certificatesResolvers:
  letsencrypt:
    acme:
      email: $Email
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web
log:
  level: INFO
"@
        $configBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($traefikConfig))
        
        # BATCHED: Directory creation, acme.json setup, and yaml transfer in one call
        $batchCmd = "mkdir -p /home/$User/traefik/letsencrypt && touch /home/$User/traefik/letsencrypt/acme.json && chmod 600 /home/$User/traefik/letsencrypt/acme.json && echo '$configBase64' | base64 -d > /home/$User/traefik/traefik.yml"
        Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $batchCmd -OSType $os | Out-Null
        
        $compose = $ComposeContent
        if ([string]::IsNullOrWhiteSpace($compose)) {
            $compose = @"
services:
  traefik:
    image: traefik:latest
    container_name: traefik
    restart: always
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/traefik.yml:ro
      - ./letsencrypt:/letsencrypt
    networks:
      - traefik-network
networks:
  traefik-network:
    external: true
"@
        }
        $result = Deploy-DockerService -IP $IP -User $User -Password $Password -ServiceName "traefik" -ComposeContent $compose -OSType $os
        if ($result) { Write-LogSuccess -Message "Traefik deployed successfully on $IP" -Component "Deployment" }
        return $result
    } catch {
        Write-LogError -Message "Error during Install-Traefik on $IP" -Component "Deployment" -Exception $_
        return $false
    }
}
#endregion

#===============================================================================
#region WSL2 SETUP FUNCTIONS (WINDOWS)
#===============================================================================
<#
.SYNOPSIS
    Evaluates a Windows machine's state against WSL2 requirements.
.DESCRIPTION
    WHAT IT DOES: Validates the prerequisites required for running Linux environments on a Windows host.
    HOW IT WORKS: 
        1. Issues a WinRM block using `Get-WindowsOptionalFeature`.
        2. Probes for `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform`.
        3. Asserts that the WSL2 Kernel is installed (checking for "must be updated" outputs).
        4. Confirms that the target distribution (e.g. `Ubuntu-22.04`) is loaded.
    WHY IT IS NEEDED: Used to conditionally skip steps in the heavy `Install-WSL2` orchestrator function, accelerating the deployment when running against pre-configured servers.
.PARAMETER IP
    Target IP.
.PARAMETER User
    Target Windows Username.
.PARAMETER Password
    Target Windows Password.
.PARAMETER Distribution
    The WSL distribution string. Defaults to "Ubuntu-22.04".
.OUTPUTS
    A Hashtable mapping various boolean statuses (`Ready`, `NeedsReboot`, `NeedsInstall`) used to control pipeline flow.
#>
function Test-WSLReady {
    param ([string]$IP, [string]$User, [string]$Password, [string]$Distribution = "Ubuntu-22.04")
    try {
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        $session = New-PSSession -ComputerName $IP -Port $script:WinRMPort -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
        
        if (-not $session) { return @{ Ready = $false; NeedsReboot = $false; NeedsInstall = $true; Message = "Could not establish remote session" } }
        
        $status = Invoke-Command -Session $session -ScriptBlock {
            param($Distro)
            [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
            $ErrorActionPreference = "SilentlyContinue"
            $result = @{ WSLFeatureEnabled = $false; VMPlatformEnabled = $false; WSLKernelInstalled = $false; DistributionInstalled = $false; DistributionReady = $false; NeedsReboot = $false; Message = "" }
            
            $wslStatus = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
            $result.WSLFeatureEnabled = ($wslStatus.State -eq "Enabled")
            if ($wslStatus.RestartNeeded -eq $true) { $result.NeedsReboot = $true }
            
            $vmStatus = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
            $result.VMPlatformEnabled = ($vmStatus.State -eq "Enabled")
            if ($vmStatus.RestartNeeded -eq $true) { $result.NeedsReboot = $true }
            
            if ($result.WSLFeatureEnabled -and $result.VMPlatformEnabled -and -not $result.NeedsReboot) {
                try {
                    $wslExe = if (Test-Path "$env:windir\sysnative\wsl.exe") { "$env:windir\sysnative\wsl.exe" } else { "wsl.exe" }
                    $wslStatusCheckRaw = & $wslExe --status 2>&1 | ForEach-Object { $_.ToString() }
                    $wslStatusStr = ($wslStatusCheckRaw -join ' ') -replace "\x00", ""
                    
                    if ($wslStatusStr -match "must be updated") { $result.WSLKernelInstalled = $false; $result.NeedsUpdate = $true; $result.Message = "WSL requires update via 'wsl --update'" }
                    elseif ($wslStatusStr -match "not installed|is not installed") { $result.WSLKernelInstalled = $false }
                    else { $result.WSLKernelInstalled = $true }
                } catch { $result.WSLKernelInstalled = $false }
                
                if ($result.WSLKernelInstalled) {
                    $distroListRaw = & $wslExe --list --quiet 2>&1 | ForEach-Object { $_.ToString() }
                    $distroList = ($distroListRaw -join " ") -replace "\x00", ""
                    
                    if ($distroList -match "(?i)$Distro") {
                        $result.DistributionInstalled = $true
                        try { 
                            $testOutputRaw = & $wslExe -u root echo 'WSL_READY_TEST' 2>&1 | ForEach-Object { $_.ToString() }
                            $testOutput = ($testOutputRaw -join " ") -replace "\x00", ""
                            if ($testOutput -match "WSL_READY_TEST") { $result.DistributionReady = $true } 
                        } catch { $result.DistributionReady = $false }
                    }
                }
            }
            
            if ($result.NeedsReboot) { $result.Message = "System reboot required" }
            elseif (-not $result.WSLFeatureEnabled) { $result.Message = "WSL feature is not enabled" }
            elseif (-not $result.VMPlatformEnabled) { $result.Message = "Virtual Machine Platform not enabled" }
            elseif (-not $result.WSLKernelInstalled) { $result.Message = "WSL2 kernel is not installed" }
            elseif (-not $result.DistributionInstalled) { $result.Message = "Linux distribution '$Distro' is not installed" }
            elseif (-not $result.DistributionReady) { $result.Message = "Linux distribution '$Distro' is installed but not ready" }
            else { $result.Message = "WSL2 is fully ready with $Distro distribution" }
            return $result
        } -ArgumentList $Distribution
        Remove-PSSession -Session $session
        
        $isReady = $status.WSLFeatureEnabled -and $status.VMPlatformEnabled -and $status.WSLKernelInstalled -and $status.DistributionInstalled -and $status.DistributionReady -and (-not $status.NeedsReboot)
        return @{ Ready = $isReady; NeedsReboot = $status.NeedsReboot; NeedsInstall = (-not $status.WSLFeatureEnabled) -or (-not $status.VMPlatformEnabled); NeedsDistribution = (-not $status.DistributionInstalled) -or (-not $status.DistributionReady); Details = $status; Message = $status.Message }
    }
    catch { return @{ Ready = $false; NeedsReboot = $false; NeedsInstall = $true; Message = "Error checking WSL status" } }
}

<#
.SYNOPSIS
    Automated WSL2 deployment. Uses Start-Process to avoid WinRM pipeline corruption.
.DESCRIPTION
    WHAT IT DOES: Executes the remote WSL2 `Ubuntu` installation protocol unattended.
    HOW IT WORKS: 
        1. Employs `Start-Process -FilePath "wsl.exe" -ArgumentList "--install -d Ubuntu-22.04 --no-launch"` remotely.
        2. Loops up to 12 times waiting for the distribution unpacking operation to finalize in the background before priming it.
        3. Connects to `Invoke-WSL2Reboot` if the host requires a restart to finish hardware configuration.
    WHY IT IS NEEDED: Remote WinRM PowerShell sessions frequently crash (pipe drops) when attempting to natively execute `wsl --install`. Wrapping the execution inside `Start-Process` physically detaches it from the unstable remote pipeline so the Windows kernel can complete the installation transparently.
.PARAMETER IP
    Target IP.
.PARAMETER User
    Target Windows Username.
.PARAMETER Password
    Target Windows Password.
.PARAMETER Distribution
    Defaults to "Ubuntu-22.04".
.PARAMETER AutoReboot
    A Switch indicating whether the target is authorized to immediately execute an unexpected hard-reboot.
.PARAMETER WaitForReboot
    A Switch indicating the local script should actively sleep and poll until the WinRM service responds again.
.OUTPUTS
    A Hashtable tracking overall Success status, Reboot flags, and Debug logs.
#>
function Install-WSL2 {
    param ([string]$IP, [string]$User, [string]$Password, [string]$Distribution = "Ubuntu-22.04", [switch]$AutoReboot, [switch]$WaitForReboot)
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            Write-LogInfo -Message "WSL2 Installation attempt $attempt on $IP" -Component "Deployment"
            
            $wslStatus = Test-WSLReady -IP $IP -User $User -Password $Password -Distribution $Distribution
            if ($wslStatus.Ready) { return @{ Success = $true; NeedsReboot = $false; Ready = $true; Message = "WSL2 is ready" } }
            
            if ($wslStatus.NeedsReboot) {
                if ($AutoReboot) { 
                    Write-LogInfo -Message "Rebooting $IP to apply WSL features..." -Component "Deployment"
                    if ($WaitForReboot) {
                        $rbResult = Invoke-WSL2Reboot -IP $IP -User $User -Password $Password -Distribution $Distribution -WaitForReboot
                    } else {
                        $rbResult = Invoke-WSL2Reboot -IP $IP -User $User -Password $Password -Distribution $Distribution
                    }
                    if (-not $rbResult.Success -and -not $WaitForReboot) { return $rbResult }
                    continue 
                }
                else { return @{ Success = $true; NeedsReboot = $true; Ready = $false; Message = "System reboot is required" } }
            }
            
            $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
            $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
            $session = New-PSSession -ComputerName $IP -Port $script:WinRMPort -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
            
            if (-not $session) { return @{ Success = $false; NeedsReboot = $false; Ready = $false; Message = "Failed to establish remote session" } }
            
            $installResult = Invoke-Command -Session $session -ScriptBlock {
                param($LinuxUser, $LinuxPass, $DistroName)
                $ErrorActionPreference = "Continue" 
                $debugLog = @()
                
                try {
                    # Absolute 64-bit path resolution to bypass 32-bit WinRM traps
                    $wslPath = if (Test-Path "$env:windir\sysnative\wsl.exe") { "$env:windir\sysnative\wsl.exe" } else { "$env:windir\System32\wsl.exe" }
                    
                    $debugLog += "Executing WSL Installer via Start-Process to avoid pipeline corruption..."
                    
                    # Using Start-Process detaches from the pipeline, allowing the installer to run without crashing
                    $installProc = Start-Process -FilePath $wslPath -ArgumentList "--install -d $DistroName --no-launch" -Wait -PassThru -NoNewWindow
                    $debugLog += "wsl.exe --install process finished with ExitCode: $($installProc.ExitCode)"
                    
                    $debugLog += "Waiting 15 seconds for background unpacking..."
                    Start-Sleep -Seconds 15
                    
                    $debugLog += "Verifying installation..."
                    $verifyProc = Start-Process -FilePath $wslPath -ArgumentList "--status" -Wait -PassThru -NoNewWindow
                    $debugLog += "wsl.exe --status finished with ExitCode: $($verifyProc.ExitCode)"
                    
                    $debugLog += "Waiting for distribution $DistroName to register..."
                    $distroReady = $false
                    for ($distroAttempt = 1; $distroAttempt -le 12; $distroAttempt++) {
                        $distroListRaw = & $wslPath --list --quiet 2>&1 | ForEach-Object { $_.ToString() }
                        $distroList = ($distroListRaw -join "`n") -replace "\x00", ""
                        $escapedDistroName = [regex]::Escape($DistroName)
                        if ($distroList -match "(?im)^\s*$escapedDistroName\s*$") {
                            $distroReady = $true
                            break
                        }
                        $debugLog += "Distribution $DistroName not ready yet (attempt $distroAttempt/12); waiting 10 seconds..."
                        Start-Sleep -Seconds 10
                    }
                    
                    if (-not $distroReady) {
                        $debugLog += "Distribution $DistroName did not register in time."
                        return @{ Success = $false; NeedsReboot = $true; Ready = $false; Message = "WSL installed but distribution '$DistroName' is not available yet."; DebugLog = $debugLog }
                    }
                    
                    $debugLog += "Priming distribution $DistroName..."
                    $primeProc = Start-Process -FilePath $wslPath -ArgumentList "-d $DistroName -u root -- bash -lc `"echo WSL_READY_TEST`"" -Wait -PassThru -NoNewWindow
                    $debugLog += "wsl.exe prime run finished with ExitCode: $($primeProc.ExitCode)"
                    
                    # Create User natively
                    $debugLog += "Creating Linux user $LinuxUser..."
                    $bashCmd = "id -u {0} &>/dev/null || (useradd -m -G adm,cdrom,sudo,dip,plugdev,users -s /bin/bash {0} && echo '{0}:{1}' | chpasswd)" -f $LinuxUser, $LinuxPass
                    Start-Process -FilePath $wslPath -ArgumentList "-d $DistroName -u root bash -c `"$bashCmd`"" -Wait -NoNewWindow | Out-Null
                    
                    # Inject configuration
                    $debugLog += "Injecting wsl.conf..."
                    $wslConf = "[boot]`nsystemd=true`n[user]`ndefault=$LinuxUser"
                    $confPath = "$env:TEMP\wsl_conf.txt"
                    Set-Content -Path $confPath -Value $wslConf -Force
                    Start-Process -FilePath $wslPath -ArgumentList "-d $DistroName -u root bash -c `"cat $(($confPath -replace '\\','/')) > /etc/wsl.conf`"" -Wait -NoNewWindow | Out-Null
                    
                    return @{ Success = $true; NeedsReboot = $false; Ready = $true; Message = "WSL2 installation completed successfully."; DebugLog = $debugLog }
                }
                catch { 
                    $debugLog += "CRITICAL ERROR in Try/Catch: $($_.Exception.Message)"
                    return @{ Success = $false; NeedsReboot = $false; Ready = $false; Message = "Installation failed: $($_.Exception.Message)"; DebugLog = $debugLog } 
                }
            } -ArgumentList $User, $Password, $Distribution
            
            Remove-PSSession -Session $session
            
            if ($installResult.DebugLog) {
                Write-Host "--- WSL2 INSTALLATION DEBUG TRACE ---" -ForegroundColor Magenta
                Write-LogInfo -Message "--- WSL2 INSTALLATION DEBUG TRACE ---" -Component "Deployment"
                
                foreach ($line in $installResult.DebugLog) {
                    if ($line -match "FAILED|CRITICAL ERROR") {
                        Write-Host "    $line" -ForegroundColor Red
                        Write-LogError -Message $line -Component "Deployment"
                    } else {
                        Write-Host "    $line" -ForegroundColor Gray
                        Write-LogInfo -Message $line -Component "Deployment"
                    }
                }
                Write-Host "-------------------------------------" -ForegroundColor Magenta
                Write-LogInfo -Message "-------------------------------------" -Component "Deployment"
            }
            
            if ($installResult.NeedsReboot) {
                if ($AutoReboot) { 
                    if ($WaitForReboot) {
                        Invoke-WSL2Reboot -IP $IP -User $User -Password $Password -Distribution $Distribution -WaitForReboot | Out-Null
                    } else {
                        Invoke-WSL2Reboot -IP $IP -User $User -Password $Password -Distribution $Distribution | Out-Null
                    }
                    continue
                }
                return @{ Success = $true; NeedsReboot = $true; Ready = $false; Message = $installResult.Message }
            }
            
            if ($installResult.Ready) {
                return @{ Success = $true; NeedsReboot = $false; Ready = $true; Message = $installResult.Message }
            }
        }
        
        return @{ Success = $false; NeedsReboot = $false; Ready = $false; Message = "Failed to install WSL2 after multiple attempts." }
    }
    catch { return @{ Success = $false; NeedsReboot = $false; Ready = $false; Message = "Error: $($_.Exception.Message)" } }
}

<#
.SYNOPSIS
    Reboots the target Windows host and waits for WinRM to return.
.DESCRIPTION
    WHAT IT DOES: Emits the `Restart-Computer` signal and manages reconnection logic.
    HOW IT WORKS: 
        1. Pushes the script's specific server IP to the internal dictionary `$script:WSL2RebootCount`.
        2. Guards against infinite failure loops (e.g. aborts if the attempt count exceeds 2).
        3. Forces the remote machine restart.
        4. If `$WaitForReboot` is true, begins polling via `Test-WinRMConnection` every 15 seconds up to 10 minutes until the remote environment responds.
    WHY IT IS NEEDED: Windows requires a strict cold restart to mount the Hyper-V kernel configurations necessary to run WSL2. This module forces the host machine to pause its background workflow threads and quietly wait for the system to resume.
.PARAMETER IP
    Target Windows IP.
.PARAMETER User
    Target Windows Username.
.PARAMETER Password
    Target Windows Password.
.PARAMETER Distribution
    A distribution trace variable.
.PARAMETER WaitForReboot
    A Switch dictating polling behavior.
.OUTPUTS
    Hashtable with Success boolean and context messages.
#>
function Invoke-WSL2Reboot {
    param (
        [string]$IP, 
        [string]$User, 
        [string]$Password, 
        [string]$Distribution, 
        [switch]$WaitForReboot
    )
    Write-LogDebug -Message "Entering Invoke-WSL2Reboot for IP: $IP" -Component "Deployment"
    try {
        # Initialize reboot counter for this IP if it doesn't exist
        if (-not $script:WSL2RebootCount.ContainsKey($IP)) {
            $script:WSL2RebootCount[$IP] = 0
        }
        
        # Anti-infinite-loop guardrail
        if ($script:WSL2RebootCount[$IP] -ge 2) {
            Write-LogError -Message "Reboot loop detected on $IP. Aborting WSL2 setup." -Component "Deployment"
            return @{ Success = $false; Message = "Reboot loop detected" }
        }
        
        $script:WSL2RebootCount[$IP]++
        Write-LogInfo -Message "Initiating reboot on $IP (Attempt $($script:WSL2RebootCount[$IP]))" -Component "Deployment"
        
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        
        # Trigger remote restart
        Restart-Computer -ComputerName $IP -Credential $credential -Force -ErrorAction Stop
        
        if ($WaitForReboot) {
            Write-LogInfo -Message "Waiting for WinRM service to return on $IP..." -Component "Deployment"
            
            # Poll for WinRM connectivity to resume
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $isOnline = $false
            
            while ($sw.Elapsed.TotalMinutes -lt 10) {
                Start-Sleep -Seconds 15
                if (Test-WinRMConnection -IP $IP -User $User -Password $Password) {
                    $isOnline = $true
                    break
                }
            }
            $sw.Stop()
            
            if (-not $isOnline) {
                Write-LogError -Message "Timeout waiting for $IP to return from reboot." -Component "Deployment"
                return @{ Success = $false; Message = "Timeout waiting for server to reboot" }
            }
            
            Write-LogInfo -Message "Server $IP is back online." -Component "Deployment"
            # Hard sleep to allow background services (like WSL) to fully spin up after network connects
            Start-Sleep -Seconds 15 
        }
        
        return @{ Success = $true; Message = "Reboot completed successfully" }
    }
    catch {
        Write-LogError -Message "Failed to reboot ${IP}: $($_.Exception.Message)" -Component "Deployment"
        return @{ Success = $false; Message = "Reboot failed: $($_.Exception.Message)" }
    }
}
#endregion

#===============================================================================
#region MODULE EXPORTS
#===============================================================================

Export-ModuleMember -Function @(
    'Initialize-Logging', 'Set-LogConfiguration', 'Write-Log', 'Write-LogDebug', 'Write-LogInfo', 'Write-LogWarning', 'Write-LogError', 'Write-LogSuccess', 'Get-LogFilePath', 'Get-LogContent', 'Clear-OldLogs', 'Write-SessionSeparator',
    'Get-TargetOS', 'Test-SSHConnection', 'Test-WinRMConnection', 'Test-RemoteConnection', 'Invoke-WSLCommand', 'Invoke-RemoteCommand',
    'Get-ServerHealth', 'Get-LinuxServerHealth', 'Get-WindowsServerHealth', 'Get-ContainerHealth', 'Get-ContainerLogs', 'Restart-Container', 'Stop-Container', 'Start-Container', 'Get-FullHealthReport', 'Format-HealthReport', 'Test-ServiceHealth', 'Test-CommonServices',
    'Install-DockerLinux', 'Install-DockerWSL2', 'Install-Traefik', 'Deploy-DockerService',
    'Test-WSLReady', 'Install-WSL2', 'Invoke-WSL2Reboot', 'Set-ConnectionConfig'
)
#endregion