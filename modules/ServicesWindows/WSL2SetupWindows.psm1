# WSL2 Setup Module for Windows Systems

function Install-WSL2 {
    param (
        [string]$IP,
        [string]$User,
        [string]$Password,
        [string]$Distribution = "Ubuntu"
    )

    try {
        Write-Host "Starting WSL2 installation on $IP..." -ForegroundColor Cyan

        # Create credential object
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)

        # Create session options
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck

        # Establish remote session
        Write-Host "  Establishing remote session..." -ForegroundColor Cyan
        $session = New-PSSession -ComputerName $IP -Credential $credential -SessionOption $sessionOption -ErrorAction Stop

        if (-not $session) {
            Write-Host "Failed to establish remote session" -ForegroundColor Red
            return $false
        }

        # Execute installation on remote system
        $installResult = Invoke-Command -Session $session -ScriptBlock {
            param($DistroName)
            
            $VerbosePreference = 'Continue'
            $installSuccess = $true
            
            try {
                # Check if WSL is already installed
                Write-Host "  Checking current WSL status..." -ForegroundColor Cyan
                $wslStatus = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
                
                # Install WSL feature if not enabled
                if ($wslStatus.State -ne "Enabled") {
                    Write-Host "  Installing WSL feature..." -ForegroundColor Yellow
                    try {
                        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -ErrorAction Stop | Out-Null
                        Write-Host "  WSL feature enabled successfully" -ForegroundColor Green
                    }
                    catch {
                        Write-Host "  Failed to enable WSL feature: $($_.Exception.Message)" -ForegroundColor Red
                        $installSuccess = $false
                        return @{ Success = $installSuccess; NeedsReboot = $true; Message = "WSL feature installation failed" }
                    }
                }
                else {
                    Write-Host "  WSL feature is already enabled" -ForegroundColor Green
                }

                # Check and enable Virtual Machine Platform feature (required for WSL2)
                Write-Host "  Checking Virtual Machine Platform feature..." -ForegroundColor Cyan
                $vmPlatformStatus = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
                
                if ($vmPlatformStatus.State -ne "Enabled") {
                    Write-Host "  Installing Virtual Machine Platform feature..." -ForegroundColor Yellow
                    try {
                        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -ErrorAction Stop | Out-Null
                        Write-Host "  Virtual Machine Platform feature enabled successfully" -ForegroundColor Green
                    }
                    catch {
                        Write-Host "  Failed to enable Virtual Machine Platform: $($_.Exception.Message)" -ForegroundColor Red
                        $installSuccess = $false
                        return @{ Success = $installSuccess; NeedsReboot = $true; Message = "Virtual Machine Platform installation failed" }
                    }
                }
                else {
                    Write-Host "  Virtual Machine Platform is already enabled" -ForegroundColor Green
                }

                # Check if reboot is required
                $rebootRequired = $false
                if ($wslStatus.State -ne "Enabled" -or $vmPlatformStatus.State -ne "Enabled") {
                    $rebootRequired = $true
                }

                # Download and install WSL2 kernel update
                Write-Host "  Checking WSL2 kernel..." -ForegroundColor Cyan
                $kernelUpdateUrl = "https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi"
                $kernelUpdatePath = "$env:TEMP\wsl_update_x64.msi"
                
                try {
                    # Check if already downloaded
                    if (-not (Test-Path $kernelUpdatePath)) {
                        Write-Host "  Downloading WSL2 kernel update..." -ForegroundColor Yellow
                        
                        # Use BITS transfer for better reliability
                        try {
                            Import-Module BitsTransfer -ErrorAction Stop
                            Start-BitsTransfer -Source $kernelUpdateUrl -Destination $kernelUpdatePath -ErrorAction Stop
                        }
                        catch {
                            # Fallback to Invoke-WebRequest
                            Write-Host "  BITS transfer failed, using WebRequest..." -ForegroundColor Yellow
                            Invoke-WebRequest -Uri $kernelUpdateUrl -OutFile $kernelUpdatePath -UseBasicParsing -ErrorAction Stop
                        }
                        
                        Write-Host "  WSL2 kernel update downloaded" -ForegroundColor Green
                    }

                    # Install kernel update
                    Write-Host "  Installing WSL2 kernel update..." -ForegroundColor Yellow
                    $installArgs = "/i `"$kernelUpdatePath`" /quiet /norestart"
                    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
                    
                    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
                        Write-Host "  WSL2 kernel update installed successfully" -ForegroundColor Green
                        
                        # Clean up installer
                        Remove-Item -Path $kernelUpdatePath -Force -ErrorAction SilentlyContinue
                    }
                    else {
                        Write-Host "  WSL2 kernel update installation returned exit code: $($process.ExitCode)" -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Host "  Warning: WSL2 kernel update failed: $($_.Exception.Message)" -ForegroundColor Yellow
                    Write-Host "  You may need to install it manually later" -ForegroundColor Yellow
                }

                # Set WSL2 as default version
                Write-Host "  Setting WSL2 as default version..." -ForegroundColor Cyan
                try {
                    & wsl --set-default-version 2 2>&1 | Out-Null
                    Write-Host "  WSL2 set as default version" -ForegroundColor Green
                }
                catch {
                    Write-Host "  Warning: Could not set default WSL version: $($_.Exception.Message)" -ForegroundColor Yellow
                }

                # Install Linux distribution
                if ($DistroName -and $DistroName -ne "") {
                    Write-Host "  Checking for Linux distribution: $DistroName..." -ForegroundColor Cyan
                    
                    # Check if distribution is already installed
                    $installedDistros = & wsl --list --quiet 2>&1 | Where-Object { $_ -match '\S' }
                    Write-Host "  Currently installed distributions: $($installedDistros -join ', ')" -ForegroundColor Cyan
                    
                    # Check for exact match or Ubuntu variants
                    $foundDistro = $null
                    if ($installedDistros -match "^$DistroName$") {
                        $foundDistro = $DistroName
                    }
                    elseif ($DistroName -eq "Ubuntu" -and $installedDistros -match "Ubuntu") {
                        # Find any Ubuntu variant
                        $foundDistro = $installedDistros | Where-Object { $_ -match "Ubuntu" } | Select-Object -First 1
                        Write-Host "  Found Ubuntu variant: $foundDistro" -ForegroundColor Cyan
                    }
                    
                    if ($foundDistro) {
                        Write-Host "  $foundDistro is already installed" -ForegroundColor Green
                        
                        # Ensure it's running WSL2
                        Write-Host "  Ensuring $foundDistro is using WSL2..." -ForegroundColor Cyan
                        & wsl --set-version $foundDistro 2 2>&1 | Out-Null
                        
                        # Verify the distribution is accessible
                        $testResult = & wsl -d $foundDistro -u root echo "WSL_TEST_SUCCESS" 2>&1
                        if ($testResult -notmatch "WSL_TEST_SUCCESS") {
                            Write-Host "  Warning: $foundDistro may not be properly initialized" -ForegroundColor Yellow
                            Write-Host "  Test output: $testResult" -ForegroundColor Yellow
                        }
                        else {
                            Write-Host "  $foundDistro is accessible and ready" -ForegroundColor Green
                        }
                    }
                    else {
                        Write-Host "  Installing $DistroName distribution..." -ForegroundColor Yellow
                        Write-Host "  Note: This requires internet connectivity and may take several minutes..." -ForegroundColor Cyan
                        
                        # Use wsl --install to install the distribution
                        $installOutput = & wsl --install -d $DistroName --no-launch 2>&1
                        
                        # Wait longer for installation to complete
                        Write-Host "  Waiting for $DistroName installation to complete..." -ForegroundColor Cyan
                        Start-Sleep -Seconds 30
                        
                        # Check if installation succeeded
                        $installedDistros = & wsl --list --quiet 2>&1 | Where-Object { $_ -match '\S' }
                        
                        if ($installedDistros -match $DistroName) {
                            Write-Host "  $DistroName installed successfully" -ForegroundColor Green
                            
                            # Initialize the distribution by running commands as root
                            Write-Host "  Initializing $DistroName..." -ForegroundColor Cyan
                            
                            try {
                                # Run a simple command to trigger initialization and test
                                $initTest = & wsl -d $DistroName -u root bash -c "echo 'Initialized' && apt-get update -qq" 2>&1
                                Start-Sleep -Seconds 5
                                
                                # Verify it's working
                                $verifyTest = & wsl -d $DistroName -u root echo "SUCCESS" 2>&1
                                if ($verifyTest -match "SUCCESS") {
                                    Write-Host "  $DistroName initialized and ready for use" -ForegroundColor Green
                                }
                                else {
                                    Write-Host "  Warning: $DistroName initialization may have issues: $verifyTest" -ForegroundColor Yellow
                                }
                            }
                            catch {
                                Write-Host "  Warning: Could not initialize $DistroName`: $($_.Exception.Message)" -ForegroundColor Yellow
                            }
                        }
                        else {
                            Write-Host "  Error: $DistroName installation failed" -ForegroundColor Red
                            Write-Host "  Installation output: $installOutput" -ForegroundColor Yellow
                            Write-Host "  Please install manually: wsl --install -d $DistroName" -ForegroundColor Yellow
                            Write-Host "  Or install from Microsoft Store" -ForegroundColor Yellow
                        }
                    }
                }

                # Return installation result
                $message = if ($rebootRequired) {
                    "WSL2 components installed successfully. System reboot is required to complete installation."
                } else {
                    "WSL2 installation completed successfully."
                }

                return @{
                    Success = $installSuccess
                    NeedsReboot = $rebootRequired
                    Message = $message
                }
            }
            catch {
                Write-Host "  Error during WSL2 installation: $($_.Exception.Message)" -ForegroundColor Red
                return @{
                    Success = $false
                    NeedsReboot = $false
                    Message = "Installation failed: $($_.Exception.Message)"
                }
            }
        } -ArgumentList $Distribution

        # Close the session
        Remove-PSSession -Session $session

        # Process results
        if ($installResult.Success) {
            Write-Host "WSL2 installation completed on $IP" -ForegroundColor Green
            Write-Host $installResult.Message -ForegroundColor Cyan
            
            if ($installResult.NeedsReboot) {
                Write-Host "WARNING: A system reboot is required to complete WSL2 installation" -ForegroundColor Yellow
                Write-Host "You can reboot the remote system with: Restart-Computer -ComputerName $IP -Force" -ForegroundColor Cyan
            }
            
            return $true
        }
        else {
            Write-Host "WSL2 installation failed on $IP" -ForegroundColor Red
            Write-Host $installResult.Message -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "Error during WSL2 installation: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Export the function
Export-ModuleMember -Function Install-WSL2
