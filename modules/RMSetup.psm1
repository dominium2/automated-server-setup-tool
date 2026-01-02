#===============================================================================
# RMSetup.psm1 - Remote Management & Server Setup Module
# Automated Server Setup Tool
#===============================================================================
# This consolidated module provides:
#   - Logging functionality
#   - Remote connection management (SSH, WinRM, WSL)
#   - Health monitoring for servers and containers
#   - Service installation (Docker, Traefik, Portainer, etc.)
#   - WSL2 setup for Windows systems
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

#endregion

#===============================================================================
#region REMOTE CONNECTION FUNCTIONS
#===============================================================================

function Get-TargetOS {
    param (
        [string]$IP
    )
    
    try {
        Write-LogDebug -Message "Detecting OS for $IP via TCP ports" -Component "RemoteConnection"
        Write-Host "  Attempting to detect OS via TCP ports..." -ForegroundColor Cyan
        
        # Check for Windows (WinRM ports 5985/5986)
        $winRMPort = Test-NetConnection -ComputerName $IP -Port 5985 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        
        if ($winRMPort.TcpTestSucceeded) {
            Write-LogInfo -Message "Detected Windows OS on $IP (WinRM port 5985 open)" -Component "RemoteConnection"
            Write-Host "  WinRM port (5985) is open - likely Windows" -ForegroundColor Green
            return "Windows"
        }
        
        # Check for SSH port 22 (Linux/Unix)
        $sshPort = Test-NetConnection -ComputerName $IP -Port 22 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        
        if ($sshPort.TcpTestSucceeded) {
            Write-LogInfo -Message "Detected Linux OS on $IP (SSH port 22 open)" -Component "RemoteConnection"
            Write-Host "  SSH port (22) is open - likely Linux/Unix" -ForegroundColor Green
            return "Linux"
        }
        
        # If neither port is open, try additional detection methods
        Write-LogDebug -Message "Standard ports not detected on $IP, trying alternative detection" -Component "RemoteConnection"
        Write-Host "  Standard ports not detected. Attempting alternative detection..." -ForegroundColor Yellow
        
        # Try to detect via TTL value in ping response
        $pingDetailed = Test-Connection -ComputerName $IP -Count 1 -ErrorAction SilentlyContinue
        
        if ($pingDetailed) {
            $ttl = $pingDetailed.ResponseTimeToLive
            Write-LogDebug -Message "TTL value for ${IP}: $ttl" -Component "RemoteConnection"
            Write-Host "  TTL value: $ttl" -ForegroundColor Cyan
            
            # Windows typically has TTL of 128
            # Linux typically has TTL of 64
            if ($ttl -ge 120 -and $ttl -le 128) {
                Write-LogInfo -Message "Detected Windows OS on $IP (TTL suggests Windows)" -Component "RemoteConnection"
                Write-Host "  TTL suggests Windows OS" -ForegroundColor Green
                return "Windows"
            }
            elseif ($ttl -ge 60 -and $ttl -le 64) {
                Write-LogInfo -Message "Detected Linux OS on $IP (TTL suggests Linux)" -Component "RemoteConnection"
                Write-Host "  TTL suggests Linux/Unix OS" -ForegroundColor Green
                return "Linux"
            }
        }
        
        Write-LogWarning -Message "Unable to reliably detect OS for $IP" -Component "RemoteConnection"
        Write-Host "  Unable to reliably detect OS" -ForegroundColor Yellow
        return $null
    }
    catch {
        Write-LogError -Message "Error during OS detection for $IP" -Component "RemoteConnection" -Exception $_.Exception
        Write-Host "  Error during OS detection: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Test-SSHConnection {
    param (
        [string]$IP,
        [string]$User,
        [string]$Password
    )
    
    try {
        Write-LogInfo -Message "Testing SSH connection to $IP" -Component "SSH"
        Write-Host "Testing SSH connection to $IP..." -ForegroundColor Cyan
        
        # Use plink if available (from PuTTY) for password-based SSH
        if (Get-Command plink -ErrorAction SilentlyContinue) {
            Write-LogDebug -Message "Using plink for SSH connection to $IP" -Component "SSH"
            Write-Host "  Using plink for SSH connection..." -ForegroundColor Cyan
            
            # Create a temporary answer file to auto-accept host key
            $tempAnswerFile = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $tempAnswerFile -Value "y"
            
            try {
                # Use the answer file to auto-accept host key, then connect
                $result = Get-Content $tempAnswerFile | & plink -pw $Password $User@$IP "hostname" 2>&1
                
                if ($LASTEXITCODE -eq 0 -and $result -and $result -notmatch "FATAL ERROR" -and $result -notmatch "Access denied") {
                    Write-LogSuccess -Message "SSH connection successful to $IP (hostname: $result)" -Component "SSH"
                    Write-Host "SSH connection successful!" -ForegroundColor Green
                    Write-Host "Connected to: $result" -ForegroundColor Green
                    return $true
                }
                else {
                    Write-LogError -Message "SSH connection failed to ${IP}: $result" -Component "SSH"
                    Write-Host "SSH connection failed: $result" -ForegroundColor Red
                    return $false
                }
            }
            finally {
                # Clean up temp file
                if (Test-Path $tempAnswerFile) {
                    Remove-Item $tempAnswerFile -Force
                }
            }
        }
        else {
            Write-LogError -Message "plink not found - required for SSH connection" -Component "SSH"
            Write-Host "  Error: 'plink' (PuTTY) is required for password-based SSH" -ForegroundColor Red
            Write-Host "  Install with: choco install putty -y" -ForegroundColor Yellow
            return $false
        }
    }
    catch {
        Write-LogError -Message "Error testing SSH connection to $IP" -Component "SSH" -Exception $_.Exception
        Write-Host "Error testing SSH connection to $IP : $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Test-WinRMConnection {
    param (
        [string]$IP,
        [string]$User,
        [string]$Password
    )
    
    try {
        Write-LogInfo -Message "Testing WinRM connection to $IP" -Component "WinRM"
        Write-Host "Testing WinRM connection to $IP..." -ForegroundColor Cyan
        
        # Check if WinRM service is running and start it if needed
        Write-LogDebug -Message "Checking WinRM service status" -Component "WinRM"
        Write-Host "  Checking WinRM service status..." -ForegroundColor Cyan
        $winrmService = Get-Service -Name WinRM -ErrorAction SilentlyContinue
        
        if ($winrmService -and $winrmService.Status -ne 'Running') {
            Write-LogInfo -Message "Starting WinRM service" -Component "WinRM"
            Write-Host "  Starting WinRM service..." -ForegroundColor Yellow
            try {
                Start-Service -Name WinRM -ErrorAction Stop
                Write-LogSuccess -Message "WinRM service started" -Component "WinRM"
                Write-Host "  WinRM service started" -ForegroundColor Green
            }
            catch {
                Write-LogWarning -Message "Could not start WinRM service: $($_.Exception.Message)" -Component "WinRM"
                Write-Host "  Warning: Could not start WinRM service: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        
        # Check and configure TrustedHosts
        Write-LogDebug -Message "Checking TrustedHosts configuration" -Component "WinRM"
        Write-Host "  Checking TrustedHosts configuration..." -ForegroundColor Cyan
        try {
            $currentTrustedHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
            
            if (-not $currentTrustedHosts.Contains($IP) -and $currentTrustedHosts -ne "*") {
                Write-LogInfo -Message "Adding $IP to TrustedHosts" -Component "WinRM"
                Write-Host "  Adding $IP to TrustedHosts..." -ForegroundColor Yellow
                
                if ([string]::IsNullOrEmpty($currentTrustedHosts)) {
                    Set-Item WSMan:\localhost\Client\TrustedHosts -Value $IP -Force
                } else {
                    Set-Item WSMan:\localhost\Client\TrustedHosts -Value "$currentTrustedHosts,$IP" -Force
                }
                Write-LogSuccess -Message "Added $IP to TrustedHosts" -Component "WinRM"
                Write-Host "  Successfully added $IP to TrustedHosts" -ForegroundColor Green
            } else {
                Write-LogDebug -Message "$IP already in TrustedHosts" -Component "WinRM"
                Write-Host "  $IP is already in TrustedHosts or using wildcard" -ForegroundColor Green
            }
        }
        catch {
            Write-LogWarning -Message "Could not configure TrustedHosts: $($_.Exception.Message)" -Component "WinRM"
            Write-Host "  Warning: Could not configure TrustedHosts: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  You may need to run PowerShell as Administrator" -ForegroundColor Yellow
            Write-Host "  Or manually run: Set-Item WSMan:\localhost\Client\TrustedHosts -Value '$IP' -Force" -ForegroundColor Yellow
        }
        
        # Create credential object
        $winSecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $winCredential = New-Object System.Management.Automation.PSCredential ($User, $winSecurePassword)
        
        # Create session options to skip certificate checks for non-domain scenarios
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        
        # Test WinRM connection
        Write-LogDebug -Message "Establishing PSSession to $IP" -Component "WinRM"
        Write-Host "  Attempting to establish PSSession..." -ForegroundColor Cyan
        $winSession = New-PSSession -ComputerName $IP -Credential $winCredential -SessionOption $sessionOption -ErrorAction Stop
        
        if ($winSession) {
            Write-LogSuccess -Message "WinRM connection successful to $IP" -Component "WinRM"
            Write-Host "WinRM connection successful!" -ForegroundColor Green
            
            # Test by running a command
            $result = Invoke-Command -Session $winSession -ScriptBlock {
                $env:COMPUTERNAME 
            }
            Write-LogInfo -Message "Connected to computer: $result" -Component "WinRM"
            Write-Host "Connected to: $result" -ForegroundColor Green
            
            # Close session
            Remove-PSSession -Session $winSession
            return $true
        }
    }
    catch {
        Write-LogError -Message "WinRM connection failed to $IP" -Component "WinRM" -Exception $_.Exception
        Write-Host "WinRM connection failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Troubleshooting tips:" -ForegroundColor Yellow
        Write-Host "  1. Run this script as Administrator" -ForegroundColor Yellow
        Write-Host "  2. Enable WinRM on target: Enable-PSRemoting -Force" -ForegroundColor Yellow
        Write-Host "  3. Configure firewall on target to allow WinRM (port 5985)" -ForegroundColor Yellow
        return $false
    }
}

function Test-RemoteConnection {
    param (
        [string]$IP,
        [string]$User,
        [string]$Password
    )

    try {
        Write-LogInfo -Message "Testing connectivity to $IP" -Component "RemoteConnection"
        Write-Host "Testing connectivity to $IP..." -ForegroundColor Cyan
        
        # Ping the target machine 4 times
        $successfulPings = 0
        $maxAttempts = 4
        
        for ($i = 1; $i -le $maxAttempts; $i++) {
            Write-Host "  Ping attempt $i of $maxAttempts..." -NoNewline
            
            $pingResult = Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue
            
            if ($pingResult) {
                $successfulPings++
                Write-Host " Success" -ForegroundColor Green
            }
            else {
                Write-Host " Failed" -ForegroundColor Red
            }
            
            Start-Sleep -Milliseconds 500
        }
        
        Write-LogDebug -Message "Ping results for ${IP}: $successfulPings/$maxAttempts successful" -Component "RemoteConnection"
        
        # Check if all pings were successful
        if ($successfulPings -eq $maxAttempts) {
            Write-LogSuccess -Message "All pings successful to $IP" -Component "RemoteConnection"
            Write-Host "All pings successful! Proceeding with connection..." -ForegroundColor Green
            
            # Detect target OS
            Write-Host "Detecting target OS..." -ForegroundColor Cyan
            $targetOS = Get-TargetOS -IP $IP
            
            if ($targetOS) {
                Write-Host "Detected OS: $targetOS" -ForegroundColor Green
                
                # Use appropriate connection method based on OS
                if ($targetOS -eq "Windows") {
                    Write-LogInfo -Message "Using WinRM for Windows connection to $IP" -Component "RemoteConnection"
                    Write-Host "Using WinRM for Windows connection..." -ForegroundColor Cyan
                    return Test-WinRMConnection -IP $IP -User $User -Password $Password
                }
                elseif ($targetOS -eq "Linux") {
                    Write-LogInfo -Message "Using SSH for Linux connection to $IP" -Component "RemoteConnection"
                    Write-Host "Using SSH for Linux connection..." -ForegroundColor Cyan
                    return Test-SSHConnection -IP $IP -User $User -Password $Password
                }
                else {
                    Write-LogWarning -Message "Unknown OS type: $targetOS for $IP, attempting SSH" -Component "RemoteConnection"
                    Write-Host "Unknown OS type: $targetOS. Attempting SSH connection..." -ForegroundColor Yellow
                    return Test-SSHConnection -IP $IP -User $User -Password $Password
                }
            }
            else {
                Write-LogWarning -Message "Failed to detect OS for $IP, attempting SSH as fallback" -Component "RemoteConnection"
                Write-Host "Failed to detect OS. Attempting SSH connection as fallback..." -ForegroundColor Yellow
                return Test-SSHConnection -IP $IP -User $User -Password $Password
            }
        }
        else {
            Write-LogError -Message "Ping test failed for ${IP}: $successfulPings/$maxAttempts successful" -Component "RemoteConnection"
            Write-Host "Ping test failed. $successfulPings out of $maxAttempts pings successful." -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-LogError -Message "Error testing connection to $IP" -Component "RemoteConnection" -Exception $_.Exception
        Write-Host "Error testing connection to $IP : $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Invoke-WSLCommand {
    param (
        [string]$IP,
        [string]$User,
        [string]$Password,
        [string]$Command,
        [string]$Distribution = "Debian"
    )
    
    try {
        Write-LogDebug -Message "Executing WSL command on $IP (Distribution: $Distribution)" -Component "WSL"
        
        # Create credential object
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        
        # Create session options
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        
        # Establish remote session to Windows machine
        $session = New-PSSession -ComputerName $IP -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
        
        if (-not $session) {
            Write-LogError -Message "Failed to establish remote session to $IP for WSL command" -Component "WSL"
            Write-Host "Failed to establish remote session to $IP" -ForegroundColor Red
            return $null
        }
        
        # Execute command inside WSL2
        $result = Invoke-Command -Session $session -ScriptBlock {
            param($Cmd, $Distro)
            
            # Helper function to clean WSL output (handles UTF-16LE encoding with null bytes)
            function Clean-WSLOutput {
                param($RawOutput)
                if (-not $RawOutput) { return @() }
                $cleaned = @()
                foreach ($line in $RawOutput) {
                    if ($line) {
                        # Remove null bytes (UTF-16LE artifact) and trim
                        $cleanLine = ($line -replace '\x00', '').Trim()
                        if ($cleanLine -and $cleanLine -match '\S') {
                            $cleaned += $cleanLine
                        }
                    }
                }
                return $cleaned
            }
            
            # First, check if WSL is installed and functional
            try {
                $wslCheck = & wsl --status 2>&1
                $wslCheckClean = (Clean-WSLOutput $wslCheck) -join ' '
                if ($LASTEXITCODE -ne 0 -or $wslCheckClean -match "not installed|is not installed") {
                    return @{
                        Output = "WSL is not installed or not ready. A system reboot may be required after WSL installation."
                        ExitCode = 1
                        WSLNotReady = $true
                    }
                }
            }
            catch {
                return @{
                    Output = "WSL command failed. WSL may not be properly installed."
                    ExitCode = 1
                    WSLNotReady = $true
                }
            }
            
            # Check if the distribution exists - clean UTF-16 output
            $distroListRaw = wsl --list --quiet 2>&1
            $distroList = Clean-WSLOutput $distroListRaw
            
            # Handle case where WSL returns error about not being installed
            $distroListStr = $distroList -join ' '
            if ($distroListStr -match "not installed|is not installed") {
                return @{
                    Output = "WSL is installed but not fully configured. A system reboot may be required."
                    ExitCode = 1
                    WSLNotReady = $true
                }
            }
            
            # Check if our distribution exists in the cleaned list
            $foundDistro = $null
            foreach ($d in $distroList) {
                if ($d -eq $Distro -or $d -match "^$Distro$" -or $d -match "^${Distro}\s*\(Default\)") {
                    $foundDistro = $Distro
                    break
                }
                # Handle Ubuntu variants
                if ($Distro -eq "Ubuntu" -and $d -match "Ubuntu") {
                    $foundDistro = ($d -replace '\s*\(Default\)', '').Trim()
                    break
                }
                # Handle Debian variants
                if ($Distro -eq "Debian" -and $d -match "Debian") {
                    $foundDistro = ($d -replace '\s*\(Default\)', '').Trim()
                    break
                }
            }
            
            if (-not $foundDistro) {
                $availableDistros = if ($distroList.Count -gt 0) { $distroList -join ', ' } else { "None installed" }
                return @{
                    Output = "Distribution '$Distro' not found. Available distributions: $availableDistros"
                    ExitCode = 1
                    WSLNotReady = $false
                    DistributionMissing = $true
                }
            }
            
            # Use the found distribution name
            $Distro = $foundDistro
            
            # Check if distribution is running, if not start it
            $runningDistrosRaw = wsl --list --running --quiet 2>&1
            $runningDistros = Clean-WSLOutput $runningDistrosRaw
            $isRunning = $runningDistros | Where-Object { $_ -match $Distro }
            
            if (-not $isRunning) {
                # Start the distribution
                wsl -d $Distro -u root echo "Starting distribution..." 2>&1 | Out-Null
                Start-Sleep -Seconds 2
            }
            
            # Execute the command in WSL as root (since we may not have a regular user set up)
            $output = wsl -d $Distro -u root bash -c $Cmd 2>&1
            
            return @{
                Output = $output
                ExitCode = $LASTEXITCODE
                WSLNotReady = $false
            }
        } -ArgumentList $Command, $Distribution
        
        # Close the session
        Remove-PSSession -Session $session
        
        # Check for WSL not ready condition
        if ($result.WSLNotReady) {
            Write-LogError -Message "WSL not ready on ${IP}: $($result.Output)" -Component "WSL"
            Write-Host "Error: $($result.Output)" -ForegroundColor Red
            Write-Host "Please ensure the system has been rebooted after WSL2 installation." -ForegroundColor Yellow
            return $null
        }
        
        Write-LogDebug -Message "WSL command completed on $IP with exit code: $($result.ExitCode)" -Component "WSL"
        return $result
    }
    catch {
        Write-LogError -Message "Error executing WSL command on $IP" -Component "WSL" -Exception $_.Exception
        Write-Host "Error executing WSL command on $IP : $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Invoke-RemoteCommand {
    <#
    .SYNOPSIS
        Executes a command on a remote system (Linux via SSH or Windows via WSL2).

    .DESCRIPTION
        This function automatically detects the OS and routes commands appropriately:
        - Linux systems: Uses SSH (plink)
        - Windows systems: Uses WinRM to execute commands in WSL2

    .PARAMETER IP
        The IP address of the target server.

    .PARAMETER User
        The username for authentication.

    .PARAMETER Password
        The password for authentication.

    .PARAMETER Command
        The Linux/bash command to execute.

    .EXAMPLE
        Invoke-RemoteCommand -IP "192.168.1.100" -User "admin" -Password "pass" -Command "docker --version"
    #>
    
    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,
        
        [Parameter(Mandatory=$true)]
        [string]$Command
    )
    
    try {
        Write-LogDebug -Message "Executing remote command on $IP" -Component "RemoteCommand"
        
        # Detect the OS
        $osType = Get-TargetOS -IP $IP
        
        if ($osType -eq "Linux") {
            Write-LogDebug -Message "Using SSH for command execution on $IP" -Component "RemoteCommand"
            # Use SSH for Linux systems
            if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
                Write-LogError -Message "plink not found - required for SSH command execution" -Component "RemoteCommand"
                Write-Host "Error: 'plink' (PuTTY) is required for SSH connection" -ForegroundColor Red
                return $null
            }
            
            $result = Write-Output y | plink -batch -pw $Password "$User@$IP" $Command 2>&1
            
            if ($LASTEXITCODE -ne 0 -and $result -match "error|fatal|failed|denied|cannot|permission denied") {
                Write-LogError -Message "SSH command failed on ${IP}: $result" -Component "RemoteCommand"
                return $null
            }
            
            Write-LogDebug -Message "SSH command completed successfully on $IP" -Component "RemoteCommand"
            return $result
        }
        elseif ($osType -eq "Windows") {
            Write-LogDebug -Message "Using WSL2 for command execution on $IP" -Component "RemoteCommand"
            # Use WSL2 for Windows systems
            $wslResult = Invoke-WSLCommand -IP $IP -User $User -Password $Password -Command $Command
            
            if ($null -eq $wslResult) {
                Write-LogError -Message "WSL command execution failed on $IP" -Component "RemoteCommand"
                Write-Host "WSL command execution failed" -ForegroundColor Red
                return $null
            }
            
            # Check for distribution errors
            if ($wslResult.ExitCode -ne 0 -and $wslResult.Output -match "no distribution|not found") {
                Write-LogError -Message "WSL distribution error on ${IP}: $($wslResult.Output)" -Component "RemoteCommand"
                Write-Host "Error: $($wslResult.Output)" -ForegroundColor Red
                return $null
            }
            
            if ($wslResult.ExitCode -ne 0 -and $wslResult.Output -match "error|fatal|failed|denied|cannot|permission denied") {
                Write-LogWarning -Message "WSL command error on ${IP}: $($wslResult.Output)" -Component "RemoteCommand"
                Write-Host "Command error: $($wslResult.Output)" -ForegroundColor Yellow
                return $null
            }
            
            Write-LogDebug -Message "WSL command completed successfully on $IP" -Component "RemoteCommand"
            return $wslResult.Output
        }
        else {
            Write-LogError -Message "Unable to detect OS type for $IP" -Component "RemoteCommand"
            Write-Host "Unable to detect OS type for $IP" -ForegroundColor Red
            return $null
        }
    }
    catch {
        Write-LogError -Message "Error executing remote command on $IP" -Component "RemoteCommand" -Exception $_.Exception
        Write-Host "Error executing remote command: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

#endregion

#===============================================================================
#region HEALTH MONITORING FUNCTIONS
#===============================================================================

#-------------------------------------------------------------------------------
# Server Health Monitoring
#-------------------------------------------------------------------------------

function Get-ServerHealth {
    <#
    .SYNOPSIS
        Gets comprehensive health information for a remote server.

    .DESCRIPTION
        Collects CPU usage, memory usage, disk usage, uptime, and system load
        from a remote server via SSH (Linux) or WinRM (Windows).

    .PARAMETER IP
        The IP address of the target server.

    .PARAMETER User
        The username for authentication.

    .PARAMETER Password
        The password for authentication.

    .EXAMPLE
        Get-ServerHealth -IP "192.168.1.100" -User "admin" -Password "password123"

    .OUTPUTS
        PSCustomObject with health metrics including Status, CPU, Memory, Disk, Uptime, Load
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password
    )
    
    try {
        Write-LogInfo -Message "Getting server health for $IP" -Component "HealthMonitoring"
        Write-Host "Checking server health for $IP..." -ForegroundColor Cyan
        
        # First check if server is reachable
        $pingResult = Test-Connection -ComputerName $IP -Count 2 -Quiet -ErrorAction SilentlyContinue
        
        if (-not $pingResult) {
            Write-LogWarning -Message "Server $IP is not reachable" -Component "HealthMonitoring"
            return [PSCustomObject]@{
                IP = $IP
                Status = "Offline"
                StatusColor = "Red"
                CPU = $null
                Memory = $null
                Disk = $null
                Uptime = $null
                Load = $null
                LastChecked = Get-Date
                ErrorMessage = "Server not reachable"
            }
        }
        
        # Detect OS type
        $osType = Get-TargetOS -IP $IP
        
        if ($osType -eq "Linux") {
            return Get-LinuxServerHealth -IP $IP -User $User -Password $Password
        }
        elseif ($osType -eq "Windows") {
            return Get-WindowsServerHealth -IP $IP -User $User -Password $Password
        }
        else {
            Write-LogWarning -Message "Unable to detect OS for $IP" -Component "HealthMonitoring"
            return [PSCustomObject]@{
                IP = $IP
                Status = "Unknown"
                StatusColor = "Yellow"
                CPU = $null
                Memory = $null
                Disk = $null
                Uptime = $null
                Load = $null
                LastChecked = Get-Date
                ErrorMessage = "Could not detect OS type"
            }
        }
    }
    catch {
        Write-LogError -Message "Error getting server health for $IP" -Component "HealthMonitoring" -Exception $_.Exception
        return [PSCustomObject]@{
            IP = $IP
            Status = "Error"
            StatusColor = "Red"
            CPU = $null
            Memory = $null
            Disk = $null
            Uptime = $null
            Load = $null
            LastChecked = Get-Date
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Get-LinuxServerHealth {
    <#
    .SYNOPSIS
        Gets health information from a Linux server via SSH.
    #>
    param(
        [string]$IP,
        [string]$User,
        [string]$Password
    )
    
    try {
        Write-LogDebug -Message "Getting Linux server health for $IP" -Component "HealthMonitoring"
        
        # Collect all health metrics in a single SSH command for efficiency
        $healthCommand = @"
echo '===CPU===' && top -bn1 | grep 'Cpu(s)' | awk '{print 100 - `$8}' && \
echo '===MEMORY===' && free -m | awk 'NR==2{printf "%.1f %.1f %.1f", `$3, `$2, `$3*100/`$2}' && \
echo '===DISK===' && df -h / | awk 'NR==2{print `$5}' | tr -d '%' && \
echo '===UPTIME===' && uptime -p && \
echo '===LOAD===' && cat /proc/loadavg | awk '{print `$1, `$2, `$3}'
"@

        $result = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $healthCommand
        
        if ($null -eq $result) {
            Write-LogWarning -Message "Failed to get health data from Linux server $IP" -Component "HealthMonitoring"
            return [PSCustomObject]@{
                IP = $IP
                Status = "Degraded"
                StatusColor = "Yellow"
                CPU = $null
                Memory = $null
                Disk = $null
                Uptime = $null
                Load = $null
                LastChecked = Get-Date
                ErrorMessage = "Failed to retrieve health metrics"
            }
        }
        
        # Parse the results
        $resultLines = $result -split "`n"
        
        $cpuUsage = $null
        $memoryUsed = $null
        $memoryTotal = $null
        $memoryPercent = $null
        $diskPercent = $null
        $uptime = $null
        $load1 = $null
        $load5 = $null
        $load15 = $null
        
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
                    if ($line -match '^\d+\.?\d*$') {
                        $cpuUsage = [math]::Round([double]$line, 1)
                    }
                }
                "MEMORY" {
                    $memParts = $line -split '\s+'
                    if ($memParts.Count -ge 3) {
                        $memoryUsed = [double]$memParts[0]
                        $memoryTotal = [double]$memParts[1]
                        $memoryPercent = [math]::Round([double]$memParts[2], 1)
                    }
                }
                "DISK" {
                    if ($line -match '^\d+\.?\d*$') {
                        $diskPercent = [math]::Round([double]$line, 1)
                    }
                }
                "UPTIME" {
                    $uptime = $line -replace '^up\s+', ''
                }
                "LOAD" {
                    $loadParts = $line -split '\s+'
                    if ($loadParts.Count -ge 3) {
                        $load1 = $loadParts[0]
                        $load5 = $loadParts[1]
                        $load15 = $loadParts[2]
                    }
                }
            }
        }
        
        # Determine overall status
        $status = "Healthy"
        $statusColor = "Green"
        
        if (($cpuUsage -and $cpuUsage -gt 90) -or ($memoryPercent -and $memoryPercent -gt 90) -or ($diskPercent -and $diskPercent -gt 90)) {
            $status = "Critical"
            $statusColor = "Red"
        }
        elseif (($cpuUsage -and $cpuUsage -gt 70) -or ($memoryPercent -and $memoryPercent -gt 70) -or ($diskPercent -and $diskPercent -gt 80)) {
            $status = "Warning"
            $statusColor = "Yellow"
        }
        
        Write-LogInfo -Message "Linux server $IP health: $status (CPU: $cpuUsage%, Mem: $memoryPercent%, Disk: $diskPercent%)" -Component "HealthMonitoring"
        
        return [PSCustomObject]@{
            IP = $IP
            OSType = "Linux"
            Status = $status
            StatusColor = $statusColor
            CPU = [PSCustomObject]@{
                UsagePercent = $cpuUsage
            }
            Memory = [PSCustomObject]@{
                UsedMB = $memoryUsed
                TotalMB = $memoryTotal
                UsagePercent = $memoryPercent
            }
            Disk = [PSCustomObject]@{
                UsagePercent = $diskPercent
            }
            Uptime = $uptime
            Load = [PSCustomObject]@{
                Load1Min = $load1
                Load5Min = $load5
                Load15Min = $load15
            }
            LastChecked = Get-Date
            ErrorMessage = $null
        }
    }
    catch {
        Write-LogError -Message "Error getting Linux server health for $IP" -Component "HealthMonitoring" -Exception $_.Exception
        return [PSCustomObject]@{
            IP = $IP
            OSType = "Linux"
            Status = "Error"
            StatusColor = "Red"
            CPU = $null
            Memory = $null
            Disk = $null
            Uptime = $null
            Load = $null
            LastChecked = Get-Date
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Get-WindowsServerHealth {
    <#
    .SYNOPSIS
        Gets health information from a Windows server via WinRM.
    #>
    param(
        [string]$IP,
        [string]$User,
        [string]$Password
    )
    
    try {
        Write-LogDebug -Message "Getting Windows server health for $IP" -Component "HealthMonitoring"
        
        # Create credential object
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        
        # Create session options
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        
        # Establish remote session
        $session = New-PSSession -ComputerName $IP -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
        
        if (-not $session) {
            Write-LogWarning -Message "Failed to establish session to Windows server $IP" -Component "HealthMonitoring"
            return [PSCustomObject]@{
                IP = $IP
                OSType = "Windows"
                Status = "Degraded"
                StatusColor = "Yellow"
                CPU = $null
                Memory = $null
                Disk = $null
                Uptime = $null
                Load = $null
                LastChecked = Get-Date
                ErrorMessage = "Failed to establish WinRM session"
            }
        }
        
        # Collect health metrics
        $healthData = Invoke-Command -Session $session -ScriptBlock {
            # CPU Usage
            $cpuUsage = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
            
            # Memory Usage
            $os = Get-CimInstance Win32_OperatingSystem
            $totalMemory = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
            $freeMemory = [math]::Round($os.FreePhysicalMemory / 1024, 0)
            $usedMemory = $totalMemory - $freeMemory
            $memoryPercent = [math]::Round(($usedMemory / $totalMemory) * 100, 1)
            
            # Disk Usage (System Drive)
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
            $diskPercent = [math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 1)
            
            # Uptime
            $uptime = (Get-Date) - $os.LastBootUpTime
            $uptimeString = "{0} days, {1} hours, {2} minutes" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
            
            # System Load (approximation using processor queue length)
            $perfCounter = Get-CimInstance Win32_PerfFormattedData_PerfOS_System
            $processorQueueLength = $perfCounter.ProcessorQueueLength
            
            return @{
                CPU = $cpuUsage
                MemoryUsed = $usedMemory
                MemoryTotal = $totalMemory
                MemoryPercent = $memoryPercent
                DiskPercent = $diskPercent
                Uptime = $uptimeString
                ProcessorQueueLength = $processorQueueLength
            }
        }
        
        # Close session
        Remove-PSSession -Session $session
        
        # Determine overall status
        $status = "Healthy"
        $statusColor = "Green"
        
        if (($healthData.CPU -gt 90) -or ($healthData.MemoryPercent -gt 90) -or ($healthData.DiskPercent -gt 90)) {
            $status = "Critical"
            $statusColor = "Red"
        }
        elseif (($healthData.CPU -gt 70) -or ($healthData.MemoryPercent -gt 70) -or ($healthData.DiskPercent -gt 80)) {
            $status = "Warning"
            $statusColor = "Yellow"
        }
        
        Write-LogInfo -Message "Windows server $IP health: $status (CPU: $($healthData.CPU)%, Mem: $($healthData.MemoryPercent)%, Disk: $($healthData.DiskPercent)%)" -Component "HealthMonitoring"
        
        return [PSCustomObject]@{
            IP = $IP
            OSType = "Windows"
            Status = $status
            StatusColor = $statusColor
            CPU = [PSCustomObject]@{
                UsagePercent = $healthData.CPU
            }
            Memory = [PSCustomObject]@{
                UsedMB = $healthData.MemoryUsed
                TotalMB = $healthData.MemoryTotal
                UsagePercent = $healthData.MemoryPercent
            }
            Disk = [PSCustomObject]@{
                UsagePercent = $healthData.DiskPercent
            }
            Uptime = $healthData.Uptime
            Load = [PSCustomObject]@{
                ProcessorQueueLength = $healthData.ProcessorQueueLength
            }
            LastChecked = Get-Date
            ErrorMessage = $null
        }
    }
    catch {
        Write-LogError -Message "Error getting Windows server health for $IP" -Component "HealthMonitoring" -Exception $_.Exception
        return [PSCustomObject]@{
            IP = $IP
            OSType = "Windows"
            Status = "Error"
            StatusColor = "Red"
            CPU = $null
            Memory = $null
            Disk = $null
            Uptime = $null
            Load = $null
            LastChecked = Get-Date
            ErrorMessage = $_.Exception.Message
        }
    }
}

#-------------------------------------------------------------------------------
# Container Health Monitoring
#-------------------------------------------------------------------------------

function Get-ContainerHealth {
    <#
    .SYNOPSIS
        Gets health information for Docker containers on a remote server.

    .DESCRIPTION
        Lists all Docker containers and their health status, resource usage,
        and restart counts on a remote server.

    .PARAMETER IP
        The IP address of the target server.

    .PARAMETER User
        The username for authentication.

    .PARAMETER Password
        The password for authentication.

    .PARAMETER ContainerName
        Optional. If specified, only returns health for this container.

    .EXAMPLE
        Get-ContainerHealth -IP "192.168.1.100" -User "admin" -Password "password123"

    .EXAMPLE
        Get-ContainerHealth -IP "192.168.1.100" -User "admin" -Password "password123" -ContainerName "nginx"

    .OUTPUTS
        Array of PSCustomObjects with container health information
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,
        
        [string]$ContainerName = $null
    )
    
    try {
        Write-LogInfo -Message "Getting container health for $IP" -Component "HealthMonitoring"
        Write-Host "Checking container health on $IP..." -ForegroundColor Cyan
        
        # First check if Docker is running
        $dockerCheck = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command "docker info --format '{{.ServerVersion}}' 2>/dev/null || echo 'DOCKER_NOT_RUNNING'"
        
        if ($null -eq $dockerCheck -or $dockerCheck -match "DOCKER_NOT_RUNNING|Cannot connect|permission denied") {
            Write-LogWarning -Message "Docker is not accessible on $IP" -Component "HealthMonitoring"
            return @([PSCustomObject]@{
                ServerIP = $IP
                Status = "DockerNotAccessible"
                StatusColor = "Red"
                ErrorMessage = "Docker daemon is not accessible or not running"
                Containers = @()
            })
        }
        
        # Build the container filter if a specific container is requested
        $containerFilter = ""
        if (-not [string]::IsNullOrEmpty($ContainerName)) {
            $containerFilter = "--filter `"name=$ContainerName`""
        }
        
        # Get container list with detailed stats using docker inspect and stats
        # Using a comprehensive command to get all needed info
        $containerCommand = @"
docker ps -a $containerFilter --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}|{{.State}}' 2>/dev/null
"@
        
        $containerList = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $containerCommand
        
        if ($null -eq $containerList -or [string]::IsNullOrWhiteSpace($containerList)) {
            Write-LogInfo -Message "No containers found on $IP" -Component "HealthMonitoring"
            return @([PSCustomObject]@{
                ServerIP = $IP
                Status = "NoContainers"
                StatusColor = "Gray"
                ErrorMessage = $null
                Containers = @()
            })
        }
        
        $containers = @()
        $containerLines = $containerList -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        
        foreach ($line in $containerLines) {
            $parts = $line -split '\|'
            if ($parts.Count -lt 6) { continue }
            
            $containerId = $parts[0].Trim()
            $containerNameParsed = $parts[1].Trim()
            $image = $parts[2].Trim()
            $statusText = $parts[3].Trim()
            $ports = $parts[4].Trim()
            $state = $parts[5].Trim()
            
            # Get detailed container stats for running containers
            $cpuPercent = $null
            $memUsage = $null
            $memLimit = $null
            $memPercent = $null
            $netIO = $null
            $blockIO = $null
            $restartCount = 0
            $healthStatus = "N/A"
            
            if ($state -eq "running") {
                # Get container stats
                $statsCommand = "docker stats $containerId --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}' 2>/dev/null"
                $stats = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $statsCommand
                
                if ($stats) {
                    $statsParts = $stats.Trim() -split '\|'
                    if ($statsParts.Count -ge 5) {
                        $cpuPercent = $statsParts[0].Trim() -replace '%', ''
                        $memUsage = $statsParts[1].Trim()
                        $memPercent = $statsParts[2].Trim() -replace '%', ''
                        $netIO = $statsParts[3].Trim()
                        $blockIO = $statsParts[4].Trim()
                    }
                }
                
                # Get container health check status if available
                $healthCommand = "docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' $containerId 2>/dev/null"
                $healthResult = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $healthCommand
                if ($healthResult) {
                    $healthStatus = $healthResult.Trim()
                }
            }
            
            # Get restart count
            $restartCommand = "docker inspect --format='{{.RestartCount}}' $containerId 2>/dev/null"
            $restartResult = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $restartCommand
            if ($restartResult -and $restartResult -match '^\d+$') {
                $restartCount = [int]$restartResult.Trim()
            }
            
            # Determine container status color
            $containerStatusColor = "Green"
            if ($state -ne "running") {
                $containerStatusColor = "Red"
            }
            elseif ($healthStatus -eq "unhealthy") {
                $containerStatusColor = "Red"
            }
            elseif ($healthStatus -eq "starting") {
                $containerStatusColor = "Yellow"
            }
            elseif ($restartCount -gt 5) {
                $containerStatusColor = "Yellow"
            }
            
            $containers += [PSCustomObject]@{
                ContainerId = $containerId
                Name = $containerNameParsed
                Image = $image
                State = $state
                Status = $statusText
                Ports = $ports
                HealthCheck = $healthStatus
                CPUPercent = $cpuPercent
                MemoryUsage = $memUsage
                MemoryPercent = $memPercent
                NetworkIO = $netIO
                BlockIO = $blockIO
                RestartCount = $restartCount
                StatusColor = $containerStatusColor
            }
        }
        
        # Determine overall status
        $overallStatus = "Healthy"
        $overallColor = "Green"
        
        $runningCount = ($containers | Where-Object { $_.State -eq "running" }).Count
        $totalCount = $containers.Count
        $unhealthyCount = ($containers | Where-Object { $_.HealthCheck -eq "unhealthy" -or $_.State -ne "running" }).Count
        
        if ($unhealthyCount -gt 0) {
            if ($runningCount -eq 0) {
                $overallStatus = "Critical"
                $overallColor = "Red"
            }
            else {
                $overallStatus = "Warning"
                $overallColor = "Yellow"
            }
        }
        
        Write-LogInfo -Message "Container health on ${IP}: $overallStatus ($runningCount/$totalCount running)" -Component "HealthMonitoring"
        
        return [PSCustomObject]@{
            ServerIP = $IP
            Status = $overallStatus
            StatusColor = $overallColor
            TotalContainers = $totalCount
            RunningContainers = $runningCount
            StoppedContainers = $totalCount - $runningCount
            UnhealthyContainers = $unhealthyCount
            ErrorMessage = $null
            Containers = $containers
            LastChecked = Get-Date
        }
    }
    catch {
        Write-LogError -Message "Error getting container health for $IP" -Component "HealthMonitoring" -Exception $_.Exception
        return [PSCustomObject]@{
            ServerIP = $IP
            Status = "Error"
            StatusColor = "Red"
            TotalContainers = 0
            RunningContainers = 0
            StoppedContainers = 0
            UnhealthyContainers = 0
            ErrorMessage = $_.Exception.Message
            Containers = @()
            LastChecked = Get-Date
        }
    }
}

function Get-ContainerLogs {
    <#
    .SYNOPSIS
        Gets logs from a Docker container.

    .DESCRIPTION
        Retrieves the last N lines of logs from a specified Docker container.

    .PARAMETER IP
        The IP address of the target server.

    .PARAMETER User
        The username for authentication.

    .PARAMETER Password
        The password for authentication.

    .PARAMETER ContainerName
        The name or ID of the container.

    .PARAMETER Tail
        Number of lines to retrieve from the end. Default: 100

    .PARAMETER Since
        Only return logs since this time (e.g., "10m", "1h", "2023-01-01")

    .EXAMPLE
        Get-ContainerLogs -IP "192.168.1.100" -User "admin" -Password "pass" -ContainerName "nginx" -Tail 50
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,
        
        [Parameter(Mandatory=$true)]
        [string]$ContainerName,
        
        [int]$Tail = 100,
        
        [string]$Since = $null
    )
    
    try {
        Write-LogInfo -Message "Getting logs for container $ContainerName on $IP" -Component "HealthMonitoring"
        
        $logsCommand = "docker logs --tail $Tail"
        
        if (-not [string]::IsNullOrEmpty($Since)) {
            $logsCommand += " --since $Since"
        }
        
        $logsCommand += " $ContainerName 2>&1"
        
        $logs = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $logsCommand
        
        if ($null -eq $logs) {
            Write-LogWarning -Message "Failed to get logs for container $ContainerName" -Component "HealthMonitoring"
            return [PSCustomObject]@{
                ContainerName = $ContainerName
                Logs = $null
                ErrorMessage = "Failed to retrieve logs"
            }
        }
        
        Write-LogDebug -Message "Retrieved logs for container $ContainerName" -Component "HealthMonitoring"
        
        return [PSCustomObject]@{
            ContainerName = $ContainerName
            Logs = $logs
            ErrorMessage = $null
        }
    }
    catch {
        Write-LogError -Message "Error getting logs for container $ContainerName" -Component "HealthMonitoring" -Exception $_.Exception
        return [PSCustomObject]@{
            ContainerName = $ContainerName
            Logs = $null
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Restart-Container {
    <#
    .SYNOPSIS
        Restarts a Docker container.

    .PARAMETER IP
        The IP address of the target server.

    .PARAMETER User
        The username for authentication.

    .PARAMETER Password
        The password for authentication.

    .PARAMETER ContainerName
        The name or ID of the container to restart.

    .EXAMPLE
        Restart-Container -IP "192.168.1.100" -User "admin" -Password "pass" -ContainerName "nginx"
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,
        
        [Parameter(Mandatory=$true)]
        [string]$ContainerName
    )
    
    try {
        Write-LogInfo -Message "Restarting container $ContainerName on $IP" -Component "HealthMonitoring"
        Write-Host "Restarting container $ContainerName..." -ForegroundColor Cyan
        
        $restartCommand = "docker restart $ContainerName 2>&1 && echo 'RESTART_SUCCESS' || echo 'RESTART_FAILED'"
        
        $result = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $restartCommand
        
        if ($result -match "RESTART_SUCCESS") {
            Write-LogSuccess -Message "Container $ContainerName restarted successfully on $IP" -Component "HealthMonitoring"
            Write-Host "Container $ContainerName restarted successfully" -ForegroundColor Green
            return $true
        }
        else {
            Write-LogError -Message "Failed to restart container ${ContainerName}: $result" -Component "HealthMonitoring"
            Write-Host "Failed to restart container: $result" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-LogError -Message "Error restarting container $ContainerName" -Component "HealthMonitoring" -Exception $_.Exception
        Write-Host "Error restarting container: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Stop-Container {
    <#
    .SYNOPSIS
        Stops a Docker container.

    .PARAMETER IP
        The IP address of the target server.

    .PARAMETER User
        The username for authentication.

    .PARAMETER Password
        The password for authentication.

    .PARAMETER ContainerName
        The name or ID of the container to stop.

    .EXAMPLE
        Stop-Container -IP "192.168.1.100" -User "admin" -Password "pass" -ContainerName "nginx"
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,
        
        [Parameter(Mandatory=$true)]
        [string]$ContainerName
    )
    
    try {
        Write-LogInfo -Message "Stopping container $ContainerName on $IP" -Component "HealthMonitoring"
        Write-Host "Stopping container $ContainerName..." -ForegroundColor Cyan
        
        $stopCommand = "docker stop $ContainerName 2>&1 && echo 'STOP_SUCCESS' || echo 'STOP_FAILED'"
        
        $result = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $stopCommand
        
        if ($result -match "STOP_SUCCESS") {
            Write-LogSuccess -Message "Container $ContainerName stopped successfully on $IP" -Component "HealthMonitoring"
            Write-Host "Container $ContainerName stopped successfully" -ForegroundColor Green
            return $true
        }
        else {
            Write-LogError -Message "Failed to stop container ${ContainerName}: $result" -Component "HealthMonitoring"
            Write-Host "Failed to stop container: $result" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-LogError -Message "Error stopping container $ContainerName" -Component "HealthMonitoring" -Exception $_.Exception
        Write-Host "Error stopping container: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Start-Container {
    <#
    .SYNOPSIS
        Starts a Docker container.

    .PARAMETER IP
        The IP address of the target server.

    .PARAMETER User
        The username for authentication.

    .PARAMETER Password
        The password for authentication.

    .PARAMETER ContainerName
        The name or ID of the container to start.

    .EXAMPLE
        Start-Container -IP "192.168.1.100" -User "admin" -Password "pass" -ContainerName "nginx"
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,
        
        [Parameter(Mandatory=$true)]
        [string]$ContainerName
    )
    
    try {
        Write-LogInfo -Message "Starting container $ContainerName on $IP" -Component "HealthMonitoring"
        Write-Host "Starting container $ContainerName..." -ForegroundColor Cyan
        
        $startCommand = "docker start $ContainerName 2>&1 && echo 'START_SUCCESS' || echo 'START_FAILED'"
        
        $result = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $startCommand
        
        if ($result -match "START_SUCCESS") {
            Write-LogSuccess -Message "Container $ContainerName started successfully on $IP" -Component "HealthMonitoring"
            Write-Host "Container $ContainerName started successfully" -ForegroundColor Green
            return $true
        }
        else {
            Write-LogError -Message "Failed to start container ${ContainerName}: $result" -Component "HealthMonitoring"
            Write-Host "Failed to start container: $result" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-LogError -Message "Error starting container $ContainerName" -Component "HealthMonitoring" -Exception $_.Exception
        Write-Host "Error starting container: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

#-------------------------------------------------------------------------------
# Combined Health Report
#-------------------------------------------------------------------------------

function Get-FullHealthReport {
    <#
    .SYNOPSIS
        Gets a comprehensive health report for a server including both system and container health.

    .DESCRIPTION
        Combines server health metrics and container health into a single comprehensive report.

    .PARAMETER IP
        The IP address of the target server.

    .PARAMETER User
        The username for authentication.

    .PARAMETER Password
        The password for authentication.

    .EXAMPLE
        Get-FullHealthReport -IP "192.168.1.100" -User "admin" -Password "password123"
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password
    )
    
    try {
        Write-LogInfo -Message "Generating full health report for $IP" -Component "HealthMonitoring"
        Write-Host "Generating comprehensive health report for $IP..." -ForegroundColor Cyan
        
        # Get server health
        $serverHealth = Get-ServerHealth -IP $IP -User $User -Password $Password
        
        # Get container health
        $containerHealth = Get-ContainerHealth -IP $IP -User $User -Password $Password
        
        # Determine overall health status
        $overallStatus = "Healthy"
        $overallColor = "Green"
        
        if ($serverHealth.Status -eq "Critical" -or $serverHealth.Status -eq "Error" -or 
            $serverHealth.Status -eq "Offline" -or $containerHealth.Status -eq "Critical") {
            $overallStatus = "Critical"
            $overallColor = "Red"
        }
        elseif ($serverHealth.Status -eq "Warning" -or $serverHealth.Status -eq "Degraded" -or 
                $containerHealth.Status -eq "Warning") {
            $overallStatus = "Warning"
            $overallColor = "Yellow"
        }
        
        Write-LogInfo -Message "Full health report for ${IP}: $overallStatus" -Component "HealthMonitoring"
        
        return [PSCustomObject]@{
            IP = $IP
            OverallStatus = $overallStatus
            OverallStatusColor = $overallColor
            Server = $serverHealth
            Containers = $containerHealth
            ReportGeneratedAt = Get-Date
        }
    }
    catch {
        Write-LogError -Message "Error generating full health report for $IP" -Component "HealthMonitoring" -Exception $_.Exception
        return [PSCustomObject]@{
            IP = $IP
            OverallStatus = "Error"
            OverallStatusColor = "Red"
            Server = $null
            Containers = $null
            ReportGeneratedAt = Get-Date
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Format-HealthReport {
    <#
    .SYNOPSIS
        Formats a health report for display.

    .DESCRIPTION
        Takes a health report object and formats it for console or GUI display.

    .PARAMETER HealthReport
        The health report object from Get-FullHealthReport.

    .PARAMETER OutputFormat
        Format type: "Console", "Simple", or "Detailed". Default: "Console"

    .EXAMPLE
        Get-FullHealthReport -IP "192.168.1.100" -User "admin" -Password "pass" | Format-HealthReport
    #>
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [PSCustomObject]$HealthReport,
        
        [ValidateSet("Console", "Simple", "Detailed")]
        [string]$OutputFormat = "Console"
    )
    
    $output = @()
    
    $output += ""
    $output += "═══════════════════════════════════════════════════════════════"
    $output += "  HEALTH REPORT: $($HealthReport.IP)"
    $output += "  Generated: $($HealthReport.ReportGeneratedAt.ToString('yyyy-MM-dd HH:mm:ss'))"
    $output += "  Overall Status: $($HealthReport.OverallStatus)"
    $output += "═══════════════════════════════════════════════════════════════"
    
    if ($HealthReport.Server) {
        $s = $HealthReport.Server
        $output += ""
        $output += "┌─ SERVER HEALTH ─────────────────────────────────────────────┐"
        $output += "│  Status: $($s.Status)"
        if ($s.CPU) {
            $output += "│  CPU Usage: $($s.CPU.UsagePercent)%"
        }
        if ($s.Memory) {
            $output += "│  Memory: $($s.Memory.UsedMB)MB / $($s.Memory.TotalMB)MB ($($s.Memory.UsagePercent)%)"
        }
        if ($s.Disk) {
            $output += "│  Disk Usage: $($s.Disk.UsagePercent)%"
        }
        if ($s.Uptime) {
            $output += "│  Uptime: $($s.Uptime)"
        }
        if ($s.Load -and $s.Load.Load1Min) {
            $output += "│  Load Average: $($s.Load.Load1Min) / $($s.Load.Load5Min) / $($s.Load.Load15Min)"
        }
        $output += "└─────────────────────────────────────────────────────────────┘"
    }
    
    if ($HealthReport.Containers) {
        $c = $HealthReport.Containers
        $output += ""
        $output += "┌─ CONTAINER HEALTH ──────────────────────────────────────────┐"
        $output += "│  Status: $($c.Status)"
        $output += "│  Total: $($c.TotalContainers) | Running: $($c.RunningContainers) | Stopped: $($c.StoppedContainers)"
        $output += "│"
        
        if ($c.Containers -and $c.Containers.Count -gt 0) {
            foreach ($container in $c.Containers) {
                $stateIcon = if ($container.State -eq "running") { "●" } else { "○" }
                $output += "│  $stateIcon $($container.Name)"
                $output += "│    Image: $($container.Image)"
                $output += "│    Status: $($container.Status)"
                if ($container.State -eq "running" -and $container.CPUPercent) {
                    $output += "│    CPU: $($container.CPUPercent)% | Memory: $($container.MemoryUsage) ($($container.MemoryPercent)%)"
                }
                if ($container.RestartCount -gt 0) {
                    $output += "│    Restarts: $($container.RestartCount)"
                }
                $output += "│"
            }
        }
        else {
            $output += "│  No containers found"
        }
        $output += "└─────────────────────────────────────────────────────────────┘"
    }
    
    $output += ""
    
    return ($output -join "`n")
}

#-------------------------------------------------------------------------------
# Service Health Checks
#-------------------------------------------------------------------------------

function Test-ServiceHealth {
    <#
    .SYNOPSIS
        Tests if a specific service/port is accessible and responding.

    .DESCRIPTION
        Performs a TCP connection test and optionally an HTTP health check.

    .PARAMETER IP
        The IP address of the target server.

    .PARAMETER Port
        The port to check.

    .PARAMETER ServiceName
        Friendly name of the service (for logging/display).

    .PARAMETER HttpPath
        Optional HTTP path to check for HTTP-based services.

    .EXAMPLE
        Test-ServiceHealth -IP "192.168.1.100" -Port 80 -ServiceName "Web Server"

    .EXAMPLE
        Test-ServiceHealth -IP "192.168.1.100" -Port 8080 -ServiceName "API" -HttpPath "/health"
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [int]$Port,
        
        [string]$ServiceName = "Service",
        
        [string]$HttpPath = $null
    )
    
    try {
        Write-LogDebug -Message "Testing service health for $ServiceName on ${IP}:$Port" -Component "HealthMonitoring"
        
        # TCP connection test
        $tcpResult = Test-NetConnection -ComputerName $IP -Port $Port -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        
        if (-not $tcpResult.TcpTestSucceeded) {
            Write-LogWarning -Message "$ServiceName on ${IP}:$Port is not accessible" -Component "HealthMonitoring"
            return [PSCustomObject]@{
                ServiceName = $ServiceName
                IP = $IP
                Port = $Port
                Status = "Unavailable"
                StatusColor = "Red"
                TcpConnected = $false
                HttpStatus = $null
                ResponseTime = $null
            }
        }
        
        $responseTime = $tcpResult.PingReplyDetails.RoundtripTime
        
        # HTTP health check if path is specified
        $httpStatus = $null
        if (-not [string]::IsNullOrEmpty($HttpPath)) {
            try {
                $uri = "http://${IP}:${Port}${HttpPath}"
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                $stopwatch.Stop()
                $responseTime = $stopwatch.ElapsedMilliseconds
                $httpStatus = [int]$response.StatusCode
            }
            catch {
                $httpStatus = "Error"
            }
        }
        
        # Determine status
        $status = "Healthy"
        $statusColor = "Green"
        
        if ($httpStatus -and $httpStatus -ne 200 -and $httpStatus -ne "Error") {
            if ($httpStatus -ge 500) {
                $status = "Critical"
                $statusColor = "Red"
            }
            else {
                $status = "Warning"
                $statusColor = "Yellow"
            }
        }
        elseif ($httpStatus -eq "Error") {
            $status = "Degraded"
            $statusColor = "Yellow"
        }
        
        Write-LogInfo -Message "$ServiceName on ${IP}:$Port is $status" -Component "HealthMonitoring"
        
        return [PSCustomObject]@{
            ServiceName = $ServiceName
            IP = $IP
            Port = $Port
            Status = $status
            StatusColor = $statusColor
            TcpConnected = $true
            HttpStatus = $httpStatus
            ResponseTime = $responseTime
        }
    }
    catch {
        Write-LogError -Message "Error testing service health for $ServiceName" -Component "HealthMonitoring" -Exception $_.Exception
        return [PSCustomObject]@{
            ServiceName = $ServiceName
            IP = $IP
            Port = $Port
            Status = "Error"
            StatusColor = "Red"
            TcpConnected = $false
            HttpStatus = $null
            ResponseTime = $null
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Test-CommonServices {
    <#
    .SYNOPSIS
        Tests common services that might be running on the server.

    .DESCRIPTION
        Checks common ports/services like SSH, HTTP, HTTPS, Docker API, etc.

    .PARAMETER IP
        The IP address of the target server.

    .EXAMPLE
        Test-CommonServices -IP "192.168.1.100"
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$IP
    )
    
    $commonServices = @(
        @{ Port = 22; Name = "SSH" },
        @{ Port = 80; Name = "HTTP" },
        @{ Port = 443; Name = "HTTPS" },
        @{ Port = 8080; Name = "HTTP Alt" },
        @{ Port = 9000; Name = "Portainer" },
        @{ Port = 9090; Name = "Prometheus" },
        @{ Port = 3000; Name = "Grafana" },
        @{ Port = 8443; Name = "Traefik Dashboard" },
        @{ Port = 53; Name = "DNS" },
        @{ Port = 5985; Name = "WinRM" }
    )
    
    $results = @()
    
    Write-Host "Checking common services on $IP..." -ForegroundColor Cyan
    
    foreach ($service in $commonServices) {
        $result = Test-ServiceHealth -IP $IP -Port $service.Port -ServiceName $service.Name
        if ($result.TcpConnected) {
            $results += $result
        }
    }
    
    return $results
}

#endregion

#===============================================================================
#region SERVICE INSTALLATION FUNCTIONS (DEBIAN)
#===============================================================================

function Install-AdGuard {
    <#
    .SYNOPSIS
        Installs AdGuard Home on a Debian-based system.

    .DESCRIPTION
        This function installs AdGuard Home, a network-wide ad and tracker blocking DNS server, on a Debian-based system
        via SSH. It checks for existing installations and installs AdGuard Home if not present.

    .PARAMETER IP
        The IP address of the target Debian server.

    .PARAMETER User
        The username for SSH authentication.

    .PARAMETER Password
        The password for SSH authentication.

    .PARAMETER Domain
        Base domain for Traefik routing (e.g., "example.com"). AdGuard will be accessible at adguard.example.com

    .EXAMPLE
        Install-AdGuard -IP "192.168.1.100" -User "admin" -Password "password123" -Domain "homelab.local"

    .NOTES
        Requires Traefik to be installed first for reverse proxy functionality.
        Requires plink (PuTTY) to be installed for SSH connectivity.
        Connection should already be validated before calling this function.
        Docker must be installed before running this function.
    #>

    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,

        [Parameter(Mandatory=$false)]
        [string]$Domain = "localhost"
    )

    try {
        Write-Host "`nStarting AdGuard Home installation on $IP..." -ForegroundColor Cyan

        # Check if plink is available
        if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
            Write-Host "Error: 'plink' (PuTTY) is required for SSH connection" -ForegroundColor Red
            Write-Host "Install with: choco install putty -y" -ForegroundColor Yellow
            return $false
        }
        
        # Function to execute remote command via SSH
        function Invoke-SSHCommand {
            param([string]$Command)
            
            $result = Write-Output y | plink -batch -pw $Password $User@$IP $Command 2>&1
            
            if ($LASTEXITCODE -ne 0 -and $result -match "error|fatal|failed|denied") {
                Write-Host "Command failed: $Command" -ForegroundColor Red
                Write-Host "Output: $result" -ForegroundColor Red
                return $null
            }
            
            return $result
        }

        # Create AdGuard directory structure
        Write-Host "Creating AdGuard Home directory structure..." -ForegroundColor Cyan
        Invoke-SSHCommand "mkdir -p /home/$User/adguard/work /home/$User/adguard/conf" | Out-Null
        
        # Check and cleanup existing AdGuard installation
        Write-Host "Checking for existing AdGuard Home installation..." -ForegroundColor Cyan
        $adguardCheck = Invoke-SSHCommand "sudo docker ps -a --filter name=adguard --format '{{.Names}}' 2>/dev/null"
        
        if ($adguardCheck -match "adguard") {
            Write-Host "Removing existing AdGuard Home container..." -ForegroundColor Yellow
            $composeExists = Invoke-SSHCommand "test -f /home/$User/adguard/docker-compose.yml && echo 'exists'"
            
            if ($composeExists -match "exists") {
                Invoke-SSHCommand "cd /home/$User/adguard && sudo docker compose down" | Out-Null
            } else {
                Invoke-SSHCommand "sudo docker rm -f adguard" | Out-Null
            }
        }
        
        # Create Docker Compose file
        Write-Host "Creating Docker Compose configuration..." -ForegroundColor Cyan
        $dockerComposeConfig = @"
services:
  adguard:
    container_name: adguard
    image: adguard/adguardhome:latest
    restart: always
    volumes:
      - ./work:/opt/adguardhome/work
      - ./conf:/opt/adguardhome/conf
    expose:
      - 80
      - 3000
    ports:
      - "53:53/tcp"
      - "53:53/udp"
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.adguard.rule=Host('adguard.$Domain')"
      - "traefik.http.routers.adguard.entrypoints=websecure"
      - "traefik.http.routers.adguard.tls.certresolver=letsencrypt"
      - "traefik.http.services.adguard.loadbalancer.server.port=80"

networks:
  traefik-network:
    external: true
"@
        
        # Write compose file using base64 encoding to preserve formatting
        $dockerComposeConfig | Out-File -FilePath "$env:TEMP\docker-compose.yml" -Encoding UTF8 -NoNewline
        $composeContent = Get-Content "$env:TEMP\docker-compose.yml" -Raw
        $composeBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($composeContent))
        
        # Transfer the compose file to remote server
        Invoke-SSHCommand "echo '$composeBase64' | base64 -d > /home/$User/adguard/docker-compose.yml" | Out-Null
        
        # Verify Traefik network exists
        Write-Host "Verifying Traefik network..." -ForegroundColor Cyan
        $networkCheck = Invoke-SSHCommand "sudo docker network ls --filter name=traefik-network --format '{{.Name}}' 2>/dev/null"
        
        if (-not ($networkCheck -match "traefik-network")) {
            Write-Host "Warning: Traefik network not found. Creating it..." -ForegroundColor Yellow
            $createNetwork = Invoke-SSHCommand "sudo docker network create traefik-network 2>&1 || true"
            if ($createNetwork -match "traefik-network|already exists") {
                Write-Host "Traefik network ready" -ForegroundColor Gray
            } else {
                Write-Host "Network creation output: $createNetwork" -ForegroundColor Gray
            }
        } else {
            Write-Host "Traefik network exists" -ForegroundColor Gray
        }
        
        # Deploy AdGuard Home using Docker Compose
        Write-Host "Deploying AdGuard Home with Docker Compose..." -ForegroundColor Cyan
        $deployOutput = Invoke-SSHCommand "cd /home/$User/adguard && sudo docker compose up -d 2>&1"
        
        if ($deployOutput) {
            Write-Host "Deploy output: $deployOutput" -ForegroundColor Gray
        }
        
        # Verify AdGuard is running
        Start-Sleep -Seconds 5
        $verifyResult = Invoke-SSHCommand "sudo docker ps --filter name=adguard --format '{{.Status}}'"
        
        if ($verifyResult -match "Up") {
            Write-Host "`nAdGuard Home installed successfully!" -ForegroundColor Green
            Write-Host "AdGuard Web UI: https://adguard.$Domain" -ForegroundColor Cyan
            Write-Host "Direct Access (if needed): http://$IP:3000" -ForegroundColor Gray
            Write-Host "DNS Server: $IP:53" -ForegroundColor Cyan
            Write-Host "`nNote: Complete the initial setup wizard on first access" -ForegroundColor Yellow
            Write-Host "Note: Ensure DNS points adguard.$Domain to $IP" -ForegroundColor Yellow
            Write-Host "Note: Configure your devices to use $IP as DNS server" -ForegroundColor Yellow
            return $true
        } else {
            Write-Host "AdGuard Home deployment failed" -ForegroundColor Red
            $logs = Invoke-SSHCommand "sudo docker logs adguard 2>&1"
            if ($logs) {
                Write-Host "Container logs:" -ForegroundColor Yellow
                Write-Host $logs -ForegroundColor Gray
            }
            return $false
        }
    }
    catch {
        Write-Host "Error during AdGuard Home installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Install-Crafty {
    <#
    .SYNOPSIS
        Installs Crafty Controller on a Debian-based system.

    .DESCRIPTION
        This function installs Crafty Controller, a powerful and easy-to-use Minecraft server management panel, on a Debian-based system
        via SSH. It checks for existing installations and installs Crafty Controller if not present.

    .PARAMETER IP
        The IP address of the target Debian server.

    .PARAMETER User
        The username for SSH authentication.

    .PARAMETER Password
        The password for SSH authentication.

    .PARAMETER Domain
        Base domain for Traefik routing (e.g., "example.com"). Crafty will be accessible at crafty.example.com

    .EXAMPLE
        Install-Crafty -IP "192.168.1.100" -User "admin" -Password "password123" -Domain "homelab.local"

    .NOTES
        Requires Traefik to be installed first for reverse proxy functionality.
        Requires plink (PuTTY) to be installed for SSH connectivity.
        Connection should already be validated before calling this function.
        Docker must be installed before running this function.
    #>

    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,

        [Parameter(Mandatory=$false)]
        [string]$Domain = "localhost"
    )

    try {
        Write-Host "`nStarting Crafty Controller installation on $IP..." -ForegroundColor Cyan

        # Check if plink is available
        if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
            Write-Host "Error: 'plink' (PuTTY) is required for SSH connection" -ForegroundColor Red
            Write-Host "Install with: choco install putty -y" -ForegroundColor Yellow
            return $false
        }
        
        # Function to execute remote command via SSH
        function Invoke-SSHCommand {
            param([string]$Command)
            
            $result = Write-Output y | plink -batch -pw $Password $User@$IP $Command 2>&1
            
            if ($LASTEXITCODE -ne 0 -and $result -match "error|fatal|failed|denied") {
                Write-Host "Command failed: $Command" -ForegroundColor Red
                Write-Host "Output: $result" -ForegroundColor Red
                return $null
            }
            
            return $result
        }

        # Create Crafty directory structure
        Write-Host "Creating Crafty Controller directory structure..." -ForegroundColor Cyan
        Invoke-SSHCommand "mkdir -p /home/$User/crafty/backups /home/$User/crafty/logs /home/$User/crafty/servers /home/$User/crafty/config" | Out-Null
        
        # Check and cleanup existing Crafty installation
        Write-Host "Checking for existing Crafty Controller installation..." -ForegroundColor Cyan
        $craftyCheck = Invoke-SSHCommand "sudo docker ps -a --filter name=crafty --format '{{.Names}}' 2>/dev/null"
        
        if ($craftyCheck -match "crafty") {
            Write-Host "Removing existing Crafty Controller container..." -ForegroundColor Yellow
            $composeExists = Invoke-SSHCommand "test -f /home/$User/crafty/docker-compose.yml && echo 'exists'"
            
            if ($composeExists -match "exists") {
                Invoke-SSHCommand "cd /home/$User/crafty && sudo docker compose down" | Out-Null
            } else {
                Invoke-SSHCommand "sudo docker rm -f crafty" | Out-Null
            }
        }
        
        # Create Docker Compose file
        Write-Host "Creating Docker Compose configuration..." -ForegroundColor Cyan
        $dockerComposeConfig = @"
services:
  crafty:
    container_name: crafty
    image: registry.gitlab.com/crafty-controller/crafty-4:latest
    restart: always
    environment:
      - TZ=Etc/UTC
    volumes:
      - ./backups:/crafty/backups
      - ./logs:/crafty/logs
      - ./servers:/crafty/servers
      - ./config:/crafty/app/config
    expose:
      - 8000
    ports:
      - "25565-25575:25565-25575"
      - "19132-19142:19132-19142/udp"
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.crafty.rule=Host('crafty.$Domain')"
      - "traefik.http.routers.crafty.entrypoints=websecure"
      - "traefik.http.routers.crafty.tls.certresolver=letsencrypt"
      - "traefik.http.services.crafty.loadbalancer.server.port=8000"

networks:
  traefik-network:
    external: true
"@
        
        # Write compose file using base64 encoding to preserve formatting
        $dockerComposeConfig | Out-File -FilePath "$env:TEMP\docker-compose.yml" -Encoding UTF8 -NoNewline
        $composeContent = Get-Content "$env:TEMP\docker-compose.yml" -Raw
        $composeBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($composeContent))
        
        # Transfer the compose file to remote server
        Invoke-SSHCommand "echo '$composeBase64' | base64 -d > /home/$User/crafty/docker-compose.yml" | Out-Null
        
        # Verify Traefik network exists
        Write-Host "Verifying Traefik network..." -ForegroundColor Cyan
        $networkCheck = Invoke-SSHCommand "sudo docker network ls --filter name=traefik-network --format '{{.Name}}' 2>/dev/null"
        
        if (-not ($networkCheck -match "traefik-network")) {
            Write-Host "Warning: Traefik network not found. Creating it..." -ForegroundColor Yellow
            $createNetwork = Invoke-SSHCommand "sudo docker network create traefik-network 2>&1 || true"
            if ($createNetwork -match "traefik-network|already exists") {
                Write-Host "Traefik network ready" -ForegroundColor Gray
            } else {
                Write-Host "Network creation output: $createNetwork" -ForegroundColor Gray
            }
        } else {
            Write-Host "Traefik network exists" -ForegroundColor Gray
        }
        
        # Deploy Crafty Controller using Docker Compose
        Write-Host "Deploying Crafty Controller with Docker Compose..." -ForegroundColor Cyan
        $deployOutput = Invoke-SSHCommand "cd /home/$User/crafty && sudo docker compose up -d 2>&1"
        
        if ($deployOutput) {
            Write-Host "Deploy output: $deployOutput" -ForegroundColor Gray
        }
        
        # Verify Crafty is running
        Start-Sleep -Seconds 5
        $verifyResult = Invoke-SSHCommand "sudo docker ps --filter name=crafty --format '{{.Status}}'"
        
        if ($verifyResult -match "Up") {
            Write-Host "`nCrafty Controller installed successfully!" -ForegroundColor Green
            Write-Host "Crafty Web UI: https://crafty.$Domain" -ForegroundColor Cyan
            Write-Host "Direct Access (if needed): http://$IP:8000" -ForegroundColor Gray
            Write-Host "Minecraft Servers: Ports 25565-25575 (Java) and 19132-19142 (Bedrock)" -ForegroundColor Cyan
            Write-Host "`nNote: Complete the initial setup wizard on first access" -ForegroundColor Yellow
            Write-Host "Note: Ensure DNS points crafty.$Domain to $IP" -ForegroundColor Yellow
            Write-Host "Note: Default credentials will be shown in container logs on first run" -ForegroundColor Yellow
            
            # Get initial credentials from logs
            Write-Host "`nFetching initial credentials..." -ForegroundColor Cyan
            Start-Sleep -Seconds 3
            $logs = Invoke-SSHCommand "sudo docker logs crafty 2>&1 | grep -A 5 'username\|password'"
            if ($logs) {
                Write-Host "Initial Credentials:" -ForegroundColor Green
                Write-Host $logs -ForegroundColor Gray
            }
            return $true
        } else {
            Write-Host "Crafty Controller deployment failed" -ForegroundColor Red
            $logs = Invoke-SSHCommand "sudo docker logs crafty 2>&1"
            if ($logs) {
                Write-Host "Container logs:" -ForegroundColor Yellow
                Write-Host $logs -ForegroundColor Gray
            }
            return $false
        }
    }
    catch {
        Write-Host "Error during Crafty Controller installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Install-Docker {
    <#
    .SYNOPSIS
        Installs Docker on a Debian-based system or Windows WSL2.

    .DESCRIPTION
        This function installs Docker Engine on a Debian-based system via SSH
        or on Windows via WSL2. It automatically detects the OS and uses the
        appropriate connection method.

    .PARAMETER IP
        The IP address of the target server.

    .PARAMETER User
        The username for authentication.

    .PARAMETER Password
        The password for authentication.

    .EXAMPLE
        Install-Docker -IP "192.168.1.100" -User "admin" -Password "password123"

    .NOTES
        Requires either plink (PuTTY) for Linux or WinRM access for Windows.
        Connection should already be validated before calling this function.
    #>

    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password
    )
    
    try {
        Write-Host "Checking Docker installation on $IP..." -ForegroundColor Cyan
        
        # Function to execute remote command (works on both Linux and Windows/WSL2)
        function Invoke-SSHCommand {
            param([string]$Command)
            
            $result = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $Command
            
            if ($null -eq $result) {
                Write-Host "Command failed: $Command" -ForegroundColor Red
                return $null
            }
            
            return $result
        }
        
        # Check if Docker is already installed
        $dockerCheck = Invoke-SSHCommand "docker --version"
        
        if ($null -ne $dockerCheck -and $dockerCheck -match "Docker version") {
            Write-Host "Docker is already installed: $dockerCheck" -ForegroundColor Green
            return $true
        }
        
        Write-Host "Docker not found. Installing Docker..." -ForegroundColor Yellow
        
        # Update package index
        Write-Host "  Updating package index..." -ForegroundColor Cyan
        $updateResult = Invoke-SSHCommand "sudo apt-get update -y"
        if ($null -eq $updateResult) {
            Write-Host "Failed to update package index" -ForegroundColor Red
            return $false
        }
        
        # Install prerequisites
        Write-Host "  Installing prerequisites..." -ForegroundColor Cyan
        $prereqResult = Invoke-SSHCommand "sudo apt-get install -y ca-certificates curl"
        if ($null -eq $prereqResult) {
            Write-Host "Failed to install prerequisites" -ForegroundColor Red
            return $false
        }
        
        # Create keyrings directory
        Write-Host "  Setting up keyrings directory..." -ForegroundColor Cyan
        $keyringDirResult = Invoke-SSHCommand "sudo install -m 0755 -d /etc/apt/keyrings"
        
        # Add Docker's official GPG key - use command that returns status
        Write-Host "  Adding Docker GPG key..." -ForegroundColor Cyan
        $gpgResult = Invoke-SSHCommand "sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && echo 'GPG_KEY_SUCCESS' || echo 'GPG_KEY_FAILED'"
        if ($gpgResult -notmatch "GPG_KEY_SUCCESS") {
            Write-Host "Failed to add Docker GPG key" -ForegroundColor Red
            Write-Host "Output: $gpgResult" -ForegroundColor Red
            return $false
        }
        Write-Host "  GPG key downloaded successfully" -ForegroundColor Green
        
        # Set proper permissions on the key file
        Write-Host "  Setting GPG key permissions..." -ForegroundColor Cyan
        $chmodResult = Invoke-SSHCommand "sudo chmod a+r /etc/apt/keyrings/docker.asc"
        
        # Remove any existing Docker repository configuration (cleanup from previous failed attempts)
        Write-Host "  Cleaning up old Docker repository configuration..." -ForegroundColor Cyan
        Invoke-SSHCommand "sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.sources"
        
        # Get the system codename for the repository
        Write-Host "  Detecting system version..." -ForegroundColor Cyan
        $codenameResult = Invoke-SSHCommand ". /etc/os-release && echo `$VERSION_CODENAME"
        $codename = ($codenameResult -split "`n")[0].Trim()
        if ([string]::IsNullOrWhiteSpace($codename)) {
            Write-Host "Failed to detect system codename, using 'bullseye' as default" -ForegroundColor Yellow
            $codename = "bullseye"
        }
        Write-Host "  System codename: $codename" -ForegroundColor Cyan
        
        # Set up Docker repository using DEB822 format with multi-line here-doc
        Write-Host "  Setting up Docker repository..." -ForegroundColor Cyan
        
        # Create the repository file line by line to avoid here-doc issues
        $setupRepoCommands = @(
            "sudo bash -c 'echo ""Types: deb"" > /etc/apt/sources.list.d/docker.sources'",
            "sudo bash -c 'echo ""URIs: https://download.docker.com/linux/debian"" >> /etc/apt/sources.list.d/docker.sources'",
            "sudo bash -c 'echo ""Suites: $codename"" >> /etc/apt/sources.list.d/docker.sources'",
            "sudo bash -c 'echo ""Components: stable"" >> /etc/apt/sources.list.d/docker.sources'",
            "sudo bash -c 'echo ""Signed-By: /etc/apt/keyrings/docker.asc"" >> /etc/apt/sources.list.d/docker.sources'"
        )
        
        $repoSuccess = $true
        foreach ($cmd in $setupRepoCommands) {
            $result = Invoke-SSHCommand $cmd
            if ($null -eq $result -and $cmd -notmatch "echo") {
                $repoSuccess = $false
                break
            }
        }
        
        if (-not $repoSuccess) {
            Write-Host "Failed to set up Docker repository" -ForegroundColor Red
            return $false
        }
        Write-Host "  Repository file created successfully" -ForegroundColor Green
        
        # Update package index with Docker repository
        Write-Host "  Updating package index with Docker repository..." -ForegroundColor Cyan
        $updateResult2 = Invoke-SSHCommand "sudo apt-get update -y"
        if ($null -eq $updateResult2) {
            Write-Host "Failed to update package index" -ForegroundColor Red
            return $false
        }
        
        # Install Docker Engine
        Write-Host "  Installing Docker Engine..." -ForegroundColor Cyan
        $installResult = Invoke-SSHCommand "sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
        if ($null -eq $installResult) {
            Write-Host "Failed to install Docker Engine" -ForegroundColor Red
            return $false
        }
        
        # Start and enable Docker service
        Write-Host "  Starting Docker service..." -ForegroundColor Cyan
        $startResult = Invoke-SSHCommand "sudo systemctl start docker && sudo systemctl enable docker"
        if ($null -eq $startResult) {
            Write-Host "Failed to start Docker service" -ForegroundColor Red
            return $false
        }
        
        # Add user to docker group (optional, for non-root usage)
        Write-Host "  Adding user to docker group..." -ForegroundColor Cyan
        Invoke-SSHCommand "sudo usermod -aG docker $User"
        
        # Verify Docker installation
        Write-Host "  Verifying Docker installation..." -ForegroundColor Cyan
        $verifyResult = Invoke-SSHCommand "docker --version"
        if ($null -ne $verifyResult -and $verifyResult -match "Docker version") {
            Write-Host "Docker installed successfully: $verifyResult" -ForegroundColor Green
            return $true
        }
        else {
            Write-Host "Docker installation completed but verification failed" -ForegroundColor Yellow
            return $false
        }
    }
    catch {
        Write-Host "Error during Docker installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Install-Heimdall {
    <#
    .SYNOPSIS
        Installs Heimdall on a Debian-based system.

    .DESCRIPTION
        This function installs Heimdall, an application dashboard for organizing your web applications,
        on a Debian-based system via SSH. It checks for existing installations and installs Heimdall if not present.

    .PARAMETER IP
        The IP address of the target Debian server.

    .PARAMETER User
        The username for SSH authentication.

    .PARAMETER Password
        The password for SSH authentication.

    .PARAMETER Domain
        Base domain for Traefik routing (e.g., "example.com"). Heimdall will be accessible at heimdall.example.com

    .EXAMPLE
        Install-Heimdall -IP "192.168.1.100" -User "admin" -Password "password123" -Domain "homelab.local"

    .NOTES
        Requires Traefik to be installed first for reverse proxy functionality.
        Requires plink (PuTTY) to be installed for SSH connectivity.
        Connection should already be validated before calling this function.
        Docker must be installed before running this function.
    #>

    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,

        [Parameter(Mandatory=$false)]
        [string]$Domain = "localhost"
    )

    try {
        Write-Host "`nStarting Heimdall installation on $IP..." -ForegroundColor Cyan

        # Check if plink is available
        if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
            Write-Host "Error: 'plink' (PuTTY) is required for SSH connection" -ForegroundColor Red
            Write-Host "Install with: choco install putty -y" -ForegroundColor Yellow
            return $false
        }
        
        # Function to execute remote command via SSH
        function Invoke-SSHCommand {
            param([string]$Command)
            
            $result = Write-Output y | plink -batch -pw $Password $User@$IP $Command 2>&1
            
            if ($LASTEXITCODE -ne 0 -and $result -match "error|fatal|failed|denied") {
                Write-Host "Command failed: $Command" -ForegroundColor Red
                Write-Host "Output: $result" -ForegroundColor Red
                return $null
            }
            
            return $result
        }

        # Create Heimdall directory structure
        Write-Host "Creating Heimdall directory structure..." -ForegroundColor Cyan
        Invoke-SSHCommand "mkdir -p /home/$User/heimdall/config" | Out-Null
        
        # Check and cleanup existing Heimdall installation
        Write-Host "Checking for existing Heimdall installation..." -ForegroundColor Cyan
        $heimdallCheck = Invoke-SSHCommand "sudo docker ps -a --filter name=heimdall --format '{{.Names}}' 2>/dev/null"
        
        if ($heimdallCheck -match "heimdall") {
            Write-Host "Removing existing Heimdall container..." -ForegroundColor Yellow
            $composeExists = Invoke-SSHCommand "test -f /home/$User/heimdall/docker-compose.yml && echo 'exists'"
            
            if ($composeExists -match "exists") {
                Invoke-SSHCommand "cd /home/$User/heimdall && sudo docker compose down" | Out-Null
            } else {
                Invoke-SSHCommand "sudo docker rm -f heimdall" | Out-Null
            }
        }
        
        # Create Docker Compose file
        Write-Host "Creating Docker Compose configuration..." -ForegroundColor Cyan
        $dockerComposeConfig = @"
services:
  heimdall:
    container_name: heimdall
    image: lscr.io/linuxserver/heimdall:latest
    restart: always
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    volumes:
      - heimdall_config:/config
    expose:
      - 80
      - 443
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.heimdall.rule=Host('heimdall.$Domain')"
      - "traefik.http.routers.heimdall.entrypoints=websecure"
      - "traefik.http.routers.heimdall.tls.certresolver=letsencrypt"
      - "traefik.http.services.heimdall.loadbalancer.server.port=80"

volumes:
  heimdall_config:
    name: heimdall_config

networks:
  traefik-network:
    external: true
"@
        
        # Write compose file using base64 encoding to preserve formatting
        $dockerComposeConfig | Out-File -FilePath "$env:TEMP\docker-compose.yml" -Encoding UTF8 -NoNewline
        $composeContent = Get-Content "$env:TEMP\docker-compose.yml" -Raw
        $composeBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($composeContent))
        
        # Transfer the compose file to remote server
        Invoke-SSHCommand "echo '$composeBase64' | base64 -d > /home/$User/heimdall/docker-compose.yml" | Out-Null
        
        # Verify Traefik network exists
        Write-Host "Verifying Traefik network..." -ForegroundColor Cyan
        $networkCheck = Invoke-SSHCommand "sudo docker network ls --filter name=traefik-network --format '{{.Name}}' 2>/dev/null"
        
        if (-not ($networkCheck -match "traefik-network")) {
            Write-Host "Warning: Traefik network not found. Creating it..." -ForegroundColor Yellow
            $createNetwork = Invoke-SSHCommand "sudo docker network create traefik-network 2>&1 || true"
            if ($createNetwork -match "traefik-network|already exists") {
                Write-Host "Traefik network ready" -ForegroundColor Gray
            } else {
                Write-Host "Network creation output: $createNetwork" -ForegroundColor Gray
            }
        } else {
            Write-Host "Traefik network exists" -ForegroundColor Gray
        }
        
        # Deploy Heimdall using Docker Compose
        Write-Host "Deploying Heimdall with Docker Compose..." -ForegroundColor Cyan
        $deployOutput = Invoke-SSHCommand "cd /home/$User/heimdall && sudo docker compose up -d 2>&1"
        
        if ($deployOutput) {
            Write-Host "Deploy output: $deployOutput" -ForegroundColor Gray
        }
        
        # Verify Heimdall is running
        Start-Sleep -Seconds 5
        $verifyResult = Invoke-SSHCommand "sudo docker ps --filter name=heimdall --format '{{.Status}}'"
        
        if ($verifyResult -match "Up") {
            Write-Host "`nHeimdall installed successfully!" -ForegroundColor Green
            Write-Host "Heimdall Web UI: https://heimdall.$Domain" -ForegroundColor Cyan
            Write-Host "Direct Access (if needed): http://$IP:80" -ForegroundColor Gray
            Write-Host "`nNote: Configure your dashboard by adding applications through the web UI" -ForegroundColor Yellow
            Write-Host "Note: Ensure DNS points heimdall.$Domain to $IP" -ForegroundColor Yellow
            return $true
        }
        else {
            Write-Host "Heimdall deployment failed" -ForegroundColor Red
            $logs = Invoke-SSHCommand "sudo docker logs heimdall 2>&1"
            if ($logs) {
                Write-Host "Container logs:" -ForegroundColor Yellow
                Write-Host $logs -ForegroundColor Gray
            }
            return $false
        }
    }
    catch {
        Write-Host "Error during Heimdall installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Install-N8N {
    <#
    .SYNOPSIS
        Installs n8n on a Debian-based system.

    .DESCRIPTION
        This function installs n8n, a workflow automation tool, on a Debian-based system
        via SSH. It checks for existing installations and installs n8n if not present.

    .PARAMETER IP
        The IP address of the target Debian server.

    .PARAMETER User
        The username for SSH authentication.

    .PARAMETER Password
        The password for SSH authentication.

    .PARAMETER Domain
        Base domain for Traefik routing (e.g., "example.com"). n8n will be accessible at n8n.example.com

    .EXAMPLE
        Install-N8N -IP "192.168.1.100" -User "admin" -Password "password123" -Domain "homelab.local"

    .NOTES
        Requires Traefik to be installed first for reverse proxy functionality.
        Requires plink (PuTTY) to be installed for SSH connectivity.
        Connection should already be validated before calling this function.
        Docker must be installed before running this function.
    #>

    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,

        [Parameter(Mandatory=$false)]
        [string]$Domain = "localhost"
    )

    try {
        Write-Host "`nStarting n8n installation on $IP..." -ForegroundColor Cyan

        # Check if plink is available
        if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
            Write-Host "Error: 'plink' (PuTTY) is required for SSH connection" -ForegroundColor Red
            Write-Host "Install with: choco install putty -y" -ForegroundColor Yellow
            return $false
        }
        
        # Function to execute remote command via SSH
        function Invoke-SSHCommand {
            param([string]$Command)
            
            $result = Write-Output y | plink -batch -pw $Password $User@$IP $Command 2>&1
            
            if ($LASTEXITCODE -ne 0 -and $result -match "error|fatal|failed|denied") {
                Write-Host "Command failed: $Command" -ForegroundColor Red
                Write-Host "Output: $result" -ForegroundColor Red
                return $null
            }
            
            return $result
        }

        # Create n8n directory structure
        Write-Host "Creating n8n directory structure..." -ForegroundColor Cyan
        Invoke-SSHCommand "mkdir -p /home/$User/n8n/data" | Out-Null
        
        # Check and cleanup existing n8n installation
        Write-Host "Checking for existing n8n installation..." -ForegroundColor Cyan
        $n8nCheck = Invoke-SSHCommand "sudo docker ps -a --filter name=n8n --format '{{.Names}}' 2>/dev/null"
        
        if ($n8nCheck -match "n8n") {
            Write-Host "Removing existing n8n container..." -ForegroundColor Yellow
            $composeExists = Invoke-SSHCommand "test -f /home/$User/n8n/docker-compose.yml && echo 'exists'"
            
            if ($composeExists -match "exists") {
                Invoke-SSHCommand "cd /home/$User/n8n && sudo docker compose down" | Out-Null
            } else {
                Invoke-SSHCommand "sudo docker rm -f n8n" | Out-Null
            }
        }
        
        # Create Docker Compose file
        Write-Host "Creating Docker Compose configuration..." -ForegroundColor Cyan
        $dockerComposeConfig = @"
services:
  n8n:
    container_name: n8n
    image: n8nio/n8n:latest
    restart: always
    environment:
      - N8N_HOST=n8n.$Domain
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://n8n.$Domain
      - GENERIC_TIMEZONE=Europe/Brussels
    volumes:
      - ./data:/home/node/.n8n
    expose:
      - 5678
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host('n8n.$Domain')"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"

networks:
  traefik-network:
    external: true
"@
        
        # Write compose file using base64 encoding to preserve formatting
        $dockerComposeConfig | Out-File -FilePath "$env:TEMP\docker-compose.yml" -Encoding UTF8 -NoNewline
        $composeContent = Get-Content "$env:TEMP\docker-compose.yml" -Raw
        $composeBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($composeContent))
        
        # Transfer the compose file to remote server
        Invoke-SSHCommand "echo '$composeBase64' | base64 -d > /home/$User/n8n/docker-compose.yml" | Out-Null
        
        # Verify Traefik network exists
        Write-Host "Verifying Traefik network..." -ForegroundColor Cyan
        $networkCheck = Invoke-SSHCommand "sudo docker network ls --filter name=traefik-network --format '{{.Name}}' 2>/dev/null"
        
        if (-not ($networkCheck -match "traefik-network")) {
            Write-Host "Warning: Traefik network not found. Creating it..." -ForegroundColor Yellow
            $createNetwork = Invoke-SSHCommand "sudo docker network create traefik-network 2>&1 || true"
            if ($createNetwork -match "traefik-network|already exists") {
                Write-Host "Traefik network ready" -ForegroundColor Gray
            } else {
                Write-Host "Network creation output: $createNetwork" -ForegroundColor Gray
            }
        } else {
            Write-Host "Traefik network exists" -ForegroundColor Gray
        }
        
        # Deploy n8n using Docker Compose
        Write-Host "Deploying n8n with Docker Compose..." -ForegroundColor Cyan
        $deployOutput = Invoke-SSHCommand "cd /home/$User/n8n && sudo docker compose up -d 2>&1"
        
        if ($deployOutput) {
            Write-Host "Deploy output: $deployOutput" -ForegroundColor Gray
        }
        
        # Verify n8n is running
        Start-Sleep -Seconds 5
        $verifyResult = Invoke-SSHCommand "sudo docker ps --filter name=n8n --format '{{.Status}}'"
        
        if ($verifyResult -match "Up") {
            Write-Host "`nn8n installed successfully!" -ForegroundColor Green
            Write-Host "n8n Web UI: https://n8n.$Domain" -ForegroundColor Cyan
            Write-Host "Direct Access (if needed): http://$IP:5678" -ForegroundColor Gray
            Write-Host "`nNote: Complete the initial setup wizard on first access" -ForegroundColor Yellow
            Write-Host "Note: Ensure DNS points n8n.$Domain to $IP" -ForegroundColor Yellow
            return $true
        } else {
            Write-Host "n8n deployment failed" -ForegroundColor Red
            $logs = Invoke-SSHCommand "sudo docker logs n8n 2>&1"
            if ($logs) {
                Write-Host "Container logs:" -ForegroundColor Yellow
                Write-Host $logs -ForegroundColor Gray
            }
            return $false
        }
    }
    catch {
        Write-Host "Error during n8n installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Install-Portainer {
    <#
    .SYNOPSIS
        Installs Portainer on a Debian-based system.

    .DESCRIPTION
        This function installs Portainer, a lightweight management UI for Docker, on a Debian-based system
        via SSH. It checks for existing installations and installs Portainer if not present.

    .PARAMETER IP
        The IP address of the target Debian server.

    .PARAMETER User
        The username for SSH authentication.

    .PARAMETER Password
        The password for SSH authentication.

    .PARAMETER Domain
        Base domain for Traefik routing (e.g., "example.com"). Portainer will be accessible at portainer.example.com

    .EXAMPLE
        Install-Portainer -IP "192.168.1.100" -User "admin" -Password "password123" -Domain "homelab.local"

    .NOTES
        Requires Traefik to be installed first for reverse proxy functionality.
        Requires plink (PuTTY) to be installed for SSH connectivity.
        Connection should already be validated before calling this function.
        Docker must be installed before running this function.
    #>

    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,

        [Parameter(Mandatory=$false)]
        [string]$Domain = "localhost"
    )

    try {
        Write-Host "`nStarting Portainer installation on $IP..." -ForegroundColor Cyan

        # Check if plink is available
        if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
            Write-Host "Error: 'plink' (PuTTY) is required for SSH connection" -ForegroundColor Red
            Write-Host "Install with: choco install putty -y" -ForegroundColor Yellow
            return $false
        }
        
        # Function to execute remote command via SSH
        function Invoke-SSHCommand {
            param([string]$Command)
            
            $result = Write-Output y | plink -batch -pw $Password $User@$IP $Command 2>&1
            
            if ($LASTEXITCODE -ne 0 -and $result -match "error|fatal|failed|denied") {
                Write-Host "Command failed: $Command" -ForegroundColor Red
                Write-Host "Output: $result" -ForegroundColor Red
                return $null
            }
            
            return $result
        }

        # Create Portainer directory structure
        Write-Host "Creating Portainer directory structure..." -ForegroundColor Cyan
        Invoke-SSHCommand "mkdir -p /home/$User/portainer" | Out-Null
        
        # Check and cleanup existing Portainer installation
        Write-Host "Checking for existing Portainer installation..." -ForegroundColor Cyan
        $portainerCheck = Invoke-SSHCommand "sudo docker ps -a --filter name=portainer --format '{{.Names}}' 2>/dev/null"
        
        if ($portainerCheck -match "portainer") {
            Write-Host "Removing existing Portainer container..." -ForegroundColor Yellow
            $composeExists = Invoke-SSHCommand "test -f /home/$User/portainer/docker-compose.yml && echo 'exists'"
            
            if ($composeExists -match "exists") {
                Invoke-SSHCommand "cd /home/$User/portainer && sudo docker compose down" | Out-Null
            } else {
                Invoke-SSHCommand "sudo docker rm -f portainer" | Out-Null
            }
        }
        
        # Create Docker Compose file
        Write-Host "Creating Docker Compose configuration..." -ForegroundColor Cyan
        $dockerComposeConfig = @"
services:
  portainer:
    container_name: portainer
    image: portainer/portainer-ce:lts
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    expose:
      - 9443
      - 8000
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host('portainer.$Domain')"
      - "traefik.http.routers.portainer.entrypoints=websecure"
      - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"
      - "traefik.http.services.portainer.loadbalancer.server.port=9443"
      - "traefik.http.services.portainer.loadbalancer.server.scheme=https"

volumes:
  portainer_data:
    name: portainer_data

networks:
  traefik-network:
    external: true
"@
        
        # Write compose file using base64 encoding to preserve formatting
        $dockerComposeConfig | Out-File -FilePath "$env:TEMP\docker-compose.yml" -Encoding UTF8 -NoNewline
        $composeContent = Get-Content "$env:TEMP\docker-compose.yml" -Raw
        $composeBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($composeContent))
        
        # Transfer the compose file to remote server
        Invoke-SSHCommand "echo '$composeBase64' | base64 -d > /home/$User/portainer/docker-compose.yml" | Out-Null
        
        # Verify Traefik network exists
        Write-Host "Verifying Traefik network..." -ForegroundColor Cyan
        $networkCheck = Invoke-SSHCommand "sudo docker network ls --filter name=traefik-network --format '{{.Name}}' 2>/dev/null"
        
        if (-not ($networkCheck -match "traefik-network")) {
            Write-Host "Warning: Traefik network not found. Creating it..." -ForegroundColor Yellow
            $createNetwork = Invoke-SSHCommand "sudo docker network create traefik-network 2>&1 || true"
            if ($createNetwork -match "traefik-network|already exists") {
                Write-Host "Traefik network ready" -ForegroundColor Gray
            } else {
                Write-Host "Network creation output: $createNetwork" -ForegroundColor Gray
            }
        } else {
            Write-Host "Traefik network exists" -ForegroundColor Gray
        }
        
        # Deploy Portainer using Docker Compose
        Write-Host "Deploying Portainer with Docker Compose..." -ForegroundColor Cyan
        $deployOutput = Invoke-SSHCommand "cd /home/$User/portainer && sudo docker compose up -d 2>&1"
        
        if ($deployOutput) {
            Write-Host "Deploy output: $deployOutput" -ForegroundColor Gray
        }
        
        # Verify Portainer is running
        Start-Sleep -Seconds 5
        $verifyResult = Invoke-SSHCommand "sudo docker ps --filter name=portainer --format '{{.Status}}'"
        
        if ($verifyResult -match "Up") {
            Write-Host "`nPortainer installed successfully!" -ForegroundColor Green
            Write-Host "Portainer Web UI: https://portainer.$Domain" -ForegroundColor Cyan
            Write-Host "Direct Access (if needed): https://$IP:9443" -ForegroundColor Gray
            Write-Host "`nNote: You will need to create an admin account on first login" -ForegroundColor Yellow
            Write-Host "Note: Ensure DNS points portainer.$Domain to $IP" -ForegroundColor Yellow
            return $true
        }
        else {
            Write-Host "Portainer deployment failed" -ForegroundColor Red
            $logs = Invoke-SSHCommand "sudo docker logs portainer 2>&1"
            if ($logs) {
                Write-Host "Container logs:" -ForegroundColor Yellow
                Write-Host $logs -ForegroundColor Gray
            }
            return $false
        }
    }
    catch {
        Write-Host "Error during Portainer installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Install-Traefik {
    <#
    .SYNOPSIS
        Installs Traefik reverse proxy on a Debian-based system.

    .DESCRIPTION
        This function installs Traefik, a modern reverse proxy and load balancer, on a Debian-based system.
        Traefik will manage all other services through automatic service discovery and SSL certificates.

    .PARAMETER IP
        The IP address of the target Debian server.

    .PARAMETER User
        The username for SSH authentication.

    .PARAMETER Password
        The password for SSH authentication.

    .PARAMETER Email
        Email address for Let's Encrypt SSL certificates.

    .PARAMETER Domain
        Base domain for services (e.g., "example.com").

    .EXAMPLE
        Install-Traefik -IP "192.168.1.100" -User "admin" -Password "password123" -Email "admin@example.com" -Domain "homelab.local"

    .NOTES
        Requires plink (PuTTY) to be installed for SSH connectivity.
        Connection should already be validated before calling this function.
        Docker must be installed before running this function.
    #>

    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,

        [Parameter(Mandatory=$false)]
        [string]$Email = "admin@localhost",

        [Parameter(Mandatory=$false)]
        [string]$Domain = "localhost"
    )
    
    try {
        Write-Host "`nStarting Traefik installation on $IP..." -ForegroundColor Cyan
        
        # Check if plink is available
        if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
            Write-Host "Error: 'plink' (PuTTY) is required for SSH connection" -ForegroundColor Red
            Write-Host "Install with: choco install putty -y" -ForegroundColor Yellow
            return $false
        }
        
        # Function to execute remote command via SSH
        function Invoke-SSHCommand {
            param([string]$Command)
            
            $result = Write-Output y | plink -batch -pw $Password $User@$IP $Command 2>&1
            
            if ($LASTEXITCODE -ne 0 -and $result -match "error|fatal|failed|denied") {
                Write-Host "Command failed: $Command" -ForegroundColor Red
                Write-Host "Output: $result" -ForegroundColor Red
                return $null
            }
            
            return $result
        }
        
        # Create Traefik directory structure
        Write-Host "Creating Traefik directory structure..." -ForegroundColor Cyan
        Invoke-SSHCommand "mkdir -p /home/$User/traefik/letsencrypt" | Out-Null
        
        # Check and cleanup existing Traefik installation
        Write-Host "Checking for existing Traefik installation..." -ForegroundColor Cyan
        $traefikCheck = Invoke-SSHCommand "sudo docker ps -a --filter name=traefik --format '{{.Names}}' 2>/dev/null"
        
        if ($traefikCheck -match "traefik") {
            Write-Host "Removing existing Traefik container..." -ForegroundColor Yellow
            $composeExists = Invoke-SSHCommand "test -f /home/$User/traefik/docker-compose.yml && echo 'exists'"
            
            if ($composeExists -match "exists") {
                Invoke-SSHCommand "cd /home/$User/traefik && sudo docker compose down" | Out-Null
            } else {
                Invoke-SSHCommand "sudo docker rm -f traefik" | Out-Null
            }
        }
        
        # Create traefik.yml configuration file
        Write-Host "Creating Traefik configuration..." -ForegroundColor Cyan
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
        
        # Write config file using tee command
        $traefikConfig | Out-File -FilePath "$env:TEMP\traefik.yml" -Encoding UTF8 -NoNewline
        $configContent = Get-Content "$env:TEMP\traefik.yml" -Raw
        $configBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($configContent))
        Invoke-SSHCommand "echo '$configBase64' | base64 -d > /home/$User/traefik/traefik.yml" | Out-Null
        Remove-Item "$env:TEMP\traefik.yml" -ErrorAction SilentlyContinue
        
        # Create Docker Compose file
        Write-Host "Creating Docker Compose configuration..." -ForegroundColor Cyan
        $dockerComposeConfig = @"
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
        
        # Write compose file using base64 encoding to preserve formatting
        $dockerComposeConfig | Out-File -FilePath "$env:TEMP\docker-compose.yml" -Encoding UTF8 -NoNewline
        $composeContent = Get-Content "$env:TEMP\docker-compose.yml" -Raw
        $composeBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($composeContent))
        Invoke-SSHCommand "echo '$composeBase64' | base64 -d > /home/$User/traefik/docker-compose.yml" | Out-Null
        Remove-Item "$env:TEMP\docker-compose.yml" -ErrorAction SilentlyContinue
        
        # Create docker network for Traefik (must exist before docker compose up)
        Write-Host "Creating Docker network for Traefik..." -ForegroundColor Cyan
        $createNetwork = Invoke-SSHCommand "sudo docker network create traefik-network 2>&1 || true"
        
        if ($createNetwork -match "already exists") {
            Write-Host "Traefik network already exists" -ForegroundColor Gray
        }
        elseif ($createNetwork -match "traefik-network") {
            Write-Host "Traefik network created" -ForegroundColor Gray
        }
        else {
            Write-Host "Network creation output: $createNetwork" -ForegroundColor Gray
        }
        
        # Create acme.json file with correct permissions
        Write-Host "Creating SSL certificate storage..." -ForegroundColor Cyan
        Invoke-SSHCommand "touch /home/$User/traefik/letsencrypt/acme.json && chmod 600 /home/$User/traefik/letsencrypt/acme.json" | Out-Null
        
        # Deploy Traefik using Docker Compose
        Write-Host "Deploying Traefik with Docker Compose..." -ForegroundColor Cyan
        $deployOutput = Invoke-SSHCommand "cd /home/$User/traefik && sudo docker compose up -d 2>&1"
        
        if ($deployOutput) {
            Write-Host "Deploy output: $deployOutput" -ForegroundColor Gray
        }
        
        # Verify Traefik is running
        Start-Sleep -Seconds 5
        $verifyResult = Invoke-SSHCommand "sudo docker ps --filter name=traefik --format '{{.Status}}'"
        
        if ($verifyResult -match "Up") {
            Write-Host "`nTraefik installed successfully!" -ForegroundColor Green
            Write-Host "Traefik Dashboard: http://$IP:8080" -ForegroundColor Cyan
            Write-Host "HTTP Entry Point: http://$IP:80" -ForegroundColor Cyan
            Write-Host "HTTPS Entry Point: https://$IP:443" -ForegroundColor Cyan
            Write-Host "`nNote: Other services should be deployed with Traefik labels for automatic routing" -ForegroundColor Yellow
            return $true
        }
        else {
            Write-Host "Traefik deployment failed" -ForegroundColor Red
            $logs = Invoke-SSHCommand "sudo docker logs traefik 2>&1"
            if ($logs) {
                Write-Host "Container logs:" -ForegroundColor Yellow
                Write-Host $logs -ForegroundColor Gray
            }
            return $false
        }
    }
    catch {
        Write-Host "Error during Traefik installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

#endregion

#===============================================================================
#region WSL2 SETUP FUNCTIONS (WINDOWS)
#===============================================================================

function Test-WSLReady {
    <#
    .SYNOPSIS
        Tests if WSL is ready and fully functional on a remote Windows system.
    
    .DESCRIPTION
        Checks if WSL features are enabled, kernel is installed, and a distribution is available.
        Works with both WSL1 and WSL2. Returns a detailed status object.
    #>
    param (
        [string]$IP,
        [string]$User,
        [string]$Password,
        [string]$Distribution = "Debian"
    )
    
    try {
        # Create credential object
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        
        $session = New-PSSession -ComputerName $IP -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
        
        if (-not $session) {
            return @{
                Ready = $false
                NeedsReboot = $false
                NeedsInstall = $true
                Message = "Could not establish remote session"
            }
        }
        
        $status = Invoke-Command -Session $session -ScriptBlock {
            param($Distro)
            
            $result = @{
                WSLFeatureEnabled = $false
                VMPlatformEnabled = $false
                WSLKernelInstalled = $false
                DistributionInstalled = $false
                DistributionReady = $false
                NeedsReboot = $false
                Message = ""
            }
            
            # Check WSL feature status
            $wslStatus = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
            $result.WSLFeatureEnabled = ($wslStatus.State -eq "Enabled")
            
            # Check if reboot is pending for WSL feature
            if ($wslStatus.RestartNeeded -eq $true) {
                $result.NeedsReboot = $true
            }
            
            # Check Virtual Machine Platform feature status
            $vmStatus = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
            $result.VMPlatformEnabled = ($vmStatus.State -eq "Enabled")
            
            # Check if reboot is pending for VM Platform feature
            if ($vmStatus.RestartNeeded -eq $true) {
                $result.NeedsReboot = $true
            }
            
            # Check for pending reboot in registry
            $rebootPending = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
            $rebootRequired = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
            if ($rebootPending -or $rebootRequired) {
                $result.NeedsReboot = $true
            }
            
            # Only check WSL functionality if features are enabled and no reboot pending
            if ($result.WSLFeatureEnabled -and $result.VMPlatformEnabled -and -not $result.NeedsReboot) {
                # Check if wsl.exe works
                try {
                    $wslStatus = & wsl --status 2>&1
                    $wslStatusStr = $wslStatus -join ' '
                    
                    # Check for various states
                    if ($wslStatusStr -match "must be updated") {
                        # WSL needs update - not a reboot issue
                        $result.WSLKernelInstalled = $false
                        $result.NeedsUpdate = $true
                        $result.Message = "WSL requires update via 'wsl --update'"
                    }
                    elseif ($wslStatusStr -match "not installed|is not installed") {
                        $result.WSLKernelInstalled = $false
                    }
                    elseif ($LASTEXITCODE -eq 0) {
                        $result.WSLKernelInstalled = $true
                    }
                    else {
                        $result.WSLKernelInstalled = $false
                    }
                }
                catch {
                    $result.WSLKernelInstalled = $false
                }
                
                # Check if distribution is installed
                if ($result.WSLKernelInstalled) {
                    $distroListRaw = & wsl --list --quiet 2>&1
                    # WSL outputs UTF-16LE with null bytes - clean them up
                    $distroList = ($distroListRaw | ForEach-Object { 
                        if ($_) { ($_ -replace '\x00', '').Trim() }
                    }) | Where-Object { $_ -match '\S' }
                    
                    # Check for distribution match
                    $distroFound = $false
                    foreach ($distro in $distroList) {
                        if ($distro -match $Distro -or $distro -eq $Distro) {
                            $distroFound = $true
                            break
                        }
                        if ($Distro -eq "Ubuntu" -and $distro -match "Ubuntu") {
                            $distroFound = $true
                            break
                        }
                        if ($Distro -eq "Debian" -and $distro -match "Debian") {
                            $distroFound = $true
                            break
                        }
                    }
                    
                    if ($distroFound) {
                        $result.DistributionInstalled = $true
                        
                        # Test if distribution is actually usable
                        try {
                            $testOutput = & wsl -d $Distro -u root echo "WSL_READY_TEST" 2>&1
                            if ($testOutput -match "WSL_READY_TEST") {
                                $result.DistributionReady = $true
                            }
                        }
                        catch {
                            $result.DistributionReady = $false
                        }
                    }
                }
            }
            
            # Build status message
            if ($result.NeedsReboot) {
                $result.Message = "System reboot required to complete WSL installation"
            }
            elseif (-not $result.WSLFeatureEnabled) {
                $result.Message = "WSL feature is not enabled"
            }
            elseif (-not $result.VMPlatformEnabled) {
                $result.Message = "Virtual Machine Platform feature is not enabled"
            }
            elseif (-not $result.WSLKernelInstalled) {
                $result.Message = "WSL kernel/component is not installed"
            }
            elseif (-not $result.DistributionInstalled) {
                $result.Message = "Linux distribution '$Distro' is not installed"
            }
            elseif (-not $result.DistributionReady) {
                $result.Message = "Linux distribution '$Distro' is installed but not ready"
            }
            else {
                $result.Message = "WSL is fully ready with $Distro distribution"
            }
            
            return $result
        } -ArgumentList $Distribution
        
        Remove-PSSession -Session $session
        
        $isReady = $status.WSLFeatureEnabled -and $status.VMPlatformEnabled -and 
                   $status.WSLKernelInstalled -and $status.DistributionInstalled -and 
                   $status.DistributionReady -and (-not $status.NeedsReboot)
        
        return @{
            Ready = $isReady
            NeedsReboot = $status.NeedsReboot
            NeedsInstall = (-not $status.WSLFeatureEnabled) -or (-not $status.VMPlatformEnabled)
            NeedsDistribution = (-not $status.DistributionInstalled) -or (-not $status.DistributionReady)
            Details = $status
            Message = $status.Message
        }
    }
    catch {
        return @{
            Ready = $false
            NeedsReboot = $false
            NeedsInstall = $true
            Message = "Error checking WSL status: $($_.Exception.Message)"
        }
    }
}

function Install-WSL2 {
    <#
    .SYNOPSIS
        Installs WSL (Windows Subsystem for Linux) on a remote Windows system.
    
    .DESCRIPTION
        Installs WSL using a reliable MSI-based approach that works in VM environments.
        Defaults to WSL1 which doesn't require nested virtualization and Debian which is lightweight.
        
    .PARAMETER WSLVersion
        WSL version to use: 1 or 2. Default is 1 (works in VMs without nested virtualization).
        WSL2 requires nested virtualization support which may not work in all VM environments.
    #>
    param (
        [string]$IP,
        [string]$User,
        [string]$Password,
        [string]$Distribution = "Debian",
        [ValidateSet(1, 2)]
        [int]$WSLVersion = 1,
        [switch]$AutoReboot,
        [switch]$WaitForReboot
    )

    try {
        Write-Host "Starting WSL installation on $IP (WSL$WSLVersion with $Distribution)..." -ForegroundColor Cyan

        # First, check current WSL status
        Write-Host "  Checking current WSL2 status..." -ForegroundColor Cyan
        $wslStatus = Test-WSLReady -IP $IP -User $User -Password $Password -Distribution $Distribution
        
        if ($wslStatus.Ready) {
            Write-Host "WSL2 is already fully installed and ready on $IP" -ForegroundColor Green
            Write-Host "  $($wslStatus.Message)" -ForegroundColor Cyan
            return @{
                Success = $true
                NeedsReboot = $false
                Ready = $true
                Message = "WSL2 is already ready"
            }
        }
        
        # Check if reboot is pending from a previous installation
        if ($wslStatus.NeedsReboot) {
            Write-Host "  A system reboot is pending from previous WSL2 installation" -ForegroundColor Yellow
            
            if ($AutoReboot) {
                return Invoke-WSL2Reboot -IP $IP -User $User -Password $Password -Distribution $Distribution -WaitForReboot:$WaitForReboot
            }
            else {
                Write-Host "WARNING: System reboot is required to complete WSL2 installation" -ForegroundColor Yellow
                Write-Host "Run with -AutoReboot to automatically reboot, or manually reboot with:" -ForegroundColor Cyan
                Write-Host "  Restart-Computer -ComputerName $IP -Credential `$credential -Force" -ForegroundColor White
                
                return @{
                    Success = $true
                    NeedsReboot = $true
                    Ready = $false
                    Message = "WSL2 features installed but system reboot is required"
                }
            }
        }
        
        Write-Host "  Current status: $($wslStatus.Message)" -ForegroundColor Yellow

        # Create credential object
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)

        # Create session options
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck

        # Establish remote session
        Write-Host "  Establishing remote session..." -ForegroundColor Cyan
        $session = New-PSSession -ComputerName $IP -Credential $credential -SessionOption $sessionOption -ErrorAction Stop

        if (-not $session) {
            Write-Host "Failed to establish remote session" -ForegroundColor Red
            return @{
                Success = $false
                NeedsReboot = $false
                Ready = $false
                Message = "Failed to establish remote session"
            }
        }

        # Execute installation on remote system
        $installResult = Invoke-Command -Session $session -ScriptBlock {
            param($DistroName, $TargetWSLVersion)
            
            $VerbosePreference = 'Continue'
            $installSuccess = $true
            
            try {
                # Check if WSL is already installed and functional
                Write-Host "  Checking current WSL status..." -ForegroundColor Cyan
                
                # Test if wsl command works
                $wslWorking = $false
                try {
                    $wslStatusOutput = & wsl --status 2>&1
                    if ($LASTEXITCODE -eq 0 -and $wslStatusOutput -notmatch "not installed|is not installed") {
                        $wslWorking = $true
                        Write-Host "  WSL is already functional" -ForegroundColor Green
                    }
                }
                catch {
                    # WSL not working yet
                }
                
                # Check Windows features
                $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
                $vmPlatform = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
                
                # Install WSL feature if not enabled
                if ($wslFeature.State -ne "Enabled") {
                    Write-Host "  Installing WSL feature..." -ForegroundColor Yellow
                    try {
                        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -ErrorAction Stop | Out-Null
                        Write-Host "  WSL feature enabled successfully" -ForegroundColor Green
                    }
                    catch {
                        Write-Host "  Failed to enable WSL feature: $($_.Exception.Message)" -ForegroundColor Red
                        $installSuccess = $false
                        return @{ Success = $installSuccess; NeedsReboot = $true; Message = "WSL feature installation failed" }
                    }
                }
                else {
                    Write-Host "  WSL feature is already enabled" -ForegroundColor Green
                }

                # Check and enable Virtual Machine Platform feature (required for WSL2)
                Write-Host "  Checking Virtual Machine Platform feature..." -ForegroundColor Cyan
                $vmPlatformStatus = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
                
                if ($vmPlatformStatus.State -ne "Enabled") {
                    Write-Host "  Installing Virtual Machine Platform feature..." -ForegroundColor Yellow
                    try {
                        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -ErrorAction Stop | Out-Null
                        Write-Host "  Virtual Machine Platform feature enabled successfully" -ForegroundColor Green
                    }
                    catch {
                        Write-Host "  Failed to enable Virtual Machine Platform: $($_.Exception.Message)" -ForegroundColor Red
                        $installSuccess = $false
                        return @{ Success = $installSuccess; NeedsReboot = $true; Message = "Virtual Machine Platform installation failed" }
                    }
                }
                else {
                    Write-Host "  Virtual Machine Platform is already enabled" -ForegroundColor Green
                }

                # Test if WSL is actually functional (not just "enabled" in features)
                Write-Host "  Testing WSL functionality..." -ForegroundColor Cyan
                $wslFunctional = $false
                try {
                    $wslTest = & wsl --status 2>&1
                    if ($LASTEXITCODE -eq 0 -and $wslTest -notmatch "not installed|is not installed") {
                        $wslFunctional = $true
                        Write-Host "  WSL is functional" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  WSL is not yet functional - will attempt to install WSL component" -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Host "  WSL test failed - will attempt to install WSL component" -ForegroundColor Yellow
                }

                # Install WSL via MSI if not working (more reliable in VM environments)
                if (-not $wslWorking) {
                    Write-Host "  Installing WSL via MSI package (reliable method for VMs)..." -ForegroundColor Cyan
                    
                    $wslMsiUrl = "https://github.com/microsoft/WSL/releases/download/2.3.26/wsl.2.3.26.0.x64.msi"
                    $wslMsiPath = "C:\wsl_install.msi"
                    
                    try {
                        # Download WSL MSI
                        Write-Host "  Downloading WSL MSI from GitHub..." -ForegroundColor Cyan
                        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                        Invoke-WebRequest -Uri $wslMsiUrl -OutFile $wslMsiPath -UseBasicParsing -ErrorAction Stop
                        
                        if (Test-Path $wslMsiPath) {
                            Write-Host "  Installing WSL MSI..." -ForegroundColor Cyan
                            $msiResult = Start-Process msiexec.exe -ArgumentList '/i', $wslMsiPath, '/quiet', '/norestart' -Wait -PassThru
                            
                            if ($msiResult.ExitCode -eq 0 -or $msiResult.ExitCode -eq 3010) {
                                Write-Host "  WSL MSI installed successfully" -ForegroundColor Green
                            }
                            else {
                                Write-Host "  WSL MSI installation returned exit code: $($msiResult.ExitCode)" -ForegroundColor Yellow
                            }
                            
                            # Cleanup
                            Remove-Item $wslMsiPath -Force -ErrorAction SilentlyContinue
                        }
                    }
                    catch {
                        Write-Host "  Warning: MSI installation failed: $($_.Exception.Message)" -ForegroundColor Yellow
                        Write-Host "  Falling back to wsl --install method..." -ForegroundColor Cyan
                        
                        # Fallback to wsl --install
                        try {
                            $wslInstallOutput = & wsl --install --no-launch 2>&1
                            Write-Host "  wsl --install output: $wslInstallOutput" -ForegroundColor Cyan
                        }
                        catch {
                            Write-Host "  wsl --install also failed: $($_.Exception.Message)" -ForegroundColor Yellow
                        }
                    }
                }

                # Set WSL version (WSL1 is more reliable in VM environments)
                Write-Host "  Setting WSL$TargetWSLVersion as default version..." -ForegroundColor Cyan
                try {
                    $setVersionOutput = & wsl --set-default-version $TargetWSLVersion 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "  WSL$TargetWSLVersion set as default version" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  Set default version output: $setVersionOutput" -ForegroundColor Yellow
                        # If WSL2 fails (common in VMs), try WSL1
                        if ($TargetWSLVersion -eq 2) {
                            Write-Host "  WSL2 may not work in this VM environment. Trying WSL1..." -ForegroundColor Yellow
                            $setVersionOutput = & wsl --set-default-version 1 2>&1
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host "  WSL1 set as default version (WSL2 not available)" -ForegroundColor Green
                            }
                        }
                    }
                }
                catch {
                    Write-Host "  Warning: Could not set default WSL version: $($_.Exception.Message)" -ForegroundColor Yellow
                }
                
                # Test if WSL is now functional
                Write-Host "  Verifying WSL is functional..." -ForegroundColor Cyan
                $wslStatusCheck = & wsl --status 2>&1
                if ($LASTEXITCODE -ne 0 -or $wslStatusCheck -match "must be updated|not installed") {
                    Write-Host "  WSL requires additional setup or reboot" -ForegroundColor Yellow
                    return @{
                        Success = $true
                        NeedsReboot = $true
                        Ready = $false
                        Message = "WSL installed but may require reboot to activate"
                    }
                }
                Write-Host "  WSL is functional" -ForegroundColor Green

                # Install Linux distribution
                if ($DistroName -and $DistroName -ne "") {
                    Write-Host "  Checking for Linux distribution: $DistroName..." -ForegroundColor Cyan
                    
                    # Helper function to clean WSL output (handles UTF-16LE encoding with null bytes)
                    function Get-CleanWSLDistroList {
                        $rawList = & wsl --list --quiet 2>&1
                        $cleanList = ($rawList | ForEach-Object { 
                            if ($_) { ($_ -replace '\x00', '').Trim() }
                        }) | Where-Object { $_ -match '\S' -and $_ -notmatch 'not installed|is not installed' }
                        return $cleanList
                    }
                    
                    # Check if distribution is already installed
                    $installedDistros = Get-CleanWSLDistroList
                    
                    # Check if WSL returned an error indicating it's not ready
                    $rawOutput = & wsl --list --quiet 2>&1
                    $distroListStr = ($rawOutput -join ' ') -replace '\x00', ''
                    if ($distroListStr -match "not installed|is not installed") {
                        Write-Host "  WSL is not fully installed yet - reboot required" -ForegroundColor Yellow
                        return @{
                            Success = $true
                            NeedsReboot = $true
                            Ready = $false
                            Message = "WSL features enabled but not active. System reboot required."
                        }
                    }
                    
                    Write-Host "  Currently installed distributions: $($installedDistros -join ', ')" -ForegroundColor Cyan
                    
                    # Check for exact match or variants
                    $foundDistro = $null
                    foreach ($distro in $installedDistros) {
                        if ($distro -eq $DistroName -or $distro -match "^$DistroName$") {
                            $foundDistro = $distro
                            break
                        }
                        if ($DistroName -eq "Ubuntu" -and $distro -match "Ubuntu") {
                            $foundDistro = $distro
                            Write-Host "  Found Ubuntu variant: $foundDistro" -ForegroundColor Cyan
                            break
                        }
                        if ($DistroName -eq "Debian" -and $distro -match "Debian") {
                            $foundDistro = $distro
                            Write-Host "  Found Debian: $foundDistro" -ForegroundColor Cyan
                            break
                        }
                    }
                    
                    if ($foundDistro) {
                        Write-Host "  $foundDistro is already installed" -ForegroundColor Green
                        
                        # Ensure it's running correct WSL version
                        Write-Host "  Ensuring $foundDistro is using WSL$TargetWSLVersion..." -ForegroundColor Cyan
                        & wsl --set-version $foundDistro $TargetWSLVersion 2>&1 | Out-Null
                        
                        # Verify the distribution is accessible
                        $testResult = & wsl -d $foundDistro -u root echo "WSL_TEST_SUCCESS" 2>&1
                        if ($testResult -notmatch "WSL_TEST_SUCCESS") {
                            Write-Host "  Warning: $foundDistro may not be properly initialized" -ForegroundColor Yellow
                            Write-Host "  Test output: $testResult" -ForegroundColor Yellow
                        }
                        else {
                            Write-Host "  $foundDistro is accessible and ready" -ForegroundColor Green
                        }
                    }
                    else {
                        Write-Host "  Installing $DistroName distribution..." -ForegroundColor Yellow
                        Write-Host "  Note: This requires internet connectivity and may take several minutes..." -ForegroundColor Cyan
                        
                        # Map distribution name to launcher executable
                        $launcherMap = @{
                            'Debian' = 'debian.exe'
                            'Ubuntu' = 'ubuntu.exe'
                            'Ubuntu-20.04' = 'ubuntu2004.exe'
                            'Ubuntu-22.04' = 'ubuntu2204.exe'
                            'Ubuntu-24.04' = 'ubuntu2404.exe'
                        }
                        
                        # Try wsl --install first to download the distribution
                        Write-Host "  Downloading $DistroName via wsl --install..." -ForegroundColor Cyan
                        $installOutput = & wsl --install -d $DistroName --no-launch 2>&1
                        $installExitCode = $LASTEXITCODE
                        $installOutputStr = $installOutput -join ' '
                        
                        Write-Host "  wsl --install output: $installOutputStr" -ForegroundColor Cyan
                        
                        # Wait for download/installation to complete
                        Write-Host "  Waiting for $DistroName package installation..." -ForegroundColor Cyan
                        Start-Sleep -Seconds 10
                        
                        # Check if distribution is now in the list
                        $installedDistros = & wsl --list --quiet 2>&1 | Where-Object { $_ -match '\S' }
                        $distroInList = $installedDistros -match $DistroName
                        
                        # If not in list but install said successful, try launcher to register it
                        if (-not $distroInList -and ($installOutputStr -match "installed|successful" -or $installExitCode -eq 0)) {
                            Write-Host "  Distribution downloaded but not registered. Using launcher to initialize..." -ForegroundColor Yellow
                            
                            $launcher = $launcherMap[$DistroName]
                            if ($launcher) {
                                Write-Host "  Running: $launcher install --root" -ForegroundColor Cyan
                                try {
                                    $launcherOutput = & $launcher install --root 2>&1
                                    $launcherExitCode = $LASTEXITCODE
                                    $launcherOutputStr = $launcherOutput -join ' '
                                    
                                    if ($launcherExitCode -eq 0 -or $launcherOutputStr -match "successful") {
                                        Write-Host "  $DistroName registered successfully via launcher" -ForegroundColor Green
                                    }
                                    else {
                                        Write-Host "  Launcher output: $launcherOutputStr" -ForegroundColor Yellow
                                        
                                        # Check for VM/virtualization errors and suggest WSL1
                                        if ($launcherOutputStr -match "0x80370102|Virtual Machine Platform|virtualization") {
                                            Write-Host "  Virtualization error detected. Ensuring WSL1 is set..." -ForegroundColor Yellow
                                            & wsl --set-default-version 1 2>&1 | Out-Null
                                            
                                            # Try launcher again with WSL1
                                            $launcherOutput2 = & $launcher install --root 2>&1
                                            if ($LASTEXITCODE -eq 0 -or ($launcherOutput2 -join ' ') -match "successful") {
                                                Write-Host "  $DistroName registered successfully with WSL1" -ForegroundColor Green
                                            }
                                        }
                                    }
                                }
                                catch {
                                    Write-Host "  Launcher error: $($_.Exception.Message)" -ForegroundColor Yellow
                                }
                            }
                            else {
                                Write-Host "  No launcher mapping found for $DistroName" -ForegroundColor Yellow
                            }
                        }
                        # If install failed with memory/virtualization error, try launcher directly
                        elseif ($installOutputStr -match "memory|0x8007000e|0x80370102|Virtual Machine Platform") {
                            Write-Host "  Standard installation failed (VM environment detected)" -ForegroundColor Yellow
                            
                            $launcher = $launcherMap[$DistroName]
                            if ($launcher) {
                                Write-Host "  Trying launcher-based installation: $launcher install --root" -ForegroundColor Cyan
                                try {
                                    # Ensure WSL1 for VM compatibility
                                    & wsl --set-default-version 1 2>&1 | Out-Null
                                    
                                    $launcherOutput = & $launcher install --root 2>&1
                                    if ($LASTEXITCODE -eq 0 -or ($launcherOutput -join ' ') -match "successful") {
                                        Write-Host "  $DistroName installed successfully via launcher" -ForegroundColor Green
                                    }
                                    else {
                                        Write-Host "  Launcher output: $($launcherOutput -join ' ')" -ForegroundColor Yellow
                                    }
                                }
                                catch {
                                    Write-Host "  Launcher installation failed: $($_.Exception.Message)" -ForegroundColor Yellow
                                }
                            }
                        }
                        
                        # Final verification - check if distribution is now available
                        Start-Sleep -Seconds 5
                        $installedDistros = Get-CleanWSLDistroList
                        
                        # Check if our distribution is in the list
                        $distroInstalled = $false
                        foreach ($distro in $installedDistros) {
                            if ($distro -eq $DistroName -or $distro -match $DistroName) {
                                $distroInstalled = $true
                                break
                            }
                        }
                        
                        if ($distroInstalled) {
                            Write-Host "  $DistroName installed successfully" -ForegroundColor Green
                            
                            # Set correct WSL version
                            & wsl --set-version $DistroName $TargetWSLVersion 2>&1 | Out-Null
                            
                            # Verify it's working
                            $verifyTest = & wsl -d $DistroName -u root echo "SUCCESS" 2>&1
                            if ($verifyTest -match "SUCCESS") {
                                Write-Host "  $DistroName initialized and ready for use" -ForegroundColor Green
                            }
                            else {
                                Write-Host "  Warning: $DistroName initialization may have issues: $verifyTest" -ForegroundColor Yellow
                            }
                        }
                        else {
                            Write-Host "  Error: $DistroName installation could not be verified" -ForegroundColor Red
                            Write-Host "  Installed distributions: $($installedDistros -join ', ')" -ForegroundColor Yellow
                            Write-Host "  Try manually: wsl --install -d $DistroName" -ForegroundColor Yellow
                        }
                    }
                }

                # Final verification - test if WSL is actually working
                Write-Host "  Performing final WSL verification..." -ForegroundColor Cyan
                $wslActuallyWorks = $false
                try {
                    $finalTest = & wsl -d $DistroName -u root echo "FINAL_WSL_TEST" 2>&1
                    if ($finalTest -match "FINAL_WSL_TEST") {
                        $wslActuallyWorks = $true
                        Write-Host "  WSL is fully functional!" -ForegroundColor Green
                    }
                }
                catch {
                    Write-Host "  WSL test failed: $($_.Exception.Message)" -ForegroundColor Yellow
                }
                
                # If WSL actually works, we don't need a reboot regardless of registry flags
                if ($wslActuallyWorks) {
                    return @{
                        Success = $true
                        NeedsReboot = $false
                        Ready = $true
                        Message = "WSL installation completed successfully. $DistroName is ready."
                    }
                }
                
                # Only check for reboot if WSL is not working
                $wslStatusAfter = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
                $vmStatusAfter = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
                
                $rebootRequired = ($wslStatusAfter.RestartNeeded -eq $true) -or ($vmStatusAfter.RestartNeeded -eq $true)
                
                $message = if ($rebootRequired) {
                    "WSL components installed but system reboot is required to activate."
                } else {
                    "WSL installation completed but distribution may need manual setup."
                }

                return @{
                    Success = $installSuccess
                    NeedsReboot = $rebootRequired
                    Ready = $false
                    Message = $message
                }
            }
            catch {
                Write-Host "  Error during WSL installation: $($_.Exception.Message)" -ForegroundColor Red
                return @{
                    Success = $false
                    NeedsReboot = $false
                    Ready = $false
                    Message = "Installation failed: $($_.Exception.Message)"
                }
            }
        } -ArgumentList $Distribution, $WSLVersion

        # Close the session
        Remove-PSSession -Session $session

        # Process results
        if ($installResult.Success) {
            Write-Host "WSL2 installation completed on $IP" -ForegroundColor Green
            Write-Host $installResult.Message -ForegroundColor Cyan
            
            if ($installResult.NeedsReboot) {
                Write-Host "" -ForegroundColor Yellow
                Write-Host "========================================" -ForegroundColor Yellow
                Write-Host "WARNING: SYSTEM REBOOT REQUIRED" -ForegroundColor Yellow
                Write-Host "========================================" -ForegroundColor Yellow
                Write-Host "A system reboot is required to complete WSL2 installation." -ForegroundColor Yellow
                Write-Host "After reboot, run the setup again to continue with service deployment." -ForegroundColor Yellow
                Write-Host "" -ForegroundColor Yellow
                
                if ($AutoReboot) {
                    return Invoke-WSL2Reboot -IP $IP -User $User -Password $Password -Distribution $Distribution -WaitForReboot:$WaitForReboot
                }
                else {
                    Write-Host "To reboot manually, run:" -ForegroundColor Cyan
                    Write-Host "  Restart-Computer -ComputerName $IP -Credential `$credential -Force" -ForegroundColor White
                    Write-Host "" -ForegroundColor Yellow
                }
                
                return @{
                    Success = $true
                    NeedsReboot = $true
                    Ready = $false
                    Message = $installResult.Message
                }
            }
            
            return @{
                Success = $true
                NeedsReboot = $false
                Ready = $true
                Message = $installResult.Message
            }
        }
        else {
            Write-Host "WSL2 installation failed on $IP" -ForegroundColor Red
            Write-Host $installResult.Message -ForegroundColor Red
            return @{
                Success = $false
                NeedsReboot = $false
                Ready = $false
                Message = $installResult.Message
            }
        }
    }
    catch {
        Write-Host "Error during WSL2 installation: $($_.Exception.Message)" -ForegroundColor Red
        return @{
            Success = $false
            NeedsReboot = $false
            Ready = $false
            Message = "Error: $($_.Exception.Message)"
        }
    }
}

