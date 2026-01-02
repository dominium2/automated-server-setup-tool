function Install-N8N {
    <#
    .SYNOPSIS
        Installs n8n on a Debian-based system.

    .DESCRIPTION
        This function installs n8n, a workflow automation tool, on a Debian-based system
        via SSH. It checks for existing installations and installs n8n if not present.

    .PARAMETER IP
        The IP address of the target Debian server.

    .PARAMETER User
        The username for SSH authentication.

    .PARAMETER Password
        The password for SSH authentication.

    .PARAMETER Domain
        Base domain for Traefik routing (e.g., "example.com"). n8n will be accessible at n8n.example.com

    .EXAMPLE
        Install-N8N -IP "192.168.1.100" -User "admin" -Password "password123" -Domain "homelab.local"

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
        Write-Host "`nStarting n8n installation on $IP..." -ForegroundColor Cyan

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

        # Create n8n directory structure
        Write-Host "Creating n8n directory structure..." -ForegroundColor Cyan
        Invoke-SSHCommand "mkdir -p /home/$User/n8n/data" | Out-Null
        
        # Check and cleanup existing n8n installation
        Write-Host "Checking for existing n8n installation..." -ForegroundColor Cyan
        $n8nCheck = Invoke-SSHCommand "sudo docker ps -a --filter name=n8n --format '{{.Names}}' 2>/dev/null"
        
        if ($n8nCheck -match "n8n") {
            Write-Host "Removing existing n8n container..." -ForegroundColor Yellow
            $composeExists = Invoke-SSHCommand "test -f /home/$User/n8n/docker-compose.yml && echo 'exists'"
            
            if ($composeExists -match "exists") {
                Invoke-SSHCommand "cd /home/$User/n8n && sudo docker compose down" | Out-Null
            } else {
                Invoke-SSHCommand "sudo docker rm -f n8n" | Out-Null
            }
        }
        
        # Create Docker Compose file
        Write-Host "Creating Docker Compose configuration..." -ForegroundColor Cyan
        $dockerComposeConfig = @"
services:
  n8n:
    container_name: n8n
    image: n8nio/n8n:latest
    restart: always
    environment:
      - N8N_HOST=n8n.$Domain
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://n8n.$Domain
      - GENERIC_TIMEZONE=Europe/Brussels
    volumes:
      - ./data:/home/node/.n8n
    expose:
      - 5678
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host('n8n.$Domain')"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"

networks:
  traefik-network:
    external: true
"@
        
        # Write compose file using base64 encoding to preserve formatting
        $dockerComposeConfig | Out-File -FilePath "$env:TEMP\docker-compose.yml" -Encoding UTF8 -NoNewline
        $composeContent = Get-Content "$env:TEMP\docker-compose.yml" -Raw
        $composeBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($composeContent))
        
        # Transfer the compose file to remote server
        Invoke-SSHCommand "echo '$composeBase64' | base64 -d > /home/$User/n8n/docker-compose.yml" | Out-Null
        
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
        
        # Deploy n8n using Docker Compose
        Write-Host "Deploying n8n with Docker Compose..." -ForegroundColor Cyan
        $deployOutput = Invoke-SSHCommand "cd /home/$User/n8n && sudo docker compose up -d 2>&1"
        
        if ($deployOutput) {
            Write-Host "Deploy output: $deployOutput" -ForegroundColor Gray
        }
        
        # Verify n8n is running
        Start-Sleep -Seconds 5
        $verifyResult = Invoke-SSHCommand "sudo docker ps --filter name=n8n --format '{{.Status}}'"
        
        if ($verifyResult -match "Up") {
            Write-Host "`nn8n installed successfully!" -ForegroundColor Green
            Write-Host "n8n Web UI: https://n8n.$Domain" -ForegroundColor Cyan
            Write-Host "Direct Access (if needed): http://$IP:5678" -ForegroundColor Gray
            Write-Host "`nNote: Complete the initial setup wizard on first access" -ForegroundColor Yellow
            Write-Host "Note: Ensure DNS points n8n.$Domain to $IP" -ForegroundColor Yellow
            return $true
        } else {
            Write-Host "n8n deployment failed" -ForegroundColor Red
            $logs = Invoke-SSHCommand "sudo docker logs n8n 2>&1"
            if ($logs) {
                Write-Host "Container logs:" -ForegroundColor Yellow
                Write-Host $logs -ForegroundColor Gray
            }
            return $false
        }
    }
    catch {
        Write-Host "Error during n8n installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

Export-ModuleMember -Function Install-N8N