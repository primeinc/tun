Azure Deployment Stack for SirTunnel: A Self-Hosted, Persistent Tunneling Solution1. IntroductionThis report details the design and implementation of a lightweight, self-hosted reverse proxy tunneling solution, SirTunnel, deployed on ephemeral Azure infrastructure using Bicep and Azure Deployment Stacks. The objective is to provide a secure, persistent, and automated alternative to SaaS tunneling services like ngrok, enabling developers to expose local web servers via HTTPS using a stable public endpoint.The architecture leverages a minimal Ubuntu virtual machine (VM), a static public IP address designed to persist beyond VM lifecycles, wildcard DNS resolution for a dedicated subdomain (*.tun.title.dev), and automated configuration of Caddy web server and the SirTunnel Python script. Azure Deployment Stacks are employed to manage the infrastructure lifecycle, ensuring clean creation and deletion of ephemeral components while preserving the essential static IP address and DNS configuration.This document provides the complete Bicep templates, installation scripts, Azure CLI commands, operational workflows, and configuration details necessary to deploy and utilize this solution effectively.2. Solution ArchitectureThe proposed architecture comprises the following key components orchestrated within Azure:
Static Public IP Address: A Standard SKU static IPv4 public IP address is provisioned within the target resource group (sirtunnel-rg). This IP address serves as the stable public endpoint for all tunnels and is configured to be retained even when associated resources (like the VM or NIC) are deleted.1 Managing this IP address outside the primary deployment stack is recommended for simplified lifecycle management, ensuring its persistence regardless of stack operations.
Networking Infrastructure: A dedicated Virtual Network (VNet) and subnet are created to host the SirTunnel VM. A Network Interface Card (NIC) is provisioned within this subnet and associated with the static public IP address.3
Virtual Machine (VM): A cost-effective Standard_B1s Ubuntu Server VM (sirtunnel-vm) is deployed.5 SSH access is enabled using public key authentication for secure remote management.7 A system-assigned managed identity is enabled on the VM.
VM Configuration (Custom Script Extension): A VM extension executes a custom script (install.sh) upon VM creation.9 This script handles the installation and initial configuration of Caddy and the SirTunnel Python script.
Caddy Web Server: Caddy acts as the reverse proxy and TLS termination point. It listens on port 443, automatically obtains and renews TLS certificates (including a wildcard certificate for *.tun.title.dev) from Let's Encrypt using the DNS-01 challenge via an Azure DNS plugin.11 Its configuration is dynamically updated by the sirtunnel.py script via its local admin API.14
SirTunnel Script (sirtunnel.py): A Python script residing on the VM that interacts with the Caddy Admin API.14 When invoked via an SSH command from the developer's laptop, it dynamically configures Caddy to proxy a specific subdomain to a designated port on the VM, which is tunneled back to the developer's local machine via SSH remote port forwarding.
Azure DNS Zone: An existing Azure DNS Zone (title.dev) is utilized. A wildcard A record (*.tun) within this zone points to the static public IP address.16 The VM's managed identity is granted permissions ("DNS Zone Contributor" role) to create the necessary TXT records within this zone for the Let's Encrypt DNS-01 challenge.18
Azure Deployment Stack: The Bicep template defining the VM, NIC, VNet, Subnet, Role Assignment, and VM Extension is deployed using an Azure Deployment Stack.20 This allows for unified management and ensures that deleting the stack can cleanly remove these ephemeral components while leaving the independently managed static IP and DNS zone untouched.
3. Bicep Implementation DetailsThe infrastructure is defined using Bicep, a declarative language for Azure resource deployment.3 The deployment is structured into a main template (main.bicep) and a setup script (install.sh) executed via a VM extension.3.1. main.bicepThis file defines the core Azure resources. It is designed to be deployed using an Azure Deployment Stack at the resource group scope.Parameters:
location: Azure region for deployment (defaults to resource group location).
adminUsername: Username for the VM administrator.
adminPublicKey: SSH public key for VM authentication.7
vmName: Name for the virtual machine (default: sirtunnel-vm).
vmSize: Azure VM size (default: Standard_B1s).
vnetName: Name for the virtual network.
subnetName: Name for the VM subnet.
dnsZoneName: Name of the existing Azure DNS zone (e.g., title.dev).
dnsZoneResourceGroupName: Name of the resource group containing the existing DNS zone.
staticPipName: Name for the static public IP resource.
staticPipResourceGroupName: Resource group where the static Public IP resides (can be the same or different from the VM RG). Note: This parameter facilitates referencing an externally managed IP.
Key Resources:
Existing Public IP Reference: Uses the existing keyword to reference the pre-provisioned static Public IP address. This allows the stack to associate the NIC with the IP without managing the IP's lifecycle itself.23 This approach ensures the IP persists when the stack is deleted.
Code snippet// Reference the existing Static Public IP managed outside this stack
resource staticPip 'Microsoft.Network/publicIPAddresses@2023-11-01' existing = {
  name: staticPipName
  scope: resourceGroup(staticPipResourceGroupName)
}