# Script-level variable to track reboot count and prevent infinite loops
$script:WSL2RebootCount = @{}

function Invoke-WSL2Reboot {
    <#
    .SYNOPSIS
        Reboots a remote Windows system and optionally waits for it to come back online.
    
    .DESCRIPTION
        Initiates a reboot on the remote system and can wait for the system to come back online
        before checking WSL status again. Includes protection against infinite reboot loops.
    #>
    param (
        [string]$IP,
        [string]$User,
        [string]$Password,
        [string]$Distribution = "Debian",
        [ValidateSet(1, 2)]
        [int]$WSLVersion = 1,
        [switch]$WaitForReboot,
        [int]$TimeoutMinutes = 10,
        [int]$MaxReboots = 2
    )
    
    try {
        # Check reboot counter to prevent infinite loops
        if (-not $script:WSL2RebootCount.ContainsKey($IP)) {
            $script:WSL2RebootCount[$IP] = 0
        }
        
        $script:WSL2RebootCount[$IP]++
        
        if ($script:WSL2RebootCount[$IP] -gt $MaxReboots) {
            Write-Host "Maximum reboot attempts ($MaxReboots) reached for $IP" -ForegroundColor Red
            Write-Host "WSL installation may require manual intervention." -ForegroundColor Yellow
            Write-Host "Please connect to the VM and run: wsl --status" -ForegroundColor Cyan
            return @{
                Success = $false
                NeedsReboot = $false
                Ready = $false
                Message = "Maximum reboot attempts reached. Manual intervention required - run 'wsl --update' on the VM."
            }
        }
        
        Write-Host "Initiating system reboot on $IP (attempt $($script:WSL2RebootCount[$IP]) of $MaxReboots)..." -ForegroundColor Yellow
        
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        
        # Initiate the reboot
        try {
            Restart-Computer -ComputerName $IP -Credential $credential -Force -ErrorAction Stop
            Write-Host "Reboot command sent successfully" -ForegroundColor Green
        }
        catch {
            Write-Host "Failed to send reboot command: $($_.Exception.Message)" -ForegroundColor Red
            return @{
                Success = $false
                NeedsReboot = $true
                Ready = $false
                Message = "Failed to initiate reboot: $($_.Exception.Message)"
            }
        }
        
        if (-not $WaitForReboot) {
            Write-Host "System is rebooting. Run the setup again after the system comes back online." -ForegroundColor Cyan
            return @{
                Success = $true
                NeedsReboot = $true
                Ready = $false
                Rebooting = $true
                Message = "System is rebooting. Run setup again after reboot completes."
            }
        }
        
        # Wait for system to go offline
        Write-Host "Waiting for system to go offline..." -ForegroundColor Cyan
        $offlineTimeout = 60  # seconds
        $offlineStart = Get-Date
        
        do {
            Start-Sleep -Seconds 5
            $pingResult = Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue
            $elapsed = ((Get-Date) - $offlineStart).TotalSeconds
        } while ($pingResult -and ($elapsed -lt $offlineTimeout))
        
        if ($pingResult) {
            Write-Host "Warning: System did not go offline within expected time" -ForegroundColor Yellow
        }
        else {
            Write-Host "System is offline, waiting for it to come back..." -ForegroundColor Cyan
        }
        
        # Wait for system to come back online
        $onlineTimeout = $TimeoutMinutes * 60  # Convert to seconds
        $onlineStart = Get-Date
        $systemOnline = $false
        
        Write-Host "Waiting up to $TimeoutMinutes minutes for system to come back online..." -ForegroundColor Cyan
        
        do {
            Start-Sleep -Seconds 10
            $pingResult = Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue
            
            if ($pingResult) {
                # Try to establish WinRM connection
                $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
                try {
                    $testSession = New-PSSession -ComputerName $IP -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
                    if ($testSession) {
                        Remove-PSSession -Session $testSession
                        $systemOnline = $true
                    }
                }
                catch {
                    # WinRM not ready yet, keep waiting
                    Write-Host "  System responding to ping, waiting for WinRM..." -ForegroundColor Cyan
                }
            }
            
            $elapsed = ((Get-Date) - $onlineStart).TotalSeconds
            $remaining = [math]::Round(($onlineTimeout - $elapsed) / 60, 1)
            
            if (-not $systemOnline -and ($elapsed % 30 -lt 10)) {
                Write-Host "  Still waiting... ($remaining minutes remaining)" -ForegroundColor Cyan
            }
        } while (-not $systemOnline -and ($elapsed -lt $onlineTimeout))
        
        if (-not $systemOnline) {
            Write-Host "Timeout waiting for system to come back online" -ForegroundColor Red
            return @{
                Success = $false
                NeedsReboot = $false
                Ready = $false
                Message = "Timeout waiting for system to come back online after reboot"
            }
        }
        
        Write-Host "System is back online!" -ForegroundColor Green
        Write-Host "Waiting additional 30 seconds for services to stabilize..." -ForegroundColor Cyan
        Start-Sleep -Seconds 30
        
        # Check WSL2 status after reboot
        Write-Host "Checking WSL2 status after reboot..." -ForegroundColor Cyan
        $wslStatus = Test-WSLReady -IP $IP -User $User -Password $Password -Distribution $Distribution
        
        if ($wslStatus.Ready) {
            Write-Host "WSL2 is now fully ready!" -ForegroundColor Green
            return @{
                Success = $true
                NeedsReboot = $false
                Ready = $true
                Message = "WSL2 is ready after reboot"
            }
        }
        elseif ($wslStatus.NeedsDistribution -or (-not $wslStatus.NeedsReboot)) {
            Write-Host "WSL2 features are ready, continuing with setup..." -ForegroundColor Yellow
            # Continue with distribution installation (pass AutoReboot in case another reboot is somehow needed)
            return Install-WSL2 -IP $IP -User $User -Password $Password -Distribution $Distribution -WSLVersion $WSLVersion -AutoReboot -WaitForReboot
        }
        else {
            Write-Host "WSL2 status after reboot: $($wslStatus.Message)" -ForegroundColor Yellow
            return @{
                Success = $wslStatus.Ready
                NeedsReboot = $wslStatus.NeedsReboot
                Ready = $wslStatus.Ready
                Message = $wslStatus.Message
            }
        }
    }
    catch {
        Write-Host "Error during reboot process: $($_.Exception.Message)" -ForegroundColor Red
        return @{
            Success = $false
            NeedsReboot = $false
            Ready = $false
            Message = "Error during reboot: $($_.Exception.Message)"
        }
    }
}

