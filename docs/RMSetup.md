# RMSetup.psm1 Documentation

Consolidated PowerShell module containing all backend functionality for remote management and service deployment.

## Overview

`RMSetup.psm1` (Remote Management Setup) provides functions for:
- Logging
- Remote connections (SSH, WinRM, WSL)
- Health monitoring
- Service installation

---

## Module Structure

```
#region Module Variables
#region LOGGING FUNCTIONS
#region REMOTE CONNECTION FUNCTIONS
#region HEALTH MONITORING FUNCTIONS
#region SERVICE INSTALLATION FUNCTIONS (DEBIAN)
#region WSL2 SETUP FUNCTIONS
#region MODULE EXPORTS
```

---

## Module Variables

```powershell
$script:LogFilePath      # Current log file path
$script:LogLevel         # Minimum log level (Debug/Info/Warning/Error)
$script:LogToFile        # Boolean - write to file
$script:LogToConsole     # Boolean - write to console
$script:MaxLogFileSizeMB # Log rotation size threshold
$script:MaxLogFiles      # Max log files to keep
$script:LogLevels        # Hashtable mapping level names to priority numbers
```

---

## Logging Functions

### Initialize-Logging
Sets up logging system. Call at application start.

```powershell
Initialize-Logging -LogLevel "Info" -LogToFile $true
```
Creates: `logs/automated-setup_YYYY-MM-DD.log`

### Write-Log
Core logging function with level, component, and optional exception.

```powershell
Write-Log -Message "text" -Level "Error" -Component "SSH" -Exception $_.Exception
```

### Shortcut Functions
```powershell
Write-LogDebug   -Message "debug info" -Component "Test"
Write-LogInfo    -Message "information" -Component "Main"
Write-LogWarning -Message "warning" -Component "Health"
Write-LogError   -Message "error" -Component "SSH" -Exception $e
Write-LogSuccess -Message "completed" -Component "Install"
```

### Other Logging Functions
- `Get-LogFilePath` - Returns current log file path
- `Get-LogContent` - Read log file with optional filtering
- `Clear-OldLogs` - Delete logs older than X days
- `Write-SessionSeparator` - Visual separator in logs

---

## Remote Connection Functions

### Get-TargetOS
Detects if target is Windows or Linux.

```powershell
$os = Get-TargetOS -IP "192.168.1.100"
# Returns: "Windows", "Linux", or $null
```

**Detection method:**
1. Check port 5985 (WinRM) → Windows
2. Check port 22 (SSH) → Linux
3. Analyze TTL from ping (128=Windows, 64=Linux)

### Test-SSHConnection
Tests SSH connectivity using plink (PuTTY).

```powershell
$success = Test-SSHConnection -IP "192.168.1.100" -User "admin" -Password "pass"
```

### Test-WinRMConnection
Tests WinRM connectivity to Windows servers.

```powershell
$success = Test-WinRMConnection -IP "192.168.1.100" -User "admin" -Password "pass"
```
Automatically configures TrustedHosts if needed.

### Test-RemoteConnection
High-level function that auto-selects SSH or WinRM.

```powershell
$success = Test-RemoteConnection -IP "192.168.1.100" -User "admin" -Password "pass"
```
Performs 4 ping tests first, then connects using appropriate method.

### Invoke-RemoteCommand
Executes bash commands on remote systems (Linux via SSH, Windows via WSL).

```powershell
$result = Invoke-RemoteCommand -IP $ip -User $user -Password $pass -Command "docker ps"
```

### Invoke-WSLCommand
Executes commands inside WSL2 on a Windows machine.

```powershell
$result = Invoke-WSLCommand -IP $ip -User $user -Password $pass -Command "apt update" -Distribution "Ubuntu"
```

---

## Health Monitoring Functions

### Get-ServerHealth
Gets CPU, memory, disk, uptime from a server.

```powershell
$health = Get-ServerHealth -IP $ip -User $user -Password $pass
```

**Returns object with:**
- `Status` - Healthy/Warning/Critical/Offline/Error
- `CPU.UsagePercent`
- `Memory.UsedMB`, `Memory.TotalMB`, `Memory.UsagePercent`
- `Disk.UsagePercent`
- `Uptime`
- `Load` (Linux: load averages, Windows: processor queue)

### Get-LinuxServerHealth / Get-WindowsServerHealth
OS-specific implementations called by `Get-ServerHealth`.

### Get-ContainerHealth
Gets Docker container status and resource usage.

