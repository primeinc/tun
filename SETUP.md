Azure Deployment Stack for SirTunnel: A Self-Hosted, Persistent Tunneling Solution

1. Introduction

This report details the design and implementation of a lightweight, self-hosted reverse proxy tunneling solution, SirTunnel, deployed on ephemeral Azure infrastructure using Bicep and Azure Deployment Stacks. The objective is to provide a secure, persistent, and automated alternative to SaaS tunneling services like ngrok, enabling developers to expose local web servers via HTTPS using a stable public endpoint.

The architecture leverages a minimal Ubuntu virtual machine (VM), a static public IP address designed to persist beyond VM lifecycles, wildcard DNS resolution for a dedicated subdomain (*.tun.title.dev), and automated configuration of Caddy web server and the SirTunnel Python script. Azure Deployment Stacks are employed to manage the infrastructure lifecycle, ensuring clean creation and deletion of ephemeral components while preserving the essential static IP address and DNS configuration.

This document provides the complete Bicep templates, installation scripts, Azure CLI commands, operational workflows, and configuration details necessary to deploy and utilize this solution effectively.

2. Solution Architecture

The proposed architecture comprises the following key components orchestrated within Azure:

Static Public IP Address: A Standard SKU static IPv4 public IP address is provisioned within the target resource group (sirtunnel-rg). This IP address serves as the stable public endpoint for all tunnels and is configured to be retained even when associated resources (like the VM or NIC) are deleted. Managing this IP address outside the primary deployment stack is recommended for simplified lifecycle management, ensuring its persistence regardless of stack operations.

Networking Infrastructure: A dedicated Virtual Network (VNet) and subnet are created to host the SirTunnel VM. A Network Interface Card (NIC) is provisioned within this subnet and associated with the static public IP address.

Virtual Machine (VM): A cost-effective Standard_B1s Ubuntu Server VM (sirtunnel-vm) is deployed. SSH access is enabled using public key authentication for secure remote management. A system-assigned managed identity is enabled on the VM.

VM Configuration (Two-Step Deployment): The solution uses a two-step deployment approach for improved reliability:
1. First, the core infrastructure (VM, networking, etc.) is provisioned via Bicep and Azure Deployment Stacks
2. Then, a separate CustomScript extension is deployed using the `redeploy-extension.ps1` script that's automatically called after successful deployment

This two-step approach offers several advantages:
- Separates infrastructure provisioning from configuration
- Provides better error handling and recovery options
- Allows independent retries of the extension if needed
- Prevents configuration failures from affecting the core infrastructure

The `redeploy-extension.ps1` script deploys a CustomScript extension that executes `install.sh`, which:
    *   Downloads and installs the Caddy web server binary to `/usr/local/bin/caddy`.
    *   Grants Caddy the capability to bind to privileged ports (e.g., 443).
    *   Creates the directories `/opt/sirtunnel/` and `/etc/caddy/`.
    *   Moves the `run_server.sh` and `sirtunnel.py` scripts (downloaded via `fileUris`) to `/opt/sirtunnel/` and makes them executable.
    *   Moves the `caddy_config.json` (also downloaded via `fileUris`) to `/etc/caddy/caddy_config.json`.
    *   Sets `HOME=/root` for Caddy's operational needs.
    After `install.sh` completes, the CustomScript Extension then executes `/opt/sirtunnel/run_server.sh` to start the Caddy server.

Caddy Web Server: Caddy acts as the reverse proxy and TLS termination point. It listens on port 443, automatically obtains and renews TLS certificates (including a wildcard certificate for *.tun.title.dev) from Let's Encrypt using the DNS-01 challenge via an Azure DNS plugin. Its configuration (`/etc/caddy/caddy_config.json`) is dynamically updated by the `sirtunnel.py` script (located at `/opt/sirtunnel/sirtunnel.py`) via its local admin API.

SirTunnel Script (sirtunnel.py): A Python script, now located at `/opt/sirtunnel/sirtunnel.py` on the VM, that interacts with the Caddy Admin API. When invoked via an SSH command from the developer's laptop, it dynamically configures Caddy to proxy a specific subdomain to a designated port on the VM, which is tunneled back to the developer's local machine via SSH remote port forwarding.

Azure DNS Zone: An existing Azure DNS Zone (title.dev) is utilized. A wildcard A record (*.tun) within this zone points to the static public IP address. The VM's managed identity is granted permissions ("DNS Zone Contributor" role) to create the necessary TXT records within this zone for the Let's Encrypt DNS-01 challenge.

