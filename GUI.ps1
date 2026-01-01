#Load WPF assemblies
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

#Load modules
Import-Module "$PSScriptRoot\modules\RemoteConnection.psm1" -Force

# Load service modules
Import-Module "$PSScriptRoot\modules\ServicesDebian\DockerSetupDebian.psm1" -Force
Import-Module "$PSScriptRoot\modules\ServicesDebian\TraefikSetupDebian.psm1" -Force
Import-Module "$PSScriptRoot\modules\ServicesDebian\PortainerSetupDebian.psm1" -Force
Import-Module "$PSScriptRoot\modules\ServicesDebian\AdGuardSetupDebian.psm1" -Force
Import-Module "$PSScriptRoot\modules\ServicesDebian\N8NSetupDebian.psm1" -Force
Import-Module "$PSScriptRoot\modules\ServicesDebian\CraftySetupDebian.psm1" -Force
Import-Module "$PSScriptRoot\modules\ServicesDebian\HeimdallSetupDebian.psm1" -Force

# Load Windows service modules
Import-Module "$PSScriptRoot\modules\ServicesWindows\WSL2SetupWindows.psm1" -Force

#Gui Design XML
[xml]$xaml = @"
<Window 
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Automated Home Lab Setup" 
    Height="700" 
    Width="900"
    WindowStartupLocation="CenterScreen">
    
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="2*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="1*"/>
        </Grid.RowDefinitions>
        
        <!-- Top Button Bar -->
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
            <Button Name="AddServerButton" Content="Add Server" Width="120" Height="35" Margin="0,0,10,0" FontSize="14"/>
            <Button Name="RunSetupButton" Content="Run Setup" Width="120" Height="35" Background="Green" Foreground="White" FontSize="14"/>
        </StackPanel>
        
        <!-- Server Container with ScrollViewer -->
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel Name="ServerContainer" Orientation="Vertical"/>
        </ScrollViewer>
        
        <!-- Terminal Output Header -->
        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,10,0,5">
            <Label Content="Terminal Output" FontWeight="Bold" FontSize="14" VerticalAlignment="Center"/>
            <Button Name="ClearOutputButton" Content="Clear" Width="80" Height="25" Margin="10,0,0,0"/>
            <Label Content="Mode:" FontWeight="Bold" FontSize="12" VerticalAlignment="Center" Margin="20,0,5,0"/>
            <Button Name="SimpleTerminalButton" Content="Simple" Width="80" Height="25" Margin="0,0,5,0" Background="#4A90E2" Foreground="White"/>
            <Button Name="AdvancedTerminalButton" Content="Advanced" Width="80" Height="25" Margin="0,0,0,0"/>
        </StackPanel>
        
        <!-- Terminal Output Display -->
        <Border Grid.Row="3" BorderBrush="Gray" BorderThickness="1" Background="#1E1E1E" Margin="0,0,0,5">
            <RichTextBox Name="TerminalOutput" 
                IsReadOnly="True" 
                Background="#1E1E1E" 
                Foreground="White" 
                FontFamily="Consolas" 
                FontSize="12"
                Padding="5"
                BorderThickness="0"
                VerticalScrollBarVisibility="Auto"
                HorizontalScrollBarVisibility="Auto"
                AcceptsReturn="True"/>
        </Border>
    </Grid>
</Window>
"@

# Initialize server counter and storage
$script:serverCount = 0
$script:serverControls = @()  # Store references to all server controls
$script:terminalMode = "Simple"  # Default terminal mode: Simple or Advanced

# Function to write colored output to the terminal
function Write-TerminalOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    
    $script:terminalOutput.Dispatcher.Invoke([action]{
        $paragraph = New-Object System.Windows.Documents.Paragraph
        $paragraph.Margin = New-Object System.Windows.Thickness(0)
        
        # In Advanced mode, add timestamp prefix
        if ($script:terminalMode -eq "Advanced" -and $Message -ne "") {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $timeRun = New-Object System.Windows.Documents.Run("[$timestamp] ")
            $timeRun.Foreground = [System.Windows.Media.Brushes]::DarkGray
            $paragraph.Inlines.Add($timeRun)
        }
        
        $run = New-Object System.Windows.Documents.Run($Message)
        
        switch ($Color) {
            "Green" { $run.Foreground = [System.Windows.Media.Brushes]::LimeGreen }
            "Red" { $run.Foreground = [System.Windows.Media.Brushes]::Red }
            "Yellow" { $run.Foreground = [System.Windows.Media.Brushes]::Yellow }
            "Cyan" { $run.Foreground = [System.Windows.Media.Brushes]::Cyan }
            "Magenta" { $run.Foreground = [System.Windows.Media.Brushes]::Magenta }
            "Gray" { $run.Foreground = [System.Windows.Media.Brushes]::Gray }
            default { $run.Foreground = [System.Windows.Media.Brushes]::White }
        }
    
        $paragraph.Inlines.Add($run)
        $script:terminalOutput.Document.Blocks.Add($paragraph)
        $script:terminalOutput.ScrollToEnd()
    }, "Normal")
}

