#Load WPF assemblies
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

#Gui Design XML
[xml]$xaml = @"
<Window 
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Automated Home Lab Setup" 
    Height="500" 
    Width="800"
    WindowStartupLocation="CenterScreen">
    
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
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
    </Grid>
</Window>
"@

# Initialize server counter and storage
$script:serverCount = 0
$script:serverControls = @()  # Store references to all server controls

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

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load( $reader )

$addServerButton = $window.FindName("AddServerButton")
$runSetupButton = $window.FindName("RunSetupButton")
$serverContainer = $window.FindName("ServerContainer")

# Add first server box on startup
Add-ServerBox

$addServerButton.Add_Click({
    Add-ServerBox
})

$runSetupButton.Add_Click({
    # Collect all server configurations
    $allServerConfigs = Get-AllServerConfigs
    
    # Display configurations (for testing)
    Write-Host "`n========== Server Configurations ==========" -ForegroundColor Cyan
    Write-Host "Total Servers: $($allServerConfigs.Count)`n" -ForegroundColor Green
    
    foreach ($config in $allServerConfigs) {
        Write-Host "Server $($config.ServerNumber):" -ForegroundColor Yellow
        Write-Host "  IP Address: $($config.IP)"
        Write-Host "  User: $($config.User)"
        Write-Host "  Password: $('*' * $config.Password.Length)"
        Write-Host "  Service: $($config.Service)"
        Write-Host ""
    }
    
    Write-Host "==========================================" -ForegroundColor Cyan
    
    # TODO: Pass $allServerConfigs to your automation scripts
    # Example: Start-ServerSetup -Configs $allServerConfigs
})

#Show the Window
$window.ShowDialog() | Out-Null