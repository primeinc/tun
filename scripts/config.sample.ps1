# Configuration for SirTunnel Azure deployment
# Copy this file to config.ps1 and adjust the values according to your environment

# Azure region for deployment
$LOCATION = "WestUS3"

# Resource group for the VM and related resources
$VM_RG_NAME = "sirtunnel-rg"

# VM administrator username
$ADMIN_USER = "azureuser"

# Path to SSH public key file
$SSH_PUB_KEY_PATH = "$env:USERPROFILE\.ssh\id_rsa.pub"

# DNS Zone information
$DNS_ZONE_NAME = "title.dev"
$DNS_ZONE_RG = "my-dns-rg"

# Static Public IP information
$STATIC_PIP_NAME = "sirtunnel-pip"
$STATIC_PIP_RG = "sirtunnel-pip-rg"

# Stack name
$STACK_NAME = "sirtunnel-stack"

# GitHub repository for install script URL (update in main.bicep as well)
$GITHUB_REPO = "YOUR_USERNAME/YOUR_REPO"

# Optional IP override for DryRun mode
# $VM_IP_OVERRIDE = "20.30.40.50"  # Uncomment and set your VM's IP here

