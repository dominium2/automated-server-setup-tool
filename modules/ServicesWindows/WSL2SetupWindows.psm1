# WSL2 Setup Module for Windows Systems

function Test-WSLReady {
    <#
    .SYNOPSIS
        Tests if WSL2 is ready and fully functional on a remote Windows system.
    
    .DESCRIPTION
        Checks if WSL2 features are enabled, kernel is installed, and a distribution is available.
        Returns a detailed status object.
    #>
    param (
        [string]$IP,
        [string]$User,
        [string]$Password,
        [string]$Distribution = "Ubuntu"
    )
    
    try {
        # Create credential object
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        
        $session = New-PSSession -ComputerName $IP -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
        
        if (-not $session) {
            return @{
                Ready = $false
                NeedsReboot = $false
                NeedsInstall = $true
                Message = "Could not establish remote session"
            }
        }
        
        $status = Invoke-Command -Session $session -ScriptBlock {
            param($Distro)
            
            $result = @{
                WSLFeatureEnabled = $false
                VMPlatformEnabled = $false
                WSLKernelInstalled = $false
                DistributionInstalled = $false
                DistributionReady = $false
                NeedsReboot = $false
                Message = ""
            }
            
            # Check WSL feature status
            $wslStatus = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
            $result.WSLFeatureEnabled = ($wslStatus.State -eq "Enabled")
            
            # Check if reboot is pending for WSL feature
            if ($wslStatus.RestartNeeded -eq $true) {
                $result.NeedsReboot = $true
            }
            
            # Check Virtual Machine Platform feature status
            $vmStatus = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
            $result.VMPlatformEnabled = ($vmStatus.State -eq "Enabled")
            
            # Check if reboot is pending for VM Platform feature
            if ($vmStatus.RestartNeeded -eq $true) {
                $result.NeedsReboot = $true
            }
            
            # Check for pending reboot in registry
            $rebootPending = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
            $rebootRequired = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
            if ($rebootPending -or $rebootRequired) {
                $result.NeedsReboot = $true
            }
            
            # Only check WSL functionality if features are enabled and no reboot pending
            if ($result.WSLFeatureEnabled -and $result.VMPlatformEnabled -and -not $result.NeedsReboot) {
                # Check if wsl.exe works
                try {
                    $wslStatus = & wsl --status 2>&1
                    $wslStatusStr = $wslStatus -join ' '
                    
                    # Check for various states
                    if ($wslStatusStr -match "must be updated") {
                        # WSL needs update - not a reboot issue
                        $result.WSLKernelInstalled = $false
                        $result.NeedsUpdate = $true
                        $result.Message = "WSL requires update via 'wsl --update'"
                    }
                    elseif ($wslStatusStr -match "not installed|is not installed") {
                        $result.WSLKernelInstalled = $false
                    }
                    elseif ($LASTEXITCODE -eq 0) {
                        $result.WSLKernelInstalled = $true
                    }
                    else {
                        $result.WSLKernelInstalled = $false
                    }
                }
                catch {
                    $result.WSLKernelInstalled = $false
                }
                
                # Check if distribution is installed
                if ($result.WSLKernelInstalled) {
                    $distroList = & wsl --list --quiet 2>&1 | Where-Object { $_ -match '\S' }
                    
                    if ($distroList -match $Distro -or ($Distro -eq "Ubuntu" -and $distroList -match "Ubuntu")) {
                        $result.DistributionInstalled = $true
                        
                        # Test if distribution is actually usable
                        try {
                            $testOutput = & wsl -d $Distro -u root echo "WSL_READY_TEST" 2>&1
                            if ($testOutput -match "WSL_READY_TEST") {
                                $result.DistributionReady = $true
                            }
                        }
                        catch {
                            $result.DistributionReady = $false
                        }
                    }
                }
            }
            
            # Build status message
            if ($result.NeedsReboot) {
                $result.Message = "System reboot required to complete WSL2 installation"
            }
            elseif (-not $result.WSLFeatureEnabled) {
                $result.Message = "WSL feature is not enabled"
            }
            elseif (-not $result.VMPlatformEnabled) {
                $result.Message = "Virtual Machine Platform feature is not enabled"
            }
            elseif (-not $result.WSLKernelInstalled) {
                $result.Message = "WSL2 kernel is not installed"
            }
            elseif (-not $result.DistributionInstalled) {
                $result.Message = "Linux distribution '$Distro' is not installed"
            }
            elseif (-not $result.DistributionReady) {
                $result.Message = "Linux distribution '$Distro' is installed but not ready"
            }
            else {
                $result.Message = "WSL2 is fully ready with $Distro distribution"
            }
            
            return $result
        } -ArgumentList $Distribution
        
        Remove-PSSession -Session $session
        
        $isReady = $status.WSLFeatureEnabled -and $status.VMPlatformEnabled -and 
                   $status.WSLKernelInstalled -and $status.DistributionInstalled -and 
                   $status.DistributionReady -and (-not $status.NeedsReboot)
        
        return @{
            Ready = $isReady
            NeedsReboot = $status.NeedsReboot
            NeedsInstall = (-not $status.WSLFeatureEnabled) -or (-not $status.VMPlatformEnabled)
            NeedsDistribution = (-not $status.DistributionInstalled) -or (-not $status.DistributionReady)
            Details = $status
            Message = $status.Message
        }
    }
    catch {
        return @{
            Ready = $false
            NeedsReboot = $false
            NeedsInstall = $true
            Message = "Error checking WSL status: $($_.Exception.Message)"
        }
    }
}