Azure Deployment Stack: The Bicep template defining the VM, NIC, VNet, Subnet, Role Assignment, and VM Extension is deployed using an Azure Deployment Stack. This allows for unified management and ensures that deleting the stack can cleanly remove these ephemeral components while leaving the independently managed static IP and DNS zone untouched.

3. Bicep Implementation Details

The infrastructure is defined using Bicep, a declarative language for Azure resource deployment. The deployment is structured into a main template (main.bicep) and a setup script (install.sh) executed via a VM extension.

3.1. main.bicep

This file defines the core Azure resources. It is designed to be deployed using an Azure Deployment Stack at the resource group scope.

Parameters:
location: Azure region for deployment (defaults to resource group location).
adminUsername: Username for the VM administrator.
adminPublicKey: SSH public key for VM authentication.
vmName: Name for the virtual machine (default: sirtunnel-vm).
vmSize: Azure VM size (default: Standard_B1s).
vnetName: Name for the virtual network.
subnetName: Name for the VM subnet.
dnsZoneName: Name of the existing Azure DNS zone (e.g., title.dev).
dnsZoneResourceGroupName: Name of the resource group containing the existing DNS zone.
staticPipName: Name for the static public IP resource.
staticPipResourceGroupName: Resource group where the static Public IP resides (can be the same or different from the VM RG). Note: This parameter facilitates referencing an externally managed IP.

Key Resources:
Existing Public IP Reference: Uses the existing keyword to reference the pre-provisioned static Public IP address. This allows the stack to associate the NIC with the IP without managing the IP's lifecycle itself. This approach ensures the IP persists when the stack is deleted.

Code snippet
// Reference the existing Static Public IP managed outside this stack
resource staticPip 'Microsoft.Network/publicIPAddresses@2023-11-01' existing = {
  name: staticPipName
  scope: resourceGroup(staticPipResourceGroupName)
}

Virtual Network & Subnet: Standard VNet and Subnet definition.

Code snippet
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
    ]
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  name: subnetName
  parent: virtualNetwork
}

Network Interface (NIC): Associates the NIC with the subnet and the existing static public IP.

Code snippet
resource networkInterface 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations:
    networkSecurityGroup: {
      id: networkSecurityGroup.id // Reference the NSG created below
    }
  }
  dependsOn: [
    virtualNetwork // Explicit dependency for clarity, though often inferred
  ]
}

Network Security Group (NSG): Defines rules to allow inbound SSH (port 22) and HTTPS (port 443) traffic.

Code snippet
resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${vmName}-nsg'
  location: location
  properties: {
    securityRules:
  }
}

Virtual Machine: Provisions the Ubuntu VM, enables system-assigned managed identity, and configures SSH access.

Code snippet
resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  // Enable System-Assigned Managed Identity
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys:
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS' // Or Premium_LRS
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
        }
      ]
    }
  }
}

Role Assignment: Grants the VM's system-assigned managed identity the "DNS Zone Contributor" role on the existing Azure DNS Zone. This permission is necessary for the Caddy Azure DNS plugin to manage ACME challenge TXT records. The scope is set to the existing DNS zone resource group.

Code snippet
// Reference the existing DNS Zone
resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: dnsZoneName
  scope: resourceGroup(dnsZoneResourceGroupName)
}

// Assign 'DNS Zone Contributor' role to the VM's Managed Identity for the DNS Zone
resource assignDnsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, virtualMachine.id, dnsZone.id) // Unique name for role assignment
  scope: dnsZone // Scope the assignment to the existing DNS zone
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'befefa01-2a29-4197-83a8-272ff33ce314') // DNS Zone Contributor Role ID
    principalId: virtualMachine.identity.principalId // VM's Managed Identity Principal ID
    principalType: 'ServicePrincipal'
  }
}

VM Extension (Post-Deployment): The VM extension is intentionally removed from the main Bicep file and applied as a post-deployment step for improved reliability. The `deploy.ps1` script automatically calls `redeploy-extension.ps1` after successful infrastructure deployment. This approach allows for more flexible error handling and recovery.

The commented reference implementation in main.bicep provides documentation for how the extension would be configured:

