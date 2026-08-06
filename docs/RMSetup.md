# RMSetup.psm1 Documentation

`RMSetup.psm1` is the consolidated backend engine. It handles cross-platform remote execution, network port routing, batched Docker deployments, and string parsing.

## Connection Architecture

### 1. `Set-ConnectionConfig`
Stores user-defined SSH and WinRM ports in the module's script scope (`$script:SSHPort`, `$script:WinRMPort`). This entirely eliminates the need to pass port parameters through dozens of nested functions.

### 2. Smart OS Detection & Caching (`Get-TargetOS`)
Probes TCP ports (WinRM 5985 and SSH 22) to determine the target OS. To prevent network overhead, the result is cached and passed down using the `-OSType` parameter. This prevents the module from executing 2-second timeout probes during subsequent bash operations.

### 3. `Invoke-RemoteCommand`
The universal transport layer. 
- **Linux**: Wraps `plink` (PuTTY) to bypass OpenSSH's strict interactive-password limitations, allowing fully automated deployments.
- **Windows**: Wraps `Invoke-WSLCommand` to route commands directly into the target's WSL2 Ubuntu distribution.

## High-Speed Command Batching

Previous iterations opened a new SSH connection for every single Linux command, causing setups to take up to 10 minutes. The architecture now relies on **Bash Chaining** to execute massive workloads in a single remote session.

### `Deploy-DockerService` Batching
Calculates required directories, translates YAML into Base64, and constructs a single string payload:
```bash
mkdir -p /home/user/app/data; cd /home/user/app; sudo docker compose down; echo 'base64...' | base64 -d > docker-compose.yml; sudo docker compose up -d
```
This reduces deployment execution from minutes to roughly ~15 seconds per server.

`Get-ContainerHealth` Batching
Uses inline bash subshells and section headers (`===INSPECT===`, `===STATS===`) to run `docker ps`, `docker inspect`, and `docker stats` concurrently across all containers in one payload.
The PowerShell backend then splits the massive returned string, indexing the data by short container IDs, dropping polling times from 5 minutes to 3 seconds.

## Service Installation

All services (Docker, Traefik, AdGuard, Portainer, etc.) follow an idempotent design:

1. Validate dependencies.
2. Resolve environment conflicts (e.g., auto-disabling `systemd-resolved` for AdGuard's DNS port 53).
3. Execute the batched payload.
4. Verify the container state returns `running` or `Up`.

## Health Reporting

1. `Get-LinuxServerHealth`: Uses native Linux binaries (`top`, `free`, `df`, `uptime`) to extract host resource usage.
2. `Get-WindowsServerHealth`: Uses `Get-CimInstance` over WinRM PSSessions to extract host resource usage.
3. `Format-HealthReport`: Converts raw `[PSCustomObject]` properties into a clean, human-readable terminal output for exporting.