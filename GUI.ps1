#Load WPF assemblies
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Determine script root
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptRoot) { $scriptRoot = Get-Location }

# --- NEW: INITIALIZE SERVICE CONFIGS ---
$servicesDir = Join-Path $scriptRoot "configs\services"
if (-not (Test-Path $servicesDir)) {
    New-Item -ItemType Directory -Path $servicesDir -Force | Out-Null
    
    $defaultPortainer = @"
services:
  portainer:
    container_name: portainer
    image: portainer/portainer-ce:lts
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    expose:
      - 9443
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host('portainer.localhost')"
      - "traefik.http.routers.portainer.entrypoints=websecure"
      - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"
      - "traefik.http.services.portainer.loadbalancer.server.port=9443"
      - "traefik.http.services.portainer.loadbalancer.server.scheme=https"
networks:
  traefik-network:
    external: true
"@
    $defaultPortainer | Out-File (Join-Path $servicesDir "Portainer.yml") -Encoding UTF8
    
    #Default config for Portainer without Traefik
    $defaultPortainerNoTraefik = @"
services:
  portainer:
    container_name: portainer
    image: portainer/portainer-ce:lts
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    ports:
      - "9000:9000"
      - "9443:9443"
"@
    $defaultPortainerNoTraefik | Out-File (Join-Path $servicesDir "Portainer-NoTraefik.yml") -Encoding UTF8
}
# ---------------------------------------

# Load the consolidated RMSetup module (contains all functionality)
Import-Module (Join-Path $scriptRoot "modules\RMSetup.psm1") -Force -Scope Global

# Initialize logging
$logPath = Initialize-Logging -LogLevel "Info" -LogToFile $true -LogToConsole $false
Write-SessionSeparator -SessionName "Automated Server Setup Tool"
Write-LogInfo -Message "Application started" -Component "GUI"

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
            <Button Name="RunSetupButton" Content="Run Setup" Width="120" Height="35" Background="Green" Foreground="White" FontSize="14" Margin="0,0,10,0"/>
            <Button Name="HealthMonitorButton" Content="Health Monitor" Width="130" Height="35" Background="#2196F3" Foreground="White" FontSize="14" Margin="0,0,10,0"/>
            <Button Name="ManageServicesButton" Content="Manage Services" Width="130" Height="35" Background="#9C27B0" Foreground="White" FontSize="14"/>
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

<#
.SYNOPSIS
    Writes colored, formatted text to the WPF terminal output area.
.DESCRIPTION
    Because background runspaces cannot directly modify WPF UI elements (cross-thread violation), 
    this function uses `$script:terminalOutput.Dispatcher.Invoke` to safely push text updates 
    to the main UI thread. It also handles timestamp prefixes when in 'Advanced' mode.
.PARAMETER Message
    The string message to display in the terminal.
.PARAMETER Color
    The brush color for the text (e.g., "Green", "Red", "Cyan"). Defaults to "White".
.OUTPUTS
    None. Modifies the UI directly.
#>
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

<#
.SYNOPSIS
    Dynamically generates and adds a new server configuration group to the UI.
.DESCRIPTION
    Instead of hardcoding a fixed number of server inputs, this function programmatically builds 
    WPF elements (TextBoxes, ComboBoxes, CheckBoxes) and appends them to the main StackPanel. 
    It stores object references in `$script:serverControls` so their values can be retrieved later.
.OUTPUTS
    None. Appends XAML elements to the UI.
#>
function Add-ServerBox {
    $script:serverCount++
    $groupBox = New-Object System.Windows.Controls.GroupBox
    $groupBox.Header = "Server$($script:serverCount)"
    $groupBox.Padding = "10"
    $groupBox.Margin = "0,0,0,10"
    $grid = New-Object System.Windows.Controls.Grid
    
    0..6 | ForEach-Object {
        $rowDef = New-Object System.Windows.Controls.RowDefinition
        $rowDef.Height = "Auto"
        [void]$grid.RowDefinitions.Add($rowDef)
    }
    
    $col1 = New-Object System.Windows.Controls.ColumnDefinition
    $col1.Width = 100
    $col2 = New-Object System.Windows.Controls.ColumnDefinition
    $col2.Width = "*"
    [void]$grid.ColumnDefinitions.Add($col1)
    [void]$grid.ColumnDefinitions.Add($col2)
    
    # 0. IP
    $ipLabel = New-Object System.Windows.Controls.Label; $ipLabel.Content = "IP Address:"; $ipLabel.VerticalAlignment = "Center"; $ipLabel.Margin = "0,5"
    [System.Windows.Controls.Grid]::SetRow($ipLabel, 0); [System.Windows.Controls.Grid]::SetColumn($ipLabel, 0); [void]$grid.Children.Add($ipLabel)
    $ipTextBox = New-Object System.Windows.Controls.TextBox; $ipTextBox.Height = 25; $ipTextBox.Margin = "0,5"; $ipTextBox.Name = "IPField$($script:serverCount)"
    [System.Windows.Controls.Grid]::SetRow($ipTextBox, 0); [System.Windows.Controls.Grid]::SetColumn($ipTextBox, 1); [void]$grid.Children.Add($ipTextBox)
    
    # 1. User
    $userLabel = New-Object System.Windows.Controls.Label; $userLabel.Content = "User:"; $userLabel.VerticalAlignment = "Center"; $userLabel.Margin = "0,5"
    [System.Windows.Controls.Grid]::SetRow($userLabel, 1); [System.Windows.Controls.Grid]::SetColumn($userLabel, 0); [void]$grid.Children.Add($userLabel)
    $userTextBox = New-Object System.Windows.Controls.TextBox; $userTextBox.Height = 25; $userTextBox.Margin = "0,5"; $userTextBox.Name = "UserField$($script:serverCount)"
    [System.Windows.Controls.Grid]::SetRow($userTextBox, 1); [System.Windows.Controls.Grid]::SetColumn($userTextBox, 1); [void]$grid.Children.Add($userTextBox)
    
    # 2. Password
    $passwordLabel = New-Object System.Windows.Controls.Label; $passwordLabel.Content = "Password:"; $passwordLabel.VerticalAlignment = "Center"; $passwordLabel.Margin = "0,5"
    [System.Windows.Controls.Grid]::SetRow($passwordLabel, 2); [System.Windows.Controls.Grid]::SetColumn($passwordLabel, 0); [void]$grid.Children.Add($passwordLabel)
    $passwordBox = New-Object System.Windows.Controls.PasswordBox; $passwordBox.Height = 25; $passwordBox.Margin = "0,5"; $passwordBox.Name = "PasswordField$($script:serverCount)"
    [System.Windows.Controls.Grid]::SetRow($passwordBox, 2); [System.Windows.Controls.Grid]::SetColumn($passwordBox, 1); [void]$grid.Children.Add($passwordBox)
    
    # 3. Service
    $serviceLabel = New-Object System.Windows.Controls.Label; $serviceLabel.Content = "Service:"; $serviceLabel.VerticalAlignment = "Center"; $serviceLabel.Margin = "0,5"
    [System.Windows.Controls.Grid]::SetRow($serviceLabel, 3); [System.Windows.Controls.Grid]::SetColumn($serviceLabel, 0); [void]$grid.Children.Add($serviceLabel)
    $serviceComboBox = New-Object System.Windows.Controls.ComboBox; $serviceComboBox.Height = 25; $serviceComboBox.Margin = "0,5"; $serviceComboBox.Name = "ServiceField$($script:serverCount)"
    $serviceFiles = Get-ChildItem -Path $servicesDir -Filter "*.yml"
    foreach ($file in $serviceFiles) {
        $item = New-Object System.Windows.Controls.ComboBoxItem; $item.Content = $file.BaseName; [void]$serviceComboBox.Items.Add($item)
    }
    [System.Windows.Controls.Grid]::SetRow($serviceComboBox, 3); [System.Windows.Controls.Grid]::SetColumn($serviceComboBox, 1); [void]$grid.Children.Add($serviceComboBox)

    # 4. Traefik
    $traefikLabel = New-Object System.Windows.Controls.Label; $traefikLabel.Content = "Use Traefik:"; $traefikLabel.VerticalAlignment = "Center"; $traefikLabel.Margin = "0,5"
    [System.Windows.Controls.Grid]::SetRow($traefikLabel, 4); [System.Windows.Controls.Grid]::SetColumn($traefikLabel, 0); [void]$grid.Children.Add($traefikLabel)
    $traefikCheckBox = New-Object System.Windows.Controls.CheckBox; $traefikCheckBox.IsChecked = $true; $traefikCheckBox.VerticalAlignment = "Center"; $traefikCheckBox.Margin = "0,5"
    [System.Windows.Controls.Grid]::SetRow($traefikCheckBox, 4); [System.Windows.Controls.Grid]::SetColumn($traefikCheckBox, 1); [void]$grid.Children.Add($traefikCheckBox)
    
    # 5. SSH Config
    $sshLabel = New-Object System.Windows.Controls.Label; $sshLabel.Content = "SSH Config:"; $sshLabel.VerticalAlignment = "Center"; $sshLabel.Margin = "0,5"
    [System.Windows.Controls.Grid]::SetRow($sshLabel, 5); [System.Windows.Controls.Grid]::SetColumn($sshLabel, 0); [void]$grid.Children.Add($sshLabel)
    $sshStack = New-Object System.Windows.Controls.StackPanel; $sshStack.Orientation = "Horizontal"
    $sshCheckBox = New-Object System.Windows.Controls.CheckBox; $sshCheckBox.Content = "Enable"; $sshCheckBox.IsChecked = $true; $sshCheckBox.VerticalAlignment = "Center"; $sshCheckBox.Margin = "0,0,10,0"
    $sshPortLabel = New-Object System.Windows.Controls.Label; $sshPortLabel.Content = "Port:"; $sshPortLabel.VerticalAlignment = "Center"; $sshPortLabel.Margin = "0,0,5,0"
    $sshPortBox = New-Object System.Windows.Controls.TextBox; $sshPortBox.Text = "22"; $sshPortBox.Width = 40; $sshPortBox.Height = 25; $sshPortBox.VerticalAlignment = "Center"
    [void]$sshStack.Children.Add($sshCheckBox); [void]$sshStack.Children.Add($sshPortLabel); [void]$sshStack.Children.Add($sshPortBox)
    [System.Windows.Controls.Grid]::SetRow($sshStack, 5); [System.Windows.Controls.Grid]::SetColumn($sshStack, 1); [void]$grid.Children.Add($sshStack)
    
    # 6. WinRM Config
    $winrmLabel = New-Object System.Windows.Controls.Label; $winrmLabel.Content = "WinRM Config:"; $winrmLabel.VerticalAlignment = "Center"; $winrmLabel.Margin = "0,5"
    [System.Windows.Controls.Grid]::SetRow($winrmLabel, 6); [System.Windows.Controls.Grid]::SetColumn($winrmLabel, 0); [void]$grid.Children.Add($winrmLabel)
    $winrmStack = New-Object System.Windows.Controls.StackPanel; $winrmStack.Orientation = "Horizontal"
    $winrmCheckBox = New-Object System.Windows.Controls.CheckBox; $winrmCheckBox.Content = "Enable"; $winrmCheckBox.IsChecked = $true; $winrmCheckBox.VerticalAlignment = "Center"; $winrmCheckBox.Margin = "0,0,10,0"
    $winrmPortLabel = New-Object System.Windows.Controls.Label; $winrmPortLabel.Content = "Port:"; $winrmPortLabel.VerticalAlignment = "Center"; $winrmPortLabel.Margin = "0,0,5,0"
    $winrmPortBox = New-Object System.Windows.Controls.TextBox; $winrmPortBox.Text = "5985"; $winrmPortBox.Width = 40; $winrmPortBox.Height = 25; $winrmPortBox.VerticalAlignment = "Center"
    [void]$winrmStack.Children.Add($winrmCheckBox); [void]$winrmStack.Children.Add($winrmPortLabel); [void]$winrmStack.Children.Add($winrmPortBox)
    [System.Windows.Controls.Grid]::SetRow($winrmStack, 6); [System.Windows.Controls.Grid]::SetColumn($winrmStack, 1); [void]$grid.Children.Add($winrmStack)
    
    $groupBox.Content = $grid
    [void]$serverContainer.Children.Add($groupBox)
    
    $script:serverControls += @{
        ServerNumber = $script:serverCount; IPTextBox = $ipTextBox; UserTextBox = $userTextBox; PasswordBox = $passwordBox; ServiceComboBox = $serviceComboBox
        UseTraefikCheckBox = $traefikCheckBox; SSHCheckBox = $sshCheckBox; SSHPortBox = $sshPortBox; WinRMCheckBox = $winrmCheckBox; WinRMPortBox = $winrmPortBox
    }
}

