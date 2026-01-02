# Health Monitoring Module for Automated Server Setup Tool
# Provides health monitoring functionality for servers and containers

# Import logging module if not already loaded
if (-not (Get-Command Write-LogInfo -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot "Logging.psm1") -Force -Scope Global -ErrorAction SilentlyContinue
}

#region Server Health Monitoring

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

#endregion

#region Container Health Monitoring

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

#endregion

#region Combined Health Report

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

#endregion

#region Service Checks

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

# Export functions
Export-ModuleMember -Function Get-ServerHealth, Get-LinuxServerHealth, Get-WindowsServerHealth
Export-ModuleMember -Function Get-ContainerHealth, Get-ContainerLogs, Restart-Container, Stop-Container, Start-Container
Export-ModuleMember -Function Get-FullHealthReport, Format-HealthReport
Export-ModuleMember -Function Test-ServiceHealth, Test-CommonServices