function Install-WSL2 {
    param (
        [string]$IP,
        [string]$User,
        [string]$Password,
        [string]$Distribution = "Ubuntu",
        [switch]$AutoReboot,
        [switch]$WaitForReboot
    )

    try {
        Write-Host "Starting WSL2 installation on $IP..." -ForegroundColor Cyan

        # First, check current WSL2 status
        Write-Host "  Checking current WSL2 status..." -ForegroundColor Cyan
        $wslStatus = Test-WSLReady -IP $IP -User $User -Password $Password -Distribution $Distribution
        
        if ($wslStatus.Ready) {
            Write-Host "WSL2 is already fully installed and ready on $IP" -ForegroundColor Green
            Write-Host "  $($wslStatus.Message)" -ForegroundColor Cyan
            return @{
                Success = $true
                NeedsReboot = $false
                Ready = $true
                Message = "WSL2 is already ready"
            }
        }
        
        # Check if reboot is pending from a previous installation
        if ($wslStatus.NeedsReboot) {
            Write-Host "  A system reboot is pending from previous WSL2 installation" -ForegroundColor Yellow
            
            if ($AutoReboot) {
                return Invoke-WSL2Reboot -IP $IP -User $User -Password $Password -Distribution $Distribution -WaitForReboot:$WaitForReboot
            }
            else {
                Write-Host "WARNING: System reboot is required to complete WSL2 installation" -ForegroundColor Yellow
                Write-Host "Run with -AutoReboot to automatically reboot, or manually reboot with:" -ForegroundColor Cyan
                Write-Host "  Restart-Computer -ComputerName $IP -Credential `$credential -Force" -ForegroundColor White
                
                return @{
                    Success = $true
                    NeedsReboot = $true
                    Ready = $false
                    Message = "WSL2 features installed but system reboot is required"
                }
            }
        }
        
        Write-Host "  Current status: $($wslStatus.Message)" -ForegroundColor Yellow

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
            return @{
                Success = $false
                NeedsReboot = $false
                Ready = $false
                Message = "Failed to establish remote session"
            }
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
                
                # Check for pending reboot in registry BEFORE attempting kernel install
                $rebootPending = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
                $rebootReq = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
                if ($rebootPending -or $rebootReq) {
                    $rebootRequired = $true
                }
                
                # Test if WSL is actually functional (not just "enabled" in features)
                Write-Host "  Testing WSL functionality..." -ForegroundColor Cyan
                $wslFunctional = $false
                try {
                    $wslTest = & wsl --status 2>&1
                    if ($LASTEXITCODE -eq 0 -and $wslTest -notmatch "not installed|is not installed") {
                        $wslFunctional = $true
                        Write-Host "  WSL is functional" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  WSL is not yet functional - reboot required" -ForegroundColor Yellow
                        $rebootRequired = $true
                    }
                }
                catch {
                    Write-Host "  WSL test failed - reboot likely required" -ForegroundColor Yellow
                    $rebootRequired = $true
                }
                
                # If reboot is required, stop here and return
                if ($rebootRequired -and -not $wslFunctional) {
                    Write-Host "  System reboot is required before WSL2 can be fully configured" -ForegroundColor Yellow
                    return @{
                        Success = $true
                        NeedsReboot = $true
                        Ready = $false
                        Message = "WSL2 features enabled. System reboot required before continuing."
                    }
                }

                # Update WSL using the modern method (wsl --update)
                Write-Host "  Updating WSL to latest version..." -ForegroundColor Cyan
                try {
                    $wslUpdateOutput = & wsl --update 2>&1
                    $wslUpdateExitCode = $LASTEXITCODE
                    
                    if ($wslUpdateExitCode -eq 0) {
                        Write-Host "  WSL updated successfully" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  WSL update output: $wslUpdateOutput" -ForegroundColor Yellow
                        # Try the --web-download flag for environments without Microsoft Store
                        Write-Host "  Trying alternative update method..." -ForegroundColor Cyan
                        $wslUpdateOutput2 = & wsl --update --web-download 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "  WSL updated successfully via web download" -ForegroundColor Green
                        }
                        else {
                            Write-Host "  WSL update returned: $wslUpdateOutput2" -ForegroundColor Yellow
                        }
                    }
                }
                catch {
                    Write-Host "  Warning: WSL update command failed: $($_.Exception.Message)" -ForegroundColor Yellow
                }
                
                # Install WSL if not yet installed (uses wsl --install which handles everything)
                Write-Host "  Ensuring WSL is fully installed..." -ForegroundColor Cyan
                try {
                    $wslInstallOutput = & wsl --install --no-launch 2>&1
                    if ($LASTEXITCODE -eq 0 -or $wslInstallOutput -match "already installed") {
                        Write-Host "  WSL installation verified" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  WSL install output: $wslInstallOutput" -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Host "  Warning: wsl --install failed: $($_.Exception.Message)" -ForegroundColor Yellow
                }

                # Set WSL2 as default version
                Write-Host "  Setting WSL2 as default version..." -ForegroundColor Cyan
                try {
                    $setVersionOutput = & wsl --set-default-version 2 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "  WSL2 set as default version" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  Set default version output: $setVersionOutput" -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Host "  Warning: Could not set default WSL version: $($_.Exception.Message)" -ForegroundColor Yellow
                }
                
                # Test if WSL is now functional
                Write-Host "  Verifying WSL is functional..." -ForegroundColor Cyan
                $wslStatusCheck = & wsl --status 2>&1
                if ($LASTEXITCODE -ne 0 -or $wslStatusCheck -match "must be updated|not installed") {
                    Write-Host "  WSL requires additional setup or reboot" -ForegroundColor Yellow
                    return @{
                        Success = $true
                        NeedsReboot = $true
                        Ready = $false
                        Message = "WSL installed but may require reboot to activate"
                    }
                }
                Write-Host "  WSL is functional" -ForegroundColor Green

                # Install Linux distribution
                if ($DistroName -and $DistroName -ne "") {
                    Write-Host "  Checking for Linux distribution: $DistroName..." -ForegroundColor Cyan
                    
                    # Check if distribution is already installed
                    $installedDistros = & wsl --list --quiet 2>&1 | Where-Object { $_ -match '\S' }
                    
                    # Check if WSL returned an error indicating it's not ready
                    $distroListStr = $installedDistros -join ' '
                    if ($distroListStr -match "not installed|is not installed") {
                        Write-Host "  WSL is not fully installed yet - reboot required" -ForegroundColor Yellow
                        return @{
                            Success = $true
                            NeedsReboot = $true
                            Ready = $false
                            Message = "WSL2 features enabled but not active. System reboot required."
                        }
                    }
                    
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
                # Check again for reboot requirement after installation
                $wslStatusAfter = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
                $vmStatusAfter = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
                
                $rebootRequired = ($wslStatusAfter.RestartNeeded -eq $true) -or ($vmStatusAfter.RestartNeeded -eq $true) -or $rebootRequired
                
                # Also check registry for pending reboot
                $rebootPending = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
                $rebootReq = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
                if ($rebootPending -or $rebootReq) {
                    $rebootRequired = $true
                }
                
                $message = if ($rebootRequired) {
                    "WSL2 components installed successfully. System reboot is required to complete installation."
                } else {
                    "WSL2 installation completed successfully."
                }

                return @{
                    Success = $installSuccess
                    NeedsReboot = $rebootRequired
                    Ready = (-not $rebootRequired)
                    Message = $message
                }
            }
            catch {
                Write-Host "  Error during WSL2 installation: $($_.Exception.Message)" -ForegroundColor Red
                return @{
                    Success = $false
                    NeedsReboot = $false
                    Ready = $false
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
                Write-Host "" -ForegroundColor Yellow
                Write-Host "========================================" -ForegroundColor Yellow
                Write-Host "WARNING: SYSTEM REBOOT REQUIRED" -ForegroundColor Yellow
                Write-Host "========================================" -ForegroundColor Yellow
                Write-Host "A system reboot is required to complete WSL2 installation." -ForegroundColor Yellow
                Write-Host "After reboot, run the setup again to continue with service deployment." -ForegroundColor Yellow
                Write-Host "" -ForegroundColor Yellow
                
                if ($AutoReboot) {
                    return Invoke-WSL2Reboot -IP $IP -User $User -Password $Password -Distribution $Distribution -WaitForReboot:$WaitForReboot
                }
                else {
                    Write-Host "To reboot manually, run:" -ForegroundColor Cyan
                    Write-Host "  Restart-Computer -ComputerName $IP -Credential `$credential -Force" -ForegroundColor White
                    Write-Host "" -ForegroundColor Yellow
                }
                
                return @{
                    Success = $true
                    NeedsReboot = $true
                    Ready = $false
                    Message = $installResult.Message
                }
            }
            
            return @{
                Success = $true
                NeedsReboot = $false
                Ready = $true
                Message = $installResult.Message
            }
        }
        else {
            Write-Host "WSL2 installation failed on $IP" -ForegroundColor Red
            Write-Host $installResult.Message -ForegroundColor Red
            return @{
                Success = $false
                NeedsReboot = $false
                Ready = $false
                Message = $installResult.Message
            }
        }
    }
    catch {
        Write-Host "Error during WSL2 installation: $($_.Exception.Message)" -ForegroundColor Red
        return @{
            Success = $false
            NeedsReboot = $false
            Ready = $false
            Message = "Error: $($_.Exception.Message)"
        }
    }
}

