function Install-Crafty {
    <#
    .SYNOPSIS
        Installs Crafty Controller on a Debian-based system.

    .DESCRIPTION
        This function installs Crafty Controller, a powerful and easy-to-use Minecraft server management panel, on a Debian-based system
        via SSH. It checks for existing installations and installs Crafty Controller if not present.

    .PARAMETER IP
        The IP address of the target Debian server.

    .PARAMETER User
        The username for SSH authentication.

    .PARAMETER Password
        The password for SSH authentication.

    .PARAMETER Domain
        Base domain for Traefik routing (e.g., "example.com"). Crafty will be accessible at crafty.example.com

    .EXAMPLE
        Install-Crafty -IP "192.168.1.100" -User "admin" -Password "password123" -Domain "homelab.local"

    .NOTES
        Requires Traefik to be installed first for reverse proxy functionality.
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
        [string]$Domain = "localhost"
    )

    try {
        Write-Host "`nStarting Crafty Controller installation on $IP..." -ForegroundColor Cyan

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

        # Create Crafty directory structure
        Write-Host "Creating Crafty Controller directory structure..." -ForegroundColor Cyan
        Invoke-SSHCommand "mkdir -p /home/$User/crafty/backups /home/$User/crafty/logs /home/$User/crafty/servers /home/$User/crafty/config" | Out-Null
        
        # Check and cleanup existing Crafty installation
        Write-Host "Checking for existing Crafty Controller installation..." -ForegroundColor Cyan
        $craftyCheck = Invoke-SSHCommand "sudo docker ps -a --filter name=crafty --format '{{.Names}}' 2>/dev/null"
        
        if ($craftyCheck -match "crafty") {
            Write-Host "Removing existing Crafty Controller container..." -ForegroundColor Yellow
            $composeExists = Invoke-SSHCommand "test -f /home/$User/crafty/docker-compose.yml && echo 'exists'"
            
            if ($composeExists -match "exists") {
                Invoke-SSHCommand "cd /home/$User/crafty && sudo docker compose down" | Out-Null
            } else {
                Invoke-SSHCommand "sudo docker rm -f crafty" | Out-Null
            }
        }
        
        # Create Docker Compose file
        Write-Host "Creating Docker Compose configuration..." -ForegroundColor Cyan
        $dockerComposeConfig = @"
services:
  crafty:
    container_name: crafty
    image: registry.gitlab.com/crafty-controller/crafty-4:latest
    restart: always
    environment:
      - TZ=Etc/UTC
    volumes:
      - ./backups:/crafty/backups
      - ./logs:/crafty/logs
      - ./servers:/crafty/servers
      - ./config:/crafty/app/config
    expose:
      - 8000
    ports:
      - "25565-25575:25565-25575"
      - "19132-19142:19132-19142/udp"
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.crafty.rule=Host('crafty.$Domain')"
      - "traefik.http.routers.crafty.entrypoints=websecure"
      - "traefik.http.routers.crafty.tls.certresolver=letsencrypt"
      - "traefik.http.services.crafty.loadbalancer.server.port=8000"

networks:
  traefik-network:
    external: true
"@
        
        # Write compose file using base64 encoding to preserve formatting
        $dockerComposeConfig | Out-File -FilePath "$env:TEMP\docker-compose.yml" -Encoding UTF8 -NoNewline
        $composeContent = Get-Content "$env:TEMP\docker-compose.yml" -Raw
        $composeBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($composeContent))
        
        # Transfer the compose file to remote server
        Invoke-SSHCommand "echo '$composeBase64' | base64 -d > /home/$User/crafty/docker-compose.yml" | Out-Null
        
        # Verify Traefik network exists
        Write-Host "Verifying Traefik network..." -ForegroundColor Cyan
        $networkCheck = Invoke-SSHCommand "sudo docker network ls --filter name=traefik-network --format '{{.Name}}' 2>/dev/null"
        
        if (-not ($networkCheck -match "traefik-network")) {
            Write-Host "Warning: Traefik network not found. Creating it..." -ForegroundColor Yellow
            $createNetwork = Invoke-SSHCommand "sudo docker network create traefik-network 2>&1 || true"
            if ($createNetwork -match "traefik-network|already exists") {
                Write-Host "Traefik network ready" -ForegroundColor Gray
            } else {
                Write-Host "Network creation output: $createNetwork" -ForegroundColor Gray
            }
        } else {
            Write-Host "Traefik network exists" -ForegroundColor Gray
        }
        
        # Deploy Crafty Controller using Docker Compose
        Write-Host "Deploying Crafty Controller with Docker Compose..." -ForegroundColor Cyan
        $deployOutput = Invoke-SSHCommand "cd /home/$User/crafty && sudo docker compose up -d 2>&1"
        
        if ($deployOutput) {
            Write-Host "Deploy output: $deployOutput" -ForegroundColor Gray
        }
        
        # Verify Crafty is running
        Start-Sleep -Seconds 5
        $verifyResult = Invoke-SSHCommand "sudo docker ps --filter name=crafty --format '{{.Status}}'"
        
        if ($verifyResult -match "Up") {
            Write-Host "`nCrafty Controller installed successfully!" -ForegroundColor Green
            Write-Host "Crafty Web UI: https://crafty.$Domain" -ForegroundColor Cyan
            Write-Host "Direct Access (if needed): http://$IP:8000" -ForegroundColor Gray
            Write-Host "Minecraft Servers: Ports 25565-25575 (Java) and 19132-19142 (Bedrock)" -ForegroundColor Cyan
            Write-Host "`nNote: Complete the initial setup wizard on first access" -ForegroundColor Yellow
            Write-Host "Note: Ensure DNS points crafty.$Domain to $IP" -ForegroundColor Yellow
            Write-Host "Note: Default credentials will be shown in container logs on first run" -ForegroundColor Yellow
            
            # Get initial credentials from logs
            Write-Host "`nFetching initial credentials..." -ForegroundColor Cyan
            Start-Sleep -Seconds 3
            $logs = Invoke-SSHCommand "sudo docker logs crafty 2>&1 | grep -A 5 'username\|password'"
            if ($logs) {
                Write-Host "Initial Credentials:" -ForegroundColor Green
                Write-Host $logs -ForegroundColor Gray
            }
            return $true
        } else {
            Write-Host "Crafty Controller deployment failed" -ForegroundColor Red
            $logs = Invoke-SSHCommand "sudo docker logs crafty 2>&1"
            if ($logs) {
                Write-Host "Container logs:" -ForegroundColor Yellow
                Write-Host $logs -ForegroundColor Gray
            }
            return $false
        }
    }
    catch {
        Write-Host "Error during Crafty Controller installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

Export-ModuleMember -Function Install-Crafty