# Automated Home Lab Setup Tool

A PowerShell-based automation tool with GUI for deploying and managing services across multiple servers simultaneously. Simplify your home lab setup with automatic OS detection, Docker deployment, Traefik reverse proxy configuration, and interactive container management.

## Overview

This tool eliminates the repetitive and time-consuming process of setting up services across multiple servers. Through an intuitive WPF interface, you can configure multiple servers and deploy services like AdGuard, N8N, Heimdall, Crafty, and Portainer with just a few clicks. 

The backend has been heavily optimized with command batching and OS-detection caching, reducing deployment and monitoring times from minutes down to seconds.

## Key Features

- **Intuitive GUI**: WPF-based interface with tabbed server management.
- **Parallel Execution**: Deploy to multiple servers simultaneously.
- **Ultra-Fast Operations**: SSH command batching reduces setup times to ~30 seconds and health monitoring to under 5 seconds.
- **Custom Connection Configurations**: Define custom SSH and WinRM ports per server directly in the GUI.
- **Automatic OS Detection**: Supports Debian-based Linux and Windows 11, with smart caching to eliminate redundant network probes.
- **Interactive Health Monitoring**: Real-time server metrics and actionable container cards (Start, Stop, Restart directly from the UI).
- **Docker Automation**: Automatic Docker/WSL2 installation and configuration.
- **Traefik Integration**: Automatic reverse proxy setup with port conflict prevention.
- **Comprehensive Logging**: Per-server logging with exportable error reports and auto-rotation.

## Supported Services (MVP)

- **AdGuard Home**: Network-wide ad blocking (includes automatic systemd-resolved port 53 conflict resolution).
- **N8N**: Workflow automation platform.
- **Crafty Controller**: Minecraft server management.
- **Heimdall**: Application dashboard.
- **Portainer**: Docker container management.

## Supported Operating Systems
- Debian-based Linux distributions (Ubuntu, Debian, Linux Mint, etc.)
- Windows 11 (with WSL2)

*Note: Testing the Windows 11 WSL2 deployment inside a virtual machine explicitly requires a Type-1 hypervisor like **Microsoft Hyper-V**. Type-2 hypervisors like VirtualBox fail to properly pass through the nested SLAT/EPT hardware virtualization instructions required for WSL2 to initialize, which will cause the automated Docker installation to fail. See `TESTING.md` for architectural details.*

## Prerequisites

- PowerShell 5.1 or later
- Administrator/root privileges on target servers
- Internet connection on all servers
- Target servers must allow remote connections (SSH for Linux, WinRM for Windows)
- `plink` (PuTTY) installed on the host machine for password-based SSH automation (`choco install putty -y`)

## Installation

1. Clone this repository:
   ```powershell
   git clone [https://github.com/dominium2/automated-server-setup-tool.git](https://github.com/dominium2/automated-server-setup-tool.git)
   cd automated-server-setup-tool
   ```
2. Run PowerShell as Administrator.

3. Set execution policy if needed
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```
## Usage

1. Launch the tool by running `GUI.ps1`

2. Click "Add Server" to create a new server configuration block.

3. Fill in the server details:
   - **IP Address**: Server IP or hostname.
   - **Credentials**: Username and password.
   - **Service**: Select from the dynamically loaded dropdown.
   - **Connection Ports**: Modify SSH or WinRM ports if your server uses non-standard configurations.

4. Click **"Run Setup"** to start the automated parallel deployment.

5. Click **"Health Monitor"** at any time to view live resource usage and manage running containers.

## Architecture

The tool follows a modular design pattern:

- **UI Layer** (GUI.ps1): WPF-based GUI for user interaction, validation, and threaded parallel runspaces.
- **Module Layer** (RMSetup.psm1): Consolidated backend logic handling remote execution, OS detection, logging, and health polling.
- **Service Layer** (configs/services/): Docker Compose YAML templates for each service.

## Testing

See the `TESTING.md` file for instructions on running the mocked Pester unit tests (which execute in milliseconds without VMs) and the live Vagrant integration tests.