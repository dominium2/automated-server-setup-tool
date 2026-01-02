# Test script for remote connections to VMs
# This script tests the RemoteConnection module with both Linux and Windows VMs

# Import the RemoteConnection module
$modulePath = Join-Path $PSScriptRoot "..\modules\RemoteConnection.psm1"
Import-Module $modulePath -Force

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Remote Connection Test Script" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Define test machines
$testMachines = @(
    @{
        Name = "Linux Server 1"
        IP = "192.168.56.11"
        User = "testuser"
        Password = "testpass123"
        ExpectedOS = "Linux"
    },
    @{
        Name = "Linux Server 2"
        IP = "192.168.56.12"
        User = "testuser"
        Password = "testpass123"
        ExpectedOS = "Linux"
    },
    @{
        Name = "Windows Server 1"
        IP = "192.168.56.21"
        User = "testuser"
        Password = "testpass123"
        ExpectedOS = "Windows"
    },
    @{
        Name = "Windows Server 2"
        IP = "192.168.56.22"
        User = "testuser"
        Password = "testpass123"
        ExpectedOS = "Windows"
    }
)

# Test results tracking
$results = @()

# Test each machine
foreach ($machine in $testMachines) {
    Write-Host "`n========================================" -ForegroundColor Yellow
    Write-Host "Testing: $($machine.Name)" -ForegroundColor Yellow
    Write-Host "IP: $($machine.IP)" -ForegroundColor Yellow
    Write-Host "Expected OS: $($machine.ExpectedOS)" -ForegroundColor Yellow
    Write-Host "========================================`n" -ForegroundColor Yellow
    
    # Test the remote connection
    $success = Test-RemoteConnection -IP $machine.IP -User $machine.User -Password $machine.Password
    
    # Store result
    $results += [PSCustomObject]@{
        Name = $machine.Name
        IP = $machine.IP
        ExpectedOS = $machine.ExpectedOS
        Success = $success
    }
    
    # Add a separator
    Write-Host "`n" -NoNewline
    Start-Sleep -Seconds 2
}

# Display summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "TEST SUMMARY" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$results | ForEach-Object {
    $color = if ($_.Success) { "Green" } else { "Red" }
    $status = if ($_.Success) { "SUCCESS" } else { "FAILED" }
    
    Write-Host "$($_.Name) ($($_.IP)) - $($_.ExpectedOS): " -NoNewline
    Write-Host $status -ForegroundColor $color
}

# Calculate success rate
$successCount = ($results | Where-Object { $_.Success }).Count
$totalCount = $results.Count
$successRate = [math]::Round(($successCount / $totalCount) * 100, 2)

Write-Host "`nTotal Tests: $totalCount" -ForegroundColor Cyan
Write-Host "Successful: $successCount" -ForegroundColor Green
Write-Host "Failed: $($totalCount - $successCount)" -ForegroundColor Red
Write-Host "Success Rate: $successRate%" -ForegroundColor $(if ($successRate -eq 100) { "Green" } else { "Yellow" })

Write-Host "`n========================================`n" -ForegroundColor Cyan