<#
.SYNOPSIS
    Gathers the user inputs from all dynamically created Server UI blocks.
.DESCRIPTION
    Iterates through the UI control references and maps them into an array of PSCustomObjects. 
    It uses the unary comma (,$allConfigs) in the return statement to explicitly prevent 
    PowerShell from automatically "unrolling" single-item arrays.
.OUTPUTS
    Array of PSCustomObjects containing the IP, Credentials, and Configuration for each server.
#>
function Get-AllServerConfigs {
    $allConfigs = @()
    foreach ($controls in $script:serverControls) {
        $sp = if ([string]::IsNullOrWhiteSpace($controls.SSHPortBox.Text)) { 22 } else { [int]$controls.SSHPortBox.Text }
        $wp = if ([string]::IsNullOrWhiteSpace($controls.WinRMPortBox.Text)) { 5985 } else { [int]$controls.WinRMPortBox.Text }
        
        $config = [PSCustomObject]@{
            ServerNumber = $controls.ServerNumber
            IP = $controls.IPTextBox.Text
            User = $controls.UserTextBox.Text
            Password = $controls.PasswordBox.Password
            Service = if ($controls.ServiceComboBox.SelectedItem) { $controls.ServiceComboBox.SelectedItem.Content } else { $null }
            UseTraefik = [bool]$controls.UseTraefikCheckBox.IsChecked
            EnableSSH = [bool]$controls.SSHCheckBox.IsChecked
            SSHPort = $sp
            EnableWinRM = [bool]$controls.WinRMCheckBox.IsChecked
            WinRMPort = $wp
        }
        $allConfigs += $config
    }
    return ,$allConfigs
}

<#
.SYNOPSIS
    Validates if a string is a properly formatted IPv4 address or Hostname.
.DESCRIPTION
    Runs early validation to ensure malformed IPs are caught before background threads 
    attempt to initiate connections, which would otherwise result in long TCP timeout waits.
.PARAMETER IP
    The IP string or Hostname to validate.
.OUTPUTS
    Boolean ($true if valid, $false if invalid).
#>
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

<#
.SYNOPSIS
    Validates the array of server configurations for empty fields and logic errors.
.DESCRIPTION
    Iterates through the collected form data to enforce business logic: ensures usernames, IPs, 
    and passwords exist, verifies that at least one remote connection protocol is enabled, and 
    checks that custom ports are within the 1-65535 valid TCP range.
.PARAMETER Configs
    The array of PSCustomObjects returned by Get-AllServerConfigs.
.OUTPUTS
    An array of string error messages. If empty, validation passed.
#>
function Test-ServerConfigs {
    param($Configs)
    $validationErrors = @()
    foreach ($config in $Configs) {
        $serverNum = $config.ServerNumber
        if ([string]::IsNullOrWhiteSpace($config.IP)) { $validationErrors += "Server $($serverNum): IP Address is required" }
        elseif (-not (Test-IPAddress $config.IP)) { $validationErrors += "Server $($serverNum): Invalid IP Address format" }
        if ([string]::IsNullOrWhiteSpace($config.User)) { $validationErrors += "Server $($serverNum): Username is required" }
        if ([string]::IsNullOrWhiteSpace($config.Password)) { $validationErrors += "Server $($serverNum): Password is required" }
        if ([string]::IsNullOrWhiteSpace($config.Service)) { $validationErrors += "Server $($serverNum): Service selection is required" }
        
        if (-not $config.EnableSSH -and -not $config.EnableWinRM) { $validationErrors += "Server $($serverNum): Must enable at least SSH or WinRM" }
        if ($config.EnableSSH -and ($config.SSHPort -le 0 -or $config.SSHPort -gt 65535)) { $validationErrors += "Server $($serverNum): Invalid SSH Port" }
        if ($config.EnableWinRM -and ($config.WinRMPort -le 0 -or $config.WinRMPort -gt 65535)) { $validationErrors += "Server $($serverNum): Invalid WinRM Port" }
    }
    return $validationErrors
}

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load( $reader )

$addServerButton = $window.FindName("AddServerButton")
$runSetupButton = $window.FindName("RunSetupButton")
$healthMonitorButton = $window.FindName("HealthMonitorButton")
$manageServicesButton = $window.FindName("ManageServicesButton")
$serverContainer = $window.FindName("ServerContainer")
$clearOutputButton = $window.FindName("ClearOutputButton")
$simpleTerminalButton = $window.FindName("SimpleTerminalButton")
$advancedTerminalButton = $window.FindName("AdvancedTerminalButton")
$script:terminalOutput = $window.FindName("TerminalOutput")

<#
.SYNOPSIS
    Visually updates the Simple and Advanced terminal mode toggle buttons.
.DESCRIPTION
    Swaps background and foreground colors to indicate which terminal verbosity mode is active.
.OUTPUTS
    None. Modifies the UI.
#>
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

<#
.SYNOPSIS
    Creates and manages the dedicated Health Monitor UI window.
.DESCRIPTION
    Because health polling is slow, this window spins up parallel runspaces to poll servers via SSH/WinRM 
    in the background. It uses a DispatcherTimer to sweep an output queue and update the UI securely, 
    preventing the WPF application from freezing during network waits.
.PARAMETER ServerConfigs
    Array of validated server configurations to monitor.
.OUTPUTS
    None. Renders an interactive modal window.
