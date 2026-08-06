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
            # Provide a fake "running" status so the script thinks the deployment succeeded
            Mock Invoke-RemoteCommand { return "running" } -ModuleName RMSetup
            
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
            
            # Assert that mkdir string contains directories but strictly ignores files
            Assert-MockCalled Invoke-RemoteCommand -ParameterFilter { 
                $Command -match "mkdir -p" -and 
                $Command -match "/config" -and 
                $Command -match "/storage" -and 
                $Command -notmatch "data.json" -and 
                $Command -notmatch "custom.yml" 
            } -ModuleName RMSetup
        }
        
        It "Should automatically inject the systemd-resolved fix if Port 53 is detected" {
            Mock Invoke-RemoteCommand { return "running" } -ModuleName RMSetup
            
            $composeDNS = @"
services:
  dns:
    ports:
      - "53:53"
"@
            Deploy-DockerService -IP "10.0.0.1" -User "test" -Password "pass" -ServiceName "dnsapp" -ComposeContent $composeDNS -OSType "Linux" | Out-Null
            
            Assert-MockCalled Invoke-RemoteCommand -ParameterFilter {
                $Command -match "systemd-resolved" -and
                $Command -match "DNSStubListener=no"
            } -ModuleName RMSetup
        }
    }
}