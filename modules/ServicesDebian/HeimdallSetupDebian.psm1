function Install-Heimdall {
    <#
    .SYNOPSIS
        Installs Heimdall on a Debian-based system.

    .DESCRIPTION
        This function installs Heimdall, an application dashboard for organizing your web applications,
        on a Debian-based system via SSH. It checks for existing installations and installs Heimdall if not present.

    .PARAMETER IP
        The IP address of the target Debian server.

    .PARAMETER User
        The username for SSH authentication.

    .PARAMETER Password
        The password for SSH authentication.

    .PARAMETER Domain
        Base domain for Traefik routing (e.g., "example.com"). Heimdall will be accessible at heimdall.example.com

    .EXAMPLE
        Install-Heimdall -IP "192.168.1.100" -User "admin" -Password "password123" -Domain "homelab.local"

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
        Write-Host "\nStarting Heimdall installation on $IP..." -ForegroundColor Cyan

        # Check if plink is available
        if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
            Write-Host "Error: 'plink' (PuTTY) is required for SSH connection" -ForegroundColor Red
            Write-Host "Install with: choco install putty -y" -ForegroundColor Yellow
            return $false
        }
        
        # Auto-accept SSH host key by caching it first
        Write-Host "  Auto-accepting SSH host key..." -ForegroundColor Cyan
        $null = cmd /c "echo y | plink -pw `"$Password`" $User@$IP exit 2>&1"
        
        # Function to execute remote command via SSH
        function Invoke-SSHCommand {
            param([string]$Command)
            
            $result = & plink -batch -pw $Password $User@$IP $Command 2>&1
            
            if ($LASTEXITCODE -ne 0 -and $result -match "error|fatal|failed|denied") {
                Write-Host "Command failed: $Command" -ForegroundColor Red
                Write-Host "Output: $result" -ForegroundColor Red
                return $null
            }
            
            return $result
        }

        # Create Heimdall directory structure
        Write-Host "Creating Heimdall directory structure..." -ForegroundColor Cyan
        Invoke-SSHCommand "mkdir -p /home/$User/heimdall/config" | Out-Null
        
        # Check and cleanup existing Heimdall installation
        Write-Host "Checking for existing Heimdall installation..." -ForegroundColor Cyan
        $heimdallCheck = Invoke-SSHCommand "sudo docker ps -a --filter name=heimdall --format '{{.Names}}' 2>/dev/null"
        
        if ($heimdallCheck -match "heimdall") {
            Write-Host "Removing existing Heimdall container..." -ForegroundColor Yellow
            $composeExists = Invoke-SSHCommand "test -f /home/$User/heimdall/docker-compose.yml && echo 'exists'"
            
            if ($composeExists -match "exists") {
                Invoke-SSHCommand "cd /home/$User/heimdall && sudo docker compose down" | Out-Null
            } else {
                Invoke-SSHCommand "sudo docker rm -f heimdall" | Out-Null
            }
        }
        
        # Create Docker Compose file
        Write-Host "Creating Docker Compose configuration..." -ForegroundColor Cyan
        $dockerComposeConfig = @"
services:
  heimdall:
    container_name: heimdall
    image: lscr.io/linuxserver/heimdall:latest
    restart: always
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Brussels
    volumes:
      - heimdall_config:/config
    expose:
      - 80
      - 443
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.heimdall.rule=Host('heimdall.$Domain')"
      - "traefik.http.routers.heimdall.entrypoints=websecure"
      - "traefik.http.routers.heimdall.tls.certresolver=letsencrypt"
      - "traefik.http.services.heimdall.loadbalancer.server.port=80"

volumes:
  heimdall_config:
    name: heimdall_config

networks:
  traefik-network:
    external: true
"@
        
        # Write compose file using base64 encoding to preserve formatting
        $dockerComposeConfig | Out-File -FilePath "$env:TEMP\docker-compose.yml" -Encoding UTF8 -NoNewline
        $composeContent = Get-Content "$env:TEMP\docker-compose.yml" -Raw
        $composeBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($composeContent))
        
        # Transfer the compose file to remote server
        Invoke-SSHCommand "echo '$composeBase64' | base64 -d > /home/$User/heimdall/docker-compose.yml" | Out-Null
        
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
        
        # Deploy Heimdall using Docker Compose
        Write-Host "Deploying Heimdall with Docker Compose..." -ForegroundColor Cyan
        $deployOutput = Invoke-SSHCommand "cd /home/$User/heimdall && sudo docker compose up -d 2>&1"
        
        if ($deployOutput) {
            Write-Host "Deploy output: $deployOutput" -ForegroundColor Gray
        }
        
        # Verify Heimdall is running
        Start-Sleep -Seconds 5
        $verifyResult = Invoke-SSHCommand "sudo docker ps --filter name=heimdall --format '{{.Status}}'"
        
        if ($verifyResult -match "Up") {
            Write-Host "\nHeimdall installed successfully!" -ForegroundColor Green
            Write-Host "Heimdall Web UI: https://heimdall.$Domain" -ForegroundColor Cyan
            Write-Host "Direct Access (if needed): http://$IP:80" -ForegroundColor Gray
            Write-Host "\nNote: Configure your dashboard by adding applications through the web UI" -ForegroundColor Yellow
            Write-Host "Note: Ensure DNS points heimdall.$Domain to $IP" -ForegroundColor Yellow
            return $true
        }
        else {
            Write-Host "Heimdall deployment failed" -ForegroundColor Red
            $logs = Invoke-SSHCommand "sudo docker logs heimdall 2>&1"
            if ($logs) {
                Write-Host "Container logs:" -ForegroundColor Yellow
                Write-Host $logs -ForegroundColor Gray
            }
            return $false
        }
    }
    catch {
        Write-Host "Error during Heimdall installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

Export-ModuleMember -Function Install-Heimdall
