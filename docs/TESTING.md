# Testing Guide

This project includes a comprehensive test suite using Pester. The tests are divided into two categories: **Local Unit Testing** (which runs instantly without actual servers) and **Integration Testing** (which requires live Virtual Machines).

## 1. Local Unit Testing (No VMs Required)

Our unit tests utilize Pester's `Mock` feature. This intercepts network commands (`Test-NetConnection`, `Invoke-RemoteCommand`, etc.) and feeds the script fake terminal data. This allows you to test logic, string parsing, and GUI validation safely and instantly.

**What is covered:**
- GUI IP Address and Port validation rules.
- Remote connection scope and OS fallback logic.
- Health monitor bash output parsing.
- Docker deployment volume path filtering.
- Logging file generation and log rotation.

**How to run:**
1. Open PowerShell in the root project directory.
2. Run the Pester command, explicitly excluding the integration tests:
   ```powershell
   Invoke-Pester -Path .\tests\* -ExcludePath .\tests\*Integration*
   ```
3. The suite should complete in under 2 seconds.

## 2. Integration Testing (Requires Virtual Machines)

# Testing with VMs

## Why Hyper-V Instead of VirtualBox?
Testing Windows WSL2 automation inside a virtual machine requires **Nested Virtualization**. The guest VM must act as a hypervisor itself to spin up the tiny Linux utility VM that powers WSL2.

VirtualBox (a Type-2 hypervisor) struggles to translate the deep CPU instructions (SLAT/EPT) required for this. By switching to **Hyper-V** (a Type-1 hypervisor), the SLAT/EPT instructions are passed through directly to the guest via the `enable_virtualization_extensions` flag, allowing WSL2 to unpack its kernel and run Docker seamlessly.

## Prerequisites
1. **Enable Hyper-V on your Host Machine**: Open Administrator PowerShell and run:
   `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All`
   *(You must restart your computer if this feature was just enabled).*
2. **Install Vagrant**: https://www.vagrantup.com/downloads

## Starting Test VMs
```powershell
# Navigate to project directory
cd automated-server-setup-tool

# Start all test servers using the Hyper-V provider
vagrant up --provider hyperv

# Check status
vagrant status

This provisions test servers (e.g., Debian at `192.168.56.11`). All servers use:
- **Username**: `testuser`
- **Password**: `testpass123`

### Running the Integration Test
Once the VMs are completely booted and running:

```powershell
Invoke-Pester -Path .\tests\Portainer-Integration.Tests.ps1
```
## Useful Vagrant Commands
```powershell
# Start all VMs using Hyper-V
vagrant up --provider hyperv

# Start specific VM
vagrant up windows1 --provider hyperv

# Stop all VMs
vagrant halt

# Delete all VMs (free up space)
vagrant destroy -f

# SSH into a Linux VM
vagrant ssh linux1

# Open Remote PowerShell into a Windows VM
vagrant powershell windows1

# Check VM status
vagrant status

## Troubleshooting
**VMs won't start (Not enough memory error):**
- Hyper-V requires contiguous memory blocks. If you see `0x800705AA` or `0x8007000E`, close heavy background applications (browsers, IDEs) on your physical host machine to free up RAM, then retry `vagrant up`.

**Can't ping VMs:**
- Ensure the Hyper-V Virtual Switch was created correctly. When Vagrant prompts you for a network interface during the first boot, ensure you select the "Default Switch".

**WSL2 Installation fails inside Windows VM:**
- Confirm you are using `--provider hyperv`. If `wsl --install` throws errors, ensure the VM has fully rebooted after the initial deployment to allow the inner hypervisor to activate.

## Snapshot VMs (Save State)
Because Vagrant with Hyper-V utilizes native Windows checkpoints, you can save clean states directly using PowerShell:

```powershell
# Take a snapshot of a clean VM state
Checkpoint-VM -Name "HomeLab-Windows1" -SnapshotName "clean-state"

# Restore the VM to the clean state
Restore-VMSnapshot -VMName "HomeLab-Windows1" -Name "clean-state"