Virtual Network & Subnet: Standard VNet and Subnet definition.3
Code snippetresource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-11-01' = {
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


Network Interface (NIC): Associates the NIC with the subnet and the existing static public IP.24
Code snippetresource networkInterface 'Microsoft.Network/networkInterfaces@2023-11-01' = {
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


Network Security Group (NSG): Defines rules to allow inbound SSH (port 22) and HTTPS (port 443) traffic.5
Code snippetresource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${vmName}-nsg'
  location: location
  properties: {
    securityRules:
  }
}


Virtual Machine: Provisions the Ubuntu VM, enables system-assigned managed identity, and configures SSH access.5
Code snippetresource virtualMachine 'Microsoft.Compute/virtualMachines@2024-03-01' = {
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


Role Assignment: Grants the VM's system-assigned managed identity the "DNS Zone Contributor" role on the existing Azure DNS Zone. This permission is necessary for the Caddy Azure DNS plugin to manage ACME challenge TXT records.18 The scope is set to the existing DNS zone resource group.23
Code snippet// Reference the existing DNS Zone
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


VM Extension (Custom Script): Executes the install.sh script to set up Caddy and SirTunnel.9 It passes necessary information like the Azure Subscription ID and DNS Zone Resource Group name to the script, which are needed for Caddy's Azure DNS provider configuration.
Code snippetresource vmExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: virtualMachine
  name: 'installSirtunnelCaddy'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      // Use commandToExecute for inline script or fileUris for external script
      // Passing parameters needed by install.sh for Caddy config
      'commandToExecute': 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/path/to/your/install.sh) -- ${subscription().subscriptionId} ${dnsZoneResourceGroupName}"'
      // Alternatively, upload install.sh and use fileUris:
      // 'fileUris':,
      // 'commandToExecute': 'bash install.sh ${subscription().subscriptionId} ${dnsZoneResourceGroupName}'
    }
    // protectedSettings could be used for secrets if needed
  }
}