# Script-level variable to track reboot count and prevent infinite loops
$script:WSL2RebootCount = @{}

function Invoke-WSL2Reboot {
    <#
    .SYNOPSIS
        Reboots a remote Windows system and optionally waits for it to come back online.
    
    .DESCRIPTION
        Initiates a reboot on the remote system and can wait for the system to come back online
        before checking WSL2 status again. Includes protection against infinite reboot loops.
    #>
    param (
        [string]$IP,
        [string]$User,
        [string]$Password,
        [string]$Distribution = "Ubuntu",
        [switch]$WaitForReboot,
        [int]$TimeoutMinutes = 10,
        [int]$MaxReboots = 2
    )
    
    try {
        # Check reboot counter to prevent infinite loops
        if (-not $script:WSL2RebootCount.ContainsKey($IP)) {
            $script:WSL2RebootCount[$IP] = 0
        }
        
        $script:WSL2RebootCount[$IP]++
        
        if ($script:WSL2RebootCount[$IP] -gt $MaxReboots) {
            Write-Host "Maximum reboot attempts ($MaxReboots) reached for $IP" -ForegroundColor Red
            Write-Host "WSL2 installation may require manual intervention." -ForegroundColor Yellow
            Write-Host "Please connect to the VM and run: wsl --update" -ForegroundColor Cyan
            return @{
                Success = $false
                NeedsReboot = $false
                Ready = $false
                Message = "Maximum reboot attempts reached. Manual intervention required - run 'wsl --update' on the VM."
            }
        }
        
        Write-Host "Initiating system reboot on $IP (attempt $($script:WSL2RebootCount[$IP]) of $MaxReboots)..." -ForegroundColor Yellow
        
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($User, $securePassword)
        
        # Initiate the reboot
        try {
            Restart-Computer -ComputerName $IP -Credential $credential -Force -ErrorAction Stop
            Write-Host "Reboot command sent successfully" -ForegroundColor Green
        }
        catch {
            Write-Host "Failed to send reboot command: $($_.Exception.Message)" -ForegroundColor Red
            return @{
                Success = $false
                NeedsReboot = $true
                Ready = $false
                Message = "Failed to initiate reboot: $($_.Exception.Message)"
            }
        }
        
        if (-not $WaitForReboot) {
            Write-Host "System is rebooting. Run the setup again after the system comes back online." -ForegroundColor Cyan
            return @{
                Success = $true
                NeedsReboot = $true
                Ready = $false
                Rebooting = $true
                Message = "System is rebooting. Run setup again after reboot completes."
            }
        }
        
        # Wait for system to go offline
        Write-Host "Waiting for system to go offline..." -ForegroundColor Cyan
        $offlineTimeout = 60  # seconds
        $offlineStart = Get-Date
        
        do {
            Start-Sleep -Seconds 5
            $pingResult = Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue
            $elapsed = ((Get-Date) - $offlineStart).TotalSeconds
        } while ($pingResult -and ($elapsed -lt $offlineTimeout))
        
        if ($pingResult) {
            Write-Host "Warning: System did not go offline within expected time" -ForegroundColor Yellow
        }
        else {
            Write-Host "System is offline, waiting for it to come back..." -ForegroundColor Cyan
        }
        
        # Wait for system to come back online
        $onlineTimeout = $TimeoutMinutes * 60  # Convert to seconds
        $onlineStart = Get-Date
        $systemOnline = $false
        
        Write-Host "Waiting up to $TimeoutMinutes minutes for system to come back online..." -ForegroundColor Cyan
        
        do {
            Start-Sleep -Seconds 10
            $pingResult = Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue
            
            if ($pingResult) {
                # Try to establish WinRM connection
                $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
                try {
                    $testSession = New-PSSession -ComputerName $IP -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
                    if ($testSession) {
                        Remove-PSSession -Session $testSession
                        $systemOnline = $true
                    }
                }
                catch {
                    # WinRM not ready yet, keep waiting
                    Write-Host "  System responding to ping, waiting for WinRM..." -ForegroundColor Cyan
                }
            }
            
            $elapsed = ((Get-Date) - $onlineStart).TotalSeconds
            $remaining = [math]::Round(($onlineTimeout - $elapsed) / 60, 1)
            
            if (-not $systemOnline -and ($elapsed % 30 -lt 10)) {
                Write-Host "  Still waiting... ($remaining minutes remaining)" -ForegroundColor Cyan
            }
        } while (-not $systemOnline -and ($elapsed -lt $onlineTimeout))
        
        if (-not $systemOnline) {
            Write-Host "Timeout waiting for system to come back online" -ForegroundColor Red
            return @{
                Success = $false
                NeedsReboot = $false
                Ready = $false
                Message = "Timeout waiting for system to come back online after reboot"
            }
        }
        
        Write-Host "System is back online!" -ForegroundColor Green
        Write-Host "Waiting additional 30 seconds for services to stabilize..." -ForegroundColor Cyan
        Start-Sleep -Seconds 30
        
        # Check WSL2 status after reboot
        Write-Host "Checking WSL2 status after reboot..." -ForegroundColor Cyan
        $wslStatus = Test-WSLReady -IP $IP -User $User -Password $Password -Distribution $Distribution
        
        if ($wslStatus.Ready) {
            Write-Host "WSL2 is now fully ready!" -ForegroundColor Green
            return @{
                Success = $true
                NeedsReboot = $false
                Ready = $true
                Message = "WSL2 is ready after reboot"
            }
        }
        elseif ($wslStatus.NeedsDistribution -or (-not $wslStatus.NeedsReboot)) {
            Write-Host "WSL2 features are ready, continuing with setup..." -ForegroundColor Yellow
            # Continue with distribution installation (pass AutoReboot in case another reboot is somehow needed)
            return Install-WSL2 -IP $IP -User $User -Password $Password -Distribution $Distribution -AutoReboot -WaitForReboot
        }
        else {
            Write-Host "WSL2 status after reboot: $($wslStatus.Message)" -ForegroundColor Yellow
            return @{
                Success = $wslStatus.Ready
                NeedsReboot = $wslStatus.NeedsReboot
                Ready = $wslStatus.Ready
                Message = $wslStatus.Message
            }
        }
    }
    catch {
        Write-Host "Error during reboot process: $($_.Exception.Message)" -ForegroundColor Red
        return @{
            Success = $false
            NeedsReboot = $false
            Ready = $false
            Message = "Error during reboot: $($_.Exception.Message)"
        }
    }
}

# Export the functions
Export-ModuleMember -Function Install-WSL2, Test-WSLReady, Invoke-WSL2Reboot
