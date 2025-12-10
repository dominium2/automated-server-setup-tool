BeforeAll {
    # Import the RemoteConnection module
    $modulePath = Join-Path $PSScriptRoot ".." "modules" "RemoteConnection.psm1"
    Import-Module $modulePath -Force
}

Describe "Test-SSHConnection" {
    Context "Port Accessibility Tests" {
        It "Should return false when SSH port is not accessible" {
            # Use a non-existent IP that will timeout
            $result = Test-SSHConnection -IP "192.0.2.1" -User "testuser" -Password "testpass"
            $result | Should -Be $false
        }
        
        It "Should handle invalid IP addresses gracefully" {
            $result = Test-SSHConnection -IP "999.999.999.999" -User "testuser" -Password "testpass"
            $result | Should -Be $false
        }
    }
}

Describe "Test-WinRMConnection" {
    Context "Port Accessibility Tests" {
        It "Should return false when WinRM port is not accessible" {
            # Use a non-existent IP that will timeout
            $result = Test-WinRMConnection -IP "192.0.2.1" -User "testuser" -Password "testpass"
            $result | Should -Be $false
        }
        
        It "Should handle invalid IP addresses gracefully" {
            $result = Test-WinRMConnection -IP "999.999.999.999" -User "testuser" -Password "testpass"
            $result | Should -Be $false
        }
    }
}

Describe "Test-RemoteConnection" {
    Context "Connection Flow Tests" {
        It "Should return false when ping fails" {
            # Use a non-existent IP that will not respond to ping
            $result = Test-RemoteConnection -IP "192.0.2.1" -User "testuser" -Password "testpass"
            $result | Should -Be $false
        }
        
        It "Should handle empty parameters gracefully" {
            $result = Test-RemoteConnection -IP "" -User "" -Password ""
            $result | Should -Be $false
        }
    }
    
    Context "Parameter Validation" {
        It "Should accept valid IP addresses" {
            # This test will fail on ping but should accept the parameters
            { Test-RemoteConnection -IP "192.168.1.1" -User "user" -Password "pass" } | Should -Not -Throw
        }
        
        It "Should accept valid hostnames" {
            # This test will fail on ping but should accept the parameters
            { Test-RemoteConnection -IP "localhost" -User "user" -Password "pass" } | Should -Not -Throw
        }
    }
}

Describe "Integration Tests" {
    Context "Module Export Tests" {
        It "Should export Test-RemoteConnection function" {
            Get-Command Test-RemoteConnection -Module RemoteConnection -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should export Test-SSHConnection function" {
            Get-Command Test-SSHConnection -Module RemoteConnection -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should export Test-WinRMConnection function" {
            Get-Command Test-WinRMConnection -Module RemoteConnection -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}