#>
function Show-HealthMonitorWindow {
    param($ServerConfigs)
    
    Write-LogInfo -Message "Opening Health Monitor window" -Component "HealthMonitor"
    
    # Create the Health Monitor Window XAML
    [xml]$healthXaml = @"
<Window 
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Server &amp; Container Health Monitor" 
    Height="700" 
    Width="1000"
    WindowStartupLocation="CenterScreen">
    
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <!-- Control Bar -->
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
            <Button Name="RefreshButton" Content="  Refresh All" Width="120" Height="30" Margin="0,0,10,0" FontSize="12"/>
            <Button Name="AutoRefreshButton" Content="Auto-Refresh: OFF" Width="140" Height="30" Margin="0,0,10,0" FontSize="12"/>
            <Label Content="Interval:" VerticalAlignment="Center" Margin="10,0,5,0"/>
            <ComboBox Name="RefreshIntervalCombo" Width="80" Height="30" VerticalAlignment="Center">
                <ComboBoxItem Content="10 sec" IsSelected="True"/>
                <ComboBoxItem Content="30 sec"/>
                <ComboBoxItem Content="1 min"/>
                <ComboBoxItem Content="5 min"/>
            </ComboBox>
        </StackPanel>
        
        <!-- Status Summary -->
        <Border Grid.Row="1" Background="#F5F5F5" CornerRadius="5" Padding="10" Margin="0,0,0,10">
            <StackPanel Orientation="Horizontal">
                <TextBlock Name="SummaryText" Text="Select servers to monitor..." FontSize="14" VerticalAlignment="Center"/>
            </StackPanel>
        </Border>
        
        <!-- Main Content Area -->
        <TabControl Grid.Row="2">
            <TabItem Header="Server Health">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Name="ServerHealthPanel" Margin="10"/>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Container Health">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Name="ContainerHealthPanel" Margin="10"/>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Health Report">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="10">
                        <Button Name="GenerateReportButton" Content="Generate Full Report" Width="150" Height="30"/>
                        <Button Name="ExportReportButton" Content="Export Report" Width="120" Height="30" Margin="10,0,0,0"/>
                    </StackPanel>
                    <RichTextBox Name="ReportOutput" Grid.Row="1" 
                         IsReadOnly="True" 
                         Background="#1E1E1E" 
                         Foreground="White" 
                         FontFamily="Consolas" 
                         FontSize="11"
                        Padding="10"
                        Margin="10"
                        VerticalScrollBarVisibility="Auto"
                        HorizontalScrollBarVisibility="Auto"/>
                </Grid>
            </TabItem>
        </TabControl>
        
        <!-- Status Bar -->
        <Border Grid.Row="3" Background="#E0E0E0" Padding="5" Margin="0,10,0,0">
            <TextBlock Name="StatusBarText" Text="Ready" FontSize="11"/>
        </Border>
    </Grid>
</Window>
"@
    $healthReader = New-Object System.Xml.XmlNodeReader $healthXaml
    $healthWindow = [Windows.Markup.XamlReader]::Load($healthReader)
    
    # Find controls
    $refreshButton = $healthWindow.FindName("RefreshButton")
    $autoRefreshButton = $healthWindow.FindName("AutoRefreshButton")
    $refreshIntervalCombo = $healthWindow.FindName("RefreshIntervalCombo")
    $summaryText = $healthWindow.FindName("SummaryText")
    $serverHealthPanel = $healthWindow.FindName("ServerHealthPanel")
    $containerHealthPanel = $healthWindow.FindName("ContainerHealthPanel")
    $generateReportButton = $healthWindow.FindName("GenerateReportButton")
    $exportReportButton = $healthWindow.FindName("ExportReportButton")
    $reportOutput = $healthWindow.FindName("ReportOutput")
    $statusBarText = $healthWindow.FindName("StatusBarText")
    
    # Auto-refresh state
    $script:autoRefreshEnabled = $false
    $script:autoRefreshTimer = $null
    $script:lastHealthData = @{}
    
    <#
    .SYNOPSIS
        Thread-safely writes to the generated Health Report RichTextBox.
    .DESCRIPTION
        Uses WPF Dispatcher to push formatted string chunks from the background report builder.
    #>
    function Write-ReportOutput {
        param([string]$Message, [string]$Color = "White")
        
        $reportOutput.Dispatcher.Invoke([action]{
            $paragraph = New-Object System.Windows.Documents.Paragraph
            $paragraph.Margin = New-Object System.Windows.Thickness(0)
            $run = New-Object System.Windows.Documents.Run($Message)
            
            switch ($Color) {
                "Green" { $run.Foreground = [System.Windows.Media.Brushes]::LimeGreen }
                "Red" { $run.Foreground = [System.Windows.Media.Brushes]::Red }
                "Yellow" { $run.Foreground = [System.Windows.Media.Brushes]::Yellow }
                "Cyan" { $run.Foreground = [System.Windows.Media.Brushes]::Cyan }
                "Gray" { $run.Foreground = [System.Windows.Media.Brushes]::Gray }
                default { $run.Foreground = [System.Windows.Media.Brushes]::White }
            }
            
            $paragraph.Inlines.Add($run)
            $reportOutput.Document.Blocks.Add($paragraph)
        }, "Normal")
    }
    
    <#
    .SYNOPSIS
        Builds a WPF UI Border card containing server metrics (CPU, RAM, Disk).
    .DESCRIPTION
        Constructs the visual component dynamically for each server, using color-coded 
        backgrounds corresponding to the health severity.
    #>
    function New-ServerHealthCard {
        param($ServerConfig, $HealthData)
        
        $border = New-Object System.Windows.Controls.Border
        $border.BorderBrush = [System.Windows.Media.Brushes]::Gray
        $border.BorderThickness = New-Object System.Windows.Thickness(1)
        $border.CornerRadius = New-Object System.Windows.CornerRadius(5)
        $border.Padding = New-Object System.Windows.Thickness(10)
        $border.Margin = New-Object System.Windows.Thickness(0,0,0,10)
        
        # Set background color based on status
        $brushConverter = New-Object System.Windows.Media.BrushConverter
        if ($HealthData.StatusColor -eq "Red") {
            $border.Background = $brushConverter.ConvertFromString("#FFEBEE")
        }
        elseif ($HealthData.StatusColor -eq "Yellow") {
            $border.Background = $brushConverter.ConvertFromString("#FFF8E1")
        }
        else {
            $border.Background = $brushConverter.ConvertFromString("#E8F5E9")
        }
        
        $grid = New-Object System.Windows.Controls.Grid
        
        # Column definitions
        $col1 = New-Object System.Windows.Controls.ColumnDefinition
        $col1.Width = "200"
        $col2 = New-Object System.Windows.Controls.ColumnDefinition
        $col2.Width = "*"
        [void]$grid.ColumnDefinitions.Add($col1)
        [void]$grid.ColumnDefinitions.Add($col2)
        
        # Server info
        $serverInfo = New-Object System.Windows.Controls.StackPanel
        [System.Windows.Controls.Grid]::SetColumn($serverInfo, 0)
        
        $ipText = New-Object System.Windows.Controls.TextBlock
        $ipText.Text = "Server: $($ServerConfig.IP)"
        $ipText.FontWeight = "Bold"
        $ipText.FontSize = 14
        [void]$serverInfo.Children.Add($ipText)
        
        $statusText = New-Object System.Windows.Controls.TextBlock
        $statusText.Text = "Status: $($HealthData.Status)"
        $statusText.FontSize = 12
        if ($HealthData.StatusColor -eq "Red") { $statusText.Foreground = [System.Windows.Media.Brushes]::Red }
        elseif ($HealthData.StatusColor -eq "Yellow") { $statusText.Foreground = [System.Windows.Media.Brushes]::Orange }
        else { $statusText.Foreground = [System.Windows.Media.Brushes]::Green }
        [void]$serverInfo.Children.Add($statusText)
        
        if ($HealthData.OSType) {
            $osText = New-Object System.Windows.Controls.TextBlock
            $osText.Text = "OS: $($HealthData.OSType)"
            $osText.FontSize = 11
            $osText.Foreground = [System.Windows.Media.Brushes]::Gray
            [void]$serverInfo.Children.Add($osText)
        }
        
        [void]$grid.Children.Add($serverInfo)
        
        # Metrics
        $metricsPanel = New-Object System.Windows.Controls.WrapPanel
        [System.Windows.Controls.Grid]::SetColumn($metricsPanel, 1)
        
        if ($HealthData.CPU) {
            $cpuBorder = New-Object System.Windows.Controls.Border
            $cpuBorder.Background = [System.Windows.Media.Brushes]::White
            $cpuBorder.CornerRadius = New-Object System.Windows.CornerRadius(3)
            $cpuBorder.Padding = New-Object System.Windows.Thickness(8,4,8,4)
            $cpuBorder.Margin = New-Object System.Windows.Thickness(5)
            $cpuText = New-Object System.Windows.Controls.TextBlock
            $cpuText.Text = "CPU: $($HealthData.CPU.UsagePercent)%"
            $cpuBorder.Child = $cpuText
            [void]$metricsPanel.Children.Add($cpuBorder)
        }
        
        if ($HealthData.Memory) {
            $memBorder = New-Object System.Windows.Controls.Border
            $memBorder.Background = [System.Windows.Media.Brushes]::White
            $memBorder.CornerRadius = New-Object System.Windows.CornerRadius(3)
            $memBorder.Padding = New-Object System.Windows.Thickness(8,4,8,4)
            $memBorder.Margin = New-Object System.Windows.Thickness(5)
            $memText = New-Object System.Windows.Controls.TextBlock
            $memText.Text = "Memory: $($HealthData.Memory.UsagePercent)%"
            $memBorder.Child = $memText
            [void]$metricsPanel.Children.Add($memBorder)
        }
        
        if ($HealthData.Disk) {
            $diskBorder = New-Object System.Windows.Controls.Border
            $diskBorder.Background = [System.Windows.Media.Brushes]::White
            $diskBorder.CornerRadius = New-Object System.Windows.CornerRadius(3)
            $diskBorder.Padding = New-Object System.Windows.Thickness(8,4,8,4)
            $diskBorder.Margin = New-Object System.Windows.Thickness(5)
            $diskText = New-Object System.Windows.Controls.TextBlock
            $diskText.Text = "Disk: $($HealthData.Disk.UsagePercent)%"
            $diskBorder.Child = $diskText
            [void]$metricsPanel.Children.Add($diskBorder)
        }
        
        if ($HealthData.Uptime) {
            $uptimeBorder = New-Object System.Windows.Controls.Border
            $uptimeBorder.Background = [System.Windows.Media.Brushes]::White
            $uptimeBorder.CornerRadius = New-Object System.Windows.CornerRadius(3)
            $uptimeBorder.Padding = New-Object System.Windows.Thickness(8,4,8,4)
            $uptimeBorder.Margin = New-Object System.Windows.Thickness(5)
            $uptimeText = New-Object System.Windows.Controls.TextBlock
            $uptimeText.Text = "Uptime: $($HealthData.Uptime)"
            $uptimeBorder.Child = $uptimeText
            [void]$metricsPanel.Children.Add($uptimeBorder)
        }
        
        [void]$grid.Children.Add($metricsPanel)
        
        $border.Child = $grid
        return $border
    }
    
    <#
    .SYNOPSIS
        Builds a WPF UI Border card displaying Docker containers with interactive controls.
    .DESCRIPTION
        Generates action buttons (Start/Stop/Restart) for every container. The buttons store the server's 
        connection credentials in their `.Tag` property so they can securely reach out via SSH/WinRM 
        when clicked without cross-contamination.
    #>
    function New-ContainerHealthCard {
        param($ServerConfig, $ContainerData)
        
        $border = New-Object System.Windows.Controls.Border
        $border.BorderBrush = [System.Windows.Media.Brushes]::Gray
        $border.BorderThickness = New-Object System.Windows.Thickness(1)
        $border.CornerRadius = New-Object System.Windows.CornerRadius(5)
        $border.Padding = New-Object System.Windows.Thickness(10)
        $border.Margin = New-Object System.Windows.Thickness(0,0,0,10)
        
        $brushConverter = New-Object System.Windows.Media.BrushConverter
        if ($ContainerData.StatusColor -eq "Red") {
            $border.Background = $brushConverter.ConvertFromString("#FFEBEE")
        }
        elseif ($ContainerData.StatusColor -eq "Yellow") {
            $border.Background = $brushConverter.ConvertFromString("#FFF8E1")
        }
        else {
            $border.Background = $brushConverter.ConvertFromString("#E8F5E9")
        }
        
        $mainStack = New-Object System.Windows.Controls.StackPanel
        
        # Header
        $headerText = New-Object System.Windows.Controls.TextBlock
        $headerText.Text = "Server: $($ServerConfig.IP) - Containers ($($ContainerData.RunningContainers)/$($ContainerData.TotalContainers) running)"
        $headerText.FontWeight = "Bold"
        $headerText.FontSize = 14
        $headerText.Margin = New-Object System.Windows.Thickness(0,0,0,10)
        [void]$mainStack.Children.Add($headerText)
        
        # Container list
        if ($ContainerData.Containers -and $ContainerData.Containers.Count -gt 0) {
            foreach ($container in $ContainerData.Containers) {
                $containerBorder = New-Object System.Windows.Controls.Border
                $containerBorder.Background = [System.Windows.Media.Brushes]::White
                $containerBorder.CornerRadius = New-Object System.Windows.CornerRadius(3)
                $containerBorder.Padding = New-Object System.Windows.Thickness(8)
                $containerBorder.Margin = New-Object System.Windows.Thickness(0,0,0,5)
                
                $containerGrid = New-Object System.Windows.Controls.Grid
                $col1 = New-Object System.Windows.Controls.ColumnDefinition
                $col1.Width = "150"
                $col2 = New-Object System.Windows.Controls.ColumnDefinition
                $col2.Width = "*"
                $col3 = New-Object System.Windows.Controls.ColumnDefinition
                $col3.Width = "100"
                $col4 = New-Object System.Windows.Controls.ColumnDefinition
                $col4.Width = "110"
                
                [void]$containerGrid.ColumnDefinitions.Add($col1)
                [void]$containerGrid.ColumnDefinitions.Add($col2)
                [void]$containerGrid.ColumnDefinitions.Add($col3)
                [void]$containerGrid.ColumnDefinitions.Add($col4)
                
                # Container name with state icon
                $namePanel = New-Object System.Windows.Controls.StackPanel
                $namePanel.Orientation = "Horizontal"
                [System.Windows.Controls.Grid]::SetColumn($namePanel, 0)
                
                $stateIcon = New-Object System.Windows.Controls.TextBlock
                if ($container.State -eq "running") {
                    $stateIcon.Text = "🟢 "
                    $stateIcon.Foreground = [System.Windows.Media.Brushes]::Green
                }
                else {
                    $stateIcon.Text = "🔴 "
                    $stateIcon.Foreground = [System.Windows.Media.Brushes]::Red
                }
                [void]$namePanel.Children.Add($stateIcon)
                
                $nameText = New-Object System.Windows.Controls.TextBlock
                $nameText.Text = $container.Name
                $nameText.FontWeight = "SemiBold"
                [void]$namePanel.Children.Add($nameText)
                [void]$containerGrid.Children.Add($namePanel)
                
                # Container status and metrics
                $statusPanel = New-Object System.Windows.Controls.StackPanel
                $statusPanel.Orientation = "Horizontal"
                [System.Windows.Controls.Grid]::SetColumn($statusPanel, 1)
                
                $statusInfo = New-Object System.Windows.Controls.TextBlock
                $statusInfo.Text = "$($container.Status)"
                $statusInfo.Foreground = [System.Windows.Media.Brushes]::Gray
                $statusInfo.Margin = New-Object System.Windows.Thickness(10,0,10,0)
                [void]$statusPanel.Children.Add($statusInfo)
                
                if ($container.State -eq "running" -and $container.CPUPercent) {
                    $resourceInfo = New-Object System.Windows.Controls.TextBlock
                    $resourceInfo.Text = "| CPU: $($container.CPUPercent)% | Mem: $($container.MemoryPercent)%"
                    $resourceInfo.Foreground = [System.Windows.Media.Brushes]::DarkGray
                    [void]$statusPanel.Children.Add($resourceInfo)
                }
                
                [void]$containerGrid.Children.Add($statusPanel)
                
                # Container image
                $imageText = New-Object System.Windows.Controls.TextBlock
                $imageText.Text = $container.Image
                $imageText.Foreground = [System.Windows.Media.Brushes]::Gray
                $imageText.FontSize = 10
                $imageText.TextTrimming = "CharacterEllipsis"
                $imageText.VerticalAlignment = "Center"
                [System.Windows.Controls.Grid]::SetColumn($imageText, 2)
                [void]$containerGrid.Children.Add($imageText)
                
                # --- Action Buttons ---
                $actionPanel = New-Object System.Windows.Controls.StackPanel
                $actionPanel.Orientation = "Horizontal"
                $actionPanel.HorizontalAlignment = "Right"
                [System.Windows.Controls.Grid]::SetColumn($actionPanel, 3)
                
                $tagData = @{ Config = $ServerConfig; ContainerName = $container.Name }
                $btnStart = New-Object System.Windows.Controls.Button
                $btnStart.Content = "▶"
                $btnStart.ToolTip = "Start Container"
                $btnStart.Width = 30
                $btnStart.Height = 22
                $btnStart.Margin = New-Object System.Windows.Thickness(2)
                $btnStart.IsEnabled = ($container.State -ne "running")
                $btnStart.Tag = $tagData
                $btnStart.Add_Click({
                    $data = $this.Tag
                    $statusBarText.Text = "Starting $($data.ContainerName) on $($data.Config.IP)..."
                    $this.Dispatcher.Invoke([action]{}, "Background")
                    Set-ConnectionConfig -SSHPort $data.Config.SSHPort -WinRMPort $data.Config.WinRMPort -EnableSSH $data.Config.EnableSSH -EnableWinRM $data.Config.EnableWinRM
                    $res = Start-Container -IP $data.Config.IP -User $data.Config.User -Password $data.Config.Password -ContainerName $data.ContainerName
                    if ($res) { $statusBarText.Text = "Started $($data.ContainerName)." } else { $statusBarText.Text = "Failed to start $($data.ContainerName)." }
                    Refresh-HealthData
                })

                $btnStop = New-Object System.Windows.Controls.Button
                $btnStop.Content = "■"
                $btnStop.ToolTip = "Stop Container"
                $btnStop.Width = 30
                $btnStop.Height = 22
                $btnStop.Margin = New-Object System.Windows.Thickness(2)
                $btnStop.IsEnabled = ($container.State -eq "running")
                $btnStop.Tag = $tagData
                $btnStop.Add_Click({
                    $data = $this.Tag
                    $statusBarText.Text = "Starting $($data.ContainerName) on $($data.Config.IP)..."
                    $this.Dispatcher.Invoke([action]{}, "Background")
                    Set-ConnectionConfig -SSHPort $data.Config.SSHPort -WinRMPort $data.Config.WinRMPort -EnableSSH $data.Config.EnableSSH -EnableWinRM $data.Config.EnableWinRM
                    $res = Start-Container -IP $data.Config.IP -User $data.Config.User -Password $data.Config.Password -ContainerName $data.ContainerName
                    if ($res) { $statusBarText.Text = "Started $($data.ContainerName)." } else { $statusBarText.Text = "Failed to start $($data.ContainerName)." }
                    Refresh-HealthData
                })

                $btnRestart = New-Object System.Windows.Controls.Button
                $btnRestart.Content = "↻"
                $btnRestart.ToolTip = "Restart Container"
                $btnRestart.Width = 30
                $btnRestart.Height = 22
                $btnRestart.Margin = New-Object System.Windows.Thickness(2)
                $btnRestart.Tag = $tagData
                $btnRestart.Add_Click({
                    $data = $this.Tag
                    $statusBarText.Text = "Starting $($data.ContainerName) on $($data.Config.IP)..."
                    $this.Dispatcher.Invoke([action]{}, "Background")
                    Set-ConnectionConfig -SSHPort $data.Config.SSHPort -WinRMPort $data.Config.WinRMPort -EnableSSH $data.Config.EnableSSH -EnableWinRM $data.Config.EnableWinRM
                    $res = Start-Container -IP $data.Config.IP -User $data.Config.User -Password $data.Config.Password -ContainerName $data.ContainerName
                    if ($res) { $statusBarText.Text = "Started $($data.ContainerName)." } else { $statusBarText.Text = "Failed to start $($data.ContainerName)." }
                    Refresh-HealthData
                })

                [void]$actionPanel.Children.Add($btnStart)
                [void]$actionPanel.Children.Add($btnStop)
                [void]$actionPanel.Children.Add($btnRestart)
                [void]$containerGrid.Children.Add($actionPanel)
                # ---------------------------
                
                $containerBorder.Child = $containerGrid
                [void]$mainStack.Children.Add($containerBorder)
            }
        }
        else {
            $noContainersText = New-Object System.Windows.Controls.TextBlock
            $noContainersText.Text = "No containers found"
            $noContainersText.Foreground = [System.Windows.Media.Brushes]::Gray
            $noContainersText.FontStyle = "Italic"
            [void]$mainStack.Children.Add($noContainersText)
        }
        
        $border.Child = $mainStack
        return $border
    }
    
    # Thread-safe queue for health data results
    $script:healthDataQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
    $script:healthRefreshInProgress = $false
    $script:healthRefreshTimer = $null
    
    <#
    .SYNOPSIS
        Initiates parallel background jobs to fetch server metrics.
    .DESCRIPTION
        Executes a concurrent RunspacePool to prevent the WPF UI from hanging while waiting 
        for SSH/WinRM responses. A timer polls the `$script:healthDataQueue` to render new cards.
    #>
    function Refresh-HealthData {
        if ($script:healthRefreshInProgress) {
            $statusBarText.Text = "Refresh already in progress..."
            return
        }
        
        $script:healthRefreshInProgress = $true
        $refreshButton.IsEnabled = $false
        $refreshButton.Content = "  Refreshing..."
        $statusBarText.Text = "Refreshing health data in background..."
        
        # Show loading indicators
        $serverHealthPanel.Children.Clear()
        $containerHealthPanel.Children.Clear()
        
        $loadingText = New-Object System.Windows.Controls.TextBlock
        $loadingText.Text = "Loading server health data..."
        $loadingText.FontStyle = "Italic"
        $loadingText.Foreground = [System.Windows.Media.Brushes]::Gray
        $loadingText.Margin = New-Object System.Windows.Thickness(10)
        [void]$serverHealthPanel.Children.Add($loadingText)
        
        $loadingText2 = New-Object System.Windows.Controls.TextBlock
        $loadingText2.Text = "Loading container health data..."
        $loadingText2.FontStyle = "Italic"
        $loadingText2.Foreground = [System.Windows.Media.Brushes]::Gray
        $loadingText2.Margin = New-Object System.Windows.Thickness(10)
        [void]$containerHealthPanel.Children.Add($loadingText2)
        
        # Clear the queue
        $tempItem = $null
        while ($script:healthDataQueue.TryDequeue([ref]$tempItem)) { }
        
        # Create runspace pool for parallel health checks
        $runspacePool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max($ServerConfigs.Count, 1))
        $runspacePool.Open()
        
        $runspaces = @()
        
        # Script block that runs in background
        $healthCheckScript = {
            param($Config, $OutputQueue, $ModulesPath)
            
            Import-Module "$ModulesPath\RMSetup.psm1" -Force -ErrorAction SilentlyContinue
            Set-ConnectionConfig -SSHPort $Config.SSHPort -WinRMPort $Config.WinRMPort -EnableSSH $Config.EnableSSH -EnableWinRM $Config.EnableWinRM
            
            $serverHealth = $null
            $containerHealth = $null
            
            # Detect target OS once and pass it down to eliminate redundant TCP port probing
            $osType = Get-TargetOS -IP $Config.IP
            
            try {
                # Get server health with cached OS
                $serverHealth = Get-ServerHealth -IP $Config.IP -User $Config.User -Password $Config.Password -OSType $osType
            }
            catch {
                $serverHealth = [PSCustomObject]@{
                    IP = $Config.IP
                    Status = "Error"
                    StatusColor = "Red"
                    ErrorMessage = $_.Exception.Message
                    LastChecked = Get-Date
                }
            }
            
            try {
                # Get container health with cached OS
                $containerHealth = Get-ContainerHealth -IP $Config.IP -User $Config.User -Password $Config.Password -OSType $osType
            }
            catch {
                $containerHealth = [PSCustomObject]@{
                    ServerIP = $Config.IP
                    Status = "Error"
                    StatusColor = "Red"
                    TotalContainers = 0
                    RunningContainers = 0
                    Containers = @()
                    ErrorMessage = $_.Exception.Message
                }
            }
            
            # Queue the results
            $OutputQueue.Enqueue(@{
                Type = "HealthData"
                Config = $Config
                ServerHealth = $serverHealth
                ContainerHealth = $containerHealth
            })
            
            return @{
                IP = $Config.IP
                ServerHealth = $serverHealth
                ContainerHealth = $containerHealth
            }
        }
        
        # Start background jobs for each server
        foreach ($config in $ServerConfigs) {
            if ([string]::IsNullOrWhiteSpace($config.IP)) { continue }
            
            $powershell = [powershell]::Create()
            $powershell.RunspacePool = $runspacePool
            
            [void]$powershell.AddScript($healthCheckScript)
            [void]$powershell.AddArgument($config)
            [void]$powershell.AddArgument($script:healthDataQueue)
            [void]$powershell.AddArgument("$PSScriptRoot\modules")
            
            $handle = $powershell.BeginInvoke()
            
            $runspaces += @{
                PowerShell = $powershell
                Handle = $handle
                Config = $config
            }
        }
        
        # Store runspace info for the timer
        $script:healthRunspaces = $runspaces
        $script:healthRunspacePool = $runspacePool
        $script:healthResults = @()
        
        # Create timer to poll for completion
        $script:healthRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:healthRefreshTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        
        $script:healthRefreshTimer.Add_Tick({
            # Process queued results
            $item = $null
            while ($script:healthDataQueue.TryDequeue([ref]$item)) {
                if ($item.Type -eq "HealthData") {
                    $script:healthResults += $item
                }
            }
            
            # Check if all runspaces are complete
            $allComplete = $true
            foreach ($rs in $script:healthRunspaces) {
                if (-not $rs.Handle.IsCompleted) {
                    $allComplete = $false
                    break
                }
            }
            
            if ($allComplete) {
                # Stop timer
                $script:healthRefreshTimer.Stop()
                
                # Collect any remaining results
                foreach ($rs in $script:healthRunspaces) {
                    try {
                        $result = $rs.PowerShell.EndInvoke($rs.Handle)
                        if ($result -and $result.ServerHealth) {
                            # Check if we already have this result from queue
                            $existing = $script:healthResults | Where-Object { $_.Config.IP -eq $result.IP }
                            if (-not $existing) {
                                $script:healthResults += @{
                                    Config = $rs.Config
                                    ServerHealth = $result.ServerHealth
                                    ContainerHealth = $result.ContainerHealth
                                }
                            }
                        }
                    }
                    catch {
                        # Add error result
                        $script:healthResults += @{
                            Config = $rs.Config
                            ServerHealth = [PSCustomObject]@{
                                IP = $rs.Config.IP
                                Status = "Error"
                                StatusColor = "Red"
                                ErrorMessage = $_.Exception.Message
                            }
                            ContainerHealth = [PSCustomObject]@{
                                ServerIP = $rs.Config.IP
                                Status = "Error"
                                StatusColor = "Red"
                                TotalContainers = 0
                                RunningContainers = 0
                                Containers = @()
                            }
                        }
                    }
                    finally {
                        $rs.PowerShell.Dispose()
                    }
                }
                
                # Cleanup runspace pool
                $script:healthRunspacePool.Close()
                $script:healthRunspacePool.Dispose()
                
                # Update UI with results
                $serverHealthPanel.Children.Clear()
                $containerHealthPanel.Children.Clear()
                
                $healthyCount = 0
                $warningCount = 0
                $criticalCount = 0
                
                foreach ($result in $script:healthResults) {
                    # Store in last health data
                    $script:lastHealthData[$result.Config.IP] = @{
                        Server = $result.ServerHealth
                        Containers = $result.ContainerHealth
                    }
                    
                    # Create server health card
                    $serverCard = New-ServerHealthCard -ServerConfig $result.Config -HealthData $result.ServerHealth
                    [void]$serverHealthPanel.Children.Add($serverCard)
                    
                    # Count statuses
                    switch ($result.ServerHealth.Status) {
                        "Healthy" { $healthyCount++ }
                        "Warning" { $warningCount++ }
                        "Degraded" { $warningCount++ }
                        default { $criticalCount++ }
                    }
                    
                    # Create container health card
                    $containerCard = New-ContainerHealthCard -ServerConfig $result.Config -ContainerData $result.ContainerHealth
                    [void]$containerHealthPanel.Children.Add($containerCard)
                }
                
                # Update summary
                $summaryText.Text = "Servers: $($ServerConfigs.Count) |   Healthy: $healthyCount |   Warning: $warningCount |   Critical: $criticalCount | Last Updated: $(Get-Date -Format 'HH:mm:ss')"
                $statusBarText.Text = "Ready - Last refresh: $(Get-Date -Format 'HH:mm:ss')"
                
                # Re-enable button
                $refreshButton.IsEnabled = $true
                $refreshButton.Content = "  Refresh All"
                $script:healthRefreshInProgress = $false
                
                Write-LogInfo -Message "Health data refreshed for $($script:healthResults.Count) server(s)" -Component "HealthMonitor"
            }
        })
        
        # Start the timer
        $script:healthRefreshTimer.Start()
    }
    
    # Refresh button click handler
    $refreshButton.Add_Click({
        Refresh-HealthData
    })
    
    # Auto-refresh button click handler
    $autoRefreshButton.Add_Click({
        if ($script:autoRefreshEnabled) {
            # Disable auto-refresh
            $script:autoRefreshEnabled = $false
            $autoRefreshButton.Content = "Auto-Refresh: OFF"
            if ($script:autoRefreshTimer) {
                $script:autoRefreshTimer.Stop()
            }
            $statusBarText.Text = "Auto-refresh disabled"
        }
        else {
            # Enable auto-refresh
            $script:autoRefreshEnabled = $true
            $autoRefreshButton.Content = "Auto-Refresh: ON"
            
            # Get interval
            $intervalText = $refreshIntervalCombo.SelectedItem.Content
            $intervalMs = switch ($intervalText) {
                "10 sec" { 10000 }
                "30 sec" { 30000 }
                "1 min" { 60000 }
                "5 min" { 300000 }
                default { 30000 }
            }
            
            # Create and start timer
            $script:autoRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:autoRefreshTimer.Interval = [TimeSpan]::FromMilliseconds($intervalMs)
            $script:autoRefreshTimer.Add_Tick({ Refresh-HealthData })
            $script:autoRefreshTimer.Start()
            
            $statusBarText.Text = "Auto-refresh enabled (every $intervalText)"
        }
    })
    
    # Generate report button click handler
    $generateReportButton.Add_Click({
        $reportOutput.Document.Blocks.Clear()
        Write-ReportOutput -Message "Generating comprehensive health report in background..." -Color "Cyan"
        Write-ReportOutput -Message "" -Color "White"
        
        $generateReportButton.IsEnabled = $false
        $generateReportButton.Content = "Generating..."
        $statusBarText.Text = "Generating health report..."
        
        # Create queue for report output
        $script:reportQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
        
        # Create runspace pool
        $reportRunspacePool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max($ServerConfigs.Count, 1))
        $reportRunspacePool.Open()
        
        $reportRunspaces = @()
        
        # Script for generating report
        $reportScript = {
            param($Config, $OutputQueue, $ModulesPath)
            
            # Use consolidated RMSetup module
            Import-Module "$ModulesPath\RMSetup.psm1" -Force -ErrorAction SilentlyContinue
            Set-ConnectionConfig -SSHPort $Config.SSHPort -WinRMPort $Config.WinRMPort -EnableSSH $Config.EnableSSH -EnableWinRM $Config.EnableWinRM
            
            try {
                $fullReport = Get-FullHealthReport -IP $Config.IP -User $Config.User -Password $Config.Password
                $formattedReport = Format-HealthReport -HealthReport $fullReport
                
                $OutputQueue.Enqueue(@{
                    Type = "Report"
                    IP = $Config.IP
                    Report = $formattedReport
                    Success = $true
                })
            }
            catch {
                $OutputQueue.Enqueue(@{
                    Type = "Report"
                    IP = $Config.IP
                    Report = "Error generating report for $($Config.IP): $($_.Exception.Message)"
                    Success = $false
                })
            }
        }
        
        # Start report generation for each server
        foreach ($config in $ServerConfigs) {
            if ([string]::IsNullOrWhiteSpace($config.IP)) { continue }
            
            $powershell = [powershell]::Create()
            $powershell.RunspacePool = $reportRunspacePool
            
            [void]$powershell.AddScript($reportScript)
            [void]$powershell.AddArgument($config)
            [void]$powershell.AddArgument($script:reportQueue)
            [void]$powershell.AddArgument("$PSScriptRoot\modules")
            
            $handle = $powershell.BeginInvoke()
            
            $reportRunspaces += @{
                PowerShell = $powershell
                Handle = $handle
            }
        }
        
        # Store for timer
        $script:reportRunspaces = $reportRunspaces
        $script:reportRunspacePool = $reportRunspacePool
        
        # Timer to poll for completion
        $script:reportTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:reportTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        
        $script:reportTimer.Add_Tick({
            # Process queued reports
            $item = $null
            while ($script:reportQueue.TryDequeue([ref]$item)) {
                if ($item.Type -eq "Report") {
                    foreach ($line in ($item.Report -split "`n")) {
                        $color = "White"
                        if ($line -match "Healthy|SUCCESS|running") { $color = "Green" }
                        elseif ($line -match "Critical|Error|FAILED|stopped") { $color = "Red" }
                        elseif ($line -match "Warning|Degraded") { $color = "Yellow" }
                        elseif ($line -match " ") { $color = "Cyan" }
                        
                        Write-ReportOutput -Message $line -Color $color
                    }
                    Write-ReportOutput -Message "" -Color "White"
                }
            }
            
            # Check if complete
            $allComplete = $true
            foreach ($rs in $script:reportRunspaces) {
                if (-not $rs.Handle.IsCompleted) {
                    $allComplete = $false
                    break
                }
            }
            
            if ($allComplete) {
                $script:reportTimer.Stop()
                
                # Cleanup
                foreach ($rs in $script:reportRunspaces) {
                    try { $rs.PowerShell.EndInvoke($rs.Handle) } catch { }
                    $rs.PowerShell.Dispose()
                }
                
                $script:reportRunspacePool.Close()
                $script:reportRunspacePool.Dispose()
                
                Write-ReportOutput -Message "Report generation complete." -Color "Cyan"
                $generateReportButton.IsEnabled = $true
                $generateReportButton.Content = "Generate Full Report"
                $statusBarText.Text = "Full health report generated"
            }
        })
        
        $script:reportTimer.Start()
    })
    
    # Export report button click handler
    $exportReportButton.Add_Click({
        # Use cached data if available, otherwise show message
        if ($script:lastHealthData.Count -eq 0) {
            [System.Windows.MessageBox]::Show("Please refresh health data first before exporting.", "No Data", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            return
        }
        
        $saveDialog = New-Object Microsoft.Win32.SaveFileDialog
        $saveDialog.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"
        $saveDialog.DefaultExt = ".txt"
        $saveDialog.FileName = "health-report_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').txt"
        
        if ($saveDialog.ShowDialog() -eq $true) {
            $exportReportButton.IsEnabled = $false
            $exportReportButton.Content = "Exporting..."
            $statusBarText.Text = "Exporting report..."
            
            # Create queue for export
            $script:exportQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
            
            # Create runspace pool
            $exportRunspacePool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max($ServerConfigs.Count, 1))
            $exportRunspacePool.Open()
            
            $exportRunspaces = @()
            
            $exportScript = {
                param($Config, $OutputQueue, $ModulesPath)
                
                # Use consolidated RMSetup module
                Import-Module "$ModulesPath\RMSetup.psm1" -Force -ErrorAction SilentlyContinue
                Set-ConnectionConfig -SSHPort $Config.SSHPort -WinRMPort $Config.WinRMPort -EnableSSH $Config.EnableSSH -EnableWinRM $Config.EnableWinRM
                
                try {
                    $fullReport = Get-FullHealthReport -IP $Config.IP -User $Config.User -Password $Config.Password
                    $formattedReport = Format-HealthReport -HealthReport $fullReport
                    
                    $OutputQueue.Enqueue(@{
                        Type = "ExportData"
                        Report = $formattedReport
                    })
                }
                catch {
                    $OutputQueue.Enqueue(@{
                        Type = "ExportData"
                        Report = "Error: $($_.Exception.Message)"
                    })
                }
            }
            
            foreach ($config in $ServerConfigs) {
                if ([string]::IsNullOrWhiteSpace($config.IP)) { continue }
                
                $powershell = [powershell]::Create()
                $powershell.RunspacePool = $exportRunspacePool
                
                [void]$powershell.AddScript($exportScript)
                [void]$powershell.AddArgument($config)
                [void]$powershell.AddArgument($script:exportQueue)
                [void]$powershell.AddArgument("$PSScriptRoot\modules")
                
                $handle = $powershell.BeginInvoke()
                
                $exportRunspaces += @{
                    PowerShell = $powershell
                    Handle = $handle
                }
            }
            
            $script:exportRunspaces = $exportRunspaces
            $script:exportRunspacePool = $exportRunspacePool
            $script:exportContent = @()
            $script:exportFilePath = $saveDialog.FileName
            
            $script:exportTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:exportTimer.Interval = [TimeSpan]::FromMilliseconds(200)
            
            $script:exportTimer.Add_Tick({
                $item = $null
                while ($script:exportQueue.TryDequeue([ref]$item)) {
                    if ($item.Type -eq "ExportData") {
                        $script:exportContent += $item.Report
                        $script:exportContent += "`n"
                    }
                }
                
                $allComplete = $true
                foreach ($rs in $script:exportRunspaces) {
                    if (-not $rs.Handle.IsCompleted) {
                        $allComplete = $false
                        break
                    }
                }
                
                if ($allComplete) {
                    $script:exportTimer.Stop()
                    
                    foreach ($rs in $script:exportRunspaces) {
                        try { $rs.PowerShell.EndInvoke($rs.Handle) } catch { }
                        $rs.PowerShell.Dispose()
                    }
                    
                    $script:exportRunspacePool.Close()
                    $script:exportRunspacePool.Dispose()
                    
                    # Write to file
                    $script:exportContent | Out-File -FilePath $script:exportFilePath -Encoding UTF8
                    
                    $exportReportButton.IsEnabled = $true
                    $exportReportButton.Content = "Export Report"
                    $statusBarText.Text = "Report exported to: $($script:exportFilePath)"
                    [System.Windows.MessageBox]::Show("Health report exported successfully!", "Export Complete", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
                }
            })
            
            $script:exportTimer.Start()
        }
    })
    
    # Window closing handler - cleanup timers
    $healthWindow.Add_Closing({
        if ($script:autoRefreshTimer) {
            $script:autoRefreshTimer.Stop()
        }
        if ($script:healthRefreshTimer) {
            $script:healthRefreshTimer.Stop()
        }
        if ($script:reportTimer) {
            $script:reportTimer.Stop()
        }
        if ($script:exportTimer) {
            $script:exportTimer.Stop()
        }
    })
    
    # Initial refresh if we have server configs
    if ($ServerConfigs.Count -gt 0) {
        Refresh-HealthData
    }
    else {
        $summaryText.Text = "No servers configured. Add servers in the main window first."
        $statusBarText.Text = "No servers to monitor"
    }
    
    # Show the window
    $healthWindow.ShowDialog() | Out-Null
}

