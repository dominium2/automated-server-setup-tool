function Install-Portainer {
    <#
    .SYNOPSIS
        Installs Portainer on a Debian-based system.

    .DESCRIPTION
        This function installs Portainer, a lightweight management UI for Docker, on a Debian-based system
        via SSH. It checks for existing installations and installs Portainer if not present.

    .PARAMETER IP
        The IP address of the target Debian server.

    .PARAMETER User
        The username for SSH authentication.

    .PARAMETER Password
        The password for SSH authentication.

    .PARAMETER Domain
        Base domain for Traefik routing (e.g., "example.com"). Portainer will be accessible at portainer.example.com

    .EXAMPLE
        Install-Portainer -IP "192.168.1.100" -User "admin" -Password "password123" -Domain "homelab.local"

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
        Write-Host "`nStarting Portainer installation on $IP..." -ForegroundColor Cyan

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

        # Create Portainer directory structure
        Write-Host "Creating Portainer directory structure..." -ForegroundColor Cyan
        Invoke-SSHCommand "mkdir -p /home/$User/portainer" | Out-Null
        
        # Check and cleanup existing Portainer installation
        Write-Host "Checking for existing Portainer installation..." -ForegroundColor Cyan
        $portainerCheck = Invoke-SSHCommand "sudo docker ps -a --filter name=portainer --format '{{.Names}}' 2>/dev/null"
        
        if ($portainerCheck -match "portainer") {
            Write-Host "Removing existing Portainer container..." -ForegroundColor Yellow
            $composeExists = Invoke-SSHCommand "test -f /home/$User/portainer/docker-compose.yml && echo 'exists'"
            
            if ($composeExists -match "exists") {
                Invoke-SSHCommand "cd /home/$User/portainer && sudo docker compose down" | Out-Null
            } else {
                Invoke-SSHCommand "sudo docker rm -f portainer" | Out-Null
            }
        }
        
        # Create Docker Compose file
        Write-Host "Creating Docker Compose configuration..." -ForegroundColor Cyan
        $dockerComposeConfig = @"
services:
  portainer:
    container_name: portainer
    image: portainer/portainer-ce:lts
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    expose:
      - 9443
      - 8000
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host(\`portainer.$Domain\`)"
      - "traefik.http.routers.portainer.entrypoints=websecure"
      - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"
      - "traefik.http.services.portainer.loadbalancer.server.port=9443"
      - "traefik.http.services.portainer.loadbalancer.server.scheme=https"

volumes:
  portainer_data:
    name: portainer_data

networks:
  traefik-network:
    external: true
"@
        
        # Write compose file using base64 encoding to preserve formatting
        $dockerComposeConfig | Out-File -FilePath "$env:TEMP\docker-compose.yml" -Encoding UTF8 -NoNewline
        $composeContent = Get-Content "$env:TEMP\docker-compose.yml" -Raw
        $composeBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($composeContent))
        # Verify Traefik network exists
        Write-Host "Verifying Traefik network..." -ForegroundColor Cyan
        $networkCheck = Invoke-SSHCommand "sudo docker network ls --filter name=traefik-network --format '{{.Name}}' 2>/dev/null"
        
        if (-not ($networkCheck -match "traefik-network")) {
            Write-Host "Warning: Traefik network not found. Creating it..." -ForegroundColor Yellow
            $createNetwork = Invoke-SSHCommand "sudo docker network create traefik-network 2>&1 || true"
            if ($createNetwork -match "traefik-network|already exists") {
                Write-Host "Traefik network ready" -ForegroundColor Gray
            }
        } else {
            Write-Host "Traefik network exists" -ForegroundColor Gray
        }
        else {
            Write-Host "Network creation output: $createNetwork" -ForegroundColor Gray
        }
        
        # Deploy Portainer using Docker Compose
        Write-Host "Deploying Portainer with Docker Compose..." -ForegroundColor Cyan
        $deployOutput = Invoke-SSHCommand "cd /home/$User/portainer && sudo docker compose up -d 2>&1"
        
        if ($deployOutput) {
            Write-Host "Deploy output: $deployOutput" -ForegroundColor Gray
        }
        
        # Verify Portainer is running
        Start-Sleep -Seconds 5
        $verifyResult = Invoke-SSHCommand "sudo docker ps --filter name=portainer --format '{{.Status}}'"
        
        if ($verifyResult -match "Up") {
            Write-Host "`nPortainer installed successfully!" -ForegroundColor Green
            Write-Host "Portainer Web UI: https://portainer.$Domain" -ForegroundColor Cyan
            Write-Host "Direct Access (if needed): https://$IP:9443" -ForegroundColor Gray
            Write-Host "`nNote: You will need to create an admin account on first login" -ForegroundColor Yellow
            Write-Host "Note: Ensure DNS points portainer.$Domain to $IP" -ForegroundColor Yellow
            return $true
        }
        else {
            Write-Host "Portainer deployment failed" -ForegroundColor Red
            $logs = Invoke-SSHCommand "sudo docker logs portainer 2>&1"
            if ($logs) {
                Write-Host "Container logs:" -ForegroundColor Yellow
                Write-Host $logs -ForegroundColor Gray
            }
            return $false
        }
    }
    catch {
        Write-Host "Error during Portainer installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

Export-ModuleMember -Function Install-Portainer
