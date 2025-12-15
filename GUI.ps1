#Load WPF assemblies
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

#Load modules
Import-Module "$PSScriptRoot\modules\RemoteConnection.psm1" -Force

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

# Function to write colored output to the terminal
function Write-TerminalOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    
    $script:terminalOutput.Dispatcher.Invoke([action]{
        $paragraph = New-Object System.Windows.Documents.Paragraph
        $paragraph.Margin = New-Object System.Windows.Thickness(0)
        
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
    @("AdGuard", "N8N", "Heimdall", "Crafty", "Portainer") | ForEach-Object {
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
$script:terminalOutput = $window.FindName("TerminalOutput")

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
    Write-TerminalOutput -Message "Validation passed! Starting deployment..." -Color "Green"
    Write-TerminalOutput -Message "" -Color "White"
    
    # Test connections and deploy services
    foreach ($config in $allServerConfigs) {
        Write-TerminalOutput -Message "--- Processing Server $($config.ServerNumber) ---" -Color "Cyan"
        
        # Test connection to the server
        $connectionSuccess = Test-RemoteConnection -IP $config.IP -User $config.User -Password $config.Password
        
        if ($connectionSuccess) {
            Write-TerminalOutput -Message "Successfully connected to $($config.IP)" -Color "Green"
            Write-TerminalOutput -Message "Deploying service: $($config.Service)" -Color "Yellow"
            
            # TODO: Add service deployment logic here
            # Example: Deploy-Service -Config $config
        }
        else {
            Write-TerminalOutput -Message "Failed to connect to $($config.IP). Skipping..." -Color "Red"
        }
        Write-TerminalOutput -Message "" -Color "White"
    }
    
    Write-TerminalOutput -Message "========== Deployment Complete ==========" -Color "Cyan"
    Write-TerminalOutput -Message "" -Color "White"
    
    # TODO: Pass $allServerConfigs to your automation scripts
    # Example: Start-ServerSetup -Configs $allServerConfigs
})

#Show the Window
$window.ShowDialog() | Out-Null