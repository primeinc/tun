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
      vmSize: vmSize
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
      fileUris: [
        'https://raw.githubusercontent.com/${githubRepo}/main/scripts/install.sh'
      ]
      commandToExecute: 'bash install.sh ${subscription().subscriptionId} ${dnsZoneResourceGroupName}'
    }
  }
}

// GitHub repository variable for install script URL
var githubRepo = 'YOUR_USERNAME/YOUR_REPO'  // REPLACE with your actual GitHub username/repo

// --- Outputs ---
output publicIPAddress string = staticPip.properties.ipAddress
output vmAdminUsername string = adminUsername
output sshCommand string = 'ssh ${adminUsername}@${staticPip.properties.ipAddress}'
output sampleTunnelEndpoint string = 'https://example.tun.${dnsZoneName}'
