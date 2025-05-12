# PowerShell script to create or update the wildcard DNS record for SirTunnel

# Source configuration variables
$configFile = Join-Path $PSScriptRoot "config.ps1"
if (Test-Path $configFile) {
    . $configFile
} else {
    Write-Error "Configuration file not found at $configFile. Please create it based on config.sample.ps1."
    exit 1
}

# Check if required variables are set
if (-not $DNS_ZONE_NAME -or -not $DNS_ZONE_RG -or -not $STATIC_PIP_NAME -or -not $STATIC_PIP_RG) {
    Write-Error "DNS_ZONE_NAME, DNS_ZONE_RG, STATIC_PIP_NAME, and STATIC_PIP_RG must be set in $configFile"
    exit 1
}

# Get the static IP address
try {
    $ip = az network public-ip show --name $STATIC_PIP_NAME --resource-group $STATIC_PIP_RG --query "ipAddress" --output tsv
    if (-not $ip) {
        Write-Error "Could not retrieve IP address from $STATIC_PIP_NAME"
        exit 1
    }
    Write-Host "Retrieved static IP address: $ip" -ForegroundColor Green
} catch {
    Write-Error "Failed to get static IP address: $_"
    exit 1
}

# Check if the DNS zone exists
try {
    $dnsZone = az network dns zone show --name $DNS_ZONE_NAME --resource-group $DNS_ZONE_RG --query "name" --output tsv
    Write-Host "Found DNS zone: $dnsZone" -ForegroundColor Green
} catch {
    Write-Error "DNS zone $DNS_ZONE_NAME not found in resource group $DNS_ZONE_RG"
    exit 1
}

# Check if the wildcard record already exists
$recordExists = $false
try {
    $record = az network dns record-set a show --name "*.tun" --zone-name $DNS_ZONE_NAME --resource-group $DNS_ZONE_RG 2>$null
    if ($record) {
        $recordExists = $true
        $recordIp = az network dns record-set a show --name "*.tun" --zone-name $DNS_ZONE_NAME --resource-group $DNS_ZONE_RG --query "aRecords[0].ipv4Address" --output tsv
        Write-Host "Existing wildcard record found: *.tun.$DNS_ZONE_NAME -> $recordIp" -ForegroundColor Yellow
    }
} catch {}

if ($recordExists) {
    # Update the record if it doesn't match our IP
    if ($recordIp -ne $ip) {
        Write-Host "Updating DNS record to point to the correct IP address..." -ForegroundColor Cyan
        
        # Remove the existing record
        az network dns record-set a remove-record `
            --resource-group $DNS_ZONE_RG `
            --zone-name $DNS_ZONE_NAME `
            --record-set-name "*.tun" `
            --ipv4-address $recordIp
        
        # Add the new record
        az network dns record-set a add-record `
            --resource-group $DNS_ZONE_RG `
            --zone-name $DNS_ZONE_NAME `
            --record-set-name "*.tun" `
            --ipv4-address $ip `
            --ttl 3600
        
        Write-Host "Updated DNS record: *.tun.$DNS_ZONE_NAME now points to $ip" -ForegroundColor Green
    } else {
        Write-Host "DNS record is already correctly configured" -ForegroundColor Green
    }
} else {
    # Create a new record
    Write-Host "Creating new wildcard DNS record..." -ForegroundColor Cyan
    
    az network dns record-set a create `
        --resource-group $DNS_ZONE_RG `
        --zone-name $DNS_ZONE_NAME `
        --name "*.tun" `
        --ttl 3600
    
    az network dns record-set a add-record `
        --resource-group $DNS_ZONE_RG `
        --zone-name $DNS_ZONE_NAME `
        --record-set-name "*.tun" `
        --ipv4-address $ip
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Created DNS record: *.tun.$DNS_ZONE_NAME -> $ip" -ForegroundColor Green
    } else {
        Write-Error "Failed to create DNS record"
        exit 1
    }
}

# Remind about DNS propagation
Write-Host "`nDNS record created/updated successfully!" -ForegroundColor Green
Write-Host "Note: DNS changes may take some time to propagate (typically 5-30 minutes)" -ForegroundColor Yellow

# Show example validation command
Write-Host "`nTo verify DNS propagation, use:" -ForegroundColor Cyan
Write-Host "Resolve-DnsName -Name api.tun.$DNS_ZONE_NAME -Type A" -ForegroundColor Yellow

# Next steps
Write-Host "`nNext Steps:" -ForegroundColor Cyan
Write-Host "1. Run the deployment script to create the SirTunnel infrastructure:" -ForegroundColor Yellow
Write-Host "   .\scripts\deploy.ps1" -ForegroundColor Yellow
