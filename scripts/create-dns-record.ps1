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
        
        # Check if ARecords array exists and is not empty
        $recordJson = $record | ConvertFrom-Json
        $existingIps = @()
        
        if ($recordJson.ARecords -and $recordJson.ARecords.Count -gt 0) {
            # Extract IP addresses from ARecords array
            $existingIps = $recordJson.ARecords | ForEach-Object { $_.ipv4Address }
        }
        
        $ipList = $existingIps -join ", "
        Write-Host "Existing wildcard record found: *.tun.$DNS_ZONE_NAME -> $ipList" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Error checking for existing wildcard record: $_" -ForegroundColor Red
}

if ($recordExists) {
    # Check if our target IP is already in the list
    $ipExists = $existingIps -contains $ip
    # Create a list of IPs that need to be removed (all IPs except our target IP)
    $ipsToRemove = @($existingIps | Where-Object { $_ -ne $ip })
    
    if ($ipsToRemove.Count -gt 0 -or -not $ipExists) {
        Write-Host "Updating DNS record to ensure only the correct IP address is present..." -ForegroundColor Cyan
        
        # Remove any stale IPs
        foreach ($oldIp in $ipsToRemove) {
            Write-Host "Removing stale IP: $oldIp" -ForegroundColor Yellow
            az network dns record-set a remove-record `
                --resource-group $DNS_ZONE_RG `
                --zone-name $DNS_ZONE_NAME `
                --record-set-name "*.tun" `
                --ipv4-address $oldIp | Out-Null
        }
        
        # Add our IP if it's not already there
        if (-not $ipExists) {
            Write-Host "Adding current IP: $ip" -ForegroundColor Yellow
            az network dns record-set a add-record `
                --resource-group $DNS_ZONE_RG `
                --zone-name $DNS_ZONE_NAME `
                --record-set-name "*.tun" `
                --ipv4-address $ip `
                --ttl 60 | Out-Null
        }
        
        Write-Host "Updated DNS record: *.tun.$DNS_ZONE_NAME now points to $ip" -ForegroundColor Green
    } else {
        Write-Host "DNS record is already correctly configured with only the target IP" -ForegroundColor Green
    }
}else {
    # Create a new record
    Write-Host "Creating new wildcard DNS record..." -ForegroundColor Cyan
    
    az network dns record-set a create `
        --resource-group $DNS_ZONE_RG `
        --zone-name $DNS_ZONE_NAME `
        --name "*.tun" `
        --ttl 60
    
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

# Check if the root tun record exists
$rootRecordExists = $false
try {
    $rootRecord = az network dns record-set a show --name "tun" --zone-name $DNS_ZONE_NAME --resource-group $DNS_ZONE_RG 2>$null
    if ($rootRecord) {
        $rootRecordExists = $true
        
        # Check if ARecords array exists and is not empty
        $rootRecordJson = $rootRecord | ConvertFrom-Json
        $rootExistingIps = @()
        
        if ($rootRecordJson.ARecords -and $rootRecordJson.ARecords.Count -gt 0) {
            # Extract IP addresses from ARecords array
            $rootExistingIps = $rootRecordJson.ARecords | ForEach-Object { $_.ipv4Address }
        }
        
        $rootIpList = $rootExistingIps -join ", "
        Write-Host "Existing root record found: tun.$DNS_ZONE_NAME -> $rootIpList" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Error checking for existing root record: $_" -ForegroundColor Red
}

if ($rootRecordExists) {
    # Check if our target IP is already in the list
    $rootIpExists = $rootExistingIps -contains $ip
    # Create a list of IPs that need to be removed (all IPs except our target IP)
    $rootIpsToRemove = @($rootExistingIps | Where-Object { $_ -ne $ip })
    
    if ($rootIpsToRemove.Count -gt 0 -or -not $rootIpExists) {
        Write-Host "Updating root DNS record to ensure only the correct IP address is present..." -ForegroundColor Cyan
        
        # Remove any stale IPs
        foreach ($oldIp in $rootIpsToRemove) {
            Write-Host "Removing stale IP from root record: $oldIp" -ForegroundColor Yellow
            az network dns record-set a remove-record `
                --resource-group $DNS_ZONE_RG `
                --zone-name $DNS_ZONE_NAME `
                --record-set-name "tun" `
                --ipv4-address $oldIp | Out-Null
        }
        
        # Add our IP if it's not already there
        if (-not $rootIpExists) {
            Write-Host "Adding current IP to root record: $ip" -ForegroundColor Yellow
            az network dns record-set a add-record `
                --resource-group $DNS_ZONE_RG `
                --zone-name $DNS_ZONE_NAME `
                --record-set-name "tun" `
                --ipv4-address $ip `
                --ttl 60 | Out-Null
        }
        
        Write-Host "Updated root DNS record: tun.$DNS_ZONE_NAME now points to $ip" -ForegroundColor Green
    } else {
        Write-Host "Root DNS record is already correctly configured with only the target IP" -ForegroundColor Green
    }
} else {    # Create a new root record
    Write-Host "Creating new root DNS record..." -ForegroundColor Cyan
    
    az network dns record-set a create `
        --resource-group $DNS_ZONE_RG `
        --zone-name $DNS_ZONE_NAME `
        --name "tun" `
        --ttl 60
    
    az network dns record-set a add-record `
        --resource-group $DNS_ZONE_RG `
        --zone-name $DNS_ZONE_NAME `
        --record-set-name "tun" `
        --ipv4-address $ip `
        --ttl 60
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Created root DNS record: tun.$DNS_ZONE_NAME -> $ip" -ForegroundColor Green
    } else {
        Write-Error "Failed to create root DNS record"
        exit 1
    }
}

# Remind about DNS propagation
Write-Host "`nDNS records created/updated successfully!" -ForegroundColor Green
Write-Host "Note: DNS changes may take some time to propagate (typically 5-30 minutes)" -ForegroundColor Yellow

# Show example validation commands
Write-Host "`nTo verify DNS propagation, use:" -ForegroundColor Cyan
Write-Host "Resolve-DnsName -Name api.tun.$DNS_ZONE_NAME -Type A" -ForegroundColor Yellow
Write-Host "Resolve-DnsName -Name tun.$DNS_ZONE_NAME -Type A" -ForegroundColor Yellow

# Next steps
Write-Host "`nNext Steps:" -ForegroundColor Cyan
Write-Host "1. Run the deployment script to create the SirTunnel infrastructure:" -ForegroundColor Yellow
Write-Host "   .\scripts\deploy.ps1" -ForegroundColor Yellow
