function Install-AdGuard {
    <#
    .SYNOPSIS
        Installs AdGuard Home on a Debian-based system.

    .DESCRIPTION
        This function installs AdGuard Home, a network-wide ad and tracker blocking DNS server, on a Debian-based system
        via SSH. It checks for existing installations and installs AdGuard Home if not present.

    .PARAMETER IP
        The IP address of the target Debian server.

    .PARAMETER User
        The username for SSH authentication.

    .PARAMETER Password
        The password for SSH authentication.

    .PARAMETER Domain
        Base domain for Traefik routing (e.g., "example.com"). AdGuard will be accessible at adguard.example.com

    .EXAMPLE
        Install-AdGuard -IP "192.168.1.100" -User "admin" -Password "password123" -Domain "homelab.local"

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
        Write-Host "`nStarting AdGuard Home installation on $IP..." -ForegroundColor Cyan

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

        # Create AdGuard directory structure
        Write-Host "Creating AdGuard Home directory structure..." -ForegroundColor Cyan
        Invoke-SSHCommand "mkdir -p /home/$User/adguard/work /home/$User/adguard/conf" | Out-Null
        
        # Check and cleanup existing AdGuard installation
        Write-Host "Checking for existing AdGuard Home installation..." -ForegroundColor Cyan
        $adguardCheck = Invoke-SSHCommand "sudo docker ps -a --filter name=adguard --format '{{.Names}}' 2>/dev/null"
        
        if ($adguardCheck -match "adguard") {
            Write-Host "Removing existing AdGuard Home container..." -ForegroundColor Yellow
            $composeExists = Invoke-SSHCommand "test -f /home/$User/adguard/docker-compose.yml && echo 'exists'"
            
            if ($composeExists -match "exists") {
                Invoke-SSHCommand "cd /home/$User/adguard && sudo docker compose down" | Out-Null
            } else {
                Invoke-SSHCommand "sudo docker rm -f adguard" | Out-Null
            }
        }
        
        # Create Docker Compose file
        Write-Host "Creating Docker Compose configuration..." -ForegroundColor Cyan
        $dockerComposeConfig = @"
services:
  adguard:
    container_name: adguard
    image: adguard/adguardhome:latest
    restart: always
    volumes:
      - ./work:/opt/adguardhome/work
      - ./conf:/opt/adguardhome/conf
    expose:
      - 80
      - 3000
    ports:
      - "53:53/tcp"
      - "53:53/udp"
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.adguard.rule=Host('adguard.$Domain')"
      - "traefik.http.routers.adguard.entrypoints=websecure"
      - "traefik.http.routers.adguard.tls.certresolver=letsencrypt"
      - "traefik.http.services.adguard.loadbalancer.server.port=80"

networks:
  traefik-network:
    external: true
"@
        
        # Write compose file using base64 encoding to preserve formatting
        $dockerComposeConfig | Out-File -FilePath "$env:TEMP\docker-compose.yml" -Encoding UTF8 -NoNewline
        $composeContent = Get-Content "$env:TEMP\docker-compose.yml" -Raw
        $composeBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($composeContent))
        
        # Transfer the compose file to remote server
        Invoke-SSHCommand "echo '$composeBase64' | base64 -d > /home/$User/adguard/docker-compose.yml" | Out-Null
        
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
        
        # Deploy AdGuard Home using Docker Compose
        Write-Host "Deploying AdGuard Home with Docker Compose..." -ForegroundColor Cyan
        $deployOutput = Invoke-SSHCommand "cd /home/$User/adguard && sudo docker compose up -d 2>&1"
        
        if ($deployOutput) {
            Write-Host "Deploy output: $deployOutput" -ForegroundColor Gray
        }
        
        # Verify AdGuard is running
        Start-Sleep -Seconds 5
        $verifyResult = Invoke-SSHCommand "sudo docker ps --filter name=adguard --format '{{.Status}}'"
        
        if ($verifyResult -match "Up") {
            Write-Host "`nAdGuard Home installed successfully!" -ForegroundColor Green
            Write-Host "AdGuard Web UI: https://adguard.$Domain" -ForegroundColor Cyan
            Write-Host "Direct Access (if needed): http://$IP:3000" -ForegroundColor Gray
            Write-Host "DNS Server: $IP:53" -ForegroundColor Cyan
            Write-Host "`nNote: Complete the initial setup wizard on first access" -ForegroundColor Yellow
            Write-Host "Note: Ensure DNS points adguard.$Domain to $IP" -ForegroundColor Yellow
            Write-Host "Note: Configure your devices to use $IP as DNS server" -ForegroundColor Yellow
            return $true
        } else {
            Write-Host "AdGuard Home deployment failed" -ForegroundColor Red
            $logs = Invoke-SSHCommand "sudo docker logs adguard 2>&1"
            if ($logs) {
                Write-Host "Container logs:" -ForegroundColor Yellow
                Write-Host $logs -ForegroundColor Gray
            }
            return $false
        }
    }
    catch {
        Write-Host "Error during AdGuard Home installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

Export-ModuleMember -Function Install-AdGuard