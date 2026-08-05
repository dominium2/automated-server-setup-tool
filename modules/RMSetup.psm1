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
        try {
            Add-Content -Path $script:LogFilePath -Value $logMessage -Encoding UTF8
        }
        catch {}
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
function Get-LogFilePath { return $script:LogFilePath }
function Get-LogContent {
    param([int]$Tail = 0, [string]$Level = $null)
    if ([string]::IsNullOrEmpty($script:LogFilePath) -or -not (Test-Path $script:LogFilePath)) { return @() }
    $content = if ($Tail -gt 0) { Get-Content -Path $script:LogFilePath -Tail $Tail } else { Get-Content -Path $script:LogFilePath }
    if (-not [string]::IsNullOrEmpty($Level)) { $content = $content | Where-Object { $_ -match "\[$Level\]" } }
    return $content
}
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
#endregion

#===============================================================================
#region REMOTE CONNECTION FUNCTIONS
#===============================================================================

function Get-TargetOS {
    param ([string]$IP)
    try {
        Write-LogDebug -Message "Detecting OS for $IP via TCP ports" -Component "RemoteConnection"
        Write-Host "  Attempting to detect OS via TCP ports..." -ForegroundColor Cyan
        
        $winRMPort = Test-NetConnection -ComputerName $IP -Port 5985 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if ($winRMPort.TcpTestSucceeded) {
            Write-LogInfo -Message "Detected Windows OS on $IP (WinRM port 5985 open)" -Component "RemoteConnection"
            Write-Host "  WinRM port (5985) is open - likely Windows" -ForegroundColor Green
            return "Windows"
        }
        
        $sshPort = Test-NetConnection -ComputerName $IP -Port 22 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if ($sshPort.TcpTestSucceeded) {
            Write-LogInfo -Message "Detected Linux OS on $IP (SSH port 22 open)" -Component "RemoteConnection"
            Write-Host "  SSH port (22) is open - likely Linux/Unix" -ForegroundColor Green
            return "Linux"
        }
        
        Write-LogDebug -Message "Standard ports not detected on $IP, trying alternative detection" -Component "RemoteConnection"
        Write-Host "  Standard ports not detected. Attempting alternative detection..." -ForegroundColor Yellow
        
        $pingDetailed = Test-Connection -ComputerName $IP -Count 1 -ErrorAction SilentlyContinue
        if ($pingDetailed) {
            $ttl = $pingDetailed.ResponseTimeToLive
            Write-LogDebug -Message "TTL value for ${IP}: $ttl" -Component "RemoteConnection"
            Write-Host "  TTL value: $ttl" -ForegroundColor Cyan
            
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
        
        # EXPLANATION FOR PLINK:
        # We use plink.exe (PuTTY) instead of the native Windows ssh.exe because native OpenSSH 
        # strictly blocks passing passwords via command-line arguments or standard input.
        # Since this automation tool relies on GUI password fields rather than SSH keys, 
        # plink is required to pass the password non-interactively using the '-pw' flag.
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
            Write-Host "  Error: 'plink' (PuTTY) is required for password-based SSH automation" -ForegroundColor Red
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
    param ([string]$IP, [string]$User, [string]$Password)
    try {
        Write-LogInfo -Message "Testing WinRM connection to $IP" -Component "WinRM"
        Write-Host "Testing WinRM connection to $IP..." -ForegroundColor Cyan
        
        $winrmService = Get-Service -Name WinRM -ErrorAction SilentlyContinue
        if ($winrmService -and $winrmService.Status -ne 'Running') {
            try {
                Start-Service -Name WinRM -ErrorAction Stop
                Write-LogSuccess -Message "WinRM service started" -Component "WinRM"
            } catch {
                Write-LogWarning -Message "Could not start WinRM service: $($_.Exception.Message)" -Component "WinRM"
            }
        }
        
        try {
            $currentTrustedHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
            if (-not $currentTrustedHosts.Contains($IP) -and $currentTrustedHosts -ne "*") {
                if ([string]::IsNullOrEmpty($currentTrustedHosts)) {
                    Set-Item WSMan:\localhost\Client\TrustedHosts -Value $IP -Force
                } else {
                    Set-Item WSMan:\localhost\Client\TrustedHosts -Value "$currentTrustedHosts,$IP" -Force
                }
                Write-LogSuccess -Message "Added $IP to TrustedHosts" -Component "WinRM"
            }
        } catch {
            Write-LogWarning -Message "Could not configure TrustedHosts: $($_.Exception.Message)" -Component "WinRM"
        }
        
        $winSecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $winCredential = New-Object System.Management.Automation.PSCredential ($User, $winSecurePassword)
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        
        Write-LogDebug -Message "Establishing PSSession to $IP" -Component "WinRM"
        $winSession = New-PSSession -ComputerName $IP -Credential $winCredential -SessionOption $sessionOption -ErrorAction Stop
        
        if ($winSession) {
            Write-LogSuccess -Message "WinRM connection successful to $IP" -Component "WinRM"
            Write-Host "WinRM connection successful!" -ForegroundColor Green
            $result = Invoke-Command -Session $winSession -ScriptBlock { $env:COMPUTERNAME }
            Write-LogInfo -Message "Connected to computer: $result" -Component "WinRM"
            Remove-PSSession -Session $winSession
            return $true
        }
    }
    catch {
        Write-LogError -Message "WinRM connection failed to $IP" -Component "WinRM" -Exception $_.Exception
        Write-Host "WinRM connection failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Test-RemoteConnection {
    param ([string]$IP, [string]$User, [string]$Password)
    try {
        Write-LogInfo -Message "Testing connectivity to $IP" -Component "RemoteConnection"
        Write-Host "Testing connectivity to $IP..." -ForegroundColor Cyan
        
        $successfulPings = 0
        $maxAttempts = 4
        
        for ($i = 1; $i -le $maxAttempts; $i++) {
            Write-Host "  Ping attempt $i of $maxAttempts..." -NoNewline
            $pingResult = Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue
            
            if ($pingResult) {
                $successfulPings++
                Write-Host " Success" -ForegroundColor Green
            } else {
                Write-Host " Failed" -ForegroundColor Red
            }
            Start-Sleep -Milliseconds 500
        }
        
        if ($successfulPings -eq $maxAttempts) {
            Write-Host "Detecting target OS..." -ForegroundColor Cyan
            $targetOS = Get-TargetOS -IP $IP
            
            if ($targetOS) {
                if ($targetOS -eq "Windows") {
                    return Test-WinRMConnection -IP $IP -User $User -Password $Password
                } else {
                    return Test-SSHConnection -IP $IP -User $User -Password $Password
                }
            } else {
                return Test-SSHConnection -IP $IP -User $User -Password $Password
            }
        } else {
            Write-LogError -Message "Ping test failed for ${IP}: $successfulPings/$maxAttempts successful" -Component "RemoteConnection"
            Write-Host "Ping test failed." -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-LogError -Message "Error testing connection to $IP" -Component "RemoteConnection" -Exception $_.Exception
        return $false
    }
}

function Invoke-WSLCommand {
    param ([string]$IP, [string]$User, [string]$Password, [string]$Command, [string]$Distribution = "Ubuntu")
    try {
        Write-LogDebug -Message "Executing WSL command on $IP (Distribution: $Distribution)" -Component "WSL"
        
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        
        $session = New-PSSession -ComputerName $IP -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
        
        if (-not $session) { return $null }
        
        $result = Invoke-Command -Session $session -ScriptBlock {
            param($Cmd, $Distro)
            try {
                $wslCheck = & wsl --status 2>&1
                if ($LASTEXITCODE -ne 0 -or $wslCheck -match "not installed|is not installed") {
                    return @{ Output = "WSL is not ready."; ExitCode = 1; WSLNotReady = $true }
                }
            } catch {
                return @{ Output = "WSL command failed."; ExitCode = 1; WSLNotReady = $true }
            }
            
            $distroList = wsl --list --quiet 2>&1 | Where-Object { $_ -match '\S' }
            if ($distroList -match "not installed|is not installed") {
                return @{ Output = "WSL is installed but not configured."; ExitCode = 1; WSLNotReady = $true }
            }
            
            if ($distroList -notmatch $Distro) {
                $foundDistro = $null
                if ($Distro -eq "Ubuntu") { $foundDistro = $distroList | Where-Object { $_ -match "Ubuntu" } | Select-Object -First 1 }
                if (-not $foundDistro) { return @{ Output = "Distribution '$Distro' not found."; ExitCode = 1; WSLNotReady = $false } }
                $Distro = $foundDistro
            }
            
            $runningDistros = wsl --list --running --quiet 2>&1 | Where-Object { $_ -match '\S' }
            if ($runningDistros -notmatch $Distro) {
                wsl -d $Distro -u root echo "Starting distribution..." 2>&1 | Out-Null
                Start-Sleep -Seconds 2
            }
            
            $output = $Cmd | wsl -d $Distro -u root bash 2>&1
            return @{ Output = $output; ExitCode = $LASTEXITCODE; WSLNotReady = $false }
        } -ArgumentList $Command, $Distribution
        
        Remove-PSSession -Session $session
        if ($result.WSLNotReady) { return $null }
        return $result
    }
    catch {
        Write-LogError -Message "Error executing WSL command on $IP" -Component "WSL" -Exception $_.Exception
        return $null
    }
}

function Invoke-RemoteCommand {
    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,
        
        [Parameter(Mandatory=$true)]
        [string]$Command,

        [string]$OSType = $null
    )
    
    try {
        # Use provided OSType to prevent re-running TCP port checks on every call
        $osType = if (-not [string]::IsNullOrEmpty($OSType)) { $OSType } else { Get-TargetOS -IP $IP }
        
        if ($osType -eq "Linux") {
            # EXPLANATION FOR PLINK:
            # Native Windows OpenSSH (ssh.exe) does not allow passing passwords via script parameters.
            # plink is required here to automate the password injection using '-pw' and '-batch'.
            if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
                Write-LogError -Message "plink not found - required for SSH command execution" -Component "RemoteCommand"
                return $null
            }
            
            $result = Write-Output y | plink -batch -pw $Password "$User@$IP" $Command 2>&1
            
            if ($LASTEXITCODE -ne 0 -and $result -match "error|fatal|failed|denied|cannot|permission denied") {
                Write-LogError -Message "SSH command failed on ${IP}: $result" -Component "RemoteCommand"
                return $null
            }
            return $result
        }
        elseif ($osType -eq "Windows") {
            $wslResult = Invoke-WSLCommand -IP $IP -User $User -Password $Password -Command $Command
            if ($null -eq $wslResult) { return $null }
            return $wslResult.Output
        }
        else {
            return $null
        }
    }
    catch {
        Write-LogError -Message "Error executing remote command on $IP" -Component "RemoteCommand" -Exception $_.Exception
        return $null
    }
}
#endregion

#===============================================================================
#region HEALTH MONITORING FUNCTIONS
#===============================================================================

function Get-ServerHealth {
    param([string]$IP, [string]$User, [string]$Password, [string]$OSType = $null)
    try {
        $pingResult = Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue
        if (-not $pingResult) {
            return [PSCustomObject]@{ IP = $IP; Status = "Offline"; StatusColor = "Red"; CPU = $null; Memory = $null; Disk = $null; Uptime = $null; Load = $null; LastChecked = Get-Date; ErrorMessage = "Server not reachable" }
        }
        
        $osType = if (-not [string]::IsNullOrEmpty($OSType)) { $OSType } else { Get-TargetOS -IP $IP }
        if ($osType -eq "Linux") { return Get-LinuxServerHealth -IP $IP -User $User -Password $Password -OSType $osType }
        elseif ($osType -eq "Windows") { return Get-WindowsServerHealth -IP $IP -User $User -Password $Password }
        else { return [PSCustomObject]@{ IP = $IP; Status = "Unknown"; StatusColor = "Yellow"; CPU = $null; Memory = $null; Disk = $null; Uptime = $null; Load = $null; LastChecked = Get-Date; ErrorMessage = "Could not detect OS type" } }
    }
    catch { return [PSCustomObject]@{ IP = $IP; Status = "Error"; StatusColor = "Red"; CPU = $null; Memory = $null; Disk = $null; Uptime = $null; Load = $null; LastChecked = Get-Date; ErrorMessage = $_.Exception.Message } }
}

function Get-LinuxServerHealth {
    param([string]$IP, [string]$User, [string]$Password, [string]$OSType = "Linux")
    try {
        $healthCommand = @"
echo '===CPU===' && top -bn1 | grep 'Cpu(s)' | awk '{print 100 - `$8}' && \
echo '===MEMORY===' && free -m | awk 'NR==2{printf "%.1f %.1f %.1f", `$3, `$2, `$3*100/`$2}' && \
echo '===DISK===' && df -h / | awk 'NR==2{print `$5}' | tr -d '%' && \
echo '===UPTIME===' && uptime -p && \
echo '===LOAD===' && cat /proc/loadavg | awk '{print `$1, `$2, `$3}'
"@
        $result = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $healthCommand -OSType $OSType
        if ($null -eq $result) { throw "Failed to retrieve health metrics" }
        
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
        return [PSCustomObject]@{ IP = $IP; OSType = "Linux"; Status = "Error"; StatusColor = "Red"; CPU = $null; Memory = $null; Disk = $null; Uptime = $null; Load = $null; LastChecked = Get-Date; ErrorMessage = $_.Exception.Message } 
    }
}

function Get-WindowsServerHealth {
    param([string]$IP, [string]$User, [string]$Password)
    try {
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        $session = New-PSSession -ComputerName $IP -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
        
        $healthData = Invoke-Command -Session $session -ScriptBlock {
            $cpuUsage = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
            $os = Get-CimInstance Win32_OperatingSystem
            $totalMemory = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
            $freeMemory = [math]::Round($os.FreePhysicalMemory / 1024, 0)
            $usedMemory = $totalMemory - $freeMemory
            $memoryPercent = [math]::Round(($usedMemory / $totalMemory) * 100, 1)
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
            $diskPercent = [math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 1)
            $uptime = (Get-Date) - $os.LastBootUpTime
            $uptimeString = "{0} days, {1} hours, {2} minutes" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
            $perfCounter = Get-CimInstance Win32_PerfFormattedData_PerfOS_System
            $processorQueueLength = $perfCounter.ProcessorQueueLength
            
            return @{ CPU = $cpuUsage; MemoryUsed = $usedMemory; MemoryTotal = $totalMemory; MemoryPercent = $memoryPercent; DiskPercent = $diskPercent; Uptime = $uptimeString; ProcessorQueueLength = $processorQueueLength }
        }
        Remove-PSSession -Session $session
        
        $status = "Healthy"; $statusColor = "Green"
        if (($healthData.CPU -gt 90) -or ($healthData.MemoryPercent -gt 90) -or ($healthData.DiskPercent -gt 90)) { $status = "Critical"; $statusColor = "Red" }
        elseif (($healthData.CPU -gt 70) -or ($healthData.MemoryPercent -gt 70) -or ($healthData.DiskPercent -gt 80)) { $status = "Warning"; $statusColor = "Yellow" }
        
        return [PSCustomObject]@{ IP = $IP; OSType = "Windows"; Status = $status; StatusColor = $statusColor; CPU = [PSCustomObject]@{ UsagePercent = $healthData.CPU }; Memory = [PSCustomObject]@{ UsedMB = $healthData.MemoryUsed; TotalMB = $healthData.MemoryTotal; UsagePercent = $healthData.MemoryPercent }; Disk = [PSCustomObject]@{ UsagePercent = $healthData.DiskPercent }; Uptime = $healthData.Uptime; Load = [PSCustomObject]@{ ProcessorQueueLength = $healthData.ProcessorQueueLength }; LastChecked = Get-Date; ErrorMessage = $null }
    }
    catch { return [PSCustomObject]@{ IP = $IP; OSType = "Windows"; Status = "Error"; StatusColor = "Red"; CPU = $null; Memory = $null; Disk = $null; Uptime = $null; Load = $null; LastChecked = Get-Date; ErrorMessage = $_.Exception.Message } }
}

function Get-ContainerHealth {
    param([string]$IP, [string]$User, [string]$Password, [string]$ContainerName = $null, [string]$OSType = $null)
    try {
        $osType = if (-not [string]::IsNullOrEmpty($OSType)) { $OSType } else { Get-TargetOS -IP $IP }

        # Single batch command: fetches container listing, inspect data, and stats in ONE SSH roundtrip
        $batchCommand = 'docker ps -a --format "{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}|{{.State}}" 2>/dev/null && echo "===INSPECT===" && (docker inspect --format "{{.ID}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}|{{.RestartCount}}" $(docker ps -aq 2>/dev/null) 2>/dev/null || true) && echo "===STATS===" && (docker stats --no-stream --format "{{.ID}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}" 2>/dev/null || true)'

        $result = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command $batchCommand -OSType $osType
        
        if ($null -eq $result -or [string]::IsNullOrWhiteSpace($result)) {
            return [PSCustomObject]@{ ServerIP = $IP; Status = "DockerNotAccessible"; StatusColor = "Red"; ErrorMessage = "Docker not accessible"; Containers = @() }
        }

        # Parse sections
        $sections = $result -split "===INSPECT==="
        $psOutput = $sections[0]
        
        $inspectOutput = ""
        $statsOutput = ""
        if ($sections.Count -gt 1) {
            $subSections = $sections[1] -split "===STATS==="
            $inspectOutput = $subSections[0]
            if ($subSections.Count -gt 1) { $statsOutput = $subSections[1] }
        }

        # Index inspection data by short container ID
        $inspectMap = @{}
        foreach ($line in ($inspectOutput -split "`n")) {
            $p = $line.Trim() -split '\|'
            if ($p.Count -ge 3) {
                $shortId = $p[0].Trim().Substring(0, [Math]::Min(12, $p[0].Trim().Length))
                $inspectMap[$shortId] = @{ Health = $p[1].Trim(); Restarts = [int]($p[2].Trim() -as [int]) }
            }
        }

        # Index stats data by short container ID
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

        return [PSCustomObject]@{ ServerIP = $IP; Status = $overallStatus; StatusColor = $overallColor; TotalContainers = $totalCount; RunningContainers = $runningCount; StoppedContainers = $totalCount - $runningCount; UnhealthyContainers = $unhealthyCount; ErrorMessage = $null; Containers = $containers; LastChecked = Get-Date }
    }
    catch { return [PSCustomObject]@{ ServerIP = $IP; Status = "Error"; StatusColor = "Red"; TotalContainers = 0; RunningContainers = 0; StoppedContainers = 0; UnhealthyContainers = 0; ErrorMessage = $_.Exception.Message; Containers = @(); LastChecked = Get-Date } }
}

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

function Restart-Container {
    param([string]$IP, [string]$User, [string]$Password, [string]$ContainerName)
    $result = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command "docker restart $ContainerName 2>&1 && echo 'RESTART_SUCCESS' || echo 'RESTART_FAILED'"
    return ($result -match "RESTART_SUCCESS")
}

function Stop-Container {
    param([string]$IP, [string]$User, [string]$Password, [string]$ContainerName)
    $result = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command "docker stop $ContainerName 2>&1 && echo 'STOP_SUCCESS' || echo 'STOP_FAILED'"
    return ($result -match "STOP_SUCCESS")
}

function Start-Container {
    param([string]$IP, [string]$User, [string]$Password, [string]$ContainerName)
    $result = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command "docker start $ContainerName 2>&1 && echo 'START_SUCCESS' || echo 'START_FAILED'"
    return ($result -match "START_SUCCESS")
}

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

function Format-HealthReport {
    param([PSCustomObject]$HealthReport, [string]$OutputFormat = "Console")
    $output = @(); $output += "================================================================================"; $output += "  HEALTH REPORT: $($HealthReport.IP)"; $output += "  Generated: $($HealthReport.ReportGeneratedAt.ToString('yyyy-MM-dd HH:mm:ss'))"; $output += "  Overall Status: $($HealthReport.OverallStatus)"; $output += "================================================================================"
    if ($HealthReport.Server) { $s = $HealthReport.Server; $output += ""; $output += "  SERVER HEALTH"; $output += "  ------------------------------------------------------------------------------"; $output += "   Status: $($s.Status)"; if ($s.CPU) { $output += "   CPU Usage: $($s.CPU.UsagePercent)%" }; if ($s.Memory) { $output += "   Memory: $($s.Memory.UsedMB)MB / $($s.Memory.TotalMB)MB ($($s.Memory.UsagePercent)%)" }; if ($s.Disk) { $output += "   Disk Usage: $($s.Disk.UsagePercent)%" }; if ($s.Uptime) { $output += "   Uptime: $($s.Uptime)" }; if ($s.Load -and $s.Load.Load1Min) { $output += "   Load Average: $($s.Load.Load1Min) / $($s.Load.Load5Min) / $($s.Load.Load15Min)" }; $output += "  ------------------------------------------------------------------------------" }
    if ($HealthReport.Containers) { $c = $HealthReport.Containers; $output += ""; $output += "  CONTAINER HEALTH"; $output += "  ------------------------------------------------------------------------------"; $output += "   Status: $($c.Status)"; $output += "   Total: $($c.TotalContainers) | Running: $($c.RunningContainers) | Stopped: $($c.StoppedContainers)"; $output += "  ------------------------------------------------------------------------------"; if ($c.Containers -and $c.Containers.Count -gt 0) { foreach ($container in $c.Containers) { $stateIcon = if ($container.State -eq "running") { "[RUNNING]" } else { "[STOPPED]" }; $output += "   $stateIcon $($container.Name)"; $output += "     Image: $($container.Image)"; $output += "     Status: $($container.Status)"; if ($container.State -eq "running" -and $container.CPUPercent) { $output += "     CPU: $($container.CPUPercent)% | Memory: $($container.MemoryUsage) ($($container.MemoryPercent)%)" }; if ($container.RestartCount -gt 0) { $output += "     Restarts: $($container.RestartCount)" }; $output += "  ------------------------------------------------------------------------------" } } else { $output += "   No containers found" }; $output += "================================================================================" }
    $output += ""
    return ($output -join "`n")
}

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

# UNIVERSAL HELPER: Replaces hundreds of lines of duplicate code in service installation functions.
# UNIVERSAL HELPER: Replaces hundreds of lines of duplicate code in service installation functions.
# UNIVERSAL HELPER: Replaces hundreds of lines of duplicate code in service installation functions.
function Deploy-DockerService {
    param (
        [string]$IP,
        [string]$User,
        [string]$Password,
        [string]$ServiceName,
        [string]$ComposeContent,
        [string]$OSType = $null
    )
    $os = if (-not [string]::IsNullOrEmpty($OSType)) { $OSType } else { Get-TargetOS -IP $IP }
    Write-Host "`nStarting $ServiceName deployment on $IP..." -ForegroundColor Cyan
    
    # 0. SMART FIX: Free up Port 53 from systemd-resolved if the config requires it
    if ($ComposeContent -match '53:53') {
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
        Write-Host "$ServiceName installed successfully!" -ForegroundColor Green
        return $true
    } else {
        Write-Host "$ServiceName deployment failed. Output: $deployResult" -ForegroundColor Red
        return $false
    }
}
function Install-Docker {
    param([string]$IP, [string]$User, [string]$Password, [string]$OSType = $null)
    $os = if (-not [string]::IsNullOrEmpty($OSType)) { $OSType } else { Get-TargetOS -IP $IP }
    
    try {
        $dockerCheck = Invoke-RemoteCommand -IP $IP -User $User -Password $Password -Command "docker --version" -OSType $os
        if ($null -ne $dockerCheck -and $dockerCheck -match "Docker version") { return $true }
        
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
        return ($null -ne $verifyResult -and $verifyResult -match "Docker version")
    } catch { return $false }
}

function Install-Traefik {
    param([string]$IP, [string]$User, [string]$Password, [string]$Email = "admin@localhost", [string]$Domain = "localhost", [string]$OSType = $null)
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
    return Deploy-DockerService -IP $IP -User $User -Password $Password -ServiceName "traefik" -ComposeContent $compose -OSType $os
}
#endregion

#===============================================================================
#region WSL2 SETUP FUNCTIONS (WINDOWS)
#===============================================================================

function Test-WSLReady {
    param ([string]$IP, [string]$User, [string]$Password, [string]$Distribution = "Ubuntu")
    try {
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        $session = New-PSSession -ComputerName $IP -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
        
        if (-not $session) { return @{ Ready = $false; NeedsReboot = $false; NeedsInstall = $true; Message = "Could not establish remote session" } }
        
        $status = Invoke-Command -Session $session -ScriptBlock {
            param($Distro)
            $result = @{ WSLFeatureEnabled = $false; VMPlatformEnabled = $false; WSLKernelInstalled = $false; DistributionInstalled = $false; DistributionReady = $false; NeedsReboot = $false; Message = "" }
            
            $wslStatus = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
            $result.WSLFeatureEnabled = ($wslStatus.State -eq "Enabled")
            if ($wslStatus.RestartNeeded -eq $true) { $result.NeedsReboot = $true }
            
            $vmStatus = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
            $result.VMPlatformEnabled = ($vmStatus.State -eq "Enabled")
            if ($vmStatus.RestartNeeded -eq $true) { $result.NeedsReboot = $true }
            
            if ($result.WSLFeatureEnabled -and $result.VMPlatformEnabled -and -not $result.NeedsReboot) {
                try {
                    $wslStatusCheck = & wsl --status 2>&1
                    $wslStatusStr = $wslStatusCheck -join ' '
                    if ($wslStatusStr -match "must be updated") { $result.WSLKernelInstalled = $false; $result.NeedsUpdate = $true; $result.Message = "WSL requires update via 'wsl --update'" }
                    elseif ($wslStatusStr -match "not installed|is not installed") { $result.WSLKernelInstalled = $false }
                    elseif ($LASTEXITCODE -eq 0) { $result.WSLKernelInstalled = $true }
                    else { $result.WSLKernelInstalled = $false }
                } catch { $result.WSLKernelInstalled = $false }
                
                if ($result.WSLKernelInstalled) {
                    $distroList = & wsl --list --quiet 2>&1 | Where-Object { $_ -match '\S' }
                    if ($distroList -match $Distro -or ($Distro -eq "Ubuntu" -and $distroList -match "Ubuntu")) {
                        $result.DistributionInstalled = $true
                        try { $testOutput = & wsl -d $Distro -u root echo "WSL_READY_TEST" 2>&1; if ($testOutput -match "WSL_READY_TEST") { $result.DistributionReady = $true } } catch { $result.DistributionReady = $false }
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

function Install-WSL2 {
    param ([string]$IP, [string]$User, [string]$Password, [string]$Distribution = "Ubuntu", [switch]$AutoReboot, [switch]$WaitForReboot)
    try {
        $wslStatus = Test-WSLReady -IP $IP -User $User -Password $Password -Distribution $Distribution
        if ($wslStatus.Ready) { return @{ Success = $true; NeedsReboot = $false; Ready = $true; Message = "WSL2 is already ready" } }
        if ($wslStatus.NeedsReboot) {
            if ($AutoReboot) { return Invoke-WSL2Reboot -IP $IP -User $User -Password $Password -Distribution $Distribution -WaitForReboot:$WaitForReboot }
            else { return @{ Success = $true; NeedsReboot = $true; Ready = $false; Message = "System reboot is required" } }
        }
        
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        $session = New-PSSession -ComputerName $IP -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
        
        if (-not $session) { return @{ Success = $false; NeedsReboot = $false; Ready = $false; Message = "Failed to establish remote session" } }
        
        $installResult = Invoke-Command -Session $session -ScriptBlock {
            param($DistroName)
            $installSuccess = $true
            try {
                $wslStatus = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
                if ($wslStatus.State -ne "Enabled") {
                    try { Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -ErrorAction Stop | Out-Null }
                    catch { $installSuccess = $false; return @{ Success = $installSuccess; NeedsReboot = $true; Message = "WSL feature installation failed" } }
                }
                
                $vmPlatformStatus = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
                if ($vmPlatformStatus.State -ne "Enabled") {
                    try { Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -ErrorAction Stop | Out-Null }
                    catch { $installSuccess = $false; return @{ Success = $installSuccess; NeedsReboot = $true; Message = "Virtual Machine Platform installation failed" } }
                }
                
                $rebootRequired = ($wslStatus.State -ne "Enabled" -or $vmPlatformStatus.State -ne "Enabled")
                $rebootPending = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
                $rebootReq = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
                if ($rebootPending -or $rebootReq) { $rebootRequired = $true }
                
                $wslFunctional = $false
                try { $wslTest = & wsl --status 2>&1; if ($LASTEXITCODE -eq 0 -and $wslTest -notmatch "not installed|is not installed") { $wslFunctional = $true } } catch { $rebootRequired = $true }
                
                if ($rebootRequired -and -not $wslFunctional) { return @{ Success = $true; NeedsReboot = $true; Ready = $false; Message = "System reboot required" } }
                
                try {
                    $wslUpdateOutput = & wsl --update 2>&1
                    if ($LASTEXITCODE -ne 0) { & wsl --update --web-download 2>&1 | Out-Null }
                } catch { }
                
                try { & wsl --install --web-download --no-launch 2>&1 | Out-Null } catch { }
                try { & wsl --set-default-version 2 2>&1 | Out-Null } catch { }
                
                $wslStatusCheck = & wsl --status 2>&1
                if ($LASTEXITCODE -ne 0 -or $wslStatusCheck -match "must be updated|not installed") {
                    return @{ Success = $true; NeedsReboot = $true; Ready = $false; Message = "Reboot required to activate WSL" }
                }
                
                if ($DistroName -and $DistroName -ne "") {
                    $installedDistros = & wsl --list --quiet 2>&1 | Where-Object { $_ -match '\S' }
                    $distroListStr = $installedDistros -join ' '
                    if ($distroListStr -match "not installed|is not installed") { return @{ Success = $true; NeedsReboot = $true; Ready = $false; Message = "Reboot required" } }
                    
                    $foundDistro = $null
                    if ($installedDistros -match "^$DistroName$") { $foundDistro = $DistroName }
                    elseif ($DistroName -eq "Ubuntu" -and $installedDistros -match "Ubuntu") { $foundDistro = $installedDistros | Where-Object { $_ -match "Ubuntu" } | Select-Object -First 1 }
                    
                    if ($foundDistro) {
                        & wsl --set-version $foundDistro 2 2>&1 | Out-Null
                    } else {
                        & wsl --install -d $DistroName --web-download --no-launch 2>&1 | Out-Null
                        Start-Sleep -Seconds 30
                        $installedDistros = & wsl --list --quiet 2>&1 | Where-Object { $_ -match '\S' }
                        
                        if ($installedDistros -match $DistroName) {
                            try { & wsl -d $DistroName -u root bash -c "echo 'Initialized' && apt-get update -qq" 2>&1 | Out-Null } catch { }
                        } else {
                            $installSuccess = $false
                        }
                    }
                }
                
                $wslStatusAfter = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
                $vmStatusAfter = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
                $rebootRequired = ($wslStatusAfter.RestartNeeded -eq $true) -or ($vmStatusAfter.RestartNeeded -eq $true) -or $rebootRequired
                
                $message = if (-not $installSuccess) { "WSL2 distribution installation failed." } elseif ($rebootRequired) { "System reboot is required." } else { "WSL2 installation completed successfully." }
                return @{ Success = $installSuccess; NeedsReboot = $rebootRequired; Ready = (-not $rebootRequired -and $installSuccess); Message = $message }
            }
            catch { return @{ Success = $false; NeedsReboot = $false; Ready = $false; Message = "Installation failed: $($_.Exception.Message)" } }
        } -ArgumentList $Distribution
        Remove-PSSession -Session $session
        
        if ($installResult.Success) {
            if ($installResult.NeedsReboot) {
                if ($AutoReboot) { return Invoke-WSL2Reboot -IP $IP -User $User -Password $Password -Distribution $Distribution -WaitForReboot:$WaitForReboot }
                return @{ Success = $true; NeedsReboot = $true; Ready = $false; Message = $installResult.Message }
            }
            return @{ Success = $true; NeedsReboot = $false; Ready = $true; Message = $installResult.Message }
        } else {
            return @{ Success = $false; NeedsReboot = $false; Ready = $false; Message = $installResult.Message }
        }
    }
    catch { return @{ Success = $false; NeedsReboot = $false; Ready = $false; Message = "Error: $($_.Exception.Message)" } }
}

function Invoke-WSL2Reboot {
    param ([string]$IP, [string]$User, [string]$Password, [string]$Distribution = "Ubuntu", [switch]$WaitForReboot, [int]$TimeoutMinutes = 10, [int]$MaxReboots = 2)
    try {
        if (-not $script:WSL2RebootCount.ContainsKey($IP)) { $script:WSL2RebootCount[$IP] = 0 }
        $script:WSL2RebootCount[$IP]++
        
        if ($script:WSL2RebootCount[$IP] -gt $MaxReboots) { return @{ Success = $false; NeedsReboot = $false; Ready = $false; Message = "Maximum reboot attempts reached." } }
        
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        
        try { Restart-Computer -ComputerName $IP -Credential $credential -Force -ErrorAction Stop }
        catch { return @{ Success = $false; NeedsReboot = $true; Ready = $false; Message = "Failed to initiate reboot." } }
        
        if (-not $WaitForReboot) { return @{ Success = $true; NeedsReboot = $true; Ready = $false; Rebooting = $true; Message = "System is rebooting." } }
        
        $offlineTimeout = 60
        $offlineStart = Get-Date
        do {
            Start-Sleep -Seconds 5
            $pingResult = Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue
            $elapsed = ((Get-Date) - $offlineStart).TotalSeconds
        } while ($pingResult -and ($elapsed -lt $offlineTimeout))
        
        $onlineTimeout = $TimeoutMinutes * 60
        $onlineStart = Get-Date
        $systemOnline = $false
        do {
            Start-Sleep -Seconds 10
            $pingResult = Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue
            if ($pingResult) {
                $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
                try { $testSession = New-PSSession -ComputerName $IP -Credential $credential -SessionOption $sessionOption -ErrorAction Stop; if ($testSession) { Remove-PSSession -Session $testSession; $systemOnline = $true } } catch { }
            }
            $elapsed = ((Get-Date) - $onlineStart).TotalSeconds
        } while (-not $systemOnline -and ($elapsed -lt $onlineTimeout))
        
        if (-not $systemOnline) { return @{ Success = $false; NeedsReboot = $false; Ready = $false; Message = "Timeout waiting for system." } }
        
        Start-Sleep -Seconds 30
        $wslStatus = Test-WSLReady -IP $IP -User $User -Password $Password -Distribution $Distribution
        
        if ($wslStatus.Ready) { return @{ Success = $true; NeedsReboot = $false; Ready = $true; Message = "WSL2 is ready after reboot" } }
        elseif ($wslStatus.NeedsDistribution -or (-not $wslStatus.NeedsReboot)) { return Install-WSL2 -IP $IP -User $User -Password $Password -Distribution $Distribution -AutoReboot -WaitForReboot }
        else { return @{ Success = $wslStatus.Ready; NeedsReboot = $wslStatus.NeedsReboot; Ready = $wslStatus.Ready; Message = $wslStatus.Message } }
    }
    catch { return @{ Success = $false; NeedsReboot = $false; Ready = $false; Message = "Error during reboot." } }
}
#endregion

#===============================================================================
#region MODULE EXPORTS
#===============================================================================

Export-ModuleMember -Function @(
    'Initialize-Logging', 'Write-Log', 'Write-LogDebug', 'Write-LogInfo', 'Write-LogWarning', 'Write-LogError', 'Write-LogSuccess', 'Get-LogFilePath', 'Get-LogContent', 'Clear-OldLogs', 'Write-SessionSeparator',
    'Get-TargetOS', 'Test-SSHConnection', 'Test-WinRMConnection', 'Test-RemoteConnection', 'Invoke-WSLCommand', 'Invoke-RemoteCommand',
    'Get-ServerHealth', 'Get-LinuxServerHealth', 'Get-WindowsServerHealth', 'Get-ContainerHealth', 'Get-ContainerLogs', 'Restart-Container', 'Stop-Container', 'Start-Container', 'Get-FullHealthReport', 'Format-HealthReport', 'Test-ServiceHealth', 'Test-CommonServices',
    'Install-Docker', 'Install-Traefik', 'Deploy-DockerService',
    'Test-WSLReady', 'Install-WSL2', 'Invoke-WSL2Reboot'
)
#endregion