# GUI Overview

The GUI entry point, [GUI.ps1](GUI.ps1), is built with Windows Presentation Foundation (WPF). Because PowerShell is inherently single-threaded, long-running deployment tasks would normally freeze the interface. To avoid that, the script uses runspaces for background work and a thread-safe queue to send updates back to the UI thread through `Dispatcher.Invoke`.

## Execution Flow

1. **Initialization**
   - Determines the current working directory.
   - Creates the `configs/services` folder when needed.
   - Adds default Portainer YAML templates if they are missing.

2. **Module and Logging Setup**
   - Imports the module from [modules/RMSetup.psm1](../modules/RMSetup.psm1).
   - Initializes the main log file for the session.

3. **UI Construction**
   - Parses the XAML layout and loads the main window.
   - Builds the first server input block dynamically.

4. **Event Wiring**
   - Connects buttons such as **Run Setup** and **Health Monitor** to their handlers.

5. **Deployment Execution**
   - Validates user input before deployment.
   - Locks the UI while background jobs run.
   - Polls the terminal output until all worker threads finish.

## Core GUI Functions

### `Write-TerminalOutput`

- Writes colored text safely to the rich terminal area.
- Uses the UI dispatcher to update the main thread from background work.
- Adds a timestamp in advanced logging mode.

### `Add-ServerBox`

- Creates the visual server input block dynamically.
- Generates text boxes, checkboxes, and dropdowns for each server.
- Populates the service list by scanning the `configs/services` directory for `.yml` files.
- Stores the created controls so the values can be collected later.

### `Get-AllServerConfigs`

- Reads all server values from the generated UI blocks.
- Converts the input into PowerShell objects.
- Fills in default SSH or WinRM ports when they are left empty.

### `Test-IPAddress`

- Validates the server address before connection attempts.
- Accepts either a strict IPv4 address or a valid hostname.

### `Test-ServerConfigs`

- Checks the collected configuration for missing values and invalid settings.
- Returns error messages when the IP is malformed or when both SSH and WinRM are disabled.

### `Update-TerminalModeButtons`

- Toggles the visual state of the **Simple** and **Advanced** logging buttons.

### `Show-HealthMonitorWindow`

- Opens the health monitoring interface.
- Uses a separate background processing routine to collect health information without freezing the UI.

### Nested Helper Functions

- `Write-ReportOutput`: Writes report output safely to the export view.
- `New-ServerHealthCard`: Builds a status card for CPU, RAM, disk, and uptime.
- `New-ContainerHealthCard`: Creates container actions and stores the relevant server data on the buttons.
- `Refresh-HealthData`: Runs health checks concurrently for all servers.

### `Show-ManageServicesWindow`

- Opens a sub-window for editing Docker Compose service files.
- Allows users to create, edit, and save YAML definitions directly from the application.