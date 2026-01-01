# Logging Module Tests
# Tests for the Logging.psm1 module

BeforeAll {
    # Import the module
    $modulePath = Join-Path $PSScriptRoot "..\modules\Logging.psm1"
    Import-Module $modulePath -Force
    
    # Set up test log directory
    $script:testLogDir = Join-Path $env:TEMP "LoggingTests_$(Get-Random)"
}

AfterAll {
    # Clean up test log directory
    if (Test-Path $script:testLogDir) {
        Remove-Item $script:testLogDir -Recurse -Force
    }
}

Describe "Initialize-Logging" {
    BeforeEach {
        # Create fresh test directory for each test
        $testDir = Join-Path $script:testLogDir "Test_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    }
    
    It "Should create log directory if it doesn't exist" {
        $newLogDir = Join-Path $script:testLogDir "NewLogDir_$(Get-Random)"
        $logPath = Initialize-Logging -LogDirectory $newLogDir -LogToConsole $false
        
        Test-Path $newLogDir | Should -Be $true
    }
    
    It "Should return a valid log file path" {
        $testDir = Join-Path $script:testLogDir "LogPathTest_$(Get-Random)"
        $logPath = Initialize-Logging -LogDirectory $testDir -LogToConsole $false
        
        $logPath | Should -Not -BeNullOrEmpty
        $logPath | Should -Match "automated-setup_.*\.log$"
    }
    
    It "Should create a log file" {
        $testDir = Join-Path $script:testLogDir "FileCreateTest_$(Get-Random)"
        $logPath = Initialize-Logging -LogDirectory $testDir -LogToConsole $false
        
        # Write a test message to create the file
        Write-Log -Message "Test message" -Level "Info" -Component "Test"
        
        Test-Path $logPath | Should -Be $true
    }
}

Describe "Write-Log" {
    BeforeAll {
        $testDir = Join-Path $script:testLogDir "WriteLogTests"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        Initialize-Logging -LogDirectory $testDir -LogLevel "Debug" -LogToConsole $false
    }
    
    It "Should write Info level messages" {
        Write-Log -Message "Info test message" -Level "Info" -Component "Test"
        $logPath = Get-LogFilePath
        $content = Get-Content $logPath -Raw
        
        $content | Should -Match "\[Info\].*Info test message"
    }
    
    It "Should write Warning level messages" {
        Write-Log -Message "Warning test message" -Level "Warning" -Component "Test"
        $logPath = Get-LogFilePath
        $content = Get-Content $logPath -Raw
        
        $content | Should -Match "\[Warning\].*Warning test message"
    }
    
    It "Should write Error level messages" {
        Write-Log -Message "Error test message" -Level "Error" -Component "Test"
        $logPath = Get-LogFilePath
        $content = Get-Content $logPath -Raw
        
        $content | Should -Match "\[Error\].*Error test message"
    }
    
    It "Should write Debug level messages when LogLevel is Debug" {
        Write-Log -Message "Debug test message" -Level "Debug" -Component "Test"
        $logPath = Get-LogFilePath
        $content = Get-Content $logPath -Raw
        
        $content | Should -Match "\[Debug\].*Debug test message"
    }
    
    It "Should include component name in log" {
        Write-Log -Message "Component test" -Level "Info" -Component "MyComponent"
        $logPath = Get-LogFilePath
        $content = Get-Content $logPath -Raw
        
        $content | Should -Match "\[MyComponent\]"
    }
    
    It "Should include timestamp in log" {
        Write-Log -Message "Timestamp test" -Level "Info" -Component "Test"
        $logPath = Get-LogFilePath
        $content = Get-Content $logPath -Raw
        
        # Check for timestamp pattern: [YYYY-MM-DD HH:MM:SS.mmm]
        $content | Should -Match "\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\]"
    }
}

Describe "Write-Log Helper Functions" {
    BeforeAll {
        $testDir = Join-Path $script:testLogDir "HelperTests"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        Initialize-Logging -LogDirectory $testDir -LogLevel "Debug" -LogToConsole $false
    }
    
    It "Write-LogDebug should write Debug level messages" {
        Write-LogDebug -Message "Debug helper test" -Component "Helper"
        $content = Get-Content (Get-LogFilePath) -Raw
        
        $content | Should -Match "\[Debug\].*Debug helper test"
    }
    
    It "Write-LogInfo should write Info level messages" {
        Write-LogInfo -Message "Info helper test" -Component "Helper"
        $content = Get-Content (Get-LogFilePath) -Raw
        
        $content | Should -Match "\[Info\].*Info helper test"
    }
    
    It "Write-LogWarning should write Warning level messages" {
        Write-LogWarning -Message "Warning helper test" -Component "Helper"
        $content = Get-Content (Get-LogFilePath) -Raw
        
        $content | Should -Match "\[Warning\].*Warning helper test"
    }
    
    It "Write-LogError should write Error level messages" {
        Write-LogError -Message "Error helper test" -Component "Helper"
        $content = Get-Content (Get-LogFilePath) -Raw
        
        $content | Should -Match "\[Error\].*Error helper test"
    }
    
    It "Write-LogSuccess should write Success level messages" {
        Write-LogSuccess -Message "Success helper test" -Component "Helper"
        $content = Get-Content (Get-LogFilePath) -Raw
        
        $content | Should -Match "\[Success\].*Success helper test"
    }
}

Describe "Log Level Filtering" {
    It "Should filter out Debug messages when LogLevel is Info" {
        $testDir = Join-Path $script:testLogDir "FilterTest_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        Initialize-Logging -LogDirectory $testDir -LogLevel "Info" -LogToConsole $false
        
        Write-Log -Message "Should not appear" -Level "Debug" -Component "Test"
        Write-Log -Message "Should appear" -Level "Info" -Component "Test"
        
        $content = Get-Content (Get-LogFilePath) -Raw
        
        $content | Should -Not -Match "Should not appear"
        $content | Should -Match "Should appear"
    }
    
    It "Should filter out Info and Debug messages when LogLevel is Warning" {
        $testDir = Join-Path $script:testLogDir "FilterTest2_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        Initialize-Logging -LogDirectory $testDir -LogLevel "Warning" -LogToConsole $false
        
        Write-Log -Message "Debug should not appear" -Level "Debug" -Component "Test"
        Write-Log -Message "Info should not appear" -Level "Info" -Component "Test"
        Write-Log -Message "Warning should appear" -Level "Warning" -Component "Test"
        
        $content = Get-Content (Get-LogFilePath) -Raw
        
        $content | Should -Not -Match "Debug should not appear"
        $content | Should -Not -Match "Info should not appear"
        $content | Should -Match "Warning should appear"
    }
}

Describe "Get-LogContent" {
    BeforeAll {
        $testDir = Join-Path $script:testLogDir "GetContentTests"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        Initialize-Logging -LogDirectory $testDir -LogLevel "Debug" -LogToConsole $false
        
        # Write some test messages
        Write-LogInfo -Message "Line 1" -Component "Test"
        Write-LogWarning -Message "Line 2" -Component "Test"
        Write-LogError -Message "Line 3" -Component "Test"
    }
    
    It "Should return log content" {
        $content = Get-LogContent
        
        $content | Should -Not -BeNullOrEmpty
        $content.Count | Should -BeGreaterThan 0
    }
    
    It "Should filter by log level" {
        $errorContent = Get-LogContent -Level "Error"
        
        $errorContent | Should -Not -BeNullOrEmpty
        $errorContent | ForEach-Object { $_ | Should -Match "\[Error\]" }
    }
    
    It "Should return last N lines with Tail parameter" {
        $tailContent = Get-LogContent -Tail 2
        
        $tailContent.Count | Should -BeLessOrEqual 2
    }
}

Describe "Get-LogFilePath" {
    It "Should return current log file path" {
        $testDir = Join-Path $script:testLogDir "PathTest_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        Initialize-Logging -LogDirectory $testDir -LogToConsole $false
        
        $path = Get-LogFilePath
        
        $path | Should -Not -BeNullOrEmpty
        $path | Should -Match "\.log$"
    }
}

Describe "Write-SessionSeparator" {
    BeforeAll {
        $testDir = Join-Path $script:testLogDir "SeparatorTests"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        Initialize-Logging -LogDirectory $testDir -LogLevel "Debug" -LogToConsole $false
    }
    
    It "Should write a session separator to the log" {
        Write-SessionSeparator -SessionName "Test Session"
        $content = Get-Content (Get-LogFilePath) -Raw
        
        $content | Should -Match "Test Session"
        $content | Should -Match "==="
    }
}
