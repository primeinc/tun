# SirTunnel on Azure

A self-hosted, persistent tunneling solution deployed on ephemeral Azure infrastructure using Bicep and Azure Deployment Stacks.

## Overview

SirTunnel provides a secure, persistent, and automated alternative to SaaS tunneling services like ngrok, enabling developers to expose local web servers via HTTPS using a stable public endpoint.

The architecture leverages:

- A minimal Ubuntu virtual machine (VM)
- A static public IP address designed to persist beyond VM lifecycles
- Wildcard DNS resolution for a dedicated subdomain (*.tun.title.dev)
- Automated configuration of Caddy web server and the SirTunnel Python script
- Azure Deployment Stacks for clean lifecycle management
- Persistent state management for reliable tunnel operations

## Features

- **Zero-Trust Security**: All tunnels are secured with HTTPS via automatic Caddy configuration
- **Wildcard DNS**: Use any subdomain with your dedicated tunnel domain (e.g., api.tun.example.com)
- **PowerShell Module**: Convenient commands for managing tunnels in Windows environments
- **Persistent State**: Tunnel information is preserved across terminal sessions and system reboots
- **Diagnostics**: Built-in tools for troubleshooting tunnel connectivity issues
- **Cost-Effective**: Deploy on minimal Azure infrastructure (as low as $15/month)

## Quick Start

See the [Quickstart Guide](QUICKSTART.md) for step-by-step instructions.

### Prerequisites

- Azure CLI installed and logged in
- An existing Azure DNS Zone (e.g., title.dev)
- A Standard SKU static Public IP address created in Azure
- SSH key pair generated (~/.ssh/id_rsa and ~/.ssh/id_rsa.pub)

### Deployment

1. Clone this repository
2. Configure deployment parameters:
   ```powershell
   Copy-Item .\scripts\config.sample.ps1 .\scripts\config.ps1
   notepad .\scripts\config.ps1  # Edit configuration variables
   ```
3. Create prerequisites and deploy:
   ```powershell
   .\scripts\validate-prerequisites.ps1
   .\scripts\create-static-ip.ps1
   .\scripts\create-dns-record.ps1
   .\scripts\prepare-deployment.ps1
   .\scripts\deploy.ps1  # Handles both infrastructure deployment and VM configuration
   ```
4. Use the tunneling service (simplified with provided alias):
   ```powershell
   # Add the alias function to your PowerShell profile as shown in deployment output
   tun api 3000  # Expose localhost:3000 as https://api.tun.yourdomain.com
   ```

## Repository Structure

```
tun/
├── README.md                     # Project overview (this file)
├── SETUP.md                      # Detailed technical documentation
├── QUICKSTART.md                 # Step-by-step quickstart guide
├── .gitignore                    # Git ignore file
├── docs/                         # Additional documentation
│   ├── USAGE.md                  # How to use SirTunnel for developers
│   └── TROUBLESHOOTING.md        # Common issues and resolutions
├── infra/                        # Infrastructure as code
│   ├── main.bicep                # Main Bicep template for VM and components
│   └── parameters/               # Environment-specific parameters 
│       ├── dev.parameters.json   # Development parameters
│       └── prod.parameters.json  # Production parameters
├── scripts/                      # Scripts for deployment and configuration
│   ├── config.sample.ps1         # Sample configuration file
│   ├── config.ps1                # Your personal configuration (gitignored)
│   ├── create-dns-record.ps1     # Script to create wildcard DNS record
│   ├── create-static-ip.ps1      # Script to create static public IP
│   ├── deploy.ps1                # Main deployment script (infrastructure)
│   ├── redeploy-extension.ps1    # VM extension deployment script (configuration)
│   ├── install.sh                # VM configuration script
│   ├── prepare-deployment.ps1    # Prepare files for deployment
│   ├── sirtunnel.py              # Enhanced SirTunnel script
│   ├── teardown.ps1              # Resource cleanup script
│   └── validate-prerequisites.ps1 # Prerequisite validation script
└── tests/                        # Testing and validation
    └── test-connectivity.ps1     # Test tunnel connectivity
```

## Documentation

For detailed documentation, see:

- [Quickstart Guide](QUICKSTART.md)
- [Detailed Technical Documentation](SETUP.md)
- [Usage Instructions](docs/USAGE.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)

## Security Notes

This implementation emphasizes security through:
- HTTPS by default with automatic certificate management
- Managed Identity for secure Azure DNS interaction
- Restricted access to Caddy Admin API 
- SSH public key authentication
- Minimal network exposure (only ports 22 and 443)
