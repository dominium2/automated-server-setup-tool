# ==============================================================================
# GUI.Tests.ps1
# Pester tests for frontend validation logic
# ==============================================================================

BeforeAll {
    $guiPath = Join-Path $PSScriptRoot ".." "GUI.ps1"
    $guiLines = Get-Content -Path $guiPath
    
    # Extract Test-IPAddress function
    $inIPFunction = $false
    $braceCount = 0
    $ipFunction = @()
    foreach ($line in $guiLines) {
        if ($line -match '^function Test-IPAddress') { $inIPFunction = $true }
        if ($inIPFunction) {
            $ipFunction += $line
            $braceCount += ($line.ToCharArray() | Where-Object { $_ -eq '{' }).Count
            $braceCount -= ($line.ToCharArray() | Where-Object { $_ -eq '}' }).Count
            if ($braceCount -eq 0 -and $line -match '\}') { break }
        }
    }
    
    # Extract Test-ServerConfigs function
    $inConfigFunction = $false
    $braceCount = 0
    $configFunction = @()
    foreach ($line in $guiLines) {
        if ($line -match '^function Test-ServerConfigs') { $inConfigFunction = $true }
        if ($inConfigFunction) {
            $configFunction += $line
            $braceCount += ($line.ToCharArray() | Where-Object { $_ -eq '{' }).Count
            $braceCount -= ($line.ToCharArray() | Where-Object { $_ -eq '}' }).Count
            if ($braceCount -eq 0 -and $line -match '\}') { break }
        }
    }
    
    # Execute the functions into the test scope
    Invoke-Expression ($ipFunction -join "`n")
    Invoke-Expression ($configFunction -join "`n")
}

Describe "Test-IPAddress" {
    Context "Valid IP Addresses" {
        It "Should accept valid IPv4 address <IP>" -TestCases @(
            @{ IP = "192.168.1.1" }
            @{ IP = "10.0.0.1" }
            @{ IP = "172.16.0.1" }
            @{ IP = "255.255.255.255" }
            @{ IP = "0.0.0.0" }
        ) {
            param($IP)
            Test-IPAddress -IP $IP | Should -Be $true
        }
        
        It "Should accept valid hostname <Hostname>" -TestCases @(
            @{ Hostname = "server" }
            @{ Hostname = "server.local" }
            @{ Hostname = "my-server.example.com" }
        ) {
            param($Hostname)
            Test-IPAddress -IP $Hostname | Should -Be $true
        }
    }
    
    Context "Invalid IP Addresses" {
        It "Should reject invalid IPv4 address <IP>" -TestCases @(
            @{ IP = "256.256.256.256" }
            @{ IP = "192.168.1" }
            @{ IP = "999.999.999.999" }
        ) {
            param($IP)
            Test-IPAddress -IP $IP | Should -Be $false
        }
    }
}

Describe "Test-ServerConfigs" {
    Context "Valid Configurations" {
        It "Should pass validation for complete configuration" {
            $config = @(
                @{
                    ServerNumber = 1
                    IP = "192.168.1.100"
                    User = "admin"
                    Password = "password123"
                    Service = "AdGuard"
                    EnableSSH = $true
                    SSHPort = 22
                    EnableWinRM = $true
                    WinRMPort = 5985
                }
            )
            $errors = Test-ServerConfigs -Configs $config
            $errors.Count | Should -Be 0
        }
    }
    
    Context "Invalid Configurations" {
        It "Should detect missing basic requirements" {
            $config = @(
                @{
                    ServerNumber = 1
                    IP = ""
                    User = ""
                    Password = ""
                    Service = $null
                    EnableSSH = $true
                    SSHPort = 22
                    EnableWinRM = $true
                    WinRMPort = 5985
                }
            )
            $errors = Test-ServerConfigs -Configs $config
            $errors.Count | Should -Be 4
            ($errors -join ' ') | Should -Match "IP Address is required"
        }

        It "Should enforce that at least one connection protocol is enabled" {
            $config = @(
                @{
                    ServerNumber = 1
                    IP = "10.0.0.1"
                    User = "admin"
                    Password = "password"
                    Service = "App"
                    EnableSSH = $false
                    EnableWinRM = $false
                }
            )
            $errors = Test-ServerConfigs -Configs $config
            $errors | Should -Contain "Server 1: Must enable at least SSH or WinRM"
        }

        It "Should validate custom port ranges" {
            $config = @(
                @{
                    ServerNumber = 1
                    IP = "10.0.0.1"
                    User = "admin"
                    Password = "password"
                    Service = "App"
                    EnableSSH = $true
                    SSHPort = 99999
                    EnableWinRM = $true
                    WinRMPort = -5
                }
            )
            $errors = Test-ServerConfigs -Configs $config
            $errors | Should -Contain "Server 1: Invalid SSH Port"
            $errors | Should -Contain "Server 1: Invalid WinRM Port"
        }
    }
}