# Function to create a new server box
function Add-ServerBox {
    $script:serverCount++
    
    # Create GroupBox
    $groupBox = New-Object System.Windows.Controls.GroupBox
    $groupBox.Header = "Server$($script:serverCount)"
    $groupBox.Padding = "10"
    $groupBox.Margin = "0,0,0,10"
    
    # Create Grid for layout
    $grid = New-Object System.Windows.Controls.Grid
    
    # Add row definitions
    0..3 | ForEach-Object {
        $rowDef = New-Object System.Windows.Controls.RowDefinition
        $rowDef.Height = "Auto"
        [void]$grid.RowDefinitions.Add($rowDef)
    }
    
    # Add column definitions
    $col1 = New-Object System.Windows.Controls.ColumnDefinition
    $col1.Width = 100
    $col2 = New-Object System.Windows.Controls.ColumnDefinition
    $col2.Width = "*"
    [void]$grid.ColumnDefinitions.Add($col1)
    [void]$grid.ColumnDefinitions.Add($col2)
    
    # IP Address Field
    $ipLabel = New-Object System.Windows.Controls.Label
    $ipLabel.Content = "IP Address:"
    $ipLabel.VerticalAlignment = "Center"
    $ipLabel.Margin = "0,5"
    [System.Windows.Controls.Grid]::SetRow($ipLabel, 0)
    [System.Windows.Controls.Grid]::SetColumn($ipLabel, 0)
    [void]$grid.Children.Add($ipLabel)
    
    $ipTextBox = New-Object System.Windows.Controls.TextBox
    $ipTextBox.Height = 25
    $ipTextBox.Margin = "0,5"
    $ipTextBox.Name = "IPField$($script:serverCount)"
    [System.Windows.Controls.Grid]::SetRow($ipTextBox, 0)
    [System.Windows.Controls.Grid]::SetColumn($ipTextBox, 1)
    [void]$grid.Children.Add($ipTextBox)
    
    # User Field
    $userLabel = New-Object System.Windows.Controls.Label
    $userLabel.Content = "User:"
    $userLabel.VerticalAlignment = "Center"
    $userLabel.Margin = "0,5"
    [System.Windows.Controls.Grid]::SetRow($userLabel, 1)
    [System.Windows.Controls.Grid]::SetColumn($userLabel, 0)
    [void]$grid.Children.Add($userLabel)
    
    $userTextBox = New-Object System.Windows.Controls.TextBox
    $userTextBox.Height = 25
    $userTextBox.Margin = "0,5"
    $userTextBox.Name = "UserField$($script:serverCount)"
    [System.Windows.Controls.Grid]::SetRow($userTextBox, 1)
    [System.Windows.Controls.Grid]::SetColumn($userTextBox, 1)
    [void]$grid.Children.Add($userTextBox)
    
    # Password Field
    $passwordLabel = New-Object System.Windows.Controls.Label
    $passwordLabel.Content = "Password:"
    $passwordLabel.VerticalAlignment = "Center"
    $passwordLabel.Margin = "0,5"
    [System.Windows.Controls.Grid]::SetRow($passwordLabel, 2)
    [System.Windows.Controls.Grid]::SetColumn($passwordLabel, 0)
    [void]$grid.Children.Add($passwordLabel)
    
    $passwordBox = New-Object System.Windows.Controls.PasswordBox
    $passwordBox.Height = 25
    $passwordBox.Margin = "0,5"
    $passwordBox.Name = "PasswordField$($script:serverCount)"
    [System.Windows.Controls.Grid]::SetRow($passwordBox, 2)
    [System.Windows.Controls.Grid]::SetColumn($passwordBox, 1)
    [void]$grid.Children.Add($passwordBox)
    
    # Service Field
    $serviceLabel = New-Object System.Windows.Controls.Label
    $serviceLabel.Content = "Service:"
    $serviceLabel.VerticalAlignment = "Center"
    $serviceLabel.Margin = "0,5"
    [System.Windows.Controls.Grid]::SetRow($serviceLabel, 3)
    [System.Windows.Controls.Grid]::SetColumn($serviceLabel, 0)
    [void]$grid.Children.Add($serviceLabel)
    
    $serviceComboBox = New-Object System.Windows.Controls.ComboBox
    $serviceComboBox.Height = 25
    $serviceComboBox.Margin = "0,5"
    $serviceComboBox.Name = "ServiceField$($script:serverCount)"
    @("Portainer", "AdGuard", "N8N", "Heimdall", "Crafty") | ForEach-Object {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $_
        [void]$serviceComboBox.Items.Add($item)
    }
    [System.Windows.Controls.Grid]::SetRow($serviceComboBox, 3)
    [System.Windows.Controls.Grid]::SetColumn($serviceComboBox, 1)
    [void]$grid.Children.Add($serviceComboBox)
    
    # Add grid to GroupBox
    $groupBox.Content = $grid
    
    # Add GroupBox to container
    [void]$serverContainer.Children.Add($groupBox)
    
    # Store references to controls for later retrieval
    $serverControlRefs = @{
        ServerNumber = $script:serverCount
        IPTextBox = $ipTextBox
        UserTextBox = $userTextBox
        PasswordBox = $passwordBox
        ServiceComboBox = $serviceComboBox
    }
    $script:serverControls += $serverControlRefs
}

