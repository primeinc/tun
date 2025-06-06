# SirTunnel Quickstart Guide

This guide will help you quickly setup and use SirTunnel on Azure.

## Prerequisites

- Azure subscription with permissions to create resources
- Azure CLI installed and logged in
- An Azure DNS zone where you can add records
- PowerShell (Windows) or Bash (Linux/macOS)
- SSH key pair generated on your computer

## Setup Steps

### 1. Clone this Repository

```powershell
git clone https://github.com/YOUR_USERNAME/YOUR_REPO.git
cd tun
```

### 2. Configure Your Deployment

Copy the sample config file and edit your settings:

```powershell
Copy-Item -Path .\scripts\config.sample.ps1 -Destination .\scripts\config.ps1
notepad .\scripts\config.ps1  # Edit with your values
```

Important configuration values to update:
- `$LOCATION` - Your preferred Azure region
- `$DNS_ZONE_NAME` - Your DNS zone name (e.g., "example.com")
- `$DNS_ZONE_RG` - Resource group containing your DNS zone
- `$SSH_PUB_KEY_PATH` - Path to your SSH public key

### 3. Validate Prerequisites

Run the validation script to make sure everything is ready:

```powershell
.\scripts\validate-prerequisites.ps1
```

### 4. Create Required Resources

Create the static public IP address (if not already created):

```powershell
.\scripts\create-static-ip.ps1
```

Create the DNS wildcard record:

```powershell
.\scripts\create-dns-record.ps1
```

### 5. Prepare Deployment Files

Run the preparation script to ensure all files are ready:

```powershell
.\scripts\prepare-deployment.ps1
```

### 6. Deploy SirTunnel

Deploy the infrastructure and configure the VM:

```powershell
.\scripts\deploy.ps1
```

This will:
1. Deploy the core infrastructure using Bicep (VM, networking, etc.)
2. Automatically execute the `redeploy-extension.ps1` script to configure the VM
3. Display connection information once complete

The deployment takes 5-10 minutes. The two-step approach ensures reliable provisioning by separating infrastructure deployment from configuration.

### 7. Test Your Deployment

Test that everything is configured correctly:

```powershell
.\tests\test-connectivity.ps1 -Subdomain api
```

## Using SirTunnel

### Simple Method (Recommended)

After deployment, the script provides a PowerShell function you can add to your profile for easy tunnel creation:

```powershell
# Add the function to your PowerShell profile
notepad $PROFILE  # Copy the function provided in the deployment output

# Then use the simplified syntax:
tun api 3000                # Exposes localhost:3000 as https://api.tun.yourdomain.com
tun dashboard 8080          # Exposes localhost:8080 as https://dashboard.tun.yourdomain.com
tun api 3000 192.168.1.10   # Exposes 192.168.1.10:3000 as https://api.tun.yourdomain.com
```

### Manual Method

Alternatively, you can create tunnels from your local machine with the full SSH command:

```powershell
# General syntax:
ssh -t -R <REMOTE_PORT>:<LOCAL_HOST>:<LOCAL_PORT> <VM_USER>@<VM_PUBLIC_IP> sirtunnel.py <SUBDOMAIN>.tun.<YOUR_DOMAIN> <REMOTE_PORT>

# Example: Expose local web server (localhost:3000) through https://api.tun.example.com
ssh -t -R 9001:localhost:3000 azureuser@<VM_PUBLIC_IP> sirtunnel.py api.tun.example.com 9001
```

Press `Ctrl+C` to stop the tunnel with either method.

## Teardown

When you're done, you can delete the infrastructure:

```powershell
.\scripts\teardown.ps1
```

This will remove all Azure resources except the static IP address and DNS zone.

## Next Steps

- Read the detailed [Setup documentation](SETUP.md)
- Check [Usage Guide](docs/USAGE.md) for more examples and best practices
- See [Troubleshooting](docs/TROUBLESHOOTING.md) if you encounter issues
