# ==============================================================================
# HealthMonitoring.Tests.ps1
# Pester tests for server and container health parsing
# ==============================================================================

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot "..\modules\RMSetup.psm1"
    Import-Module $modulePath -Force
    Initialize-Logging -LogLevel "Debug" -LogToFile $false -LogToConsole $false | Out-Null
}

Describe "Health Monitoring Data Parsing" {
    
    Context "Get-LinuxServerHealth Parser" {
        It "Should parse bash output correctly into a Health Object" {
            Mock Invoke-RemoteCommand {
                return @"
===CPU===
12.5
===MEMORY===
2048.0 8192.0 25.0
===DISK===
45.5
===UPTIME===
up 2 days, 4 hours
===LOAD===
0.15 0.10 0.05
"@
            } -ModuleName RMSetup
            
            $health = Get-LinuxServerHealth -IP "10.0.0.5" -User "root" -Password "pass" -OSType "Linux"
            
            $health.Status | Should -Be "Healthy"
            $health.CPU.UsagePercent | Should -Be 12.5
            $health.Memory.UsedMB | Should -Be 2048.0
            $health.Memory.TotalMB | Should -Be 8192.0
            $health.Memory.UsagePercent | Should -Be 25.0
            $health.Disk.UsagePercent | Should -Be 45.5
            $health.Uptime | Should -Be "2 days, 4 hours"
            $health.Load.Load1Min | Should -Be "0.15"
        }

        It "Should flag Status as Critical if CPU is over 90%" {
            Mock Invoke-RemoteCommand {
                return @"
===CPU===
95.0
===MEMORY===
2048.0 8192.0 25.0
===DISK===
45.5
"@
            } -ModuleName RMSetup
            
            $health = Get-LinuxServerHealth -IP "10.0.0.5" -User "root" -Password "pass" -OSType "Linux"
            $health.Status | Should -Be "Critical"
            $health.StatusColor | Should -Be "Red"
        }
    }
    
    Context "Get-ContainerHealth Batched Parser" {
        It "Should join multiline arrays and successfully split into containers" {
            Mock Invoke-RemoteCommand {
                # Returning an array of strings exactly as plink/wsl does
                return @(
                    "abc123def456|adguard|adguard/adguardhome:latest|Up 2 days|0.0.0.0:53->53/tcp|running",
                    "===INSPECT===",
                    "abc123def456|healthy|0",
                    "===STATS===",
                    "abc123def456|0.15%|50MiB|2.5%"
                )
            } -ModuleName RMSetup
            
            $health = Get-ContainerHealth -IP "10.0.0.5" -User "test" -Password "pass" -OSType "Linux"
            
            $health.TotalContainers | Should -Be 1
            $health.RunningContainers | Should -Be 1
            $health.Containers[0].Name | Should -Be "adguard"
            $health.Containers[0].HealthCheck | Should -Be "healthy"
            $health.Containers[0].CPUPercent | Should -Be "0.15"
            $health.Containers[0].StatusColor | Should -Be "Green"
        }
    }
}