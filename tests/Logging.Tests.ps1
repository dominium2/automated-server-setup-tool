# ==============================================================================
# Logging.Tests.ps1
# Pester tests for RMSetup logging mechanics
# ==============================================================================

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot "..\modules\RMSetup.psm1"
    Import-Module $modulePath -Force
    $script:testLogDir = Join-Path $env:TEMP "LoggingTests_$(Get-Random)"
}

AfterAll {
    if (Test-Path $script:testLogDir) { Remove-Item $script:testLogDir -Recurse -Force }
}

Describe "RMSetup Logging Core" {
    BeforeEach {
        $testDir = Join-Path $script:testLogDir "Test_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        Initialize-Logging -LogDirectory $testDir -LogLevel "Debug" -LogToConsole $false | Out-Null
    }

    It "Should create a log file with the correct naming convention" {
        $logPath = Get-LogFilePath
        Test-Path $logPath | Should -Be $true
        $logPath | Should -Match "automated-setup_.*\.log$"
    }

    It "Should write Warning level messages correctly" {
        Write-LogWarning -Message "Warning test message" -Component "Test"
        $content = Get-Content (Get-LogFilePath) -Raw
        $content | Should -Match "\[Warning\].*Warning test message"
    }

    It "Should filter out Debug messages when LogLevel is Info" {
        Initialize-Logging -LogDirectory $script:testLogDir -LogLevel "Info" -LogToConsole $false | Out-Null
        Write-LogDebug -Message "Should not appear" -Component "Test"
        Write-LogInfo -Message "Should appear" -Component "Test"
        
        $content = Get-Content (Get-LogFilePath) -Raw
        $content | Should -Not -Match "Should not appear"
        $content | Should -Match "Should appear"
    }
    
    It "Should write a session separator" {
        Write-SessionSeparator -SessionName "Test Session"
        $content = Get-Content (Get-LogFilePath) -Raw
        $content | Should -Match "Test Session"
        $content | Should -Match "==="
    }
}