# GUI.ps1 Documentation

Main application file that provides the WPF-based graphical user interface.

## Overview

`GUI.ps1` creates a Windows Presentation Foundation (WPF) GUI for configuring and deploying services to remote servers. It handles user input, displays progress, and coordinates with the `RMSetup.psm1` module for actual operations.

---

## Dependencies

```powershell
# WPF Assemblies
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Custom Module
Import-Module "modules\RMSetup.psm1"
```

---

## Script Variables

| Variable | Type | Purpose |
|----------|------|---------|
| `$script:serverCount` | Int | Tracks number of server configurations added |
| `$script:serverControls` | Array | Stores references to UI controls for each server |
| `$script:terminalMode` | String | Current terminal output mode ("Simple" or "Advanced") |
| `$script:terminalOutput` | RichTextBox | Reference to the terminal output control |

---

## Main Window (XAML)

The main window contains:
- **Top Bar**: Add Server, Run Setup, Health Monitor buttons
- **Server Container**: Scrollable area for server configuration panels
- **Terminal Section**: Output display with mode toggle buttons

### Key UI Elements

| Element Name | Type | Purpose |
|--------------|------|---------|
| `AddServerButton` | Button | Adds new server config panel |
| `RunSetupButton` | Button | Starts deployment process |
| `HealthMonitorButton` | Button | Opens health monitor window |
| `ServerContainer` | StackPanel | Holds server configuration boxes |
| `TerminalOutput` | RichTextBox | Displays colored output messages |
| `SimpleTerminalButton` | Button | Switch to simple output mode |
| `AdvancedTerminalButton` | Button | Switch to advanced output mode |

---

## Functions

### Write-TerminalOutput

Writes colored text to the terminal output area.

```powershell
Write-TerminalOutput -Message "text" -Color "Green"
```

**Colors**: White, Green, Red, Yellow, Cyan, Magenta, Gray

**Behavior**: In Advanced mode, prepends timestamp `[HH:mm:ss]` to messages.

---

### Add-ServerBox

Creates a new server configuration panel in the UI.

**Creates these input fields:**
- IP Address (TextBox)
- User (TextBox)
- Password (PasswordBox)
- Service (ComboBox: Portainer, AdGuard, N8N, Heimdall, Crafty)

**Stores control references** in `$script:serverControls` for later retrieval.

---

### Get-AllServerConfigs

Collects configuration data from all server panels.

**Returns**: Array of hashtables with:
```powershell
@{
    ServerNumber = 1
    IP = "192.168.1.100"
    User = "admin"
    Password = "pass123"
    Service = "Portainer"
}
```

---

### Test-IPAddress

Validates IP address or hostname format.

```powershell
Test-IPAddress -IP "192.168.1.100"  # Returns $true
Test-IPAddress -IP "server.local"   # Returns $true
Test-IPAddress -IP "999.999.999.999" # Returns $false
```

**Validation rules:**
- Valid IPv4 format (4 octets, 0-255 each)
- Valid hostname (alphanumeric, hyphens, dots)
- Rejects empty/whitespace input

---

### Test-ServerConfigs

Validates all server configurations before deployment.

```powershell
$errors = Test-ServerConfigs -Configs $allConfigs
```

**Checks:**
- IP Address: Required, valid format
- Username: Required
- Password: Required
- Service: Required (must select from dropdown)

**Returns**: Array of error messages (empty if all valid)

---

### Update-TerminalModeButtons

Updates button styling when switching between Simple/Advanced modes.

---

### Show-HealthMonitorWindow

Opens the Health Monitor window with:
- Server Health tab (CPU, Memory, Disk, Uptime)
- Container Health tab (Docker containers status)
- Health Report tab (exportable full report)
- Auto-refresh capability

---

## Event Handlers

### Add Server Button
```powershell
$addServerButton.Add_Click({ Add-ServerBox })
```

### Run Setup Button
Workflow:
1. Collect all configurations (`Get-AllServerConfigs`)
2. Validate inputs (`Test-ServerConfigs`)
3. Display validation errors or proceed
4. For each server:
   - Test connectivity (`Test-RemoteConnection`)
   - Detect OS (`Get-TargetOS`)
   - Install Docker if needed (`Install-Docker`)
   - Install selected service (`Install-<Service>`)
5. Report results

### Health Monitor Button
```powershell
$healthMonitorButton.Add_Click({
    $configs = Get-AllServerConfigs
    Show-HealthMonitorWindow -ServerConfigs $configs
})
```

### Terminal Mode Buttons
Toggle between Simple and Advanced output modes.

### Clear Button
Clears all text from terminal output.

---

## AI Assistance Note

Parts of this GUI code were developed with AI assistance, including:
- XAML layout structure and styling
- Long/repetitive code sections (UI element creation, event wiring)
- Health Monitor window implementation
- Documentation writing