Note: The commandToExecute example uses curl to fetch the script directly. For production, hosting install.sh securely (e.g., Azure Storage Blob with SAS token, GitHub Raw with caution) and using fileUris is generally preferred.
Outputs:
publicIPAddress: The static public IP address associated with the VM.
vmAdminUsername: The administrator username for SSH access.
sshCommand: A sample SSH command to connect to the VM.
sampleTunnelEndpoint: An example HTTPS endpoint URL (e.g., https://example.tun.title.dev).
Code snippet// --- main.bicep ---
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
3.2. install.shThis script is executed by the VM Custom Script Extension to prepare the VM environment. It installs Caddy, SirTunnel, and configures Caddy's initial state, including setting up the Azure DNS provider with Managed Identity.Bash#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# Script arguments passed from Bicep VM Extension
AZURE_SUBSCRIPTION_ID="$1"
AZURE_RESOURCE_GROUP_NAME="$2" # DNS Zone RG Name

echo "Starting Caddy and SirTunnel installation..."
echo "Azure Subscription ID: ${AZURE_SUBSCRIPTION_ID}"
echo "Azure DNS Zone Resource Group: ${AZURE_RESOURCE_GROUP_NAME}"

# Update package list and install dependencies
echo "Updating packages and installing dependencies..."
sudo apt-get update -y
sudo apt-get install -y curl wget gnupg apt-transport-https debian-keyring debian-archive-keyring python3 python3-pip

# Install Caddy using the official Cloudsmith repository [11, 27]
echo "Installing Caddy..."
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update -y
sudo apt-get install caddy -y

# Enable and start Caddy service
echo "Enabling and starting Caddy service..."
sudo systemctl enable --now caddy
sudo systemctl status caddy --no-pager

# Configure Caddy systemd service to include Azure environment variables for DNS plugin
# This allows Caddy to use Managed Identity for Azure DNS challenges [28]
echo "Configuring Caddy service environment variables..."
SERVICE_FILE="/etc/systemd/system/caddy.service"
if; then
    # Check if Environment lines already exist to avoid duplicates
    if! grep -q "Environment=AZURE_SUBSCRIPTION_ID=" "$SERVICE_FILE"; then
        sudo sed -i "/\/a Environment=AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}" "$SERVICE_FILE"
    fi
    if! grep -q "Environment=AZURE_RESOURCE_GROUP_NAME=" "$SERVICE_FILE"; then
        sudo sed -i "/\/a Environment=AZURE_RESOURCE_GROUP_NAME=${AZURE_RESOURCE_GROUP_NAME}" "$SERVICE_FILE"
    fi
    sudo systemctl daemon-reload
    sudo systemctl restart caddy # Restart Caddy to apply environment variables
    echo "Caddy service environment variables configured and service restarted."
else
    echo "WARNING: Caddy service file not found at ${SERVICE_FILE}. Cannot set environment variables."
fi

# Install SirTunnel script [14]
echo "Installing SirTunnel script..."
# Replace with the actual raw URL of sirtunnel.py from the desired repository/branch
SIRTUNNEL_URL="https://raw.githubusercontent.com/anderspitman/SirTunnel/master/sirtunnel.py"
sudo wget -O /usr/local/bin/sirtunnel.py "$SIRTUNNEL_URL"
sudo chmod +x /usr/local/bin/sirtunnel.py
# Check if pip dependencies are needed for sirtunnel.py (currently none apparent)
# sudo pip3 install requests # Example if needed

# Configure Caddy initial state via Admin API [15, 29]
# This ensures the admin API is ready and TLS automation with Azure DNS is configured
echo "Configuring Caddy initial state via API..."
CADDY_CONFIG_JSON=$(cat <<EOF
{
  "admin": {
    "listen": "localhost:2019" // Default, but explicit for clarity [15]
  },
  "logging": {
    "logs": {
      "default": {
        "level": "INFO"
      }
    }
  },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [":443"], // Listen on standard HTTPS port
          "routes": // Routes will be added dynamically by sirtunnel.py
        }
      }
    },
    "tls": {
      "automation": {
        "policies":,
            "challenges": {
              "dns": {
                "provider": {
                  "name": "azure",
                  // These values are read from environment variables set in the service file [28]
                  "subscription_id": "{env.AZURE_SUBSCRIPTION_ID}",
                  "resource_group_name": "{env.AZURE_RESOURCE_GROUP_NAME}"
                  // tenant_id, client_id, client_secret are omitted for Managed Identity
                }
              }
            }
            // Add 'on_demand: true' here if needed, but likely not required for SirTunnel's explicit API calls
          }
        ]
      }
    }
  }
}
EOF
)

# Wait a moment for Caddy API to be ready after restart
sleep 5

# Load the initial configuration using curl to the admin API
curl -X POST "http://localhost:2019/load" \
  -H "Content-Type: application/json" \
  -d "${CADDY_CONFIG_JSON}" --fail --silent --show-error |
| echo "Failed to load initial Caddy config via API. Check Caddy status and logs."

echo "Installation and initial configuration complete."

