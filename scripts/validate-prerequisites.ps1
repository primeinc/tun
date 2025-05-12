# PowerShell script to validate SirTunnel prerequisites
# This ensures all requirements are met before attempting deployment

# Source configuration variables
$configFile = Join-Path $PSScriptRoot "config.ps1"
if (Test-Path $configFile) {
    . $configFile
} else {
    Write-Error "Configuration file not found at $configFile. Please create it based on config.sample.ps1."
    exit 1
}

Write-Host "Validating SirTunnel prerequisites..." -ForegroundColor Cyan

# Check Azure CLI installation
try {
    $azVersion = az --version | Select-Object -First 1
    Write-Host "✓ Azure CLI is installed: $azVersion" -ForegroundColor Green
} catch {
    Write-Host "✗ Azure CLI is not installed or not in PATH" -ForegroundColor Red
    Write-Host "  Please install Azure CLI: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli" -ForegroundColor Yellow
    exit 1
}

# Check Azure CLI login status
$account = $null
try {
    $account = az account show | ConvertFrom-Json
    Write-Host "✓ Logged into Azure as: $($account.user.name) (Subscription: $($account.name))" -ForegroundColor Green
} catch {
    Write-Host "✗ Not logged into Azure CLI" -ForegroundColor Red
    Write-Host "  Please login using: az login" -ForegroundColor Yellow
    exit 1
}

# Check SSH key existence
if (Test-Path $SSH_PUB_KEY_PATH) {
    $keyContent = Get-Content $SSH_PUB_KEY_PATH -Raw
    if (-not [string]::IsNullOrWhiteSpace($keyContent)) {
        Write-Host "✓ SSH public key found at: $SSH_PUB_KEY_PATH" -ForegroundColor Green
    } else {
        Write-Host "✗ SSH public key file exists but is empty: $SSH_PUB_KEY_PATH" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "✗ SSH public key not found at: $SSH_PUB_KEY_PATH" -ForegroundColor Red
    Write-Host "  Generate an SSH key using: ssh-keygen -t rsa -b 4096" -ForegroundColor Yellow
    exit 1
}

# Check if static public IP exists
try {
    $pip = az network public-ip show --name $STATIC_PIP_NAME --resource-group $STATIC_PIP_RG | ConvertFrom-Json
    Write-Host "✓ Static Public IP found: $STATIC_PIP_NAME (IP: $($pip.ipAddress))" -ForegroundColor Green
    
    # Check if it's Standard SKU
    if ($pip.sku.name -ne "Standard") {
        Write-Host "✗ Public IP is not Standard SKU. Current: $($pip.sku.name)" -ForegroundColor Red
        Write-Host "  Standard SKU is required for this deployment." -ForegroundColor Yellow
        exit 1
    }
} catch {
    Write-Host "✗ Static Public IP not found: $STATIC_PIP_NAME in resource group $STATIC_PIP_RG" -ForegroundColor Red
    Write-Host "  Please create a Standard SKU static Public IP before proceeding." -ForegroundColor Yellow
    Write-Host "  Example command:" -ForegroundColor Yellow
    Write-Host "  az network public-ip create --name $STATIC_PIP_NAME --resource-group $STATIC_PIP_RG --sku Standard --allocation-method Static" -ForegroundColor Yellow
    exit 1
}

# Check if DNS Zone exists
try {
    $dnsZoneExists = az network dns zone show --name $DNS_ZONE_NAME --resource-group $DNS_ZONE_RG | ConvertFrom-Json
    Write-Host "✓ DNS Zone found: $DNS_ZONE_NAME" -ForegroundColor Green
    
    # Check if the wildcard record already exists
    try {
        $record = az network dns record-set a show --name "*.tun" --zone-name $DNS_ZONE_NAME --resource-group $DNS_ZONE_RG | ConvertFrom-Json
        Write-Host "✓ Wildcard DNS record found: *.tun.$DNS_ZONE_NAME (Points to: $($record.aRecords[0].ipv4Address))" -ForegroundColor Green
        
        # Check if it points to the correct IP
        if ($record.aRecords[0].ipv4Address -ne $pip.ipAddress) {
            Write-Host "⚠ Wildcard DNS record points to $($record.aRecords[0].ipv4Address), but static IP is $($pip.ipAddress)" -ForegroundColor Yellow
            Write-Host "  Consider updating the DNS record to match your static IP." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "⚠ Wildcard DNS record not found: *.tun.$DNS_ZONE_NAME" -ForegroundColor Yellow
        Write-Host "  After deployment, create this record with:" -ForegroundColor Yellow
        Write-Host "  az network dns record-set a add-record --resource-group $DNS_ZONE_RG --zone-name $DNS_ZONE_NAME --record-set-name '*.tun' --ipv4-address $($pip.ipAddress)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "✗ DNS Zone not found: $DNS_ZONE_NAME in resource group $DNS_ZONE_RG" -ForegroundColor Red
    Write-Host "  Please create the DNS Zone before proceeding." -ForegroundColor Yellow
    exit 1
}

# Check bicep installation
try {
    $bicepVersion = az bicep version | ConvertFrom-Json
    Write-Host "✓ Bicep is installed: $($bicepVersion.version)" -ForegroundColor Green
} catch {
    Write-Host "✗ Bicep is not installed or not up to date" -ForegroundColor Red
    Write-Host "  Install or update Bicep with: az bicep install" -ForegroundColor Yellow
    exit 1
}

# Final confirmation
Write-Host "`nAll prerequisites have been validated! You're ready to deploy." -ForegroundColor Green
Write-Host "Run the following command to deploy SirTunnel:" -ForegroundColor Cyan
Write-Host ".\scripts\deploy.ps1" -ForegroundColor Yellow
