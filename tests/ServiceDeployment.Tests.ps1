# ==============================================================================
# ServiceDeployment.Tests.ps1
# Pester tests for docker service deployment algorithms
# ==============================================================================

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot "..\modules\RMSetup.psm1"
    Import-Module $modulePath -Force
    Initialize-Logging -LogLevel "Debug" -LogToFile $false -LogToConsole $false | Out-Null
}

Describe "Service Deployment Algorithms" {
    
    Context "Deploy-DockerService Volume Parsing" {
        It "Should parse directories but ignore explicit files during mkdir" {
            # Mock Start-Sleep to instantly skip the 5-second waiting period
            Mock Start-Sleep { } -ModuleName RMSetup

            # Use a script-scoped variable to safely capture the command across the mock boundary
            $script:CapturedCommand = ""
            Mock Invoke-RemoteCommand { 
                if ($Command -match "mkdir -p") {
                    $script:CapturedCommand = $Command
                }
                return "running" 
            } -ModuleName RMSetup
            
            $composeWithFiles = @"
services:
  testapp:
    image: testapp:latest
    volumes:
      - ./config:/config
      - ./data.json:/app/data.json
      - ./custom.yml:/app/custom.yml
      - ./storage:/storage
"@
            
            Deploy-DockerService -IP "10.0.0.1" -User "test" -Password "pass" -ServiceName "testapp" -ComposeContent $composeWithFiles -OSType "Linux" | Out-Null
            
            # Perform asserts directly on the captured string rather than relying on Pester's ParameterFilter
            $script:CapturedCommand | Should -Match "mkdir -p"
            $script:CapturedCommand | Should -Match "/config"
            $script:CapturedCommand | Should -Match "/storage"
            $script:CapturedCommand | Should -Not -Match "data.json"
            $script:CapturedCommand | Should -Not -Match "custom.yml"
        }
        
        It "Should automatically inject the systemd-resolved fix if Port 53 is detected" {
            Mock Start-Sleep { } -ModuleName RMSetup
            
            $script:DnsFixCommand = ""
            Mock Invoke-RemoteCommand { 
                if ($Command -match "systemd-resolved") {
                    $script:DnsFixCommand = $Command
                }
                return "running" 
            } -ModuleName RMSetup
            
            $composeDNS = @"
services:
  dns:
    ports:
      - "53:53"
"@
            Deploy-DockerService -IP "10.0.0.1" -User "test" -Password "pass" -ServiceName "dnsapp" -ComposeContent $composeDNS -OSType "Linux" | Out-Null
            
            $script:DnsFixCommand | Should -Match "systemd-resolved"
            $script:DnsFixCommand | Should -Match "DNSStubListener=no"
        }
    }
}