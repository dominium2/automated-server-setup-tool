BeforeAll {
    # Simple approach: Load the entire GUI.ps1 content and extract function definitions
    # by parsing line by line
    $guiLines = Get-Content -Path "$PSScriptRoot\GUI.ps1"
    
    # Extract Test-IPAddress function
    $inIPFunction = $false
    $braceCount = 0
    $ipFunction = @()
    
    foreach ($line in $guiLines) {
        if ($line -match '^function Test-IPAddress') {
            $inIPFunction = $true
        }
        
        if ($inIPFunction) {
            $ipFunction += $line
            
            # Count braces to find function end
            $braceCount += ($line.ToCharArray() | Where-Object { $_ -eq '{' }).Count
            $braceCount -= ($line.ToCharArray() | Where-Object { $_ -eq '}' }).Count
            
            if ($braceCount -eq 0 -and $line -match '\}') {
                break
            }
        }
    }
    
    # Extract Test-ServerConfigs function
    $inConfigFunction = $false
    $braceCount = 0
    $configFunction = @()
    
    foreach ($line in $guiLines) {
        if ($line -match '^function Test-ServerConfigs') {
            $inConfigFunction = $true
        }
        
        if ($inConfigFunction) {
            $configFunction += $line
            
            # Count braces to find function end
            $braceCount += ($line.ToCharArray() | Where-Object { $_ -eq '{' }).Count
            $braceCount -= ($line.ToCharArray() | Where-Object { $_ -eq '}' }).Count
            
            if ($braceCount -eq 0 -and $line -match '\}') {
                break
            }
        }
    }
    
    # Execute the functions
    $ipFunctionCode = $ipFunction -join "`n"
    $configFunctionCode = $configFunction -join "`n"
    
    Invoke-Expression $ipFunctionCode
    Invoke-Expression $configFunctionCode
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
            @{ Hostname = "server01" }
        ) {
            param($Hostname)
            Test-IPAddress -IP $Hostname | Should -Be $true
        }
    }
    
    Context "Invalid IP Addresses" {
        It "Should reject invalid IPv4 address <IP>" -TestCases @(
            @{ IP = "256.256.256.256" }
            @{ IP = "192.168.1" }
            @{ IP = "192.168.1.1.1" }
            @{ IP = "999.999.999.999" }
            @{ IP = "192.168.-1.1" }
        ) {
            param($IP)
            Test-IPAddress -IP $IP | Should -Be $false
        }
        
        It "Should reject empty or whitespace input <Input>" -TestCases @(
            @{ Input = "" }
            @{ Input = "   " }
            @{ Input = $null }
        ) {
            param($Input)
            Test-IPAddress -IP $Input | Should -Be $false
        }
        
        It "Should reject invalid hostname formats <Hostname>" -TestCases @(
            @{ Hostname = "-server" }
            @{ Hostname = "server-" }
            @{ Hostname = "ser ver" }
            @{ Hostname = "server@example.com" }
        ) {
            param($Hostname)
            Test-IPAddress -IP $Hostname | Should -Be $false
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
                }
            )
            
            $errors = Test-ServerConfigs -Configs $config
            $errors.Count | Should -Be 0
        }
        
        It "Should pass validation for multiple complete configurations" {
            $configs = @(
                @{
                    ServerNumber = 1
                    IP = "192.168.1.100"
                    User = "admin"
                    Password = "pass1"
                    Service = "AdGuard"
                },
                @{
                    ServerNumber = 2
                    IP = "server.local"
                    User = "root"
                    Password = "pass2"
                    Service = "N8N"
                }
            )
            
            $errors = Test-ServerConfigs -Configs $configs
            $errors.Count | Should -Be 0
        }
    }
    
    Context "Invalid Configurations" {
        It "Should detect missing IP address" {
            $config = @(
                @{
                    ServerNumber = 1
                    IP = ""
                    User = "admin"
                    Password = "password123"
                    Service = "AdGuard"
                }
            )
            
            $errors = Test-ServerConfigs -Configs $config
            $errors.Count | Should -BeGreaterThan 0
            ($errors -join ' ') | Should -Match "IP Address is required"
        }
        
        It "Should detect invalid IP address format" {
            $config = @(
                @{
                    ServerNumber = 1
                    IP = "999.999.999.999"
                    User = "admin"
                    Password = "password123"
                    Service = "AdGuard"
                }
            )
            
            $errors = Test-ServerConfigs -Configs $config
            $errors.Count | Should -BeGreaterThan 0
            ($errors -join ' ') | Should -Match "Invalid IP Address format"
        }
        
        It "Should detect missing username" {
            $config = @(
                @{
                    ServerNumber = 1
                    IP = "192.168.1.100"
                    User = ""
                    Password = "password123"
                    Service = "AdGuard"
                }
            )
            
            $errors = Test-ServerConfigs -Configs $config
            $errors.Count | Should -BeGreaterThan 0
            $errors | Should -Contain "Server 1: Username is required"
        }
        
        It "Should detect missing password" {
            $config = @(
                @{
                    ServerNumber = 1
                    IP = "192.168.1.100"
                    User = "admin"
                    Password = ""
                    Service = "AdGuard"
                }
            )
            
            $errors = Test-ServerConfigs -Configs $config
            $errors.Count | Should -BeGreaterThan 0
            $errors | Should -Contain "Server 1: Password is required"
        }
        
        It "Should detect missing service selection" {
            $config = @(
                @{
                    ServerNumber = 1
                    IP = "192.168.1.100"
                    User = "admin"
                    Password = "password123"
                    Service = $null
                }
            )
            
            $errors = Test-ServerConfigs -Configs $config
            $errors.Count | Should -BeGreaterThan 0
            $errors | Should -Contain "Server 1: Service selection is required"
        }
        
        It "Should detect multiple validation errors" {
            $config = @(
                @{
                    ServerNumber = 1
                    IP = ""
                    User = ""
                    Password = ""
                    Service = $null
                }
            )
            
            $errors = Test-ServerConfigs -Configs $config
            $errors.Count | Should -Be 4
        }
        
        It "Should validate multiple servers independently" {
            $configs = @(
                @{
                    ServerNumber = 1
                    IP = "192.168.1.100"
                    User = "admin"
                    Password = "pass1"
                    Service = "AdGuard"
                },
                @{
                    ServerNumber = 2
                    IP = ""
                    User = ""
                    Password = "pass2"
                    Service = "N8N"
                }
            )
            
            $errors = Test-ServerConfigs -Configs $configs
            $errors.Count | Should -Be 2
            $errors[0] | Should -Match "Server 2"
            $errors[1] | Should -Match "Server 2"
        }
    }
}
