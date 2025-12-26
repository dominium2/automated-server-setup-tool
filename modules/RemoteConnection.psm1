#This file handles the remote connection to the target machines

function Get-TargetOS {
    param (
        [string]$IP
    )
    
    try {
        Write-Host "  Attempting to detect OS via TCP ports..." -ForegroundColor Cyan
        
        # Check for Windows (WinRM ports 5985/5986)
        $winRMPort = Test-NetConnection -ComputerName $IP -Port 5985 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        
        if ($winRMPort.TcpTestSucceeded) {
            Write-Host "  WinRM port (5985) is open - likely Windows" -ForegroundColor Green
            return "Windows"
        }
        
        # Check for SSH port 22 (Linux/Unix)
        $sshPort = Test-NetConnection -ComputerName $IP -Port 22 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        
        if ($sshPort.TcpTestSucceeded) {
            Write-Host "  SSH port (22) is open - likely Linux/Unix" -ForegroundColor Green
            return "Linux"
        }
        
        # If neither port is open, try additional detection methods
        Write-Host "  Standard ports not detected. Attempting alternative detection..." -ForegroundColor Yellow
        
        # Try to detect via TTL value in ping response
        $pingDetailed = Test-Connection -ComputerName $IP -Count 1 -ErrorAction SilentlyContinue
        
        if ($pingDetailed) {
            $ttl = $pingDetailed.ResponseTimeToLive
            Write-Host "  TTL value: $ttl" -ForegroundColor Cyan
            
            # Windows typically has TTL of 128
            # Linux typically has TTL of 64
            if ($ttl -ge 120 -and $ttl -le 128) {
                Write-Host "  TTL suggests Windows OS" -ForegroundColor Green
                return "Windows"
            }
            elseif ($ttl -ge 60 -and $ttl -le 64) {
                Write-Host "  TTL suggests Linux/Unix OS" -ForegroundColor Green
                return "Linux"
            }
        }
        
        Write-Host "  Unable to reliably detect OS" -ForegroundColor Yellow
        return $null
    }
    catch {
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
        Write-Host "Testing SSH connection to $IP..." -ForegroundColor Cyan
        
        # Use plink if available (from PuTTY) for password-based SSH
        if (Get-Command plink -ErrorAction SilentlyContinue) {
            Write-Host "  Using plink for SSH connection..." -ForegroundColor Cyan
            
            # Create a temporary answer file to auto-accept host key
            $tempAnswerFile = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $tempAnswerFile -Value "y"
            
            try {
                # Use the answer file to auto-accept host key, then connect
                $result = Get-Content $tempAnswerFile | & plink -pw $Password $User@$IP "hostname" 2>&1
                
                if ($LASTEXITCODE -eq 0 -and $result -and $result -notmatch "FATAL ERROR" -and $result -notmatch "Access denied") {
                    Write-Host "SSH connection successful!" -ForegroundColor Green
                    Write-Host "Connected to: $result" -ForegroundColor Green
                    return $true
                }
                else {
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
            Write-Host "  Error: 'plink' (PuTTY) is required for password-based SSH" -ForegroundColor Red
            Write-Host "  Install with: choco install putty -y" -ForegroundColor Yellow
            return $false
        }
    }
    catch {
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
        Write-Host "Testing WinRM connection to $IP..." -ForegroundColor Cyan
        
        # Check if WinRM service is running and start it if needed
        Write-Host "  Checking WinRM service status..." -ForegroundColor Cyan
        $winrmService = Get-Service -Name WinRM -ErrorAction SilentlyContinue
        
        if ($winrmService -and $winrmService.Status -ne 'Running') {
            Write-Host "  Starting WinRM service..." -ForegroundColor Yellow
            try {
                Start-Service -Name WinRM -ErrorAction Stop
                Write-Host "  WinRM service started" -ForegroundColor Green
            }
            catch {
                Write-Host "  Warning: Could not start WinRM service: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        
        # Check and configure TrustedHosts
        Write-Host "  Checking TrustedHosts configuration..." -ForegroundColor Cyan
        try {
            $currentTrustedHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
            
            if (-not $currentTrustedHosts.Contains($IP) -and $currentTrustedHosts -ne "*") {
                Write-Host "  Adding $IP to TrustedHosts..." -ForegroundColor Yellow
                
                if ([string]::IsNullOrEmpty($currentTrustedHosts)) {
                    Set-Item WSMan:\localhost\Client\TrustedHosts -Value $IP -Force
                } else {
                    Set-Item WSMan:\localhost\Client\TrustedHosts -Value "$currentTrustedHosts,$IP" -Force
                }
                Write-Host "  Successfully added $IP to TrustedHosts" -ForegroundColor Green
            } else {
                Write-Host "  $IP is already in TrustedHosts or using wildcard" -ForegroundColor Green
            }
        }
        catch {
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
        Write-Host "  Attempting to establish PSSession..." -ForegroundColor Cyan
        $winSession = New-PSSession -ComputerName $IP -Credential $winCredential -SessionOption $sessionOption -ErrorAction Stop
        
        if ($winSession) {
            Write-Host "WinRM connection successful!" -ForegroundColor Green
            
            # Test by running a command
            $result = Invoke-Command -Session $winSession -ScriptBlock {
                $env:COMPUTERNAME 
            }
            Write-Host "Connected to: $result" -ForegroundColor Green
            
            # Close session
            Remove-PSSession -Session $winSession
            return $true
        }
    }
    catch {
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
        
        # Check if all pings were successful
        if ($successfulPings -eq $maxAttempts) {
            Write-Host "All pings successful! Proceeding with connection..." -ForegroundColor Green
            
            # Detect target OS
            Write-Host "Detecting target OS..." -ForegroundColor Cyan
            $targetOS = Get-TargetOS -IP $IP
            
            if ($targetOS) {
                Write-Host "Detected OS: $targetOS" -ForegroundColor Green
                
                # Use appropriate connection method based on OS
                if ($targetOS -eq "Windows") {
                    Write-Host "Using WinRM for Windows connection..." -ForegroundColor Cyan
                    return Test-WinRMConnection -IP $IP -User $User -Password $Password
                }
                elseif ($targetOS -eq "Linux") {
                    Write-Host "Using SSH for Linux connection..." -ForegroundColor Cyan
                    return Test-SSHConnection -IP $IP -User $User -Password $Password
                }
                else {
                    Write-Host "Unknown OS type: $targetOS. Attempting SSH connection..." -ForegroundColor Yellow
                    return Test-SSHConnection -IP $IP -User $User -Password $Password
                }
            }
            else {
                Write-Host "Failed to detect OS. Attempting SSH connection as fallback..." -ForegroundColor Yellow
                return Test-SSHConnection -IP $IP -User $User -Password $Password
            }
        }
        else {
            Write-Host "Ping test failed. $successfulPings out of $maxAttempts pings successful." -ForegroundColor Red
            return $false
        }
    }
    catch {
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
        [string]$Distribution = "Ubuntu"
    )
    
    try {
        # Create credential object
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        
        # Create session options
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        
        # Establish remote session to Windows machine
        $session = New-PSSession -ComputerName $IP -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
        
        if (-not $session) {
            Write-Host "Failed to establish remote session to $IP" -ForegroundColor Red
            return $null
        }
        
        # Execute command inside WSL2
        $result = Invoke-Command -Session $session -ScriptBlock {
            param($Cmd, $Distro)
            
            # First, check if the distribution exists
            $distroList = wsl --list --quiet 2>&1 | Where-Object { $_ -match '\S' }
            
            if ($distroList -notmatch $Distro) {
                return @{
                    Output = "Distribution '$Distro' not found. Available distributions: $($distroList -join ', ')"
                    ExitCode = 1
                }
            }
            
            # Check if distribution is running, if not start it
            $runningDistros = wsl --list --running --quiet 2>&1 | Where-Object { $_ -match '\S' }
            if ($runningDistros -notmatch $Distro) {
                # Start the distribution
                wsl -d $Distro -u root echo "Starting distribution..." 2>&1 | Out-Null
                Start-Sleep -Seconds 2
            }
            
            # Execute the command in WSL as root (since we may not have a regular user set up)
            $output = wsl -d $Distro -u root bash -c $Cmd 2>&1
            
            return @{
                Output = $output
                ExitCode = $LASTEXITCODE
            }
        } -ArgumentList $Command, $Distribution
        
        # Close the session
        Remove-PSSession -Session $session
        
        return $result
    }
    catch {
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
        # Detect the OS
        $osType = Get-TargetOS -IP $IP
        
        if ($osType -eq "Linux") {
            # Use SSH for Linux systems
            if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
                Write-Host "Error: 'plink' (PuTTY) is required for SSH connection" -ForegroundColor Red
                return $null
            }
            
            $result = Write-Output y | plink -batch -pw $Password "$User@$IP" $Command 2>&1
            
            if ($LASTEXITCODE -ne 0 -and $result -match "error|fatal|failed|denied|cannot|permission denied") {
                return $null
            }
            
            return $result
        }
        elseif ($osType -eq "Windows") {
            # Use WSL2 for Windows systems
            $wslResult = Invoke-WSLCommand -IP $IP -User $User -Password $Password -Command $Command
            
            if ($null -eq $wslResult) {
                Write-Host "WSL command execution failed" -ForegroundColor Red
                return $null
            }
            
            # Check for distribution errors
            if ($wslResult.ExitCode -ne 0 -and $wslResult.Output -match "no distribution|not found") {
                Write-Host "Error: $($wslResult.Output)" -ForegroundColor Red
                return $null
            }
            
            if ($wslResult.ExitCode -ne 0 -and $wslResult.Output -match "error|fatal|failed|denied|cannot|permission denied") {
                Write-Host "Command error: $($wslResult.Output)" -ForegroundColor Yellow
                return $null
            }
            
            return $wslResult.Output
        }
        else {
            Write-Host "Unable to detect OS type for $IP" -ForegroundColor Red
            return $null
        }
    }
    catch {
        Write-Host "Error executing remote command: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# Export functions to make them available when module is imported
Export-ModuleMember -Function Test-RemoteConnection, Test-SSHConnection, Test-WinRMConnection, Get-TargetOS, Invoke-WSLCommand, Invoke-RemoteCommand