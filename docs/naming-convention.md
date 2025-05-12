# Azure Resource Naming Conventions

This document outlines the standard naming conventions for Azure resources used in our environment. Following these conventions ensures consistency, improves resource organization, and enhances manageability across our Azure infrastructure.

## General Naming Pattern

Resources follow this general pattern:
```
<resource-type-prefix>-<workload>-<context>-<environment>
```

Where:
- **resource-type-prefix**: Short code indicating the Azure resource type (e.g., vm, pip, nsg)
- **workload**: Identifier for the application, service, or workload (e.g., sirtunnel)
- **context**: Optional additional context about the resource (can be omitted for simplicity)
- **environment**: Deployment environment (e.g., dev, test, prod)

## Resource Group Naming

Resource groups use a consistent naming pattern:
```
rg-<domain>-<subscope>-<env>
```

Where:
- **rg**: Standard prefix for resource groups
- **domain**: Functional domain (e.g., app, network, data)
- **subscope**: Specific workload or purpose (e.g., sirtunnel, core, dns)
- **env**: Environment identifier (e.g., dev, test, prod, shared)

## Resource Type Prefixes

| Resource Type | Prefix | Example |
|---------------|--------|---------|
| Resource Group | rg | rg-app-sirtunnel-dev |
| Virtual Machine | vm | vm-sirtunnel-dev |
| Public IP Address | pip | pip-tun-title-dev |
| Network Interface | nic | nic-sirtunnel-dev |
| Virtual Network | vnet | vnet-core-dev |
| Network Security Group | nsg | nsg-sirtunnel-dev |
| Storage Account | st | stsirlogs001dev |
| Key Vault | kv | kv-sirtunnel-dev |
| DNS Zone | dns | dns-title-dev |

## Lifecycle Boundaries

Resources are grouped in resource groups based on their lifecycle:

- **Shared Infrastructure Resources**: Resources that persist across multiple deployments and are shared
  - Example: `rg-network-dns-shared` for DNS zones and records
  - Example: `rg-network-core-dev` for networking components in dev environment

- **Application-Specific Resources**: Resources dedicated to a specific application with the same lifecycle
  - Example: `rg-app-sirtunnel-dev` for all SirTunnel components (VMs, NICs, etc.)

## SirTunnel-Specific Naming

### Infrastructure Components

- **Resource Group**: `rg-app-sirtunnel-dev`
- **Virtual Machine**: `vm-sirtunnel-dev`
- **Network Interface**: `nic-sirtunnel-dev`
- **OS Disk**: `osdisk-sirtunnel-dev`

### Persistent Network Resources

- **Public IP Address**: `pip-tun-title-dev`
- **DNS Records**: Managed in the appropriate DNS zone resource group (`rg-network-dns-shared`)

## Best Practices

1. **Consistency**: Use conventions consistently across all deployments
2. **Lowercase**: Use lowercase for all resource names
3. **No Special Characters**: Avoid using special characters, except hyphens
4. **Length Limitations**: Be aware of Azure naming length restrictions for various resources
5. **Searchability**: Names should support easy searching and filtering in the Azure portal
6. **Descriptive**: Names should identify the resource type, purpose, and environment at a glance
