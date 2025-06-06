// --- main.bicep ---
@description('Azure region for deployment.')
param location string = resourceGroup().location

@description('Username for the Virtual Machine.')
param adminUsername string

@description('SSH Public Key for the Virtual Machine.')
@secure()
param adminPublicKey string

@description('Environment (dev, test, prod).')
param environment string = 'dev'

@description('GitHub repository in the format owner/repo for sourcing the install.sh script. Example: "yourusername/yourrepository"')
param githubRepo string

@description('Name of the Virtual Machine.')
param vmName string = 'vm-sirtunnel-${environment}'

@description('Size for the Virtual Machine.')
param vmSize string = 'Standard_B1s'

@description('Name of the Virtual Network.')
param vnetName string = 'vnet-sirtunnel-${environment}'

@description('Name of the Subnet.')
param subnetName string = 'snet-sirtunnel-${environment}'

@description('Name of the existing Azure DNS Zone (e.g., title.dev).')
param dnsZoneName string

@description('Resource Group name where the existing Azure DNS Zone resides.')
param dnsZoneResourceGroupName string

@description('Name of the existing Static Public IP Address resource.')
param staticPipName string

@description('Resource Group name where the existing Static Public IP Address resides.')
param staticPipResourceGroupName string

var networkInterfaceName = 'nic-sirtunnel-${environment}'
var networkSecurityGroupName = 'nsg-sirtunnel-${environment}'
var osDiskName = 'osdisk-sirtunnel-${environment}'

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
    securityRules: [
      {
        name: 'SSH'
        properties: {
          priority: 1000
          access: 'Allow'
          direction: 'Inbound'
          destinationPortRange: '22'
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'HTTPS'
        properties: {
          priority: 1001
          access: 'Allow'
          direction: 'Inbound'
          destinationPortRange: '443'
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: networkInterfaceName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnet.id
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: staticPip.id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: networkSecurityGroup.id
    }
  }
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
      // Use a larger SKU for faster provisioning during debug
      vmSize: vmSize
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
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
        name: osDiskName
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

// --- Role Assignment for Managed Identity (via module) ---
module dnsRoleAssignment 'modules/dns-role-assignment.bicep' = {
  name: 'dnsRoleAssignment'
  scope: resourceGroup(dnsZoneResourceGroupName)
  params: {
    principalId: virtualMachine.identity.principalId
    dnsZoneId: dnsZone.id
  }
}

// --- VM Extension for Setup ---
// VM Extension for Setup intentionally removed from Bicep critical path.
// The CustomScript extension is applied post-provision via the redeploy-extension.ps1 script 
// which is automatically called by deploy.ps1 after a successful deployment.
// This two-step approach allows for more flexibility and better error recovery.
// Reference implementation kept below for documentation:
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
        'https://raw.githubusercontent.com/${githubRepo}/main/scripts/install.sh'
        'https://raw.githubusercontent.com/${githubRepo}/main/scripts/run_server.sh'
        'https://raw.githubusercontent.com/${githubRepo}/main/scripts/caddy_config.json'
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

// --- Outputs ---
output publicIPAddress string = staticPip.properties.ipAddress
output vmAdminUsername string = adminUsername
output sshCommand string = 'ssh ${adminUsername}@${staticPip.properties.ipAddress}'
output sampleTunnelEndpoint string = 'https://example.tun.${dnsZoneName}'
