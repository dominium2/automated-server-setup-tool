# RMSetup Module Overview

This module abstracts the complexity of remote server operations. It acts as a routing layer that decides whether a target is Linux or Windows, establishes the appropriate connection, executes the requested command, and normalizes the results.

## Backend Execution Flow

1. **Configuration Sync**
   - The GUI passes custom SSH and WinRM ports into the module scope through `Set-ConnectionConfig`.

2. **Operating System Detection**
   - `Get-TargetOS` tests the available ports and uses TTL-based fallback logic to determine whether the target is Windows or Linux.

3. **Command Routing**
   - `Invoke-RemoteCommand` routes bash-based work to PuTTY or WSL depending on the detected OS.

4. **Action Execution**
   - Higher-level functions such as `Deploy-DockerService` build optimized batched commands to reduce network round-trips and speed up deployment.

## Core Module Areas

### 1. Configuration and Logging

- `Set-ConnectionConfig`: Stores the configured SSH and WinRM ports globally for reuse.
- `Initialize-Logging`: Creates a timestamped log file under the `logs/` directory.
- `Invoke-LogRotation`: Rotates or removes old log files when they exceed size or count thresholds.
- `Write-Log` and wrappers like `Write-LogInfo`/`Write-LogError`: Record messages with timestamps and severity levels.
- `Set-LogConfiguration`: Passes the active log path into background runspaces to keep logging consistent.

### 2. Remote Connection Routing

- `Get-TargetOS`: Detects the remote operating system using port checks and fallback ping logic.
- `Test-SSHConnection` and `Test-WinRMConnection`: Validate direct connectivity for each protocol.
- `Test-RemoteConnection`: Runs a short validation sequence to confirm the target is reachable and supports the expected protocol.
- `Invoke-WSLCommand`: Executes bash payloads on Windows hosts through WSL.
- `Invoke-RemoteCommand`: The primary dispatcher for remote execution.

### 3. Health Monitoring and Parsers

- `Get-ServerHealth`: Routes to the correct OS-specific health check.
- `Get-LinuxServerHealth`: Collects CPU, RAM, disk, and uptime data over SSH.
- `Get-WindowsServerHealth`: Queries WMI over WinRM for host metrics.
- `Get-ContainerHealth`: Retrieves Docker container status and resource usage in a single pass.
- `Restart-Container`, `Stop-Container`, and `Start-Container`: Wrap docker lifecycle operations.
- `Get-FullHealthReport` and `Format-HealthReport`: Combine host and container data into a human-readable report.

### 4. Service Installation Algorithms

- `Deploy-DockerService`: Performs the deployment workflow, including dependency checks, compose file handling, stack teardown, and container startup.
- `Install-DockerLinux`: Installs Docker CE on Debian or Ubuntu hosts.
- `Install-DockerWSL2`: Configures Docker inside WSL2 with memory and CPU limits.
- `Install-Traefik`: Deploys Traefik and ensures the `acme.json` file has the correct permissions.

### 5. WSL2 Infrastructure

- `Test-WSLReady`: Checks whether Hyper-V, Virtual Machine Platform, WSL, and a distribution are available on the Windows host.
- `Install-WSL2`: Installs and configures WSL2 and its Linux distribution.
- `Invoke-WSL2Reboot`: Reboots the host when required to finish feature activation.