Using the official Caddy Debian package handles the creation of the caddy user and group, sets up necessary directories like /etc/caddy, /var/lib/caddy, and /etc/ssl/caddy, and configures appropriate permissions.30 It also provides the systemd service file (/etc/systemd/system/caddy.service), simplifying service management compared to manual binary installation. The script modifies this service file to inject the Azure Subscription ID and Resource Group Name as environment variables, making them accessible to the Caddy process for the Azure DNS plugin.283.3. Azure Resources CreatedThe Bicep template and associated script provision the following core Azure resources:Resource TypeAzure Name (Example)Key Configuration/PurposeManaged by StackPublic IP Addresssirtunnel-pipStandard SKU, Static IPv4 (Referenced, Managed Externally)NoDNS Zonetitle.devExisting Zone (Referenced for Role Assignment)NoVirtual Networksirtunnel-vnet10.0.0.0/16 address spaceYesSubnetsirtunnel-subnet10.0.0.0/24 within VNetYesNetwork Security Groupsirtunnel-vm-nsgAllows Inbound TCP 22 (SSH) & 443 (HTTPS)YesNetwork Interfacesirtunnel-vm-nicAssociates Subnet, NSG, and existing Static Public IPYesVirtual Machinesirtunnel-vmStandard_B1s Ubuntu 22.04 LTS, System-Assigned Managed IDYesRole AssignmentGUID-basedAssigns "DNS Zone Contributor" to VM ID on DNS ZoneYesVM Extension (CustomScript)installSirtunnelCaddyExecutes install.sh for Caddy/SirTunnel setupYes4. Caddy Configuration Deep DiveCaddy serves as the core component handling HTTPS termination, certificate management, and dynamic reverse proxying based on instructions from sirtunnel.py.4.1. Initial Configuration (caddy_config.json)The install.sh script pushes an initial JSON configuration to the Caddy Admin API (localhost:2019/load).15 This establishes the baseline operational state.JSON{
  "admin": {
    "listen": "localhost:2019" // Default, ensures API is only locally accessible [15]
  },
  "logging": {
    "logs": {
      "default": {
        "level": "INFO" // Adjust log level (DEBUG, WARN, ERROR) as needed
      }
    }
  },
  "apps": {
    "http": {
      "servers": {
        "srv0": { // Default server instance
          "listen": [":443"], // Listen on standard HTTPS port
          "routes": // Start with no predefined routes; sirtunnel.py adds them dynamically
        }
      }
    },
    "tls": {
      "automation": {
        "policies":,
            "challenges": {
              "dns": {
                "provider": {
                  "name": "azure", // Use the Azure DNS provider plugin [28, 32]
                  // These values are read from environment variables set in the systemd service file
                  "subscription_id": "{env.AZURE_SUBSCRIPTION_ID}",
                  "resource_group_name": "{env.AZURE_RESOURCE_GROUP_NAME}"
                  // For Managed Identity: tenant_id, client_id, client_secret MUST be omitted [28]
                }
              }
            }
          }
        ]
        // 'on_demand': {} // On-demand TLS could be configured here if needed, but not required by SirTunnel's approach
      }
    }
  }
}
Key aspects of this configuration:
Admin API: Explicitly configured to listen only on localhost:2019. This is the default behavior 15 but is stated here for clarity. This restriction is critical; exposing the admin API externally would allow unauthorized control over the Caddy instance.
HTTP App: Defines a server (srv0) listening on port 443 for incoming HTTPS traffic. It starts with an empty routes array; sirtunnel.py will dynamically add routes to this array via API calls.29
TLS App (Automation):