#endregion

#===============================================================================
#region MODULE EXPORTS
#===============================================================================

# Export all public functions
Export-ModuleMember -Function @(
    # Logging Functions
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
    'Write-SessionSeparator',
    
    # Remote Connection Functions
    'Get-TargetOS',
    'Test-SSHConnection',
    'Test-WinRMConnection',
    'Test-RemoteConnection',
    'Invoke-WSLCommand',
    'Invoke-RemoteCommand',
    
    # Health Monitoring Functions
    'Get-ServerHealth',
    'Get-LinuxServerHealth',
    'Get-WindowsServerHealth',
    'Get-ContainerHealth',
    'Get-ContainerLogs',
    'Restart-Container',
    'Stop-Container',
    'Start-Container',
    'Get-FullHealthReport',
    'Format-HealthReport',
    'Test-ServiceHealth',
    'Test-CommonServices',
    
    # Service Installation Functions (Debian)
    'Install-AdGuard',
    'Install-Crafty',
    'Install-Docker',
    'Install-Heimdall',
    'Install-N8N',
    'Install-Portainer',
    'Install-Traefik',
    
    # WSL2 Setup Functions (Windows)
    'Test-WSLReady',
    'Install-WSL2',
    'Invoke-WSL2Reboot'
)

#endregion