# Function to collect all server configurations
function Get-AllServerConfigs {
    $allConfigs = @()
    
    foreach ($controls in $script:serverControls) {
        # Get selected service
        $selectedService = if ($controls.ServiceComboBox.SelectedItem) {
            $controls.ServiceComboBox.SelectedItem.Content
        } else {
            $null
        }
        
        # Create configuration hashtable
        $config = @{
            ServerNumber = $controls.ServerNumber
            IP = $controls.IPTextBox.Text
            User = $controls.UserTextBox.Text
            Password = $controls.PasswordBox.Password
            Service = $selectedService
        }
        
        $allConfigs += $config
    }
    
    return $allConfigs
}

# Function to validate IP address format
function Test-IPAddress {
    param([string]$IP)
    
    if ([string]::IsNullOrWhiteSpace($IP)) {
        return $false
    }
    
    # Try to parse as IPv4 address first (most reliable method)
    try {
        $ipObj = [System.Net.IPAddress]::Parse($IP)
        # Check if it's IPv4 (AddressFamily = InterNetwork)
        if ($ipObj.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            # Additional validation: must have exactly 4 octets in original string
            $octets = $IP.Split('.')
            if ($octets.Count -eq 4) {
                return $true
            }
        }
    }
    catch {
        # Not a valid IP, continue to hostname check
    }
    
    # Check if it's a valid hostname
    # Hostname rules: 1-63 chars per label, alphanumeric + hyphens, cannot start/end with hyphen
    $hostnamePattern = '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$'
    
    if ($IP -match $hostnamePattern) {
        # Additional check: hostname shouldn't be all numbers with dots (would look like malformed IP)
        if ($IP -notmatch '^\d+(\.\d+)*$') {
            return $true
        }
    }
    
    return $false
}

# Function to validate all server configurations
function Test-ServerConfigs {
    param($Configs)
    
    $validationErrors = @()
    
    foreach ($config in $Configs) {
        $serverNum = $config.ServerNumber
        
        # Validate IP Address
        if ([string]::IsNullOrWhiteSpace($config.IP)) {
            $validationErrors += "Server $($serverNum): IP Address is required"
        }
        elseif (-not (Test-IPAddress $config.IP)) {
            $validationErrors += "Server $($serverNum): Invalid IP Address format"
        }
        
        # Validate Username
        if ([string]::IsNullOrWhiteSpace($config.User)) {
            $validationErrors += "Server $($serverNum): Username is required"
        }
        
        # Validate Password
        if ([string]::IsNullOrWhiteSpace($config.Password)) {
            $validationErrors += "Server $($serverNum): Password is required"
        }
        
        # Validate Service Selection
        if ([string]::IsNullOrWhiteSpace($config.Service)) {
            $validationErrors += "Server $($serverNum): Service selection is required"
        }
    }
    
    return $validationErrors
}

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load( $reader )

$addServerButton = $window.FindName("AddServerButton")
$runSetupButton = $window.FindName("RunSetupButton")
$serverContainer = $window.FindName("ServerContainer")
$clearOutputButton = $window.FindName("ClearOutputButton")
$simpleTerminalButton = $window.FindName("SimpleTerminalButton")
$advancedTerminalButton = $window.FindName("AdvancedTerminalButton")
$script:terminalOutput = $window.FindName("TerminalOutput")

