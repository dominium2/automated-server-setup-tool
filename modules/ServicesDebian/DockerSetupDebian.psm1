function Install-Docker {
    <#
    .SYNOPSIS
        Installs Docker on a Debian-based system.

    .DESCRIPTION
        This function installs Docker Engine on a Debian-based system via SSH.
        It checks for existing installations and installs Docker if not present.

    .PARAMETER IP
        The IP address of the target Debian server.

    .PARAMETER User
        The username for SSH authentication.

    .PARAMETER Password
        The password for SSH authentication.

    .EXAMPLE
        Install-Docker -IP "192.168.1.100" -User "admin" -Password "password123"

    .NOTES
        Requires plink (PuTTY) to be installed for SSH connectivity.
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
        
        # Check if plink is available
        if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
            Write-Host "Error: 'plink' (PuTTY) is required for SSH connection" -ForegroundColor Red
            Write-Host "Install with: choco install putty -y" -ForegroundColor Yellow
            return $false
        }
        
        # Function to execute remote command via SSH
        function Invoke-SSHCommand {
            param([string]$Command)
            
            $result = echo y | plink -batch -pw $Password $User@$IP $Command 2>&1
            
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Command failed: $Command" -ForegroundColor Red
                Write-Host "Output: $result" -ForegroundColor Red
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
        $prereqResult = Invoke-SSHCommand "sudo apt-get install -y ca-certificates curl gnupg lsb-release"
        if ($null -eq $prereqResult) {
            Write-Host "Failed to install prerequisites" -ForegroundColor Red
            return $false
        }
        
        # Add Docker's official GPG key
        Write-Host "  Adding Docker GPG key..." -ForegroundColor Cyan
        $gpgResult = Invoke-SSHCommand "sudo mkdir -p /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
        if ($null -eq $gpgResult) {
            Write-Host "Failed to add Docker GPG key" -ForegroundColor Red
            return $false
        }
        
        # Set up Docker repository
        Write-Host "  Setting up Docker repository..." -ForegroundColor Cyan
        $repoResult = Invoke-SSHCommand "echo 'deb [arch=`$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian `$(lsb_release -cs) stable' | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null"
        if ($null -eq $repoResult) {
            Write-Host "Failed to set up Docker repository" -ForegroundColor Red
            return $false
        }
        
        # Update package index again
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
        $groupResult = Invoke-SSHCommand "sudo usermod -aG docker $User"
        
        # Verify Docker installation
        $verifyResult = Invoke-SSHCommand "docker --version"
        if ($null -ne $verifyResult -and $verifyResult -match "Docker version") {
            Write-Host "Docker installed successfully: $verifyResult" -ForegroundColor Green
        }
        else {
            Write-Host "Docker installation completed but verification failed" -ForegroundColor Yellow
            return $false
        }
        
        # Verify Docker Compose installation
        Write-Host "  Verifying Docker Compose..." -ForegroundColor Cyan
        $composeResult = Invoke-SSHCommand "docker compose version"
        if ($null -ne $composeResult -and $composeResult -match "Docker Compose version") {
            Write-Host "Docker Compose verified: $composeResult" -ForegroundColor Green
            return $true
        }
        else {
            Write-Host "Warning: Docker Compose not found or not working properly" -ForegroundColor Yellow
            Write-Host "Attempting to install Docker Compose standalone..." -ForegroundColor Cyan
            
            # Install standalone Docker Compose as fallback
            $composeInstall = Invoke-SSHCommand "sudo curl -L 'https://github.com/docker/compose/releases/latest/download/docker-compose-`$(uname -s)-`$(uname -m)' -o /usr/local/bin/docker-compose && sudo chmod +x /usr/local/bin/docker-compose"
            
            if ($null -ne $composeInstall) {
                $composeVerify = Invoke-SSHCommand "docker-compose --version"
                if ($null -ne $composeVerify) {
                    Write-Host "Docker Compose standalone installed successfully" -ForegroundColor Green
                    return $true
                }
            }
            
            Write-Host "Docker installed but Docker Compose may not be available" -ForegroundColor Yellow
            return $true
        }
    }
    catch {
        Write-Host "Error during Docker installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

Export-ModuleMember -Function Install-Docker