<#
.SYNOPSIS
    Pops up a window for users to manage Docker Compose YAML files.
.DESCRIPTION
    Instead of hardcoding files or making the user edit text manually, this allows on-the-fly 
    creation, editing, and deletion of service configurations from the local directory.
.OUTPUTS
    None. Displays an interactive WPF sub-window.
#>
function Show-ManageServicesWindow {
    [xml]$manageXaml = @"
<Window 
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    Title="Manage Custom Services" Height="600" Width="800" WindowStartupLocation="CenterScreen">
    <Grid Margin="10">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="200"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <ListBox Name="ServiceList" Grid.Column="0" Grid.Row="0" Margin="0,0,10,10"/>
        
        <StackPanel Grid.Column="0" Grid.Row="1" Orientation="Horizontal">
            <Button Name="NewServiceButton" Content="New Service" Width="90" Height="30" Margin="0,0,10,0"/>
            <Button Name="DeleteServiceButton" Content="Delete" Width="90" Height="30" Background="Red" Foreground="White"/>
        </StackPanel>
        
        <TextBox Name="ComposeEditor" Grid.Column="1" Grid.Row="0" AcceptsReturn="True" AcceptsTab="True" FontFamily="Consolas" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Margin="0,0,0,10"/>
        <Button Name="SaveServiceButton" Grid.Column="1" Grid.Row="1" Content="Save Compose File" Height="30" Background="Green" Foreground="White"/>
    </Grid>
</Window>
"@
    $manageReader = New-Object System.Xml.XmlNodeReader $manageXaml
    $manageWindow = [Windows.Markup.XamlReader]::Load($manageReader)
    
    $serviceList = $manageWindow.FindName("ServiceList")
    $newButton = $manageWindow.FindName("NewServiceButton")
    $deleteButton = $manageWindow.FindName("DeleteServiceButton")
    $editor = $manageWindow.FindName("ComposeEditor")
    $saveButton = $manageWindow.FindName("SaveServiceButton")
    
    <#
    .SYNOPSIS
        Populates the ListBox with available .yml files.
    #>
    function Load-ServiceList {
        $serviceList.Items.Clear()
        Get-ChildItem -Path $servicesDir -Filter "*.yml" | ForEach-Object {
            [void]$serviceList.Items.Add($_.BaseName)
        }
    }
    
    Load-ServiceList
    
    $serviceList.Add_SelectionChanged({
        if ($serviceList.SelectedItem) {
            $path = Join-Path $servicesDir "$($serviceList.SelectedItem).yml"
            $editor.Text = Get-Content $path -Raw
        }
    })
    
    $newButton.Add_Click({
        $newName = [Microsoft.VisualBasic.Interaction]::InputBox("Enter new service name (no spaces):", "New Service")
        if (-not [string]::IsNullOrWhiteSpace($newName)) {
            $newName = $newName -replace '\s','_'
            $path = Join-Path $servicesDir "$newName.yml"
            "services:`n  ${newName}:`n    image: " | Out-File $path -Encoding UTF8
            Load-ServiceList
        }
    })
    
    $saveButton.Add_Click({
        if ($serviceList.SelectedItem) {
            $path = Join-Path $servicesDir "$($serviceList.SelectedItem).yml"
            $editor.Text | Out-File $path -Encoding UTF8
            [System.Windows.MessageBox]::Show("Compose file saved!", "Success")
        }
    })
    
    $deleteButton.Add_Click({
        if ($serviceList.SelectedItem) {
            $path = Join-Path $servicesDir "$($serviceList.SelectedItem).yml"
            Remove-Item $path -Force
            $editor.Text = ""
            Load-ServiceList
        }
    })
    
    $manageWindow.ShowDialog() | Out-Null
}

