# PowerShell script to create a static Public IP for SirTunnel

# Source configuration variables
$configFile = Join-Path $PSScriptRoot "config.ps1"
if (Test-Path $configFile) {
    . $configFile
} else {
    Write-Error "Configuration file not found at $configFile. Please create it based on config.sample.ps1."
    exit 1
}

# Check if variables are set
if (-not $STATIC_PIP_NAME -or -not $STATIC_PIP_RG) {
    Write-Error "STATIC_PIP_NAME and STATIC_PIP_RG must be set in $configFile"
    exit 1
}

# Check if the resource group exists, create if not
$rgExists = az group exists --name $STATIC_PIP_RG
if ($rgExists -ne "true") {
    Write-Host "Resource group $STATIC_PIP_RG does not exist. Creating..." -ForegroundColor Yellow
    az group create --name $STATIC_PIP_RG --location $LOCATION
}

# Check if the Public IP already exists
$pipExists = az network public-ip show --name $STATIC_PIP_NAME --resource-group $STATIC_PIP_RG --query "name" --output tsv 2>$null
if ($pipExists -eq $STATIC_PIP_NAME) {
    Write-Host "Static Public IP $STATIC_PIP_NAME already exists in resource group $STATIC_PIP_RG" -ForegroundColor Yellow
    
    # Check if it's Standard SKU
    $sku = az network public-ip show --name $STATIC_PIP_NAME --resource-group $STATIC_PIP_RG --query "sku.name" --output tsv
    if ($sku -ne "Standard") {
        Write-Error "Existing Public IP is $sku SKU, but Standard SKU is required. Please delete it or use a different name."
        exit 1
    }
    
    # Display IP information
    $ip = az network public-ip show --name $STATIC_PIP_NAME --resource-group $STATIC_PIP_RG --query "ipAddress" --output tsv
    Write-Host "IP Address: $ip" -ForegroundColor Green
} else {
    # Create the Static Public IP
    Write-Host "Creating new Static Public IP: $STATIC_PIP_NAME..." -ForegroundColor Cyan
    az network public-ip create `
        --name $STATIC_PIP_NAME `
        --resource-group $STATIC_PIP_RG `
        --location $LOCATION `
        --sku Standard `
        --allocation-method Static `
        --tags "Purpose=SirTunnel" "Environment=Shared" "CreatedBy=Script" "CreatedOn=$(Get-Date -Format "yyyy-MM-dd")"
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create Static Public IP"
        exit 1
    }
    
    # Display the created IP
    $ip = az network public-ip show --name $STATIC_PIP_NAME --resource-group $STATIC_PIP_RG --query "ipAddress" --output tsv
    Write-Host "Created Static Public IP: $ip" -ForegroundColor Green
}

# Recommend DNS record creation
Write-Host "`nNext Steps:" -ForegroundColor Cyan
Write-Host "1. Create a wildcard DNS record for your tunnels:" -ForegroundColor Yellow
Write-Host "   az network dns record-set a add-record --resource-group $DNS_ZONE_RG --zone-name $DNS_ZONE_NAME --record-set-name '*.tun' --ipv4-address $ip" -ForegroundColor Yellow
Write-Host "2. Run the deployment script to create the SirTunnel infrastructure:" -ForegroundColor Yellow
Write-Host "   .\scripts\deploy.ps1" -ForegroundColor Yellow