# Function to update terminal mode button styles
function Update-TerminalModeButtons {
    $brushConverter = New-Object System.Windows.Media.BrushConverter
    if ($script:terminalMode -eq "Simple") {
        $simpleTerminalButton.Background = $brushConverter.ConvertFromString("#4A90E2")
        $simpleTerminalButton.Foreground = [System.Windows.Media.Brushes]::White
        $advancedTerminalButton.Background = $brushConverter.ConvertFromString("#F0F0F0")
        $advancedTerminalButton.Foreground = [System.Windows.Media.Brushes]::Black
    } else {
        $simpleTerminalButton.Background = $brushConverter.ConvertFromString("#F0F0F0")
        $simpleTerminalButton.Foreground = [System.Windows.Media.Brushes]::Black
        $advancedTerminalButton.Background = $brushConverter.ConvertFromString("#4A90E2")
        $advancedTerminalButton.Foreground = [System.Windows.Media.Brushes]::White
    }
}

# Initialize button styles
Update-TerminalModeButtons

# Add first server box on startup
Add-ServerBox

# Welcome message in terminal
Write-TerminalOutput -Message "Welcome to Automated Home Lab Setup" -Color "Cyan"
Write-TerminalOutput -Message "Add servers and click 'Run Setup' to begin deployment." -Color "Gray"
Write-TerminalOutput -Message "" -Color "White"

$addServerButton.Add_Click({
    Add-ServerBox
    Write-TerminalOutput -Message "Added Server $($script:serverCount)" -Color "Green"
})

$clearOutputButton.Add_Click({
    $script:terminalOutput.Document.Blocks.Clear()
    Write-TerminalOutput -Message "Terminal cleared." -Color "Gray"
})

$simpleTerminalButton.Add_Click({
    if ($script:terminalMode -ne "Simple") {
        $script:terminalMode = "Simple"
        Update-TerminalModeButtons
        Write-TerminalOutput -Message "Switched to Simple terminal mode" -Color "Cyan"
        Write-TerminalOutput -Message "Output will be displayed without timestamps." -Color "Gray"
        Write-TerminalOutput -Message "" -Color "White"
    }
})

$advancedTerminalButton.Add_Click({
    if ($script:terminalMode -ne "Advanced") {
        $script:terminalMode = "Advanced"
        Update-TerminalModeButtons
        Write-TerminalOutput -Message "Switched to Advanced terminal mode" -Color "Cyan"
        Write-TerminalOutput -Message "Output will include timestamps and verbose details." -Color "Gray"
        Write-TerminalOutput -Message "" -Color "White"
    }
})

