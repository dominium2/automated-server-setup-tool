# Testing with VMs

## Prerequisites

1. **Install VirtualBox**: https://www.virtualbox.org/wiki/Downloads
2. **Install Vagrant**: https://www.vagrantup.com/downloads

## Starting Test VMs

```powershell
# Navigate to project directory
cd automated-server-setup-tool

# Start all 3 test servers (takes 5-10 minutes first time)
vagrant up

# Check status
vagrant status
```

This creates 3 Debian servers:
- **testserver1**: 192.168.56.11
- **testserver2**: 192.168.56.12
- **testserver3**: 192.168.56.13

**Credentials for all servers:**
- Username: `testuser`
- Password: `testpass123`

## Testing Your GUI

1. Start the VMs: `vagrant up`
2. Launch your GUI: `.\GUI.ps1`
3. Add server configurations:
   - **Server 1**: IP: `192.168.56.11`, User: `testuser`, Password: `testpass123`, Service: `AdGuard`
   - **Server 2**: IP: `192.168.56.12`, User: `testuser`, Password: `testpass123`, Service: `N8N`
   - **Server 3**: IP: `192.168.56.13`, User: `testuser`, Password: `testpass123`, Service: `Heimdall`
4. Click **"Run Setup"**
5. Watch the ping tests and connection attempts in the terminal

## Useful Vagrant Commands

```powershell
# Start all VMs
vagrant up

# Start specific VM
vagrant up testserver1

# Stop all VMs
vagrant halt

# Delete all VMs (free up space)
vagrant destroy -f

# SSH into a VM
vagrant ssh testserver1

# Restart a VM
vagrant reload testserver1

# Check VM status
vagrant status
```

## Manual SSH Test

Test SSH connection manually:

```powershell
# Install OpenSSH client (if not already installed)
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0

# Test SSH connection
ssh testuser@192.168.56.11
# Password: testpass123
```

## Troubleshooting

**VMs won't start:**
- Ensure VirtualBox is installed and virtualization is enabled in BIOS
- Check Windows Hyper-V is disabled: `bcdedit /set hypervisorlaunchtype off`

**Can't ping VMs:**
- Check VirtualBox host-only network adapter exists
- Run: `Get-NetAdapter | Where-Object {$_.Name -like "*VirtualBox*"}`

**SSH connection fails:**
- Verify VM is running: `vagrant status`
- Test ping: `Test-Connection -ComputerName 192.168.56.11 -Count 4`
- Check SSH service: `vagrant ssh testserver1`, then `sudo systemctl status sshd`

## Snapshot VMs (Save State)

After initial setup, save a snapshot:

```powershell
# Using VirtualBox CLI
VBoxManage snapshot HomeLab-TestServer1 take "clean-state"

# Restore snapshot
VBoxManage snapshot HomeLab-TestServer1 restore "clean-state"
```

This lets you quickly reset VMs to a clean state between tests.
