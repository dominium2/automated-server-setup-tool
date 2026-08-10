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
    Why: Prevents passing port parameters manually down through dozens of nested functions.
    It ensures that custom ports and protocol toggles are globally respected by the module
    during background thread execution.
.PARAMETER SSHPort
    The SSH port to use. Default is 22.
.PARAMETER WinRMPort
    The WinRM HTTP port to use. Default is 5985.
.PARAMETER EnableSSH
    Whether to attempt SSH connections. Default is $true.
.PARAMETER EnableWinRM
    Whether to attempt WinRM connections. Default is $true.
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
    Why: Establishes a foundational file trace for debugging failed parallel deployments,
    rotating automatically to prevent infinite log bloat on the host machine.
.OUTPUTS
    The path to the generated log file.
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
    Why: Executed automatically on Init to keep the system clean of old logs that exceed
    the predefined threshold ($MaxLogFileSizeMB or $MaxLogFiles).
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
    Core logging utility.
.DESCRIPTION
    Why: Filters messages based on the globally configured $script:LogLevel threshold,
    so debug info doesn't flood the standard runtime logs unless requested.
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
    Wrapper functions for streamlined logging syntax.
#>
function Write-LogDebug {
    param([string]$Message, [string]$Component = "General")
    Write-Log -Message $Message -Level "Debug" -Component $Component
}

function Write-LogInfo {
    param([string]$Message, [string]$Component = "General")
    Write-Log -Message $Message -Level "Info" -Component $Component
}

function Write-LogWarning {
    param([string]$Message, [string]$Component = "General")
    Write-Log -Message $Message -Level "Warning" -Component $Component
}

function Write-LogError {
    param([string]$Message, [string]$Component = "General", [System.Exception]$Exception = $null)
    Write-Log -Message $Message -Level "Error" -Component $Component -Exception $Exception
}

function Write-LogSuccess {
    param([string]$Message, [string]$Component = "General")
    Write-Log -Message $Message -Level "Success" -Component $Component
}

<#
.SYNOPSIS
    Returns the active log file path.
#>
function Get-LogFilePath {
    return $script:LogFilePath
}

<#
.SYNOPSIS
    Reads the content of the active log file.
.DESCRIPTION
    Why: Used primarily for test harnesses to verify that outputs were logged successfully.
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
    Why: Background threads (runspaces) do not inherit script-scoped variables from the main thread.
    This function receives the active log path from the GUI and explicitly assigns it so background logs aren't lost.
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
    Detects if the remote server is Linux or Windows.
.DESCRIPTION
    Why: Uses `Test-NetConnection` to actively probe the scoped SSH and WinRM ports.
    It caches and returns the OS string to prevent redundant network timeouts during nested commands.
    Includes a Ping TTL fallback check.
.PARAMETER IP
    Target server IP.
.OUTPUTS
    String: "Windows", "Linux", or $null.
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
    Why: Uses `plink` (PuTTY) to bypass OpenSSH's strict non-interactive password blocks.
    Generates a temporary answer file with "y" to automatically trust and store new host keys,
    preventing the script from freezing while waiting for a user prompt.
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
    Why: Passes -SkipCACheck and -SkipCNCheck to ensure connection works immediately on Homelab 
    targets utilizing self-signed default certificates. Will attempt to start the WinRM service if stopped.
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
    Why: Attempts multiple ICMP pings before attempting to delegate to the heavier 
    TCP tests (Test-SSHConnection or Test-WinRMConnection).
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
    Why: Abstracts away the protocol logic. If the target is Linux, it executes via PuTTY (plink) 
    using the `-batch` and `-pw` flags. If the target is Windows, it routes it to `Invoke-WSLCommand`.
.PARAMETER Command
    The bash payload to execute.
.PARAMETER OSType
    (Optional) Provided to skip the 2-second Get-TargetOS TCP port probe.
.OUTPUTS
    The raw string output of the execution, or $null if failure occurred.
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
    Why: Delegates to OS-specific fetching functions after verifying the machine is 
    still responding to an ICMP ping, returning an object mapped explicitly for the GUI.
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
    Why: Formats a massive single bash string wrapping `top`, `free`, `df`, and `uptime` 
    to parse memory and CPU blocks remotely, preventing the need for multiple heavy SSH connections.
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
    Why: Uses native `Get-CimInstance` WMI requests passed through WinRM to gather load values 
    natively without invoking WSL.
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
    Queries Docker stats and metadata.
.DESCRIPTION
    Why: Drastically optimized to query container lists, resource stats, and health checks 
    concurrently through one massive inline bash subshell (`docker ps -aq`). This prevents the script 
    from opening separate SSH connections per container, dropping execution time from >4 mins to 3 seconds.
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
    Fetches raw docker logs.
#>
function Get-ContainerLogs {
    param([string]$IP, [string]$User, [string]$Password, [string]$ContainerName, [int]$Tail = 100, [string]$Since = $null)
    try {
        $logsCommand = "docker logs --tail $Tail"
        if (-not [string]::IsNullOrEmpty($Since)) { $logsCommand += " --since $Since" }
        $logsCommand += " $ContainerName 2>&1"
        $logs = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $logsCommand
        return [PSCustomObject]@{ ContainerName = $ContainerName; Logs = $logs; ErrorMessage = if ($null -eq $logs) { "Failed to retrieve logs" } else { $null } }
    }
    catch { return [PSCustomObject]@{ ContainerName = $ContainerName; Logs = $null; ErrorMessage = $_.Exception.Message } }
}

<#
.SYNOPSIS
    Container Action: Restart.
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
    Combines machine resources and docker resources into a single object.
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
    Why: Instead of opening a new SSH connection for every single command (mkdir, compose down, echo, compose up), 
    we parse the inputs and construct a massive batched bash string separated by semicolons. 
    This reduces a sequential setup into a single ~15-second remote payload.
    It also natively checks for port 53 allocations to forcefully disable systemd-resolved conflicts automatically.
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
    Why: Before invoking the standard `Deploy-DockerService`, this explicitly touches and 
    sets 600 permissions on the `acme.json` file. Traefik will purposefully crash if this file 
    does not have exact 600 permissions prior to container execution.
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
    Why: Manages the required system restarts for enabling nested virtualization 
    features. Tracks reboot attempts to prevent infinite loops.
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