Code snippet
/*
resource vmExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: virtualMachine
  name: 'install-sirtunnel-caddy'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      skipDos2Unix: false
      fileUris: [
        'https://raw.githubusercontent.com/${githubRepo}/main/scripts/install.sh',
        'https://raw.githubusercontent.com/${githubRepo}/main/scripts/run_server.sh',
        'https://raw.githubusercontent.com/${githubRepo}/main/scripts/caddy_config.json',
        'https://raw.githubusercontent.com/${githubRepo}/main/scripts/sirtunnel.py'
      ]
    }
    protectedSettings: {
      commandToExecute: 'bash install.sh ${subscription().subscriptionId} ${dnsZoneResourceGroupName} ${dnsZoneName}'
    }
  }
  dependsOn: [
    dnsRoleAssignment
  ]
}
*/

Note: The commandToExecute example uses curl to fetch the script directly. For production, hosting install.sh securely (e.g., Azure Storage Blob with SAS token, GitHub Raw with caution) and using fileUris is generally preferred.

Outputs:
publicIPAddress: The static public IP address associated with the VM.
vmAdminUsername: The administrator username for SSH access.
sshCommand: A sample SSH command to connect to the VM.
sampleTunnelEndpoint: An example HTTPS endpoint URL (e.g., https://example.tun.title.dev).

Code snippet
// --- main.bicep ---
@description('Azure region for deployment.')
param location string = resourceGroup().location

@description('Username for the Virtual Machine.')
param adminUsername string

@description('SSH Public Key for the Virtual Machine.')
@secure()
param adminPublicKey string

@description('Name of the Virtual Machine.')
param vmName string = 'sirtunnel-vm'

@description('Size for the Virtual Machine.')
param vmSize string = 'Standard_B1s'

@description('Name of the Virtual Network.')
param vnetName string = 'sirtunnel-vnet'

@description('Name of the Subnet.')
param subnetName string = 'sirtunnel-subnet'

@description('Name of the existing Azure DNS Zone (e.g., title.dev).')
param dnsZoneName string

@description('Resource Group name where the existing Azure DNS Zone resides.')
param dnsZoneResourceGroupName string

@description('Name of the existing Static Public IP Address resource.')
param staticPipName string

@description('Resource Group name where the existing Static Public IP Address resides.')
param staticPipResourceGroupName string

var networkInterfaceName = '${vmName}-nic'
var networkSecurityGroupName = '${vmName}-nsg'
var dnsZoneContributorRoleId = 'befefa01-2a29-4197-83a8-272ff33ce314' // Built-in DNS Zone Contributor Role ID
// URL to your install.sh script (replace with your actual URL if using fileUris)
var installScriptUrl = 'https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/install.sh' // EXAMPLE URL - REPLACE

// --- Reference Existing Resources ---
resource staticPip 'Microsoft.Network/publicIPAddresses@2023-11-01' existing = {
  name: staticPipName
  scope: resourceGroup(staticPipResourceGroupName)
}

resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: dnsZoneName
  scope: resourceGroup(dnsZoneResourceGroupName)
}

// --- Networking ---
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
    ]
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  name: subnetName
  parent: virtualNetwork
}

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: networkSecurityGroupName
  location: location
  properties: {
    securityRules:
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: networkInterfaceName
  location: location
  properties: {
    ipConfigurations:
    networkSecurityGroup: {
      id: networkSecurityGroup.id
    }
  }
  dependsOn: [
    virtualNetwork
  ]
}

// --- Virtual Machine ---
resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys:
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
        deleteOption: 'Delete' // Delete OS disk when VM is deleted
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
        }
      ]
    }
  }
}

// --- Role Assignment for Managed Identity ---
resource assignDnsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, virtualMachine.id, dnsZone.id)
  scope: dnsZone // Scope to the existing DNS zone
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dnsZoneContributorRoleId)
    principalId: virtualMachine.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// --- VM Extension for Setup ---
resource vmExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: virtualMachine
  name: 'installSirtunnelCaddy'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      // Fetch and execute install.sh, passing Subscription ID and DNS Zone RG Name
      'commandToExecute': 'bash -c "$(curl -fsSL ${installScriptUrl}) ${subscription().subscriptionId} ${dnsZoneResourceGroupName}"'
    }
    // Add protectedSettings if install.sh needs secrets
  }
}

// --- Outputs ---
output publicIPAddress string = staticPip.properties.ipAddress
output vmAdminUsername string = adminUsername
output sshCommand string = 'ssh ${adminUsername}@${staticPip.properties.ipAddress}'
output sampleTunnelEndpoint string = 'https://example.tun.${dnsZoneName}'