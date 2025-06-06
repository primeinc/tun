// Module for DNS Zone Role Assignment
// This module handles assigning DNS Zone Contributor role to the VM's managed identity

@description('Principal ID of the VM managed identity')
param principalId string

@description('DNS Zone resource ID')
param dnsZoneId string

// Built-in DNS Zone Contributor Role ID
var dnsZoneContributorRoleId = 'befefa01-2a29-4197-83a8-272ff33ce314'

// Role Assignment for Managed Identity
resource assignDnsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dnsZoneId, principalId, dnsZoneContributorRoleId)
  scope: resourceGroup() // This module is deployed at the DNS zone's resource group scope
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dnsZoneContributorRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
