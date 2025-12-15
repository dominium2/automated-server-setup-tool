function Install-Portainer {
    <#
    .SYNOPSIS
        Installs Portainer on a Debian-based system.

    .DESCRIPTION
        This function installs Portainer, a lightweight management UI for Docker, on a Debian-based system.
        It requires Docker to be installed and will use the DockerSetupDebian module if needed.

    .PARAMETER IP
        The IP address of the target Debian server.

    .PARAMETER User
        The username for SSH authentication.

    .PARAMETER Password
        The password for SSH authentication.

    .EXAMPLE
        Install-Portainer -IP "192.168.1.100" -User "admin" -Password "password123"

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
        Write-Host "`nStarting Portainer installation on $IP..." -ForegroundColor Cyan
        
        # Import Docker module
        $dockerModulePath = Join-Path $PSScriptRoot "DockerSetupDebian.psm1"
        Import-Module $dockerModulePath -Force
        
        # Ensure Docker is installed
        $dockerInstalled = Install-Docker -IP $IP -User $User -Password $Password
        
        if (-not $dockerInstalled) {
            Write-Host "Cannot install Portainer without Docker" -ForegroundColor Red
            return $false
        }
        
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
        
        # Check if Portainer is already running
        Write-Host "Checking for existing Portainer installation..." -ForegroundColor Cyan
        $portainerCheck = Invoke-SSHCommand "sudo docker ps -a --filter name=portainer --format '{{.Names}}'"
        
        if ($portainerCheck -match "portainer") {
            Write-Host "Portainer container already exists. Removing old container..." -ForegroundColor Yellow
            $removeResult = Invoke-SSHCommand "sudo docker rm -f portainer"
            if ($null -eq $removeResult) {
                Write-Host "Warning: Failed to remove old Portainer container" -ForegroundColor Yellow
            }
        }
        
        # Create Portainer data volume
        Write-Host "Creating Portainer data volume..." -ForegroundColor Cyan
        $volumeResult = Invoke-SSHCommand "sudo docker volume create portainer_data"
        if ($null -eq $volumeResult) {
            Write-Host "Failed to create Portainer data volume" -ForegroundColor Red
            return $false
        }
        
        # Check if Traefik network exists
        Write-Host "Checking for Traefik network..." -ForegroundColor Cyan
        $networkCheck = Invoke-SSHCommand "sudo docker network ls --filter name=traefik-network --format '{{.Name}}'"
        
        $useTraefik = $false
        if ($networkCheck -match "traefik-network") {
            Write-Host "Traefik network found. Portainer will be integrated with Traefik" -ForegroundColor Green
            $useTraefik = $true
        }
        else {
            Write-Host "Traefik network not found. Portainer will use direct port mapping" -ForegroundColor Yellow
        }
        
        # Deploy Portainer container
        Write-Host "Deploying Portainer container..." -ForegroundColor Cyan
        
        if ($useTraefik) {
            # Deploy with Traefik integration
            $portainerCommand = @"
sudo docker run -d \
  --name=portainer \
  --restart=always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  --network traefik-network \
  --label 'traefik.enable=true' \
  --label 'traefik.http.routers.portainer.rule=Host(\`portainer.$IP.nip.io\`)' \
  --label 'traefik.http.routers.portainer.entrypoints=websecure' \
  --label 'traefik.http.routers.portainer.tls.certresolver=letsencrypt' \
  --label 'traefik.http.services.portainer.loadbalancer.server.port=9000' \
  portainer/portainer-ce:latest
"@
        }
        else {
            # Deploy with direct port mapping
            $portainerCommand = "sudo docker run -d -p 9000:9000 -p 9443:9443 --name=portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest"
        }
        
        $portainerInstall = Invoke-SSHCommand $portainerCommand
        
        if ($null -eq $portainerInstall) {
            Write-Host "Failed to install Portainer" -ForegroundColor Red
            return $false
        }
        
        # Verify Portainer is running
        Start-Sleep -Seconds 3
        $verifyResult = Invoke-SSHCommand "sudo docker ps --filter name=portainer --format '{{.Status}}'"
        
        if ($verifyResult -match "Up") {
            Write-Host "`nPortainer installed successfully!" -ForegroundColor Green
            if ($useTraefik) {
                Write-Host "Access Portainer via Traefik: https://portainer.$IP.nip.io" -ForegroundColor Cyan
            }
            else {
                Write-Host "Access Portainer directly: https://$IP:9443" -ForegroundColor Cyan
                Write-Host "  or: http://$IP:9000" -ForegroundColor Cyan
            }
            return $true
        }
        else {
            Write-Host "Portainer container deployed but not running properly" -ForegroundColor Yellow
            return $false
        }
    }
    catch {
        Write-Host "Error during Portainer installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

Export-ModuleMember -Function Install-Portainer