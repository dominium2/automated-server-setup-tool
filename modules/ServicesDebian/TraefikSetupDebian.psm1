function Install-Traefik {
    <#
    .SYNOPSIS
        Installs Traefik reverse proxy on a Debian-based system.

    .DESCRIPTION
        This function installs Traefik, a modern reverse proxy and load balancer, on a Debian-based system.
        Traefik will manage all other services through automatic service discovery and SSL certificates.

    .PARAMETER IP
        The IP address of the target Debian server.

    .PARAMETER User
        The username for SSH authentication.

    .PARAMETER Password
        The password for SSH authentication.

    .PARAMETER Email
        Email address for Let's Encrypt SSL certificates.

    .PARAMETER Domain
        Base domain for services (e.g., "example.com").

    .EXAMPLE
        Install-Traefik -IP "192.168.1.100" -User "admin" -Password "password123" -Email "admin@example.com" -Domain "homelab.local"

    .NOTES
        Requires plink (PuTTY) to be installed for SSH connectivity.
        Connection should already be validated before calling this function.
        Docker must be installed before running this function.
    #>

    param(
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,

        [Parameter(Mandatory=$false)]
        [string]$Email = "admin@localhost",

        [Parameter(Mandatory=$false)]
        [string]$Domain = "localhost"
    )
    
    try {
        Write-Host "`nStarting Traefik installation on $IP..." -ForegroundColor Cyan
        
        # Import Docker module
        $dockerModulePath = Join-Path $PSScriptRoot "DockerSetupDebian.psm1"
        Import-Module $dockerModulePath -Force
        
        # Ensure Docker is installed
        $dockerInstalled = Install-Docker -IP $IP -User $User -Password $Password
        
        if (-not $dockerInstalled) {
            Write-Host "Cannot install Traefik without Docker" -ForegroundColor Red
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
        
        # Check if Traefik is already running
        Write-Host "Checking for existing Traefik installation..." -ForegroundColor Cyan
        $traefikCheck = Invoke-SSHCommand "sudo docker ps -a --filter name=traefik --format '{{.Names}}'"
        
        if ($traefikCheck -match "traefik") {
            Write-Host "Traefik container already exists. Removing old container..." -ForegroundColor Yellow
            $removeResult = Invoke-SSHCommand "sudo docker rm -f traefik"
            if ($null -eq $removeResult) {
                Write-Host "Warning: Failed to remove old Traefik container" -ForegroundColor Yellow
            }
        }
        
        # Create Traefik directory structure
        Write-Host "Creating Traefik directory structure..." -ForegroundColor Cyan
        $dirResult = Invoke-SSHCommand "mkdir -p /home/$User/traefik/config"
        if ($null -eq $dirResult) {
            Write-Host "Failed to create Traefik directories" -ForegroundColor Red
            return $false
        }
        
        # Create traefik.yml configuration file
        Write-Host "Creating Traefik configuration..." -ForegroundColor Cyan
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
        
        $configResult = Invoke-SSHCommand "cat > /home/$User/traefik/traefik.yml << 'EOF'`n$traefikConfig`nEOF"
        if ($null -eq $configResult) {
            Write-Host "Failed to create Traefik configuration" -ForegroundColor Red
            return $false
        }
        
        # Create docker network for Traefik
        Write-Host "Creating Docker network for Traefik..." -ForegroundColor Cyan
        $networkCheck = Invoke-SSHCommand "sudo docker network ls --filter name=traefik-network --format '{{.Name}}'"
        
        if ($networkCheck -notmatch "traefik-network") {
            $networkResult = Invoke-SSHCommand "sudo docker network create traefik-network"
            if ($null -eq $networkResult) {
                Write-Host "Failed to create Traefik network" -ForegroundColor Red
                return $false
            }
        }
        else {
            Write-Host "Traefik network already exists" -ForegroundColor Gray
        }
        
        # Create acme.json file with correct permissions
        Write-Host "Creating SSL certificate storage..." -ForegroundColor Cyan
        $acmeResult = Invoke-SSHCommand "mkdir -p /home/$User/traefik/letsencrypt && touch /home/$User/traefik/letsencrypt/acme.json && chmod 600 /home/$User/traefik/letsencrypt/acme.json"
        if ($null -eq $acmeResult) {
            Write-Host "Failed to create acme.json file" -ForegroundColor Red
            return $false
        }
        
        # Deploy Traefik container
        Write-Host "Deploying Traefik container..." -ForegroundColor Cyan
        $traefikCommand = @"
sudo docker run -d \
  --name=traefik \
  --restart=always \
  -p 80:80 \
  -p 443:443 \
  -p 8080:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /home/$User/traefik/traefik.yml:/traefik.yml:ro \
  -v /home/$User/traefik/letsencrypt:/letsencrypt \
  --network traefik-network \
  traefik:latest
"@
        
        $traefikInstall = Invoke-SSHCommand $traefikCommand
        
        if ($null -eq $traefikInstall) {
            Write-Host "Failed to deploy Traefik" -ForegroundColor Red
            return $false
        }
        
        # Verify Traefik is running
        Start-Sleep -Seconds 3
        $verifyResult = Invoke-SSHCommand "sudo docker ps --filter name=traefik --format '{{.Status}}'"
        
        if ($verifyResult -match "Up") {
            Write-Host "`nTraefik installed successfully!" -ForegroundColor Green
            Write-Host "Traefik Dashboard: http://$IP:8080" -ForegroundColor Cyan
            Write-Host "HTTP Entry Point: http://$IP:80" -ForegroundColor Cyan
            Write-Host "HTTPS Entry Point: https://$IP:443" -ForegroundColor Cyan
            Write-Host "`nNote: Other services should be deployed with Traefik labels for automatic routing" -ForegroundColor Yellow
            return $true
        }
        else {
            Write-Host "Traefik container deployed but not running properly" -ForegroundColor Yellow
            return $false
        }
    }
    catch {
        Write-Host "Error during Traefik installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

Export-ModuleMember -Function Install-Traefik