$manageServicesButton.Add_Click({ Show-ManageServicesWindow })

# Add first server box on startup
Add-ServerBox

# Welcome message in terminal
Write-TerminalOutput -Message "Welcome to Automated Home Lab Setup" -Color "Cyan"
Write-TerminalOutput -Message "Add servers and click 'Run Setup' to begin deployment." -Color "Gray"
Write-TerminalOutput -Message "" -Color "White"
Write-TerminalOutput -Message "Terminal Modes:" -Color "Yellow"
Write-TerminalOutput -Message "  Simple   - Shows major status updates only" -Color "Gray"
Write-TerminalOutput -Message "  Advanced - Shows all setup details (SSH commands, Docker output)" -Color "Gray"
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
        Write-TerminalOutput -Message "Shows: Major status updates, success/failure messages" -Color "Gray"
        Write-TerminalOutput -Message "" -Color "White"
    }
})

$advancedTerminalButton.Add_Click({
    if ($script:terminalMode -ne "Advanced") {
        $script:terminalMode = "Advanced"
        Update-TerminalModeButtons
        Write-TerminalOutput -Message "Switched to Advanced terminal mode" -Color "Cyan"
        Write-TerminalOutput -Message "Shows: All setup steps, SSH commands, Docker output, timestamps" -Color "Gray"
        Write-TerminalOutput -Message "Tip: Use this mode to troubleshoot deployment issues" -Color "Yellow"
        Write-TerminalOutput -Message "" -Color "White"
    }
})

