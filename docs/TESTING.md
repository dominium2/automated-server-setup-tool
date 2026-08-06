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

Integration tests perform actual end-to-end deployments against live virtual machines. This ensures that the generated bash scripts, Docker installation sequences, and Traefik proxy networking behave correctly in a real-world environment.

### Prerequisites
1. Install VirtualBox

2. Install Vagrant

### Starting the Test VMs

```powershell
# Navigate to project directory
cd automated-server-setup-tool

# Start the test servers (takes 5-10 minutes the first time)
vagrant up

# Check status
vagrant status
```

This provisions test servers (e.g., Debian at `192.168.56.11`). All servers use:
- **Username**: `testuser`
- **Password**: `testpass123`

### Running the Integration Test
Once the VMs are completely booted and running:

```powershell
Invoke-Pester -Path .\tests\Portainer-Integration.Tests.ps1
```
### Useful Vagrant Commands

```powershell
# Stop all VMs
vagrant halt

# Delete all VMs (free up space)
vagrant destroy -f

# SSH directly into a VM to verify containers manually
vagrant ssh linux1
```