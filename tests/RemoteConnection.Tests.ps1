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
            Set-ConnectionConfig -SSHPort 2222 -WinRMPort 5986 -EnableSSH $true -EnableWinRM $false
            
            InModuleScope "RMSetup" {
                $script:SSHPort | Should -Be 2222
                $script:WinRMPort | Should -Be 5986
                $script:EnableSSH | Should -Be $true
                $script:EnableWinRM | Should -Be $false
            }
            
            Set-ConnectionConfig -SSHPort 22 -WinRMPort 5985 -EnableSSH $true -EnableWinRM $true
        }
    }

    Context "Get-TargetOS Logic" {
        It "Should return 'Windows' when WinRM port is open" {
            # Use explicit ParameterFilters to guarantee the mock binds correctly on GitHub Actions
            Mock Test-NetConnection { return [PSCustomObject]@{ TcpTestSucceeded = $true } } -ParameterFilter { $Port -eq 5985 } -ModuleName RMSetup
            Mock Test-Connection { return $null } -ModuleName RMSetup
            
            $os = Get-TargetOS -IP "192.168.1.100"
            $os | Should -Be "Windows"
        }

        It "Should return 'Linux' when WinRM is closed but SSH is open" {
            Mock Test-NetConnection { return [PSCustomObject]@{ TcpTestSucceeded = $false } } -ParameterFilter { $Port -eq 5985 } -ModuleName RMSetup
            Mock Test-NetConnection { return [PSCustomObject]@{ TcpTestSucceeded = $true } } -ParameterFilter { $Port -eq 22 } -ModuleName RMSetup
            Mock Test-Connection { return $null } -ModuleName RMSetup
            
            $os = Get-TargetOS -IP "192.168.1.100"
            $os | Should -Be "Linux"
        }
        
        It "Should return `$null if standard ports are closed and Ping fallback fails" {
            Mock Test-NetConnection { return [PSCustomObject]@{ TcpTestSucceeded = $false } } -ModuleName RMSetup
            Mock Test-Connection { return $null } -ModuleName RMSetup
            
            $os = Get-TargetOS -IP "192.168.1.200"
            $os | Should -BeNullOrEmpty
        }
    }
}