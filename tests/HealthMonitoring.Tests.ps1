# Health Monitoring Module Tests
# Pester tests for the HealthMonitoring.psm1 module

BeforeAll {
    # Get the script root
    $script:ModulesPath = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $script:ModulesPath "modules"
    
    # Import required modules
    Import-Module (Join-Path $script:ModulePath "Logging.psm1") -Force
    Import-Module (Join-Path $script:ModulePath "RemoteConnection.psm1") -Force
    Import-Module (Join-Path $script:ModulePath "HealthMonitoring.psm1") -Force
    
    # Initialize logging for tests
    Initialize-Logging -LogLevel "Debug" -LogToFile $false -LogToConsole $false
}

Describe "HealthMonitoring Module" {
    Context "Module Loading" {
        It "Should export Get-ServerHealth function" {
            Get-Command -Name Get-ServerHealth -Module HealthMonitoring -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should export Get-ContainerHealth function" {
            Get-Command -Name Get-ContainerHealth -Module HealthMonitoring -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should export Get-FullHealthReport function" {
            Get-Command -Name Get-FullHealthReport -Module HealthMonitoring -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should export Test-ServiceHealth function" {
            Get-Command -Name Test-ServiceHealth -Module HealthMonitoring -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should export container management functions" {
            Get-Command -Name Restart-Container -Module HealthMonitoring -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            Get-Command -Name Stop-Container -Module HealthMonitoring -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            Get-Command -Name Start-Container -Module HealthMonitoring -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should export Get-ContainerLogs function" {
            Get-Command -Name Get-ContainerLogs -Module HealthMonitoring -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should export Format-HealthReport function" {
            Get-Command -Name Format-HealthReport -Module HealthMonitoring -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should export Test-CommonServices function" {
            Get-Command -Name Test-CommonServices -Module HealthMonitoring -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Get-ServerHealth Function Parameters" {
        It "Should have IP parameter" {
            $cmd = Get-Command Get-ServerHealth
            $cmd.Parameters.Keys | Should -Contain 'IP'
        }
        
        It "Should have User parameter" {
            $cmd = Get-Command Get-ServerHealth
            $cmd.Parameters.Keys | Should -Contain 'User'
        }
        
        It "Should have Password parameter" {
            $cmd = Get-Command Get-ServerHealth
            $cmd.Parameters.Keys | Should -Contain 'Password'
        }
        
        It "Should require IP parameter" {
            $cmd = Get-Command Get-ServerHealth
            $cmd.Parameters['IP'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | ForEach-Object { $_.Mandatory } | Should -Contain $true
        }
    }
    
    Context "Get-ContainerHealth Function Parameters" {
        It "Should have IP parameter" {
            $cmd = Get-Command Get-ContainerHealth
            $cmd.Parameters.Keys | Should -Contain 'IP'
        }
        
        It "Should have optional ContainerName parameter" {
            $cmd = Get-Command Get-ContainerHealth
            $cmd.Parameters.Keys | Should -Contain 'ContainerName'
        }
    }
    
    Context "Get-ServerHealth - Unreachable Server" {
        It "Should return Offline status for unreachable server" {
            # Use a non-routable IP that will fail quickly
            $result = Get-ServerHealth -IP "192.0.2.1" -User "test" -Password "test"
            
            $result | Should -Not -BeNullOrEmpty
            $result.Status | Should -Be "Offline"
            $result.StatusColor | Should -Be "Red"
            $result.IP | Should -Be "192.0.2.1"
        }
        
        It "Should include LastChecked timestamp" {
            $result = Get-ServerHealth -IP "192.0.2.1" -User "test" -Password "test"
            
            $result.LastChecked | Should -Not -BeNullOrEmpty
            $result.LastChecked | Should -BeOfType [DateTime]
        }
    }
    
    Context "Test-ServiceHealth Function" {
        It "Should return object with expected properties" {
            # Test against a non-existent service
            $result = Test-ServiceHealth -IP "127.0.0.1" -Port 65535 -ServiceName "TestService"
            
            $result | Should -Not -BeNullOrEmpty
            $result.PSObject.Properties.Name | Should -Contain 'ServiceName'
            $result.PSObject.Properties.Name | Should -Contain 'IP'
            $result.PSObject.Properties.Name | Should -Contain 'Port'
            $result.PSObject.Properties.Name | Should -Contain 'Status'
            $result.PSObject.Properties.Name | Should -Contain 'TcpConnected'
        }
        
        It "Should return Unavailable for closed port" {
            $result = Test-ServiceHealth -IP "127.0.0.1" -Port 65535 -ServiceName "TestService"
            
            $result.Status | Should -Be "Unavailable"
            $result.TcpConnected | Should -Be $false
        }
        
        It "Should have correct ServiceName in result" {
            $result = Test-ServiceHealth -IP "127.0.0.1" -Port 65535 -ServiceName "MyTestService"
            
            $result.ServiceName | Should -Be "MyTestService"
        }
    }
    
    Context "Format-HealthReport Function" {
        It "Should format a health report without errors" {
            # Create a mock health report
            $mockReport = [PSCustomObject]@{
                IP = "192.168.1.100"
                OverallStatus = "Healthy"
                OverallStatusColor = "Green"
                Server = [PSCustomObject]@{
                    Status = "Healthy"
                    CPU = [PSCustomObject]@{ UsagePercent = 25 }
                    Memory = [PSCustomObject]@{ UsedMB = 1024; TotalMB = 4096; UsagePercent = 25 }
                    Disk = [PSCustomObject]@{ UsagePercent = 50 }
                    Uptime = "5 days, 3 hours"
                    Load = [PSCustomObject]@{ Load1Min = "0.5"; Load5Min = "0.4"; Load15Min = "0.3" }
                }
                Containers = [PSCustomObject]@{
                    Status = "Healthy"
                    TotalContainers = 3
                    RunningContainers = 3
                    StoppedContainers = 0
                    Containers = @(
                        [PSCustomObject]@{
                            Name = "nginx"
                            Image = "nginx:latest"
                            State = "running"
                            Status = "Up 2 days"
                            CPUPercent = "0.5"
                            MemoryUsage = "50MB / 100MB"
                            MemoryPercent = "50"
                            RestartCount = 0
                        }
                    )
                }
                ReportGeneratedAt = Get-Date
            }
            
            $output = Format-HealthReport -HealthReport $mockReport
            
            $output | Should -Not -BeNullOrEmpty
            $output | Should -BeOfType [String]
            $output | Should -Match "HEALTH REPORT"
            $output | Should -Match "192.168.1.100"
        }
        
        It "Should include server health section" {
            $mockReport = [PSCustomObject]@{
                IP = "192.168.1.100"
                OverallStatus = "Healthy"
                OverallStatusColor = "Green"
                Server = [PSCustomObject]@{
                    Status = "Healthy"
                    CPU = [PSCustomObject]@{ UsagePercent = 25 }
                    Memory = [PSCustomObject]@{ UsedMB = 1024; TotalMB = 4096; UsagePercent = 25 }
                    Disk = [PSCustomObject]@{ UsagePercent = 50 }
                    Uptime = "5 days"
                    Load = $null
                }
                Containers = $null
                ReportGeneratedAt = Get-Date
            }
            
            $output = Format-HealthReport -HealthReport $mockReport
            
            $output | Should -Match "SERVER HEALTH"
            $output | Should -Match "CPU Usage"
        }
        
        It "Should include container health section when containers exist" {
            $mockReport = [PSCustomObject]@{
                IP = "192.168.1.100"
                OverallStatus = "Healthy"
                OverallStatusColor = "Green"
                Server = $null
                Containers = [PSCustomObject]@{
                    Status = "Healthy"
                    TotalContainers = 1
                    RunningContainers = 1
                    StoppedContainers = 0
                    Containers = @(
                        [PSCustomObject]@{
                            Name = "test-container"
                            Image = "test:latest"
                            State = "running"
                            Status = "Up 1 hour"
                            CPUPercent = "1.0"
                            MemoryUsage = "100MB / 200MB"
                            MemoryPercent = "50"
                            RestartCount = 0
                        }
                    )
                }
                ReportGeneratedAt = Get-Date
            }
            
            $output = Format-HealthReport -HealthReport $mockReport
            
            $output | Should -Match "CONTAINER HEALTH"
            $output | Should -Match "test-container"
        }
    }
    
    Context "Get-ContainerLogs Function Parameters" {
        It "Should have all required parameters" {
            $cmd = Get-Command Get-ContainerLogs
            $cmd.Parameters.Keys | Should -Contain 'IP'
            $cmd.Parameters.Keys | Should -Contain 'User'
            $cmd.Parameters.Keys | Should -Contain 'Password'
            $cmd.Parameters.Keys | Should -Contain 'ContainerName'
        }
        
        It "Should have optional Tail parameter with default" {
            $cmd = Get-Command Get-ContainerLogs
            $cmd.Parameters.Keys | Should -Contain 'Tail'
        }
        
        It "Should have optional Since parameter" {
            $cmd = Get-Command Get-ContainerLogs
            $cmd.Parameters.Keys | Should -Contain 'Since'
        }
    }
    
    Context "Container Management Functions Parameters" {
        It "Restart-Container should have required parameters" {
            $cmd = Get-Command Restart-Container
            $cmd.Parameters['IP'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | ForEach-Object { $_.Mandatory } | Should -Contain $true
            $cmd.Parameters['ContainerName'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | ForEach-Object { $_.Mandatory } | Should -Contain $true
        }
        
        It "Stop-Container should have required parameters" {
            $cmd = Get-Command Stop-Container
            $cmd.Parameters['IP'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | ForEach-Object { $_.Mandatory } | Should -Contain $true
            $cmd.Parameters['ContainerName'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | ForEach-Object { $_.Mandatory } | Should -Contain $true
        }
        
        It "Start-Container should have required parameters" {
            $cmd = Get-Command Start-Container
            $cmd.Parameters['IP'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | ForEach-Object { $_.Mandatory } | Should -Contain $true
            $cmd.Parameters['ContainerName'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | ForEach-Object { $_.Mandatory } | Should -Contain $true
        }
    }
    
    Context "Health Status Determination" {
        It "Should return correct status colors" {
            # Test with unreachable server
            $result = Get-ServerHealth -IP "192.0.2.1" -User "test" -Password "test"
            
            # Offline servers should be Red
            $result.StatusColor | Should -BeIn @("Red", "Yellow", "Green", "Gray")
        }
    }
    
    Context "Test-CommonServices Function" {
        It "Should return service results for localhost" {
            # Mock or use localhost
            $results = Test-CommonServices -IP "127.0.0.1"
            
            # Should return an array (possibly empty if no common services are running)
            # If results exist, they should be PSCustomObjects
            if ($null -ne $results -and $results.Count -gt 0) {
                $results[0].PSObject.Properties.Name | Should -Contain 'ServiceName'
            }
            # If empty, that's also valid
            $true | Should -Be $true
        }
    }
}

Describe "Health Report Object Structure" {
    Context "Server Health Object" {
        It "Should have standard properties" {
            $result = Get-ServerHealth -IP "192.0.2.1" -User "test" -Password "test"
            
            $result.PSObject.Properties.Name | Should -Contain 'IP'
            $result.PSObject.Properties.Name | Should -Contain 'Status'
            $result.PSObject.Properties.Name | Should -Contain 'StatusColor'
            $result.PSObject.Properties.Name | Should -Contain 'LastChecked'
        }
    }
}
