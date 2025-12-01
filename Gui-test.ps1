# Load WPF assemblies
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

[xml]$xaml = @"
<Window 
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Automated Home Lab Setup" 
    Height="600" 
    Width="900"
    WindowStartupLocation="CenterScreen">
    
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <!-- Top Button Bar -->
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
            <Button Name="AddServiceButton" Content="Add Service" Width="100" Height="30" Margin="0,0,10,0"/>
            <Button Name="RunButton" Content="Run" Width="100" Height="30" Background="Green" Foreground="White"/>
        </StackPanel>
        
        <!-- Tab Control for Servers -->
        <TabControl Name="ServerTabControl" Grid.Row="1">
            <!-- Tabs will be added dynamically -->
        </TabControl>
        
        <!-- Status Bar -->
        <StatusBar Grid.Row="2" Height="30">
            <StatusBarItem>
                <TextBlock Name="StatusText" Text="Ready"/>
            </StatusBarItem>
        </StatusBar>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load( $reader )

$addServiceButton = $window.FindName("AddServiceButton")
$runButton = $window.FindName("RunButton")
$serverTabControl = $window.FindName("ServerTabControl")
$statusText = $window.FindName("StatusText")

$addServiceButton.Add_Click({
    # Code to add a new tab
    $statusText.Text = "Adding new service..."
})

$runButton.Add_Click({
    # Code to run the automation
    $statusText.Text = "Running deployment..."
})

$window.ShowDialog() | Out-Null