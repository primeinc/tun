# PowerShell deployment script for SirTunnel Azure infrastructure

# Source configuration variables
$configFile = Join-Path $PSScriptRoot "config.ps1"
if (Test-Path $configFile) {
    . $configFile
} else {
    Write-Error "Configuration file not found at $configFile. Please create it based on config.sample.ps1."
    exit 1
}

# Check if required variables are set
$requiredVars = @('LOCATION', 'VM_RG_NAME', 'ADMIN_USER', 'SSH_PUB_KEY_PATH', 
                 'DNS_ZONE_NAME', 'DNS_ZONE_RG', 'STATIC_PIP_NAME', 'STATIC_PIP_RG', 'STACK_NAME', 'GITHUB_REPO')

foreach ($var in $requiredVars) {
    if (-not (Get-Variable -Name $var -ErrorAction SilentlyContinue)) {
        Write-Error "Required variable $var is not set in $configFile"
        exit 1
    }
}

# Ensure resource group exists
Write-Host "Ensuring resource group exists: $VM_RG_NAME..."
az group create --name $VM_RG_NAME --location $LOCATION

# Read SSH Public Key
if (Test-Path $SSH_PUB_KEY_PATH) {
    $SSH_PUB_KEY = Get-Content $SSH_PUB_KEY_PATH -Raw
    if ([string]::IsNullOrEmpty($SSH_PUB_KEY)) {
        Write-Error "SSH public key file is empty: $SSH_PUB_KEY_PATH"
        exit 1
    }
} else {
    Write-Error "SSH public key file not found: $SSH_PUB_KEY_PATH"
    exit 1
}

# Create/Update the Deployment Stack
Write-Host "Deploying/Updating Deployment Stack: $STACK_NAME in resource group $VM_RG_NAME..."

$templateFile = Join-Path $PSScriptRoot "..\infra\main.bicep"

# Deploy the stack
az stack group create `
    --name $STACK_NAME `
    --resource-group $VM_RG_NAME `
    --template-file $templateFile `
    --parameters `
        location=$LOCATION `
        adminUsername=$ADMIN_USER `
        "adminPublicKey=$SSH_PUB_KEY" `
        dnsZoneName=$DNS_ZONE_NAME `
        dnsZoneResourceGroupName=$DNS_ZONE_RG `
        staticPipName=$STATIC_PIP_NAME `
        staticPipResourceGroupName=$STATIC_PIP_RG `
        githubRepo=$GITHUB_REPO `
    --action-on-unmanage deleteResources `
    --deny-settings-mode none

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed."
    exit 1
}

# Get deployment outputs
$outputs = az stack group show --name $STACK_NAME --resource-group $VM_RG_NAME --query "outputs" | ConvertFrom-Json

# Display useful information
Write-Host "`nDeployment completed successfully!`n" -ForegroundColor Green
Write-Host "Public IP Address: $($outputs.publicIPAddress.value)"
Write-Host "VM Admin Username: $($outputs.vmAdminUsername.value)"
Write-Host "SSH Command: $($outputs.sshCommand.value)"
Write-Host "Sample Tunnel Endpoint: $($outputs.sampleTunnelEndpoint.value)"
Write-Host "`nExample SirTunnel command:"
Write-Host "ssh -t -R 9001:localhost:3000 $($outputs.vmAdminUsername.value)@$($outputs.publicIPAddress.value) sirtunnel.py api.tun.$DNS_ZONE_NAME 9001" -ForegroundColor Yellow
