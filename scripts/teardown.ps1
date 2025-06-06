# PowerShell script for tearing down SirTunnel Azure infrastructure

# Source configuration variables
$configFile = Join-Path $PSScriptRoot "config.ps1"
if (Test-Path $configFile) {
    . $configFile
} else {
    Write-Error "Configuration file not found at $configFile. Please create it based on config.sample.ps1."
    exit 1
}

# Check if required variables are set
if (-not $VM_RG_NAME -or -not $STACK_NAME) {
    Write-Error "Required variables VM_RG_NAME and STACK_NAME must be set in $configFile"
    exit 1
}

Write-Host "WARNING: This will delete Deployment Stack: $STACK_NAME and its managed resources..." -ForegroundColor Red
Write-Host "The external Static IP and DNS Zone will remain untouched." -ForegroundColor Yellow
Write-Host ""

$confirmation = Read-Host "Are you sure you want to proceed? (y/N)"
if ($confirmation -ne "y" -and $confirmation -ne "Y") {
    Write-Host "Operation cancelled."
    exit 0
}

# Delete the stack
Write-Host "Deleting Deployment Stack: $STACK_NAME from resource group $VM_RG_NAME..."

az stack group delete `
    --name $STACK_NAME `
    --resource-group $VM_RG_NAME `
    --action-on-unmanage deleteResources `
    --yes

if ($LASTEXITCODE -ne 0) {
    Write-Error "Stack deletion failed."
    exit 1
}

Write-Host "Stack and managed resources deleted. External Static IP and DNS Zone remain." -ForegroundColor Green