Configures automatic HTTPS using ACME issuers (Let's Encrypt and optionally ZeroSSL). A valid email address is required for certificate notifications.
Specifies the DNS-01 challenge using the azure provider.28
Critically, it relies on environment variables (AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP_NAME) set by install.sh in the caddy.service file.
By omitting tenant_id, client_id, and client_secret, the Azure DNS plugin is instructed to use the VM's system-assigned Managed Identity for authentication with Azure DNS.28 This avoids storing sensitive credentials on the VM.


4.2. Caddy Admin APIThe Admin API, listening on http://localhost:2019 by default, is the mechanism through which sirtunnel.py dynamically manages reverse proxy routes.14
Accessibility: It is crucial that this API remains bound to localhost. The Bicep template's NSG rules do not expose port 2019, providing network-level enforcement. Any changes to Caddy's configuration must preserve this local binding to maintain security.
Interaction: sirtunnel.py makes HTTP POST/PATCH/DELETE requests to endpoints like /config/apps/http/servers/srv0/routes/... to add or remove proxy configurations for specific subdomains requested by the user via the SSH command.14
4.3. Wildcard Certificate HandlingCaddy's automatic HTTPS and the DNS challenge integration streamline certificate management for the *.tun.title.dev wildcard domain.
Trigger: When sirtunnel.py adds the first route for a subdomain (e.g., api.tun.title.dev) via the API, Caddy recognizes the need for a TLS certificate.
ACME Process: Caddy initiates the ACME protocol with Let's Encrypt (or the configured issuer).
DNS Challenge: Because the tls.automation.policies specify the dns challenge with the azure provider, Caddy invokes the caddy-dns/azure module.12
Azure Authentication: The module uses the VM's Managed Identity to authenticate to Azure Resource Manager.28
TXT Record Creation: Using the permissions granted by the "DNS Zone Contributor" role assignment, the module creates the required _acme-challenge.tun TXT record in the title.dev Azure DNS zone with the value provided by the ACME server.
Verification: Let's Encrypt queries Azure DNS, finds the TXT record, and verifies domain ownership.
Issuance & Storage: Caddy receives the wildcard certificate for *.tun.title.dev and securely stores it locally (typically within /var/lib/caddy/.local/share/caddy/certificates/).30
Serving: Caddy uses the obtained wildcard certificate to serve HTTPS traffic for api.tun.title.dev and any subsequent subdomains under *.tun.title.dev requested via SirTunnel.
4.4. Caddy Azure DNS Provider Configuration (Managed Identity)The core configuration for enabling the Azure DNS challenge with Managed Identity within the Caddy JSON is summarized below:
ParameterRequiredValueNotesnameYesazureSpecifies the Azure DNS provider plugin.32subscription_idYes{env.AZURE_SUBSCRIPTION_ID}Reads Subscription ID from environment variable.28resource_group_nameYes{env.AZURE_RESOURCE_GROUP_NAME}Reads DNS Zone's Resource Group Name from environment variable.28tenant_idNo(Omitted)Must be omitted to trigger Managed Identity authentication.28client_idNo(Omitted)Must be omitted to trigger Managed Identity authentication.28client_secretNo(Omitted)Must be omitted to trigger Managed Identity authentication.28
5. Azure DNS ConfigurationProper DNS configuration is essential for routing traffic to the SirTunnel VM and enabling automatic TLS certificate issuance.
Requirement: A wildcard DNS A record (*.tun) within the existing title.dev zone must resolve to the static public IP address provisioned for the SirTunnel VM.
Verification/Creation:

Obtain the static public IP address value (e.g., from deployment outputs or by querying the Azure resource).
Access the title.dev Azure DNS Zone via the Azure portal or Azure CLI.
Check for an existing A record named *.tun.
If it exists: Verify its value matches the static IP address. Update if necessary using az network dns record-set a update or the portal.
If it does not exist: Create the record using az network dns record-set a add-record or the portal:

Name: *.tun
Type: A
TTL: e.g., 3600 (seconds)
IP Address: <Your_Static_Public_IP>

Code snippet# Example CLI command to add the record
az network dns record-set a add-record \
  --resource-group <DNS_ZONE_RG_NAME> \
  --zone-name title.dev \
  --record-set-name '*.tun' \
  --ipv4-address <Your_Static_Public_IP> \
  --ttl 3600


Allow time for DNS propagation, which can take minutes to hours depending on TTL settings and DNS caching worldwide.13 Tools like dig or online DNS checkers can help verify propagation.


Bicep Context: The main.bicep template references the existing DNS zone (Microsoft.Network/dnsZones using the existing keyword and scope) primarily to establish the target scope for the Role Assignment.23 This allows the VM's Managed Identity to interact with the zone for ACME challenges. The Bicep template itself does not create or modify the DNS zone or its records (except for the TXT records managed by Caddy via the assigned role).
6. Deployment Stack UsageAzure Deployment Stacks provide a robust mechanism for managing the lifecycle of the Azure resources defined in main.bicep.21 Using the recommended approach where the Static Public IP is managed outside the stack simplifies operations.

Prerequisites:

Azure CLI installed and logged in.
An existing Azure DNS Zone (title.dev in this example).
A Standard SKU static Public IP address created in Azure (note its name and resource group).
An SSH key pair (~/.ssh/id_rsa and ~/.ssh/id_rsa.pub assumed).
The main.bicep and install.sh (hosted at a reachable URL) files.



Create/Update Command:
Bash# --- Define Variables ---
LOCATION="WestUS3" # Or your preferred Azure region
VM_RG_NAME="sirtunnel-rg" # Resource group for the VM and related resources
ADMIN_USER="azureuser"
SSH_PUB_KEY_PATH="$HOME/.ssh/id_rsa.pub"

# DNS Zone Info
DNS_ZONE_NAME="title.dev"
DNS_ZONE_RG="my-dns-rg" # RG containing the title.dev zone

# External Static IP Info
STATIC_PIP_NAME="sirtunnel-pip" # Name of your pre-created static IP
STATIC_PIP_RG="sirtunnel-pip-rg" # RG containing the static IP (can be same as VM_RG_NAME)

STACK_NAME="sirtunnel-stack"

# --- Ensure Resource Group Exists ---
az group create --name $VM_RG_NAME --location $LOCATION

# --- Read SSH Public Key ---
SSH_PUB_KEY=$(cat "$SSH_PUB_KEY_PATH")
if; then
  echo "Error: SSH public key not found or empty at $SSH_PUB_KEY_PATH"
  exit 1
fi

# --- Deploy/Update the Stack ---
echo "Deploying/Updating Deployment Stack: $STACK_NAME in resource group $VM_RG_NAME..."
az stack group create \
  --name $STACK_NAME \
  --resource-group $VM_RG_NAME \
  --template-file main.bicep \
  --parameters \
      location=$LOCATION \
      adminUsername=$ADMIN_USER \
      adminPublicKey="$SSH_PUB_KEY" \
      dnsZoneName=$DNS_ZONE_NAME \
      dnsZoneResourceGroupName=$DNS_ZONE_RG \
      staticPipName=$STATIC_PIP_NAME \
      staticPipResourceGroupName=$STATIC_PIP_RG \
  --action-on-unmanage resources=delete \
  --deny-settings-mode none # Allows manual changes if needed

echo "Deployment stack operation completed."


--action-on-unmanage resources=delete: This flag dictates what happens if a resource definition is removed from the main.bicep file during a stack update. In this case, the corresponding Azure resource would be deleted.22 resources=detach could also be used if preferring to manually clean up resources removed from the template. deleteAll is generally discouraged here unless managing the RG itself via Bicep.
--deny-settings-mode none: Disables resource locks via the stack, allowing flexibility for manual intervention if required. More restrictive modes (denyDelete, denyWriteAndDelete) can be used for production hardening.22



Delete Command (Removing VM/NIC/VNet, Keeping External IP/DNS):Since the Static Public IP and DNS Zone are managed externally (referenced using existing in Bicep), deleting the stack will remove the VM, NIC, VNet, Subnet, NSG, Role Assignment, and Extension, but leave the IP and DNS Zone untouched. The action-on-unmanage flag during delete primarily affects resources managed by the stack.
Bashecho "Deleting Deployment Stack: $STACK_NAME and its managed resources..."
az stack group delete \
  --name $STACK_NAME \
  --resource-group $VM_RG_NAME \
  --action-on-unmanage deleteResources \
  --yes # Skip confirmation

echo "Stack and managed resources deleted. External Static IP and DNS Zone remain."


Using deleteResources ensures the managed resources (VM, NIC, VNet, etc.) are deleted, providing a clean teardown of the ephemeral infrastructure. deleteAll would have the same effect here as the resource group itself isn't defined within this particular Bicep template. Using detachAll would leave the VM, NIC, VNet etc. in place but unmanaged, which is generally not desired for ephemeral components.20


7. SirTunnel Usage WorkflowOnce the infrastructure is deployed and Caddy is running, developers can establish secure tunnels from their local machines.

Initiate Tunnel (Developer Laptop):Open a terminal and run the SSH command with remote port forwarding, executing sirtunnel.py on the remote VM.14
Bash# General Syntax:
ssh -t -R <REMOTE_PORT>:<LOCAL_HOST>:<LOCAL_PORT> <VM_USER>@<VM_PUBLIC_IP> sirtunnel.py <SUBDOMAIN>.tun.title.dev <REMOTE_PORT>

# Example: Expose local server on localhost:3000 via https://api.tun.title.dev
# Assumes VM_PUBLIC_IP is the output from Bicep, VM_USER is 'azureuser'
# REMOTE_PORT 9001 is chosen arbitrarily for the VM-side listener
ssh -t -R 9001:localhost:3000 azureuser@<VM_PUBLIC_IP> sirtunnel.py api.tun.title.dev 9001


ssh: The command-line SSH client.
-t: Allocates a pseudo-terminal. This is essential for ensuring that pressing Ctrl+C locally correctly terminates the sirtunnel.py script on the remote server, allowing for cleanup.14 Without -t, Ctrl+C might only close the local SSH connection, leaving the Caddy route active.
-R <REMOTE_PORT>:<LOCAL_HOST>:<LOCAL_PORT>: Sets up SSH remote port forwarding. Traffic arriving at <REMOTE_PORT> on the remote VM (sirtunnel-vm) will be forwarded through the SSH tunnel to <LOCAL_HOST>:<LOCAL_PORT> on the local developer machine.
<VM_USER>@<VM_PUBLIC_IP>: Credentials to connect to the Azure VM.
sirtunnel.py <SUBDOMAIN>.tun.title.dev <REMOTE_PORT>: The command executed on the remote VM after the SSH connection is established. It passes the desired public subdomain and the corresponding remote port to the SirTunnel script.



Server-Side Action (Azure VM):

The SSH daemon on the VM receives the connection and executes /usr/local/bin/sirtunnel.py api.tun.title.dev 9001.
sirtunnel.py connects to the Caddy Admin API at http://localhost:2019.14
It crafts a JSON payload representing a new route configuration for Caddy. This route matches the host api.tun.title.dev and defines a reverse proxy handler pointing to localhost:9001 (the <REMOTE_PORT> specified in the command).14
The script sends this payload via an HTTP POST request to the Caddy API endpoint (e.g., /config/apps/http/servers/srv0/routes).15
Caddy receives the API request, validates the JSON, and dynamically adds the new route to its active configuration without downtime.
If Caddy doesn't already have a valid certificate for *.tun.title.dev, it initiates the ACME DNS challenge process described earlier.



Accessing the Service:

External clients or services can now make HTTPS requests to https://api.tun.title.dev.
The traffic flow is: Client -> Internet -> Azure Static IP:443 -> sirtunnel-vm NIC -> Caddy (TLS Termination) -> Caddy Route Match (api.tun.title.dev) -> Reverse Proxy to localhost:9001 (on sirtunnel-vm) -> SSH Tunnel -> Developer Laptop localhost:3000.



Tear-down:

On the developer laptop, press Ctrl+C in the terminal where the ssh command is running.
The -t flag ensures the interrupt signal (SIGINT) is sent through the SSH connection to the sirtunnel.py process on the VM.14
The sirtunnel.py script (assuming it includes signal handling, which is present in the original script) catches the signal.
Before exiting, the script makes a final API call (HTTP DELETE) to Caddy's Admin API to remove the route configuration associated with api.tun.title.dev and port 9001.15
The SSH connection closes. The tunnel is now inactive, and requests to https://api.tun.title.dev will no longer be proxied by Caddy (likely resulting in a Caddy default response or error, depending on configuration).


8. Operational ConsiderationsMaintaining a self-hosted solution requires attention to several operational aspects.
Wildcard DNS and Caddy Interaction: The *.tun.title.dev A record directs all traffic for any subdomain under .tun.title.dev to the single static IP of the VM.16 Caddy inspects the Host header of incoming HTTPS requests to determine which subdomain is being accessed. It uses this information to match the dynamically configured routes added by sirtunnel.py and to serve the correct content using the single, shared wildcard TLS certificate (*.tun.title.dev) obtained via the ACME DNS challenge.12
Bicep Dependency Validation: Bicep's declarative nature allows it to automatically infer dependencies between resources in most cases. For instance, it understands that the networkInterface depends on the virtualNetwork, subnet, networkSecurityGroup, and the referenced staticPip. Similarly, the virtualMachine depends on the networkInterface. Explicit dependsOn clauses are generally unnecessary unless dealing with complex scenarios or implicit dependencies that Bicep cannot detect 37, which is not the case in this straightforward deployment. The Role Assignment implicitly depends on the VM (for its principalId) and the DNS Zone (for the scope). The VM Extension depends on the VM.
Ephemeral VM Rotation: The use of an externally managed Static Public IP significantly simplifies VM rotation (e.g., for OS updates, resizing, or replacing a compromised instance).

Delete Stack: Run az stack group delete --name sirtunnel-stack --resource-group sirtunnel-rg --action-on-unmanage deleteResources --yes. This removes the VM, NIC, VNet, Subnet, NSG, Role Assignment, and Extension. The externally managed Static IP and the DNS Zone remain untouched.
Recreate Stack: Re-run the az stack group create... command from section 6. This provisions a completely new set of VM infrastructure (VNet, Subnet, NIC, VM, NSG, Role Assignment, Extension) and automatically associates the new NIC with the same existing Static Public IP address referenced in the parameters. The wildcard DNS record (*.tun.title.dev) continues to point to this IP, ensuring seamless service restoration once the new VM is provisioned and Caddy is configured by the extension. This approach provides a clean and predictable way to manage the ephemeral compute layer while maintaining endpoint persistence.


SirTunnel Script Robustness: The original sirtunnel.py script 14 is intentionally minimal. For production or team use, consider:

Stale Route Cleanup: The base script relies on clean termination (Ctrl+C) to remove Caddy routes. If the SSH connection drops unexpectedly or the script crashes, routes might be left orphaned in the Caddy configuration. Forks exist that implement periodic checks and cleanup of stale tunnels.14
Error Handling: Enhance error handling for Caddy API interactions (e.g., retries if the API is temporarily unavailable during script startup or shutdown).
Multi-User Conflicts: The base script doesn't prevent multiple users from trying to claim the same subdomain simultaneously. Forks addressing multi-user coordination might be necessary in shared environments.14


Security Hardening:

OS Patching: Configure unattended-upgrades on the Ubuntu VM for automatic security patches.
Minimal Exposure: The NSG rules defined in Bicep limit inbound traffic strictly to SSH (port 22) and HTTPS (port 443). Verify no additional ports are inadvertently opened.
Caddy Admin API: Double-check Caddy's configuration (admin.listen in JSON or admin directive in Caddyfile) ensures the API remains bound to localhost:2019.15
Monitoring: Regularly monitor Caddy logs (sudo journalctl -u caddy --no-pager) and system logs for errors or suspicious activity. Consider integrating with Azure Monitor.
SSH Security: Use strong SSH keys, potentially restrict source IPs for SSH in the NSG if feasible, and consider tools like fail2ban.


Let's Encrypt Rate Limits: Let's Encrypt imposes rate limits on certificate issuance to prevent abuse.40 During development and testing, frequently creating and destroying the environment or tunnels could hit these limits (e.g., Duplicate Certificate limit, Certificates per Registered Domain limit). Use the Let's Encrypt staging environment (https://acme-staging-v02.api.letsencrypt.org/directory) for testing by configuring it in Caddy's ACME issuer settings to avoid consuming production quotas.
Cost: The primary ongoing costs are associated with the Standard_B1s VM compute hours, the Standard SKU static public IP address, egress bandwidth, and Azure DNS queries. This configuration is designed to be cost-effective for development and low-traffic scenarios.
Scalability & Availability: This architecture uses a single VM and is not inherently highly available or scalable. It is suitable for individual developers or small teams exposing development services. For production workloads requiring high availability, a more complex setup involving load balancers, multiple VMs, and potentially different tunneling solutions would be necessary.
9. ConclusionThis report outlines a robust and automated solution for deploying SirTunnel on Azure, providing a self-hosted, persistent, and secure alternative to commercial tunneling services. By leveraging Azure Bicep, Deployment Stacks, Managed Identities, and Caddy's automation capabilities, the architecture achieves:
Persistence: A static public IP, managed externally to the main deployment stack, ensures a stable endpoint address across VM lifecycles. Wildcard DNS points consistently to this IP.
Automation: Bicep defines the infrastructure declaratively, and a custom script automates the setup of Caddy and SirTunnel on the VM. Caddy handles TLS certificate acquisition and renewal automatically using Managed Identity for secure Azure DNS interaction.
Security: HTTPS is enforced by default. Managed Identity eliminates the need to store Azure credentials on the VM for DNS updates. The Caddy Admin API is restricted to localhost access. SSH public key authentication is used for VM access.
Control & Cost-Effectiveness: Provides full control over the tunneling infrastructure using cost-effective Azure resources (B1s VM, Standard IP).
Clean Lifecycle Management: Deployment Stacks enable atomic deployment and simplified teardown of ephemeral components (VM, NIC, VNet) while preserving the essential external resources (Static IP, DNS Zone).
While offering significant advantages in control and persistence, this self-hosted solution carries inherent operational responsibilities, including VM patching, monitoring, and potentially adapting the SirTunnel script for enhanced robustness or multi-user support using available forks.14 The provided Bicep templates and scripts offer a solid foundation for operationalizing SirTunnel securely and efficiently on Azure.