```powershell
$containers = Get-ContainerHealth -IP $ip -User $user -Password $pass
```

**Returns:**
- `TotalContainers`, `RunningContainers`, `StoppedContainers`
- `Containers` array with name, state, CPU%, memory, etc.

### Container Management
```powershell
Get-ContainerLogs    -IP $ip -User $u -Password $p -ContainerName "nginx" -Tail 100
Restart-Container    -IP $ip -User $u -Password $p -ContainerName "nginx"
Stop-Container       -IP $ip -User $u -Password $p -ContainerName "nginx"
Start-Container      -IP $ip -User $u -Password $p -ContainerName "nginx"
```

### Get-FullHealthReport
Combines server and container health into one report.

### Format-HealthReport
Formats health data for display (Console/Simple/Detailed).

---

## Service Installation Functions

All follow the same pattern:

```powershell
Install-<Service> -IP "192.168.1.100" -User "admin" -Password "pass" -Domain "homelab.local"
```

### Install-Docker
Installs Docker Engine on Debian-based systems.

**Steps:**
1. Check if Docker already installed
2. Update apt packages
3. Install prerequisites (curl, gnupg, etc.)
4. Add Docker GPG key and repository
5. Install docker-ce, docker-ce-cli, containerd.io
6. Add user to docker group

### Install-Traefik
Installs Traefik reverse proxy container.

**Ports:** 80 (HTTP), 443 (HTTPS), 8080 (Dashboard)

### Install-Portainer
Installs Portainer container management UI.

**Port:** 9000

### Install-AdGuard
Installs AdGuard Home DNS ad-blocker.

**Ports:** 53 (DNS), 3000 (Web UI setup), 80 (Web UI after setup)

### Install-N8N
Installs N8N workflow automation.

**Port:** 5678

### Install-Heimdall
Installs Heimdall application dashboard.

**Port:** 8000

### Install-Crafty
Installs Crafty Controller for Minecraft servers.

**Port:** 8443

---

## WSL2 Setup Functions

For Windows targets that need Linux containers.

### Test-WSLReady
Checks if WSL2 is installed and functional.

```powershell
$status = Test-WSLReady -IP $ip -User $user -Password $pass
# Returns: @{ Ready = $true/$false; NeedsReboot = $true/$false; Message = "..." }
```

### Install-WSL2
Installs WSL2 and a Linux distribution on Windows.

```powershell
Install-WSL2 -IP $ip -User $user -Password $pass -Distribution "Ubuntu" -AutoReboot
```

### Invoke-WSL2Reboot
Handles reboot and reconnection during WSL2 installation.

---

## Exported Functions

```powershell
Export-ModuleMember -Function @(
    # Logging
    'Initialize-Logging', 'Write-Log', 'Write-LogDebug', 'Write-LogInfo',
    'Write-LogWarning', 'Write-LogError', 'Write-LogSuccess',
    'Get-LogFilePath', 'Get-LogContent', 'Clear-OldLogs', 'Write-SessionSeparator',
    
    # Remote Connection
    'Get-TargetOS', 'Test-SSHConnection', 'Test-WinRMConnection',
    'Test-RemoteConnection', 'Invoke-WSLCommand', 'Invoke-RemoteCommand',
    
    # Health Monitoring
    'Get-ServerHealth', 'Get-LinuxServerHealth', 'Get-WindowsServerHealth',
    'Get-ContainerHealth', 'Get-ContainerLogs', 'Restart-Container',
    'Stop-Container', 'Start-Container', 'Get-FullHealthReport',
    'Format-HealthReport', 'Test-ServiceHealth', 'Test-CommonServices',
    
    # Service Installation
    'Install-AdGuard', 'Install-Crafty', 'Install-Docker',
    'Install-Heimdall', 'Install-N8N', 'Install-Portainer', 'Install-Traefik',
    
    # WSL2 Setup
    'Test-WSLReady', 'Install-WSL2', 'Invoke-WSL2Reboot'
)
```

---

## Error Handling Pattern

All functions use consistent error handling:

```powershell
try {
    # Operation
    Write-LogSuccess -Message "Done" -Component "ModuleName"
    return $true
}
catch {
    Write-LogError -Message "Failed" -Component "ModuleName" -Exception $_.Exception
    return $false  # or $null for data-returning functions
}
```

---

## AI Assistance Note

Parts of this module were developed with AI assistance, including:
- Long/repetitive code sections (service installation functions, health monitoring)
- Health monitoring command construction
- Error handling patterns
- WSL2 setup functions
- Documentation writing
