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
            
            if ($LASTEXITCODE -ne 0 -and $result -match "error|fatal|failed|denied") {
                Write-Host "Command failed: $Command" -ForegroundColor Red
                Write-Host "Output: $result" -ForegroundColor Red
                return $null
            }
            
            return $result
        }
        
        # Create Traefik directory structure
        Write-Host "Creating Traefik directory structure..." -ForegroundColor Cyan
        Invoke-SSHCommand "mkdir -p /home/$User/traefik/letsencrypt" | Out-Null
        
        # Check and cleanup existing Traefik installation
        Write-Host "Checking for existing Traefik installation..." -ForegroundColor Cyan
        $traefikCheck = Invoke-SSHCommand "sudo docker ps -a --filter name=traefik --format '{{.Names}}' 2>/dev/null"
        
        if ($traefikCheck -match "traefik") {
            Write-Host "Removing existing Traefik container..." -ForegroundColor Yellow
            $composeExists = Invoke-SSHCommand "test -f /home/$User/traefik/docker-compose.yml && echo 'exists'"
            
            if ($composeExists -match "exists") {
                Invoke-SSHCommand "cd /home/$User/traefik && sudo docker compose down" | Out-Null
            } else {
                Invoke-SSHCommand "sudo docker rm -f traefik" | Out-Null
            }
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
        
        # Write config file using tee command
        $traefikConfig | Out-File -FilePath "$env:TEMP\traefik.yml" -Encoding UTF8 -NoNewline
        $configContent = Get-Content "$env:TEMP\traefik.yml" -Raw
        $configBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($configContent))
        Invoke-SSHCommand "echo '$configBase64' | base64 -d > /home/$User/traefik/traefik.yml" | Out-Null
        Remove-Item "$env:TEMP\traefik.yml" -ErrorAction SilentlyContinue
        
        # Create Docker Compose file
        Write-Host "Creating Docker Compose configuration..." -ForegroundColor Cyan
        $dockerComposeConfig = @"
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
        
        # Write compose file using base64 encoding to preserve formatting
        $dockerComposeConfig | Out-File -FilePath "$env:TEMP\docker-compose.yml" -Encoding UTF8 -NoNewline
        $composeContent = Get-Content "$env:TEMP\docker-compose.yml" -Raw
        $composeBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($composeContent))
        Invoke-SSHCommand "echo '$composeBase64' | base64 -d > /home/$User/traefik/docker-compose.yml" | Out-Null
        Remove-Item "$env:TEMP\docker-compose.yml" -ErrorAction SilentlyContinue
        
        # Create docker network for Traefik (must exist before docker compose up)
        Write-Host "Creating Docker network for Traefik..." -ForegroundColor Cyan
        $createNetwork = Invoke-SSHCommand "sudo docker network create traefik-network 2>&1 || true"
        
        if ($createNetwork -match "already exists") {
            Write-Host "Traefik network already exists" -ForegroundColor Gray
        }
        elseif ($createNetwork -match "traefik-network") {
            Write-Host "Traefik network created" -ForegroundColor Gray
        }
        else {
            Write-Host "Network creation output: $createNetwork" -ForegroundColor Gray
        }
        
        # Create acme.json file with correct permissions
        Write-Host "Creating SSL certificate storage..." -ForegroundColor Cyan
        Invoke-SSHCommand "touch /home/$User/traefik/letsencrypt/acme.json && chmod 600 /home/$User/traefik/letsencrypt/acme.json" | Out-Null
        
        # Deploy Traefik using Docker Compose
        Write-Host "Deploying Traefik with Docker Compose..." -ForegroundColor Cyan
        $deployOutput = Invoke-SSHCommand "cd /home/$User/traefik && sudo docker compose up -d 2>&1"
        
        if ($deployOutput) {
            Write-Host "Deploy output: $deployOutput" -ForegroundColor Gray
        }
        
        # Verify Traefik is running
        Start-Sleep -Seconds 5
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
            Write-Host "Traefik deployment failed" -ForegroundColor Red
            $logs = Invoke-SSHCommand "sudo docker logs traefik 2>&1"
            if ($logs) {
                Write-Host "Container logs:" -ForegroundColor Yellow
                Write-Host $logs -ForegroundColor Gray
            }
            return $false
        }
    }
    catch {
        Write-Host "Error during Traefik installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

Export-ModuleMember -Function Install-Traefik
