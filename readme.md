# Automated Home Lab Setup Tool

A PowerShell-based automation tool with GUI for deploying and managing services across multiple servers simultaneously. Simplify your home lab setup with automatic OS detection, Docker deployment, and Traefik reverse proxy configuration.

## Overview

This tool eliminates the repetitive and time-consuming process of setting up services across multiple servers. Through an intuitive WPF interface, you can configure multiple servers and deploy services like AdGuard, N8N, Heimdall, Crafty, and Portainer with just a few clicks. The tool handles everything from OS detection to Docker installation, service deployment, and health monitoring—all in parallel.

## Key Features

- **🖥️ Intuitive GUI**: WPF-based interface with tabbed server management
- **🚀 Parallel Execution**: Deploy to multiple servers simultaneously
- **🔍 Automatic OS Detection**: Supports Debian-based Linux and Windows 11
- **🐳 Docker Automation**: Automatic Docker/WSL2 installation and configuration
- **🔀 Traefik Integration**: Automatic reverse proxy setup with port conflict prevention
- **💚 Health Monitoring**: Real-time server and container health checks
- **📝 Comprehensive Logging**: Per-server logging with exportable error reports
- **🛡️ Robust Error Handling**: Failures on one server don't affect others
- **🔧 Modular Architecture**: Easy to extend with new services and OS support

## Supported Services (MVP)

- **AdGuard Home**: Network-wide ad blocking
- **N8N**: Workflow automation platform
- **Crafty Controller**: Minecraft server management
- **Heimdall**: Application dashboard
- **Portainer**: Docker container management

## Supported Operating Systems

- Debian-based Linux distributions (Ubuntu, Debian, Linux Mint, etc.)
- Windows 11 (with WSL2)

## Prerequisites

- PowerShell 5.1 or later
- Administrator/root privileges on target servers
- Internet connection on all servers
- SSH access configured for Linux servers
- WinRM configured for Windows servers
- Target servers must allow remote connections

## Installation

1. Clone this repository:
```powershell
git clone https://github.com/dominium2/automated-server-setup-tool.git
cd automated-server-setup-tool
```

2. Run PowerShell as Administrator

3. Set execution policy if needed:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

## Usage

### Quick Start

1. Launch the tool

2. Click **"Add Service"** to create a new server configuration tab

3. Fill in the server details:
   - **IP Address**: Server IP or hostname
   - **Credentials**: Username and password
   - **Service**: Select from dropdown (AdGuard, N8N, Heimdall, etc.)

4. Repeat for additional servers (you can deploy multiple services to the same IP)

5. Click **"Run"** to start automated deployment

## How It Works

1. **OS Detection**: Automatically identifies the target OS
2. **Dependency Installation**: Installs Docker (Linux) or WSL2/Docker Desktop (Windows)
3. **Service Deployment**: Uses Docker Compose templates for each service
4. **Traefik Configuration**: Sets up reverse proxy with automatic routing
5. **Health Checks**: Monitors container and service health
6. **Logging**: Records all operations and errors per server

## Architecture

The tool follows a modular design pattern:

- **UI Layer**: WPF-based GUI for user interaction
- **Logic Layer**: Core automation logic and orchestration
- **Module Layer**: Reusable PowerShell modules for specific tasks
- **Service Layer**: Docker Compose templates for each service

This separation ensures maintainability, testability, and extensibility.

## Testing
- Input validation
- OS detection logic
- Docker installation modules
- Deployment templates
- Error handling scenarios

## Roadmap

### MVP (Current Focus)
- ✅ OS detection (Debian-based, Windows 11)
- ✅ Docker/WSL2 installation
- ✅ Service deployment via Docker Compose
- ✅ Traefik reverse proxy configuration
- ✅ Health monitoring
- ✅ Comprehensive logging and error handling
- ✅ Parallel server setup
- ✅ Five core services (AdGuard, N8N, Crafty, Heimdall, Portainer)

### Future Enhancements
- 🔄 Auto-restart failed containers (3 attempts with exponential backoff)
- 📧 Email/webhook notifications on failures
- ➕ Additional services (Plex, Nextcloud, and more)
- 🐧 Red Hat-based Linux support (RHEL, CentOS, Fedora)
- 🖥️ Windows Server support
- 🌐 Web-based UI alternative

## Troubleshooting

### Common Issues

**Connection Failures:**
- Ensure SSH/WinRM is properly configured on target servers
- Verify firewall rules allow remote connections
- Check credentials are correct

**Docker Installation Fails:**
- Verify internet connectivity on target server
- Check if virtualization is enabled in BIOS
- Ensure sufficient disk space

**Port Conflicts:**
- Traefik automatically manages ports, but ensure port 80/443 are available
- Check for existing services on target ports

## Security Considerations

- Credentials are used only for the duration of deployment
- Consider using SSH keys instead of passwords where possible
- Store configuration files securely
- Review generated Docker Compose files before deployment
- Use HTTPS with Traefik in production environments

## Contributing

Contributions are welcome! Please follow these steps:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/new-service`)
3. Add your changes with appropriate tests
4. Ensure all tests pass (`Invoke-Pester`)
5. Submit a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Author

**dominium2**

## Acknowledgments

- Built with PowerShell and WPF
- Docker and Docker Compose for containerization
- Traefik for reverse proxy functionality

## Support

For issues, questions, or contributions, please open an issue on the GitHub repository.