$healthMonitorButton.Add_Click({
    Write-LogInfo -Message "Health Monitor button clicked" -Component "GUI"
    
    # Collect all server configurations
    $allServerConfigs = Get-AllServerConfigs
    
    # Filter out empty configurations
    $validConfigs = @()
    foreach ($config in $allServerConfigs) {
        if (-not [string]::IsNullOrWhiteSpace($config.IP) -and 
            -not [string]::IsNullOrWhiteSpace($config.User) -and 
            -not [string]::IsNullOrWhiteSpace($config.Password)) {
            $validConfigs += $config
        }
    }
    
    if ($validConfigs.Count -eq 0) {
        Write-TerminalOutput -Message "No valid server configurations found. Please add at least one server with IP, user, and password." -Color "Yellow"
        [System.Windows.MessageBox]::Show("Please add at least one server with IP address, username, and password before opening Health Monitor.", "No Servers Configured", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    
    Write-TerminalOutput -Message "Opening Health Monitor for $($validConfigs.Count) server(s)..." -Color "Cyan"
    
    # Show the health monitor window
    Show-HealthMonitorWindow -ServerConfigs $validConfigs
    
    Write-TerminalOutput -Message "Health Monitor closed." -Color "Gray"
})

$runSetupButton.Add_Click({
    Write-LogInfo -Message "Run Setup button clicked" -Component "GUI"
    
    # Collect all server configurations
    $allServerConfigs = Get-AllServerConfigs
    Write-LogInfo -Message "Collected $($allServerConfigs.Count) server configuration(s)" -Component "GUI"
    
    # Validate configurations
    $validationErrors = Test-ServerConfigs -Configs $allServerConfigs
    
    if ($validationErrors.Count -gt 0) {
        Write-LogWarning -Message "Validation failed with $($validationErrors.Count) error(s)" -Component "GUI"
        foreach ($validationError in $validationErrors) {
            Write-LogWarning -Message "Validation: $validationError" -Component "GUI"
        }
        
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
    
    Write-LogInfo -Message "Validation passed, starting deployment" -Component "GUI"
    
    # Display configurations in terminal
    Write-TerminalOutput -Message "" -Color "White"
    Write-TerminalOutput -Message "========== Server Configurations ==========" -Color "Cyan"
    Write-TerminalOutput -Message "Total Servers: $($allServerConfigs.Count)" -Color "Green"
    Write-TerminalOutput -Message "" -Color "White"
    
    foreach ($config in $allServerConfigs) {
        Write-LogDebug -Message "Server $($config.ServerNumber): IP=$($config.IP), User=$($config.User), Service=$($config.Service)" -Component "GUI"
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
    
    # Show terminal mode info
    if ($script:terminalMode -eq "Advanced") {
        Write-TerminalOutput -Message "Terminal Mode: ADVANCED - Showing all setup details" -Color "Magenta"
    } else {
        Write-TerminalOutput -Message "Terminal Mode: SIMPLE - Showing major updates only" -Color "Gray"
        Write-TerminalOutput -Message "Tip: Switch to 'Advanced' mode to see detailed setup progress" -Color "Gray"
    }
    Write-TerminalOutput -Message "" -Color "White"
    
    # Disable the Run Setup button during deployment
    $runSetupButton.IsEnabled = $false
    $runSetupButton.Content = "Deploying..."
    
    # Create a thread-safe collection for output messages
    $global:outputQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
    
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
            $ModulesPath,
            $TerminalMode,
            $ServicesDir
        )
        
        # Helper function to queue output messages
        function Send-Output {
            param([string]$Message, [string]$Color = "White", [int]$ServerNum, [switch]$AdvancedOnly)
            # If AdvancedOnly is set, only show in Advanced mode
            if ($AdvancedOnly -and $TerminalMode -ne "Advanced") {
                return
            }
            $OutputQueue.Enqueue(@{
                Message = $Message
                Color = $Color
                ServerNum = $ServerNum
            })
        }
        
        # Helper function to capture and forward Write-Host output from module functions
        function Invoke-WithOutput {
            param(
                [scriptblock]$ScriptBlock,
                [int]$ServerNum
            )
            
            # Use a StringWriter to capture console output
            $previousHost = $Host
            $infoRecords = @()
            $capturedOutput = $null
            $errorOutput = $null
            
            try {
                # Redirect Information stream (6) to output and capture everything
                $capturedOutput = & {
                    & $ScriptBlock *>&1
                } 6>&1 2>&1
            }
            catch {
                $errorOutput = $_.Exception.Message
            }
            
            # Process captured output
            if ($capturedOutput) {
                foreach ($item in $capturedOutput) {
                    if ($null -eq $item) { continue }
                    
                    $message = $null
                    $messageColor = "Gray"
                    
                    if ($item -is [System.Management.Automation.InformationRecord]) {
                        $message = $item.MessageData.ToString()
                        # Try to get foreground color from InformationRecord
                        if ($item.Tags -contains "PSHOST") {
                            $fgColor = $item.MessageData.ForegroundColor
                            if ($fgColor) {
                                switch ($fgColor.ToString()) {
                                    "Green" { $messageColor = "Green" }
                                    "Red" { $messageColor = "Red" }
                                    "Yellow" { $messageColor = "Yellow" }
                                    "Cyan" { $messageColor = "Cyan" }
                                    "Magenta" { $messageColor = "Magenta" }
                                    "Gray" { $messageColor = "Gray" }
                                    default { $messageColor = "White" }
                                }
                            }
                        }
                    }
                    elseif ($item -is [System.Management.Automation.ErrorRecord]) {
                        $message = $item.Exception.Message
                        $messageColor = "Red"
                    }
                    elseif ($item -is [System.Management.Automation.HostInformationMessage]) {
                        $message = $item.Message
                        # Get color from the HostInformationMessage
                        if ($item.ForegroundColor) {
                            switch ($item.ForegroundColor.ToString()) {
                                "Green" { $messageColor = "Green" }
                                "Red" { $messageColor = "Red" }
                                "Yellow" { $messageColor = "Yellow" }
                                "Cyan" { $messageColor = "Cyan" }
                                "Magenta" { $messageColor = "Magenta" }
                                "Gray" { $messageColor = "Gray" }
                                default { $messageColor = "White" }
                            }
                        }
                    }
                    else {
                        $message = $item.ToString()
                    }
                    
                    if ([string]::IsNullOrWhiteSpace($message)) { continue }
                    
                    # Auto-detect color from content if not already set to a specific color
                    if ($messageColor -eq "Gray" -or $messageColor -eq "White") {
                        if ($message -match "error|fail|denied|cannot") { $messageColor = "Red" }
                        elseif ($message -match "success|installed|complete|ready|running") { $messageColor = "Green" }
                        elseif ($message -match "warning|skip|already") { $messageColor = "Yellow" }
                        elseif ($message -match "starting|checking|creating|deploying|installing|verifying|updating|detecting|setting") { $messageColor = "Cyan" }
                    }
                    
                    # In Advanced mode, show all output; in Simple mode, only show important messages
                    if ($TerminalMode -eq "Advanced") {
                        Send-Output -Message "    $message" -Color $messageColor -ServerNum $ServerNum
                    }
                    elseif ($message -match "success|fail|error|complete|installed|deployed|running|ready") {
                        Send-Output -Message "    $message" -Color $messageColor -ServerNum $ServerNum
                    }
                }
            }
            
            # Handle any captured errors
            if ($errorOutput) {
                Send-Output -Message "    Error: $errorOutput" -Color "Red" -ServerNum $ServerNum
            }
        }
        
        # Import the consolidated RMSetup module in the runspace
        # This module contains all functionality: Logging, Remote Connection, Health Monitoring, Service Installation, WSL2 Setup
        Import-Module "$ModulesPath\RMSetup.psm1" -Force
        Set-ConnectionConfig -SSHPort $Config.SSHPort -WinRMPort $Config.WinRMPort -EnableSSH $Config.EnableSSH -EnableWinRM $Config.EnableWinRM
        
        $serverNum = $Config.ServerNumber
        Send-Output -Message "[Server $serverNum] Starting deployment to $($Config.IP)..." -Color "Cyan" -ServerNum $serverNum
        
        # Test connection to the server
        Send-Output -Message "[Server $serverNum] Testing connection..." -Color "Cyan" -ServerNum $serverNum -AdvancedOnly
        Invoke-WithOutput -ScriptBlock {
            $script:connectionResult = Test-RemoteConnection -IP $Config.IP -User $Config.User -Password $Config.Password
        } -ServerNum $serverNum
        $connectionResult = $script:connectionResult
        
        if (-not $connectionResult) {
            Send-Output -Message "[Server $serverNum] Failed to connect to $($Config.IP). Skipping..." -Color "Red" -ServerNum $serverNum
            return @{ Success = $false; ServerNum = $serverNum; IP = $Config.IP; Error = "Connection failed" }
        }
        
        Send-Output -Message "[Server $serverNum] Successfully connected to $($Config.IP)" -Color "Green" -ServerNum $serverNum
        
        # Get the OS type
        Send-Output -Message "[Server $serverNum] Detecting operating system..." -Color "Cyan" -ServerNum $serverNum -AdvancedOnly
        Invoke-WithOutput -ScriptBlock {
            $script:osType = Get-TargetOS -IP $Config.IP
        } -ServerNum $serverNum
        $osType = $script:osType
        Send-Output -Message "[Server $serverNum] Detected OS: $osType" -Color "Cyan" -ServerNum $serverNum
        
        # Deploy service based on OS
        if ($osType -eq "Linux") {
            
            # --- NEW: Install Docker ---
            Send-Output -Message "[Server $serverNum] Verifying/Installing Docker..." -Color "Cyan" -ServerNum $serverNum
            Invoke-WithOutput -ScriptBlock {
                $script:dockerSuccess = Install-Docker -IP $Config.IP -User $Config.User -Password $Config.Password -OSType $osType
            } -ServerNum $serverNum
            $dockerSuccess = $script:dockerSuccess
            
            if (-not $dockerSuccess) {
                Send-Output -Message "[Server $serverNum] Docker installation failed. Skipping..." -Color "Red" -ServerNum $serverNum
                return @{ Success = $false; ServerNum = $serverNum; IP = $Config.IP; Error = "Docker installation failed" }
            }
            # ---------------------------

            Send-Output -Message "[Server $serverNum] Docker is ready" -Color "Green" -ServerNum $serverNum
            
            # Install Traefik
            if ($Config.UseTraefik) {
                Send-Output -Message "[Server $serverNum] Installing Traefik reverse proxy..." -Color "Cyan" -ServerNum $serverNum
                $traefikSuccess = $null
                Invoke-WithOutput -ScriptBlock {
                    $script:traefikSuccess = Install-Traefik -IP $Config.IP -User $Config.User -Password $Config.Password
                } -ServerNum $serverNum
                $traefikSuccess = $script:traefikSuccess
                
                if ($traefikSuccess) {
                    Send-Output -Message "[Server $serverNum] Traefik installed successfully" -Color "Green" -ServerNum $serverNum
                }
                else {
                    Send-Output -Message "[Server $serverNum] Warning: Traefik installation failed, services will use direct ports" -Color "Yellow" -ServerNum $serverNum
                }
            } else {
                Send-Output -Message "[Server $serverNum] Traefik installation skipped (Disabled in config)" -Color "Gray" -ServerNum $serverNum
            }
            
            # Deploy the selected service
            Send-Output -Message "[Server $serverNum] Deploying service: $($Config.Service)" -Color "Yellow" -ServerNum $serverNum
            
            $composeFileName = "$($Config.Service).yml"
            $composePath = Join-Path $ServicesDir $composeFileName
            
            if (-not (Test-Path $composePath)) {
                Send-Output -Message "[Server $serverNum] Error: Config file not found ($composeFileName)" -Color "Red" -ServerNum $serverNum
                return @{ Success = $false; ServerNum = $serverNum; IP = $Config.IP; Error = "Config missing" }
            }
            
            $composeContent = Get-Content $composePath -Raw
            
            Invoke-WithOutput -ScriptBlock {
                $script:serviceSuccess = Deploy-DockerService -IP $Config.IP -User $Config.User -Password $Config.Password -ServiceName $Config.Service -ComposeContent $composeContent -OSType $osType
            } -ServerNum $serverNum
            
            $serviceSuccess = $script:serviceSuccess
            if ($serviceSuccess) {
                Send-Output -Message "[Server $serverNum] $($Config.Service) deployed successfully" -Color "Green" -ServerNum $serverNum
            } else {
                Send-Output -Message "[Server $serverNum] $($Config.Service) deployment failed" -Color "Red" -ServerNum $serverNum
            }
            
            Send-Output -Message "[Server $serverNum] Deployment complete" -Color "Cyan" -ServerNum $serverNum
            return @{ Success = $serviceSuccess; ServerNum = $serverNum; IP = $Config.IP; Service = $Config.Service }
        }
        elseif ($osType -eq "Windows") {
            
            # --- NEW: Install WSL2 and Docker ---
            Send-Output -Message "[Server $serverNum] Verifying/Installing WSL2..." -Color "Cyan" -ServerNum $serverNum
            Invoke-WithOutput -ScriptBlock {
                $script:wslResult = Install-WSL2 -IP $Config.IP -User $Config.User -Password $Config.Password
            } -ServerNum $serverNum
            $wslResult = $script:wslResult
            
            if (-not $wslResult.Ready) {
                Send-Output -Message "[Server $serverNum] WSL2 setup not ready: $($wslResult.Message)" -Color "Red" -ServerNum $serverNum
                return @{ Success = $false; ServerNum = $serverNum; IP = $Config.IP; Error = "WSL2 not ready" }
            }

            Send-Output -Message "[Server $serverNum] Verifying/Installing Docker in WSL2..." -Color "Cyan" -ServerNum $serverNum
            Invoke-WithOutput -ScriptBlock {
                $script:dockerSuccess = Install-Docker -IP $Config.IP -User $Config.User -Password $Config.Password -OSType $osType
            } -ServerNum $serverNum
            $dockerSuccess = $script:dockerSuccess
            
            if (-not $dockerSuccess) {
                Send-Output -Message "[Server $serverNum] Docker installation failed in WSL2. Skipping..." -Color "Red" -ServerNum $serverNum
                return @{ Success = $false; ServerNum = $serverNum; IP = $Config.IP; Error = "Docker installation failed" }
            }
            # -------------------------------------

            Send-Output -Message "[Server $serverNum] Docker is ready in WSL2" -Color "Green" -ServerNum $serverNum
            
            if ($Config.UseTraefik) {
                Send-Output -Message "[Server $serverNum] Installing Traefik reverse proxy in WSL2..." -Color "Cyan" -ServerNum $serverNum
                Invoke-WithOutput -ScriptBlock {
                    $script:traefikSuccess = Install-Traefik -IP $Config.IP -User $Config.User -Password $Config.Password -OSType $osType
                } -ServerNum $serverNum
                $traefikSuccess = $script:traefikSuccess
                
                if ($traefikSuccess) {
                    Send-Output -Message "[Server $serverNum] Traefik installed successfully in WSL2" -Color "Green" -ServerNum $serverNum
                }
                else {
                    Send-Output -Message "[Server $serverNum] Warning: Traefik installation failed, services will use direct ports" -Color "Yellow" -ServerNum $serverNum
                }
            } else {
                Send-Output -Message "[Server $serverNum] Traefik installation skipped (Disabled in config)" -Color "Gray" -ServerNum $serverNum
            }
            
            Send-Output -Message "[Server $serverNum] Deploying service: $($Config.Service)" -Color "Yellow" -ServerNum $serverNum
            
            $composeFileName = "$($Config.Service).yml"
            $composePath = Join-Path $ServicesDir $composeFileName
            
            if (-not (Test-Path $composePath)) {
                Send-Output -Message "[Server $serverNum] Error: Config file not found ($composeFileName)" -Color "Red" -ServerNum $serverNum
                return @{ Success = $false; ServerNum = $serverNum; IP = $Config.IP; Error = "Config missing" }
            }
            
            $composeContent = Get-Content $composePath -Raw
            
            Invoke-WithOutput -ScriptBlock {
                $script:serviceSuccess = Deploy-DockerService -IP $Config.IP -User $Config.User -Password $Config.Password -ServiceName $Config.Service -ComposeContent $composeContent -OSType $osType
            } -ServerNum $serverNum
            
            $serviceSuccess = $script:serviceSuccess
            if ($serviceSuccess) {
                Send-Output -Message "[Server $serverNum] $($Config.Service) deployed successfully" -Color "Green" -ServerNum $serverNum
            } else {
                Send-Output -Message "[Server $serverNum] $($Config.Service) deployment failed" -Color "Red" -ServerNum $serverNum
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
        [void]$powershell.AddArgument($global:outputQueue)
        [void]$powershell.AddArgument("$PSScriptRoot\modules")
        [void]$powershell.AddArgument($script:terminalMode)  # Pass terminal mode to runspace
        [void]$powershell.AddArgument($servicesDir)
        
        $handle = $powershell.BeginInvoke()
        
        $runspaces += @{
            PowerShell = $powershell
            Handle = $handle
            ServerNum = $config.ServerNumber
        }
    }
    
    # Create a timer to poll for output messages and check completion
    $global:deploymentTimer = New-Object System.Windows.Threading.DispatcherTimer
    $global:deploymentTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $global:deploymentRunspaces = $runspaces
    $global:deploymentRunspacePool = $runspacePool
    $global:deploymentResults = @()
    
    $global:deploymentTimer.Add_Tick({
        # Process any queued output messages
        $outputItem = $null
        while ($global:outputQueue.TryDequeue([ref]$outputItem)) {
            Write-TerminalOutput -Message $outputItem.Message -Color $outputItem.Color
        }
        
        # SECURITY GUARD: Prevent multiple queued timer ticks from executing the completion block
        if ($null -eq $global:deploymentRunspaces -or $global:deploymentRunspaces.Count -eq 0) {
            return
        }
        
        # Check if all runspaces are complete
        $allComplete = $true
        foreach ($rs in $global:deploymentRunspaces) {
            if (-not $rs.Handle.IsCompleted) {
                $allComplete = $false
                break
            }
        }
        
        if ($allComplete) {
            # Stop the timer
            $global:deploymentTimer.Stop()
            
            # LOCK THE RUNSPACES AND CLEAR GLOBAL
            $runspacesToProcess = $global:deploymentRunspaces
            $global:deploymentRunspaces = @()
            
            # Collect results
            foreach ($rs in $runspacesToProcess) {
                try {
                    $result = $rs.PowerShell.EndInvoke($rs.Handle)
                    if ($result) {
                        $global:deploymentResults += $result
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
            while ($global:outputQueue.TryDequeue([ref]$outputItem)) {
                Write-TerminalOutput -Message $outputItem.Message -Color $outputItem.Color
            }
            
            # Clean up runspace pool
            if ($global:deploymentRunspacePool) {
                $global:deploymentRunspacePool.Close()
                $global:deploymentRunspacePool.Dispose()
                $global:deploymentRunspacePool = $null
            }
            
            # Summary
            Write-TerminalOutput -Message "" -Color "White"
            Write-TerminalOutput -Message "========== Deployment Summary ==========" -Color "Cyan"
            
            $successCount = ($global:deploymentResults | Where-Object { $_.Success -eq $true }).Count
            $failCount = ($global:deploymentResults | Where-Object { $_.Success -eq $false }).Count
            
            Write-TerminalOutput -Message "Successful: $successCount" -Color "Green"
            Write-TerminalOutput -Message "Failed: $failCount" -Color $(if ($failCount -gt 0) { "Red" } else { "Green" })
            
            foreach ($result in $global:deploymentResults) {
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
    
    $global:deploymentTimer.Start()
})

#Show the Window
$window.ShowDialog() | Out-Null