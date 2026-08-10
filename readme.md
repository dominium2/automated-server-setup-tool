# 🚀 Automated Home Lab Setup Tool

A high-performance, multithreaded PowerShell orchestration tool with a rich WPF-based graphical interface. It automates the deployment, configuration, and monitoring of Dockerized services across multiple servers and virtual machines.

By combining SSH and WinRM execution with parallel runspaces, the tool can orchestrate multi-server deployments much faster than a sequential workflow.

> **Disclaimer:** Portions of this project, including its code and documentation, were generated, optimized, and refined with the assistance of Artificial Intelligence (AI).

---

## ✨ Key Features

- **Parallel execution**: Deploy to multiple servers at once without freezing the interface.
- **Automatic OS detection**: Identify Linux and Windows targets and route commands to the correct protocol.
- **Zero-touch Docker provisioning**:
  - **Linux**: install Docker Engine and required repositories automatically.
  - **Windows**: configure WSL2, provision a Linux user, and install Docker inside the WSL environment.
- **Health dashboard**: Monitor CPU, memory, disk, uptime, and container state from the UI.
- **Traefik integration**: Deploy reverse proxy services and handle certificate-related file permissions automatically.
- **Port 53 conflict resolution**: Detect and resolve DNS stub conflicts for services like AdGuard Home.

---

## 📋 Prerequisites

### Host machine

- Windows 10 or 11 with PowerShell 5.1 or newer
- Administrator privileges
- PuTTY with `plink.exe` available in your `PATH`

Install PuTTY with:

```powershell
choco install putty -y
```

### Target machines

- **Linux targets**: Debian-based systems with SSH enabled
- **Windows targets**: Windows 10/11 with WinRM enabled
- **Note**: Windows targets must support hardware virtualization for WSL2-based deployment

---

## ⚙️ Installation and Quick Start

### 1. Clone the repository

```powershell
git clone https://github.com/yourusername/automated-server-setup-tool.git
cd automated-server-setup-tool
```

### 2. Set PowerShell execution policy

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 3. Launch the application

Run the GUI as Administrator:

```powershell
.\GUI.ps1
```

---

## 🖥️ Using the Interface

### 1. Add servers

- Click **Add Server** to create a new configuration block.
- Enter the target IP address or hostname.
- Provide the username and password for the server.
- Select the service to deploy.
- Optionally enable Traefik and adjust SSH or WinRM ports.

### 2. Manage services

- Open **Manage Services** to edit Docker Compose templates.
- Create or update service definitions in the [configs/services](configs/services) directory.
- Saved files will appear in the service dropdown automatically.

### 3. Deploy

- Click **Run Setup** to begin orchestration.
- The tool validates your inputs, pings the targets, and shows live output in the terminal area.
- Use **Simple** mode for a concise summary or **Advanced** mode for detailed command output.

### 4. Monitor health

- Open **Health Monitor** to view server and container health.
- Review CPU, memory, disk, and uptime information.
- Start, stop, or restart containers directly from the dashboard.
- Export a full text report for auditing or troubleshooting.

---

## 🏗️ Architecture Overview

The project is split into three main layers:

- [GUI.ps1](GUI.ps1): presentation layer for the WPF UI, validation, and runspace-based orchestration
- [modules/RMSetup.psm1](modules/RMSetup.psm1): logic layer for remote connection handling, command execution, and deployment logic
- [configs/services](configs/services): storage for Docker Compose YAML service templates

---

## ⚠️ Known Limitations and Troubleshooting

- **Nested virtualization**: WSL2 deployment on a Windows virtual machine may fail unless nested virtualization is enabled in the hypervisor.
- **WinRM interruptions**: Windows deployments can occasionally interrupt the monitoring pipeline, especially when the WSL kernel is being installed.
- **Logs**: Check the [logs](logs) directory if a deployment fails silently. The tool writes timestamped log files to help with diagnostics.