$runSetupButton.Add_Click({
    # Collect all server configurations
    $allServerConfigs = Get-AllServerConfigs
    
    # Validate configurations
    $validationErrors = Test-ServerConfigs -Configs $allServerConfigs
    
    if ($validationErrors.Count -gt 0) {
        # Show validation errors in terminal and message box
        Write-TerminalOutput -Message "" -Color "White"
        Write-TerminalOutput -Message "========== Validation Errors ==========" -Color "Red"
        foreach ($validationError in $validationErrors) {
            Write-TerminalOutput -Message $validationError -Color "Red"
        }
        Write-TerminalOutput -Message "=======================================" -Color "Red"
        Write-TerminalOutput -Message "" -Color "White"
        
        $errorMessage = "Please fix the following errors:`n`n" + ($validationErrors -join "`n")
        [System.Windows.MessageBox]::Show($errorMessage, "Validation Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    
    # Display configurations in terminal
    Write-TerminalOutput -Message "" -Color "White"
    Write-TerminalOutput -Message "========== Server Configurations ==========" -Color "Cyan"
    Write-TerminalOutput -Message "Total Servers: $($allServerConfigs.Count)" -Color "Green"
    Write-TerminalOutput -Message "" -Color "White"
    
    foreach ($config in $allServerConfigs) {
        Write-TerminalOutput -Message "Server $($config.ServerNumber):" -Color "Yellow"
        Write-TerminalOutput -Message "  IP Address: $($config.IP)" -Color "White"
        Write-TerminalOutput -Message "  User: $($config.User)" -Color "White"
        Write-TerminalOutput -Message "  Password: $('*' * $config.Password.Length)" -Color "White"
        Write-TerminalOutput -Message "  Service: $($config.Service)" -Color "White"
        Write-TerminalOutput -Message "" -Color "White"
    }
    
    Write-TerminalOutput -Message "==========================================" -Color "Cyan"
    Write-TerminalOutput -Message "Validation passed! Starting parallel deployment..." -Color "Green"
    Write-TerminalOutput -Message "Deploying to $($allServerConfigs.Count) server(s) simultaneously..." -Color "Cyan"
    Write-TerminalOutput -Message "" -Color "White"
    
    # Disable the Run Setup button during deployment
    $runSetupButton.IsEnabled = $false
    $runSetupButton.Content = "Deploying..."
    
    # Create a thread-safe collection for output messages
    $script:outputQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
    
    # Create runspace pool for parallel execution
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max($allServerConfigs.Count, 1))
    $runspacePool.Open()
    
    # Store all runspaces and handles
    $runspaces = @()
    
    # Define the scriptblock that will run for each server
    $serverDeploymentScript = {
        param(
            $Config,
            $OutputQueue,
            $ModulesPath
        )
        
        # Helper function to queue output messages
        function Send-Output {
            param([string]$Message, [string]$Color = "White", [int]$ServerNum)
            $OutputQueue.Enqueue(@{
                Message = $Message
                Color = $Color
                ServerNum = $ServerNum
            })
        }
        
        # Import modules in the runspace
        Import-Module "$ModulesPath\RemoteConnection.psm1" -Force
        Import-Module "$ModulesPath\ServicesDebian\DockerSetupDebian.psm1" -Force
        Import-Module "$ModulesPath\ServicesDebian\TraefikSetupDebian.psm1" -Force
        Import-Module "$ModulesPath\ServicesDebian\PortainerSetupDebian.psm1" -Force
        Import-Module "$ModulesPath\ServicesDebian\AdGuardSetupDebian.psm1" -Force
        Import-Module "$ModulesPath\ServicesDebian\N8NSetupDebian.psm1" -Force
        Import-Module "$ModulesPath\ServicesDebian\CraftySetupDebian.psm1" -Force
        Import-Module "$ModulesPath\ServicesDebian\HeimdallSetupDebian.psm1" -Force
        Import-Module "$ModulesPath\ServicesWindows\WSL2SetupWindows.psm1" -Force
        
        $serverNum = $Config.ServerNumber
        Send-Output -Message "[Server $serverNum] Starting deployment to $($Config.IP)..." -Color "Cyan" -ServerNum $serverNum
        
        # Test connection to the server
        $connectionResult = Test-RemoteConnection -IP $Config.IP -User $Config.User -Password $Config.Password
        
        if (-not $connectionResult) {
            Send-Output -Message "[Server $serverNum] Failed to connect to $($Config.IP). Skipping..." -Color "Red" -ServerNum $serverNum
            return @{ Success = $false; ServerNum = $serverNum; IP = $Config.IP; Error = "Connection failed" }
        }
        
        Send-Output -Message "[Server $serverNum] Successfully connected to $($Config.IP)" -Color "Green" -ServerNum $serverNum
        
        # Get the OS type
        $osType = Get-TargetOS -IP $Config.IP
        Send-Output -Message "[Server $serverNum] Detected OS: $osType" -Color "Cyan" -ServerNum $serverNum
        
        # Deploy service based on OS
        if ($osType -eq "Linux") {
            Send-Output -Message "[Server $serverNum] Deploying on Linux system..." -Color "Yellow" -ServerNum $serverNum
            
            # Install Docker first (required for all services)
            Send-Output -Message "[Server $serverNum] Ensuring Docker is installed..." -Color "Cyan" -ServerNum $serverNum
            $dockerInstalled = Install-Docker -IP $Config.IP -User $Config.User -Password $Config.Password
            
            if (-not $dockerInstalled) {
                Send-Output -Message "[Server $serverNum] Failed to install Docker. Skipping service deployment." -Color "Red" -ServerNum $serverNum
                return @{ Success = $false; ServerNum = $serverNum; IP = $Config.IP; Error = "Docker installation failed" }
            }
            
            # Install Traefik
            Send-Output -Message "[Server $serverNum] Installing Traefik reverse proxy..." -Color "Cyan" -ServerNum $serverNum
            $traefikSuccess = Install-Traefik -IP $Config.IP -User $Config.User -Password $Config.Password
            
            if ($traefikSuccess) {
                Send-Output -Message "[Server $serverNum] Traefik installed successfully" -Color "Green" -ServerNum $serverNum
            }
            else {
                Send-Output -Message "[Server $serverNum] Warning: Traefik installation failed, services will use direct ports" -Color "Yellow" -ServerNum $serverNum
            }
            
            # Deploy the selected service
            Send-Output -Message "[Server $serverNum] Deploying service: $($Config.Service)" -Color "Yellow" -ServerNum $serverNum
            
            $serviceSuccess = $false
            switch ($Config.Service) {
                "Portainer" {
                    $serviceSuccess = Install-Portainer -IP $Config.IP -User $Config.User -Password $Config.Password -Domain "localhost"
                    if ($serviceSuccess) {
                        Send-Output -Message "[Server $serverNum] Portainer deployed successfully" -Color "Green" -ServerNum $serverNum
                    }
                    else {
                        Send-Output -Message "[Server $serverNum] Portainer deployment failed" -Color "Red" -ServerNum $serverNum
                    }
                }
                "AdGuard" {
                    $serviceSuccess = Install-AdGuard -IP $Config.IP -User $Config.User -Password $Config.Password -Domain "localhost"
                    if ($serviceSuccess) {
                        Send-Output -Message "[Server $serverNum] AdGuard deployed successfully" -Color "Green" -ServerNum $serverNum
                    }
                    else {
                        Send-Output -Message "[Server $serverNum] AdGuard deployment failed" -Color "Red" -ServerNum $serverNum
                    }
                }
                "N8N" {
                    $serviceSuccess = Install-N8N -IP $Config.IP -User $Config.User -Password $Config.Password -Domain "localhost"
                    if ($serviceSuccess) {
                        Send-Output -Message "[Server $serverNum] n8n deployed successfully" -Color "Green" -ServerNum $serverNum
                    }
                    else {
                        Send-Output -Message "[Server $serverNum] n8n deployment failed" -Color "Red" -ServerNum $serverNum
                    }
                }
                "Heimdall" {
                    $serviceSuccess = Install-Heimdall -IP $Config.IP -User $Config.User -Password $Config.Password -Domain "localhost"
                    if ($serviceSuccess) {
                        Send-Output -Message "[Server $serverNum] Heimdall deployed successfully" -Color "Green" -ServerNum $serverNum
                    }
                    else {
                        Send-Output -Message "[Server $serverNum] Heimdall deployment failed" -Color "Red" -ServerNum $serverNum
                    }
                }
                "Crafty" {
                    $serviceSuccess = Install-Crafty -IP $Config.IP -User $Config.User -Password $Config.Password -Domain "localhost"
                    if ($serviceSuccess) {
                        Send-Output -Message "[Server $serverNum] Crafty deployed successfully" -Color "Green" -ServerNum $serverNum
                    }
                    else {
                        Send-Output -Message "[Server $serverNum] Crafty deployment failed" -Color "Red" -ServerNum $serverNum
                    }
                }
                default {
                    Send-Output -Message "[Server $serverNum] Unknown service: $($Config.Service)" -Color "Red" -ServerNum $serverNum
                }
            }
            
            Send-Output -Message "[Server $serverNum] Deployment complete" -Color "Cyan" -ServerNum $serverNum
            return @{ Success = $serviceSuccess; ServerNum = $serverNum; IP = $Config.IP; Service = $Config.Service }
        }
        elseif ($osType -eq "Windows") {
            Send-Output -Message "[Server $serverNum] Deploying on Windows system..." -Color "Yellow" -ServerNum $serverNum
            
            # Step 1: Install WSL2 first (with automatic reboot if needed)
            Send-Output -Message "[Server $serverNum] Step 1: Installing WSL2 (required for containerized services)..." -Color "Cyan" -ServerNum $serverNum
            $wsl2Result = Install-WSL2 -IP $Config.IP -User $Config.User -Password $Config.Password -Distribution "Ubuntu" -AutoReboot -WaitForReboot
            
            # Handle the new return format (hashtable with Success, NeedsReboot, Ready properties)
            $wsl2Success = $false
            $wsl2NeedsReboot = $false
            $wsl2Ready = $false
            
            if ($wsl2Result -is [hashtable]) {
                $wsl2Success = $wsl2Result.Success
                $wsl2NeedsReboot = $wsl2Result.NeedsReboot
                $wsl2Ready = $wsl2Result.Ready
            }
            elseif ($wsl2Result -is [bool]) {
                # Backward compatibility
                $wsl2Success = $wsl2Result
                $wsl2Ready = $wsl2Result
            }
            
            if (-not $wsl2Success) {
                Send-Output -Message "[Server $serverNum] WSL2 installation failed. Cannot proceed with service deployment." -Color "Red" -ServerNum $serverNum
                Send-Output -Message "[Server $serverNum] Please ensure WSL2 prerequisites are met and try again." -Color "Yellow" -ServerNum $serverNum
                return @{ Success = $false; ServerNum = $serverNum; IP = $Config.IP; Error = "WSL2 installation failed" }
            }
            
            # Check if reboot is still required
            if ($wsl2NeedsReboot -and -not $wsl2Ready) {
                Send-Output -Message "[Server $serverNum] SYSTEM REBOOT STILL REQUIRED" -Color "Yellow" -ServerNum $serverNum
                Send-Output -Message "[Server $serverNum] Automatic reboot may have failed. Please reboot manually." -Color "Yellow" -ServerNum $serverNum
                return @{ Success = $false; ServerNum = $serverNum; IP = $Config.IP; Error = "Reboot required" }
            }
            
            Send-Output -Message "[Server $serverNum] WSL2 is ready" -Color "Green" -ServerNum $serverNum
            
            # Step 2: Deploy the selected service inside WSL2
            Send-Output -Message "[Server $serverNum] Step 2: Deploying service inside WSL2: $($Config.Service)" -Color "Yellow" -ServerNum $serverNum
            Send-Output -Message "[Server $serverNum] Connecting to WSL2 instance..." -Color "Cyan" -ServerNum $serverNum
            
            # Install Docker in WSL2 (required for all services)
            Send-Output -Message "[Server $serverNum] Ensuring Docker is installed in WSL2..." -Color "Cyan" -ServerNum $serverNum
            $dockerInstalled = Install-Docker -IP $Config.IP -User $Config.User -Password $Config.Password
            
            if (-not $dockerInstalled) {
                Send-Output -Message "[Server $serverNum] Failed to install Docker in WSL2. Skipping service deployment." -Color "Red" -ServerNum $serverNum
                Send-Output -Message "[Server $serverNum] This may indicate WSL2 is not fully ready." -Color "Yellow" -ServerNum $serverNum
                return @{ Success = $false; ServerNum = $serverNum; IP = $Config.IP; Error = "Docker in WSL2 failed" }
            }
            
            # Install Traefik
            Send-Output -Message "[Server $serverNum] Installing Traefik reverse proxy in WSL2..." -Color "Cyan" -ServerNum $serverNum
            $traefikSuccess = Install-Traefik -IP $Config.IP -User $Config.User -Password $Config.Password
            
            if ($traefikSuccess) {
                Send-Output -Message "[Server $serverNum] Traefik installed successfully in WSL2" -Color "Green" -ServerNum $serverNum
            }
            else {
                Send-Output -Message "[Server $serverNum] Warning: Traefik installation failed, services will use direct ports" -Color "Yellow" -ServerNum $serverNum
            }
            
            # Deploy the selected service in WSL2
            $serviceSuccess = $false
            switch ($Config.Service) {
                "Portainer" {
                    $serviceSuccess = Install-Portainer -IP $Config.IP -User $Config.User -Password $Config.Password -Domain "localhost"
                    if ($serviceSuccess) {
                        Send-Output -Message "[Server $serverNum] Portainer deployed successfully in WSL2" -Color "Green" -ServerNum $serverNum
                    }
                    else {
                        Send-Output -Message "[Server $serverNum] Portainer deployment failed" -Color "Red" -ServerNum $serverNum
                    }
                }
                "AdGuard" {
                    $serviceSuccess = Install-AdGuard -IP $Config.IP -User $Config.User -Password $Config.Password -Domain "localhost"
                    if ($serviceSuccess) {
                        Send-Output -Message "[Server $serverNum] AdGuard deployed successfully in WSL2" -Color "Green" -ServerNum $serverNum
                    }
                    else {
                        Send-Output -Message "[Server $serverNum] AdGuard deployment failed" -Color "Red" -ServerNum $serverNum
                    }
                }
                "N8N" {
                    $serviceSuccess = Install-N8N -IP $Config.IP -User $Config.User -Password $Config.Password -Domain "localhost"
                    if ($serviceSuccess) {
                        Send-Output -Message "[Server $serverNum] n8n deployed successfully in WSL2" -Color "Green" -ServerNum $serverNum
                    }
                    else {
                        Send-Output -Message "[Server $serverNum] n8n deployment failed" -Color "Red" -ServerNum $serverNum
                    }
                }
                "Heimdall" {
                    $serviceSuccess = Install-Heimdall -IP $Config.IP -User $Config.User -Password $Config.Password -Domain "localhost"
                    if ($serviceSuccess) {
                        Send-Output -Message "[Server $serverNum] Heimdall deployed successfully in WSL2" -Color "Green" -ServerNum $serverNum
                    }
                    else {
                        Send-Output -Message "[Server $serverNum] Heimdall deployment failed" -Color "Red" -ServerNum $serverNum
                    }
                }
                "Crafty" {
                    $serviceSuccess = Install-Crafty -IP $Config.IP -User $Config.User -Password $Config.Password -Domain "localhost"
                    if ($serviceSuccess) {
                        Send-Output -Message "[Server $serverNum] Crafty deployed successfully in WSL2" -Color "Green" -ServerNum $serverNum
                    }
                    else {
                        Send-Output -Message "[Server $serverNum] Crafty deployment failed" -Color "Red" -ServerNum $serverNum
                    }
                }
                default {
                    Send-Output -Message "[Server $serverNum] Unknown service: $($Config.Service)" -Color "Red" -ServerNum $serverNum
                }
            }
            
            Send-Output -Message "[Server $serverNum] Deployment complete" -Color "Cyan" -ServerNum $serverNum
            return @{ Success = $serviceSuccess; ServerNum = $serverNum; IP = $Config.IP; Service = $Config.Service }
        }
        else {
            Send-Output -Message "[Server $serverNum] Unable to detect OS type. Skipping deployment." -Color "Red" -ServerNum $serverNum
            return @{ Success = $false; ServerNum = $serverNum; IP = $Config.IP; Error = "Unknown OS" }
        }
    }
    
    # Start parallel deployment for each server
    foreach ($config in $allServerConfigs) {
        $powershell = [powershell]::Create()
        $powershell.RunspacePool = $runspacePool
        
        [void]$powershell.AddScript($serverDeploymentScript)
        [void]$powershell.AddArgument($config)
        [void]$powershell.AddArgument($script:outputQueue)
        [void]$powershell.AddArgument("$PSScriptRoot\modules")
        
        $handle = $powershell.BeginInvoke()
        
        $runspaces += @{
            PowerShell = $powershell
            Handle = $handle
            ServerNum = $config.ServerNumber
        }
    }
    
    # Create a timer to poll for output messages and check completion
    $script:deploymentTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:deploymentTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:deploymentRunspaces = $runspaces
    $script:deploymentRunspacePool = $runspacePool
    $script:deploymentResults = @()
    
    $script:deploymentTimer.Add_Tick({
        # Process any queued output messages
        $outputItem = $null
        while ($script:outputQueue.TryDequeue([ref]$outputItem)) {
            Write-TerminalOutput -Message $outputItem.Message -Color $outputItem.Color
        }
        
        # Check if all runspaces are complete
        $allComplete = $true
        foreach ($rs in $script:deploymentRunspaces) {
            if (-not $rs.Handle.IsCompleted) {
                $allComplete = $false
                break
            }
        }
        
        if ($allComplete) {
            # Stop the timer
            $script:deploymentTimer.Stop()
            
            # Collect results
            foreach ($rs in $script:deploymentRunspaces) {
                try {
                    $result = $rs.PowerShell.EndInvoke($rs.Handle)
                    if ($result) {
                        $script:deploymentResults += $result
                    }
                }
                catch {
                    Write-TerminalOutput -Message "[Server $($rs.ServerNum)] Error: $_" -Color "Red"
                }
                finally {
                    $rs.PowerShell.Dispose()
                }
            }
            
            # Process any remaining queued messages
            $outputItem = $null
            while ($script:outputQueue.TryDequeue([ref]$outputItem)) {
                Write-TerminalOutput -Message $outputItem.Message -Color $outputItem.Color
            }
            
            # Clean up runspace pool
            $script:deploymentRunspacePool.Close()
            $script:deploymentRunspacePool.Dispose()
            
            # Summary
            Write-TerminalOutput -Message "" -Color "White"
            Write-TerminalOutput -Message "========== Deployment Summary ==========" -Color "Cyan"
            
            $successCount = ($script:deploymentResults | Where-Object { $_.Success -eq $true }).Count
            $failCount = ($script:deploymentResults | Where-Object { $_.Success -eq $false }).Count
            
            Write-TerminalOutput -Message "Successful: $successCount" -Color "Green"
            Write-TerminalOutput -Message "Failed: $failCount" -Color $(if ($failCount -gt 0) { "Red" } else { "Green" })
            
            foreach ($result in $script:deploymentResults) {
                if ($result.Success) {
                    Write-TerminalOutput -Message "  [Server $($result.ServerNum)] $($result.IP) - $($result.Service): SUCCESS" -Color "Green"
                }
                else {
                    Write-TerminalOutput -Message "  [Server $($result.ServerNum)] $($result.IP): FAILED - $($result.Error)" -Color "Red"
                }
            }
            
            Write-TerminalOutput -Message "========== Parallel Deployment Complete ==========" -Color "Cyan"
            Write-TerminalOutput -Message "" -Color "White"
            
            # Re-enable the button
            $runSetupButton.IsEnabled = $true
            $runSetupButton.Content = "Run Setup"
        }
    })
    
    # Start the timer
    $script:deploymentTimer.Start()
})

#Show the Window
$window.ShowDialog() | Out-Null