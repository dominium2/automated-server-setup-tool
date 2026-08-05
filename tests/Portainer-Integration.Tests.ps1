# ==============================================================================
# Portainer-Integration.Tests.ps1
# End-to-end integration test for deploying Portainer to Linux and Windows
# ==============================================================================

$modulePath = Join-Path $PSScriptRoot "..\modules\RMSetup.psm1"
Import-Module $modulePath -Force

# Initialize logging for the test session
Initialize-Logging -LogLevel "Debug" -LogToFile $false -LogToConsole $true | Out-Null

Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host "  PORTAINER DEPLOYMENT INTEGRATION TEST" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

$testTargets = @(
    @{
        OS = "Linux"
        IP = "192.168.56.11"
        User = "testuser"
        Password = "testpass123"
    },
    @{
        OS = "Windows"
        IP = "192.168.56.21"
        User = "testuser"
        Password = "testpass123"
    }
)

foreach ($target in $testTargets) {
    Write-Host "`n--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "Testing Deployment to $($target.OS) Target: $($target.IP)" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------`n" -ForegroundColor Yellow

    # Step 1: Test Connection
    Write-Host "Step 1: Testing Connection..." -ForegroundColor Cyan
    $connection = Test-RemoteConnection -IP $target.IP -User $target.User -Password $target.Password
    
    if (-not $connection) {
        Write-Host "FAILED: Could not connect to $($target.IP)" -ForegroundColor Red
        continue
    }

    # Step 2: Environment Prep (OS Specific)
    Write-Host "`nStep 2: Preparing Environment..." -ForegroundColor Cyan
    
    if ($target.OS -eq "Windows") {
        Write-Host "  Installing/Verifying WSL2..." -ForegroundColor Cyan
        $wslResult = Install-WSL2 -IP $target.IP -User $target.User -Password $target.Password -Distribution "Ubuntu" -AutoReboot
        
        if ($wslResult.NeedsReboot) {
            Write-Host "  VM is rebooting. You must run this test again after the VM comes back online." -ForegroundColor Yellow
            continue
        }
        
        if (-not $wslResult.Success -and -not $wslResult.Ready) {
            Write-Host "FAILED: WSL2 preparation failed on $($target.IP)" -ForegroundColor Red
            continue
        }
    }

    # Step 3: Install Docker
    Write-Host "`nStep 3: Ensuring Docker is Installed..." -ForegroundColor Cyan
    $dockerSuccess = Install-Docker -IP $target.IP -User $target.User -Password $target.Password
    
    if (-not $dockerSuccess) {
        Write-Host "FAILED: Docker installation failed on $($target.IP)" -ForegroundColor Red
        continue
    }

    # Step 4: Deploy Portainer
    Write-Host "`nStep 4: Deploying Portainer..." -ForegroundColor Cyan
    $portainerSuccess = Install-Portainer -IP $target.IP -User $target.User -Password $target.Password -Domain "integration.local"
    
    if ($portainerSuccess) {
        Write-Host "`n========================================================" -ForegroundColor Green
        Write-Host "  SUCCESS: Portainer deployed on $($target.OS) ($($target.IP))" -ForegroundColor Green
        Write-Host "  Access at: https://$($target.IP):9443" -ForegroundColor Green
        Write-Host "========================================================`n" -ForegroundColor Green
    } else {
        Write-Host "`n========================================================" -ForegroundColor Red
        Write-Host "  FAILED: Portainer deployment failed on $($target.OS) ($($target.IP))" -ForegroundColor Red
        Write-Host "========================================================`n" -ForegroundColor Red
    }
}