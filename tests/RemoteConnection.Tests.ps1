# ==============================================================================
# RemoteConnection.Tests.ps1
# Pester tests for OS detection and connection routing
# ==============================================================================

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot "..\modules\RMSetup.psm1"
    Import-Module $modulePath -Force
    Initialize-Logging -LogLevel "Debug" -LogToFile $false -LogToConsole $false | Out-Null
}

Describe "Connection Configuration & OS Detection" {
    Context "Set-ConnectionConfig" {
        It "Should correctly update script-scoped port variables" {
            # Call the exported function from the outside
            Set-ConnectionConfig -SSHPort 2222 -WinRMPort 5986 -EnableSSH $true -EnableWinRM $false
            
            # Step INSIDE the module to verify its private variables updated
            InModuleScope "RMSetup" {
                $script:SSHPort | Should -Be 2222
                $script:WinRMPort | Should -Be 5986
                $script:EnableSSH | Should -Be $true
                $script:EnableWinRM | Should -Be $false
            }
            
            # Reset to defaults for the next tests
            Set-ConnectionConfig -SSHPort 22 -WinRMPort 5985 -EnableSSH $true -EnableWinRM $true
        }
    }

    Context "Get-TargetOS Logic" {
        It "Should return 'Windows' when WinRM port is open" {
            InModuleScope "RMSetup" {
                # Mocking inside the module scope ensures 100% interception
                Mock Test-NetConnection { return [PSCustomObject]@{ TcpTestSucceeded = ($Port -eq 5985) } }
                Mock Test-Connection { return $null }
                
                $os = Get-TargetOS -IP "192.168.1.100"
                $os | Should -Be "Windows"
                
                Assert-MockCalled Test-NetConnection -Times 1 -ParameterFilter { $Port -eq 5985 }
            }
        }

        It "Should return 'Linux' when WinRM is closed but SSH is open" {
            InModuleScope "RMSetup" {
                Mock Test-NetConnection { return [PSCustomObject]@{ TcpTestSucceeded = ($Port -eq 22) } }
                Mock Test-Connection { return $null }
                
                $os = Get-TargetOS -IP "192.168.1.100"
                $os | Should -Be "Linux"
            }
        }
        
        It "Should return `$null if standard ports are closed and Ping fallback fails" {
            InModuleScope "RMSetup" {
                Mock Test-NetConnection { return [PSCustomObject]@{ TcpTestSucceeded = $false } }
                Mock Test-Connection { return $null }
                
                $os = Get-TargetOS -IP "192.168.1.200"
                $os | Should -BeNullOrEmpty
            }
        }
    }
}