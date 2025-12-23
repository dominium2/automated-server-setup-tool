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
            
            $result = Write-Output y | plink -batch -pw $Password $User@$IP $Command 2>&1
            
            # Only treat as error if we get actual error messages
            if ($LASTEXITCODE -ne 0 -and $result -match "error|fatal|failed|denied|cannot|permission denied") {
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

Export-ModuleMember -Function Install-Docker
