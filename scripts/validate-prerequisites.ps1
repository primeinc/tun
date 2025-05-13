# Source configuration variables
$configFile = Join-Path $PSScriptRoot "config.ps1"
if (Test-Path $configFile) {
    . $configFile
} else {
    Write-Error "Configuration file not found at $configFile. Please create it based on config.sample.ps1."
    exit 1
}

# Track overall validation progress
$script:validationStep = 0
$script:totalValidationSteps = 6  # Total high-level validation steps

# Define function before use
function Update-ValidationProgress {
    param (
        [string]$Status,
        [int]$Step = -1
    )

    if ($Step -ge 0) {
        $script:validationStep = $Step
    } else {
        $script:validationStep++
    }

    if ($script:totalValidationSteps -eq 0) {
        $percentComplete = 0
    } else {
        $percentComplete = ($script:validationStep / $script:totalValidationSteps) * 100
    }

    Write-Progress -Id 0 -Activity "SirTunnel Validation" -Status $Status -PercentComplete $percentComplete
}

Write-Host "Validating SirTunnel prerequisites..." -ForegroundColor Cyan

# Start overall validation progress tracking
Update-ValidationProgress -Status "Starting validation..." -Step 0


# Check Azure CLI installation
Update-ValidationProgress -Status "Checking Azure CLI installation..."
try {
    $azVersion = az --version | Select-Object -First 1
    Write-Host "✓ Azure CLI is installed: $azVersion" -ForegroundColor Green
} catch {
    Write-Host "✗ Azure CLI is not installed or not in PATH" -ForegroundColor Red
    Write-Host "  Please install Azure CLI: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli" -ForegroundColor Yellow
    exit 1
}

# Configure Azure CLI to allow preview extensions if needed
Write-Host "Configuring Azure CLI extension settings..." -ForegroundColor Cyan
az config set extension.dynamic_install_allow_preview=true --only-show-errors
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors
Write-Host "✓ Azure CLI extension settings configured" -ForegroundColor Green

# Check Azure CLI login status
Update-ValidationProgress -Status "Checking Azure CLI authentication..."
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
Update-ValidationProgress -Status "Checking SSH key..."
if (Test-Path $SSH_PUB_KEY_PATH) {
    $keyContent = Get-Content $SSH_PUB_KEY_PATH -Raw
    if (-not [string]::IsNullOrWhiteSpace($keyContent)) {
        Write-Host "✓ SSH public key found at: $SSH_PUB_KEY_PATH" -ForegroundColor Green
    } else {
        Write-Host "✗ SSH public key file exists but is empty: $SSH_PUB_KEY_PATH" -ForegroundColor Red
        Write-Progress -Id 0 -Completed
        exit 1
    }
} else {
    Write-Host "✗ SSH public key not found at: $SSH_PUB_KEY_PATH" -ForegroundColor Red
    Write-Host "  Generate an SSH key using: ssh-keygen -t rsa -b 4096" -ForegroundColor Yellow
    Write-Progress -Id 0 -Completed
    exit 1
}

# Track overall validation progress
$script:validationStep = 0
$script:totalValidationSteps = 6  # Total high-level validation steps

function Update-ValidationProgress {
    param (
        [string]$Status,
        [int]$Step = -1
    )
    
    if ($Step -ge 0) {
        $script:validationStep = $Step
    } else {
        $script:validationStep++
    }
    
    $percentComplete = ($script:validationStep / $script:totalValidationSteps) * 100
    Write-Progress -Id 0 -Activity "SirTunnel Validation" -Status $Status -PercentComplete $percentComplete
}

# Function to get any resource that might be using a public IP
function Get-PublicIpUsage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PipId
    )

    $result = @{
        IsInUse      = $false
        ResourceName = $null
        ResourceType = $null
        ResourceId   = $null
    }

    $normalizedPipId = $PipId.ToLower()

    try {
        # Function to safely convert JSON and handle errors
        function ConvertFrom-JsonSafely {
            param([string]$JsonString, [string]$ResourceType)
            
            try {
                if ([string]::IsNullOrWhiteSpace($JsonString)) {
                    return @()
                }
                
                return $JsonString | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                Write-Host "⚠ Error parsing $ResourceType JSON: $($_.Exception.Message)" -ForegroundColor Yellow
                return @()
            }
        }
        Write-Progress -Id 1 -Activity "Public IP Usage Analysis" -Status "Getting resource groups..." -PercentComplete 0
        
        # Cache resource groups for later use
        $resourceGroups = ConvertFrom-JsonSafely -JsonString (az group list --only-show-errors) -ResourceType "Resource Group"
        
        Write-Progress -Id 1 -Activity "Public IP Usage Analysis" -Status "Checking Network Interfaces..." -PercentComplete 10
        
        # Check NICs
        $nics = ConvertFrom-JsonSafely -JsonString (az network nic list --only-show-errors) -ResourceType "Network Interface"
        $nicIndex = 0
        $totalNics = $nics.Count
        
        foreach ($nic in $nics) {
            $nicIndex++
            if ($totalNics -gt 10) {  # Only show detailed progress if we have many NICs
                Write-Progress -Id 2 -ParentId 1 -Activity "Checking NICs" -Status "Processing $($nic.name)" -PercentComplete (($nicIndex / $totalNics) * 100)
            }
            
            foreach ($ipConfig in $nic.ipConfigurations) {
                if ($ipConfig.publicIpAddress -and ($ipConfig.publicIpAddress.id.ToLower() -eq $normalizedPipId)) {
                    $result.IsInUse      = $true
                    $result.ResourceName = $nic.name
                    $result.ResourceType = "Network Interface"
                    $result.ResourceId   = $nic.id

                    if ($nic.virtualMachine -and $nic.virtualMachine.id) {
                        $vmId = $nic.virtualMachine.id
                        $vmName = ($vmId -split "/")[-1]
                        $result.ResourceName = $vmName
                        $result.ResourceType = "Virtual Machine"
                        $result.ResourceId   = $vmId
                    }
                    Write-Progress -Id 2 -Completed
                    return $result
                }
            }
        }
        Write-Progress -Id 2 -Completed

        Write-Progress -Id 1 -Activity "Public IP Usage Analysis" -Status "Checking Load Balancers..." -PercentComplete 20
        
        # Check Load Balancers
        $lbs = ConvertFrom-JsonSafely -JsonString (az network lb list --only-show-errors) -ResourceType "Load Balancer"
        $lbIndex = 0
        $totalLbs = $lbs.Count

        foreach ($lb in $lbs) {
            $lbIndex++
            if ($totalLbs -gt 5) {  # Only show progress for multiple resources
                Write-Progress -Id 2 -ParentId 1 -Activity "Checking Load Balancers" -Status "Processing $($lb.name)" -PercentComplete (($lbIndex / $totalLbs) * 100)
            }
            
            foreach ($config in $lb.frontendIpConfigurations) {
                if ($config.publicIpAddress -and ($config.publicIpAddress.id.ToLower() -eq $normalizedPipId)) {
                    $result.IsInUse      = $true
                    $result.ResourceName = $lb.name
                    $result.ResourceType = "Load Balancer"
                    $result.ResourceId   = $lb.id
                    Write-Progress -Id 2 -Completed
                    return $result
                }
            }
        }
        Write-Progress -Id 2 -Completed

        Write-Progress -Id 1 -Activity "Public IP Usage Analysis" -Status "Checking Application Gateways..." -PercentComplete 30
        
        # Check Application Gateways
        $agws = ConvertFrom-JsonSafely -JsonString (az network application-gateway list --only-show-errors) -ResourceType "Application Gateway"
        $agwIndex = 0
        $totalAgws = $agws.Count
        
        foreach ($agw in $agws) {
            $agwIndex++
            if ($totalAgws -gt 3) {
                Write-Progress -Id 2 -ParentId 1 -Activity "Checking Application Gateways" -Status "Processing $($agw.name)" -PercentComplete (($agwIndex / $totalAgws) * 100)
            }
            
            foreach ($config in $agw.frontendIPConfigurations) {
                if ($config.publicIPAddress -and ($config.publicIPAddress.id.ToLower() -eq $normalizedPipId)) {
                    $result.IsInUse      = $true
                    $result.ResourceName = $agw.name
                    $result.ResourceType = "Application Gateway"
                    $result.ResourceId   = $agw.id
                    Write-Progress -Id 2 -Completed
                    return $result
                }
            }
        }
        Write-Progress -Id 2 -Completed

        Write-Progress -Id 1 -Activity "Public IP Usage Analysis" -Status "Checking NAT Gateways..." -PercentComplete 40
        
        # Check NAT Gateways
        $nats = ConvertFrom-JsonSafely -JsonString (az network nat gateway list --only-show-errors) -ResourceType "NAT Gateway"
        $natIndex = 0
        $totalNats = $nats.Count
        
        foreach ($nat in $nats) {
            $natIndex++
            if ($totalNats -gt 3) {
                Write-Progress -Id 2 -ParentId 1 -Activity "Checking NAT Gateways" -Status "Processing $($nat.name)" -PercentComplete (($natIndex / $totalNats) * 100)
            }
            
            foreach ($pip in $nat.publicIpAddresses) {
                if ($pip.id.ToLower() -eq $normalizedPipId) {
                    $result.IsInUse      = $true
                    $result.ResourceName = $nat.name
                    $result.ResourceType = "NAT Gateway"
                    $result.ResourceId   = $nat.id
                    Write-Progress -Id 2 -Completed
                    return $result
                }
            }
        }
        Write-Progress -Id 2 -Completed

        Write-Progress -Id 1 -Activity "Public IP Usage Analysis" -Status "Checking Azure Firewalls..." -PercentComplete 50
        
        # Check Azure Firewalls
        $fws = ConvertFrom-JsonSafely -JsonString (az network firewall list --only-show-errors) -ResourceType "Azure Firewall"
        $fwIndex = 0
        $totalFws = $fws.Count
        
        foreach ($fw in $fws) {
            $fwIndex++
            if ($totalFws -gt 2) {
                Write-Progress -Id 2 -ParentId 1 -Activity "Checking Azure Firewalls" -Status "Processing $($fw.name)" -PercentComplete (($fwIndex / $totalFws) * 100)
            }
            
            foreach ($ipConfig in $fw.ipConfigurations) {
                if ($ipConfig.publicIpAddress -and ($ipConfig.publicIpAddress.id.ToLower() -eq $normalizedPipId)) {
                    $result.IsInUse      = $true
                    $result.ResourceName = $fw.name
                    $result.ResourceType = "Firewall"
                    $result.ResourceId   = $fw.id
                    Write-Progress -Id 2 -Completed
                    return $result
                }
            }
        }
        Write-Progress -Id 2 -Completed

        Write-Progress -Id 1 -Activity "Public IP Usage Analysis" -Status "Checking Bastion Hosts..." -PercentComplete 60
        
        # Check Bastion Hosts
        $bastions = ConvertFrom-JsonSafely -JsonString (az network bastion list --only-show-errors) -ResourceType "Bastion Host"
        $bastionIndex = 0
        $totalBastions = $bastions.Count
        
        foreach ($bastion in $bastions) {
            $bastionIndex++
            if ($totalBastions -gt 2) {
                Write-Progress -Id 2 -ParentId 1 -Activity "Checking Bastion Hosts" -Status "Processing $($bastion.name)" -PercentComplete (($bastionIndex / $totalBastions) * 100)
            }
            
            if ($bastion.ipConfigurations) {
                foreach ($ipConfig in $bastion.ipConfigurations) {
                    if ($ipConfig.publicIPAddress -and ($ipConfig.publicIPAddress.id.ToLower() -eq $normalizedPipId)) {
                        $result.IsInUse      = $true
                        $result.ResourceName = $bastion.name
                        $result.ResourceType = "Bastion Host"
                        $result.ResourceId   = $bastion.id
                        return $result
                    }
                }
            }
        }
        Write-Progress -Id 1 -Activity "Public IP Usage Analysis" -Status "Checking VPN Gateways..." -PercentComplete 70
        
        # Check VPN Gateways - We need to list resource groups first and then check each one
        try {
            # We've already cached the resource groups earlier
            $rgIndex = 0
            $totalRgs = $resourceGroups.Count
            
            foreach ($rg in $resourceGroups) {
                $rgIndex++
                $rgName = $rg.name
                
                Write-Progress -Id 2 -ParentId 1 -Activity "Checking VPN Gateways" -Status "Resource Group: $rgName" -PercentComplete (($rgIndex / $totalRgs) * 100)
                
                $vpngws = ConvertFrom-JsonSafely -JsonString (az network vnet-gateway list --resource-group $rgName --only-show-errors 2>$null) -ResourceType "VPN Gateway in $rgName"
                $vpngwIndex = 0
                $totalVpnGws = $vpngws.Count
                
                foreach ($vpngw in $vpngws) {
                    $vpngwIndex++
                    if ($totalVpnGws -gt 1) {
                        Write-Progress -Id 3 -ParentId 2 -Activity "VPN Gateways in $rgName" -Status "Processing $($vpngw.name)" -PercentComplete (($vpngwIndex / $totalVpnGws) * 100)
                    }
                    foreach ($ipConfig in $vpngw.ipConfigurations) {
                        if ($ipConfig.publicIpAddress -and ($ipConfig.publicIpAddress.id.ToLower() -eq $normalizedPipId)) {
                            $result.IsInUse      = $true
                            $result.ResourceName = $vpngw.name
                            $result.ResourceType = "VPN Gateway"
                            $result.ResourceId   = $vpngw.id
                            Write-Progress -Id 3 -Completed
                            return $result
                        }
                    }
                }
                Write-Progress -Id 3 -Completed
            }
            Write-Progress -Id 2 -Completed
        } catch {
            Write-Host "⚠ Error checking VPN Gateways: $($_.Exception.Message)" -ForegroundColor Yellow
        }        Write-Progress -Id 1 -Activity "Public IP Usage Analysis" -Status "Checking ExpressRoute Gateways..." -PercentComplete 85
        
        # Check ExpressRoute Gateways - Also requires resource group iteration
        try {
            # We've already retrieved resource groups for VPN gateways above
            if (-not $resourceGroups) {
                $resourceGroups = ConvertFrom-JsonSafely -JsonString (az group list --only-show-errors) -ResourceType "Resource Group"
            }
            
            $rgIndex = 0
            $totalRgs = $resourceGroups.Count
            
            foreach ($rg in $resourceGroups) {
                $rgIndex++
                $rgName = $rg.name
                
                Write-Progress -Id 2 -ParentId 1 -Activity "Checking ExpressRoute Gateways" -Status "Resource Group: $rgName" -PercentComplete (($rgIndex / $totalRgs) * 100)
                
                $ergws = ConvertFrom-JsonSafely -JsonString (az network express-route gateway list --resource-group $rgName --only-show-errors 2>$null) -ResourceType "ExpressRoute Gateway in $rgName"
                foreach ($ergw in $ergws) {
                    if ($ergw.expressRouteConnections) {
                        foreach ($conn in $ergw.expressRouteConnections) {
                            if ($conn.routingConfiguration -and $conn.routingConfiguration.publicIpAddresses) {
                                foreach ($pip in $conn.routingConfiguration.publicIpAddresses) {
                                    if ($pip.id.ToLower() -eq $normalizedPipId) {
                                        $result.IsInUse      = $true
                                        $result.ResourceName = $ergw.name
                                        $result.ResourceType = "ExpressRoute Gateway"
                                        $result.ResourceId   = $ergw.id
                                        return $result                                    }
                                }
                            }
                        }
                    }
                }
            }
            Write-Progress -Id 2 -Completed
        } catch {
            Write-Host "⚠ Error checking ExpressRoute Gateways: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        
        # Complete all progress bars
        Write-Progress -Id 1 -Completed

    } catch {
        Write-Host "⚠ Error while resolving Public IP usage: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    return $result
}

# Get all Public IPs in the subscription and check if our target IP exists
Update-ValidationProgress -Status "Checking Public IP resources..."
$allPips = @()
try {
    Write-Progress -Id 1 -Activity "Public IP Validation" -Status "Retrieving all Public IPs..." -PercentComplete 0
    $allPips = az network public-ip list --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($null -eq $allPips) {
        Write-Host "⚠ Unable to retrieve the list of all Public IPs. Continuing with limited functionality." -ForegroundColor Yellow
        $allPips = @()
    }
    Write-Progress -Id 1 -Activity "Public IP Validation" -Status "Retrieved $(if ($allPips) { $allPips.Count } else { 0 }) Public IPs" -PercentComplete 30
} catch {
    Write-Host "⚠ Error retrieving Public IP list: $($_.Exception.Message)" -ForegroundColor Yellow
    $allPips = @()
    Write-Progress -Id 1 -Activity "Public IP Validation" -Status "Failed to retrieve Public IPs" -PercentComplete 30
}

$targetPipExists = $false
$targetPip = $null

# Find if our target IP exists in the full list
foreach ($pip in $allPips) {
    if ($pip.name -eq $STATIC_PIP_NAME -and $pip.resourceGroup -eq $STATIC_PIP_RG) {
        $targetPipExists = $true
        $targetPip = $pip
        break
    }
}

# Check if static public IP exists
try {
    Write-Progress -Id 1 -Activity "Public IP Validation" -Status "Looking for Static IP: $STATIC_PIP_NAME..." -PercentComplete 50
    
    # If we already found the IP in our list, use that instead of querying again
    if ($targetPipExists -and $null -ne $targetPip) {
        $pip = $targetPip
        Write-Progress -Id 1 -Activity "Public IP Validation" -Status "Found static IP in subscription list" -PercentComplete 60
    } else {
        # Traditional approach - attempt to get the specific public IP
        Write-Progress -Id 1 -Activity "Public IP Validation" -Status "Querying specific IP resource..." -PercentComplete 55
        $pip = az network public-ip show --name $STATIC_PIP_NAME --resource-group $STATIC_PIP_RG 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        Write-Progress -Id 1 -Activity "Public IP Validation" -Status "Completed IP resource query" -PercentComplete 60
    }

    # Check if $pip is valid and has the necessary properties
    if (($null -ne $pip) -and `
        -not [string]::IsNullOrEmpty($pip.name) -and `
        -not [string]::IsNullOrEmpty($pip.resourceGroup) -and `
        $pip.sku -and -not [string]::IsNullOrEmpty($pip.sku.name)) {
        
        $ipUsage = Get-PublicIpUsage -PipId $pip.id
        $usageInfo = ""
        if ($ipUsage.IsInUse) {
            $usageInfo = " (In use by $($ipUsage.ResourceType): $($ipUsage.ResourceName))"
        } else {
            $usageInfo = " (Not in use)"
        }
        
        # Handle case where ipAddress might be null (recently created PIPs might not have an address assigned yet)
        $ipAddressInfo = if ([string]::IsNullOrEmpty($pip.ipAddress)) { "Not yet assigned" } else { $pip.ipAddress }
        
        Write-Host "✓ Static Public IP found: $($pip.name) (IP: $ipAddressInfo, SKU: $($pip.sku.name))$usageInfo" -ForegroundColor Green
    
        # Check if it's Standard SKU
        if ($pip.sku.name -ne "Standard") {
            Write-Host "✗ Public IP '$($pip.name)' is not Standard SKU. Current SKU: $($pip.sku.name)" -ForegroundColor Red
            Write-Host "  Standard SKU is required for this deployment." -ForegroundColor Yellow
            Write-Host "  Example command to create (or delete and recreate with Standard SKU):" -ForegroundColor Yellow
            Write-Host "  az network public-ip create --name $STATIC_PIP_NAME --resource-group $STATIC_PIP_RG --sku Standard --allocation-method Static" -ForegroundColor Yellow
            
            # List all available Standard SKU public IPs as alternatives
            Write-Host "`nAvailable Standard SKU Public IPs in your subscription:" -ForegroundColor Cyan
            $standardPips = $allPips | Where-Object { $_.sku.name -eq "Standard" }
            
            if ($standardPips -and $standardPips.Count -gt 0) {
                $i = 1
                foreach ($standardPip in $standardPips) {
                    $stdIpUsage = Get-PublicIpUsage -PipId $standardPip.id
                    $stdUsageInfo = ""
                    if ($stdIpUsage.IsInUse) {
                        $stdUsageInfo = " (In use by $($stdIpUsage.ResourceType): $($stdIpUsage.ResourceName))"
                    } else {
                        $stdUsageInfo = " (Not in use)"
                    }
                    
                    Write-Host "  $i. Name: $($standardPip.name), RG: $($standardPip.resourceGroup), IP: $($standardPip.ipAddress)$stdUsageInfo" -ForegroundColor Yellow
                    $i++
                }
            } else {
                Write-Host "  No Standard SKU Public IPs found in your subscription." -ForegroundColor Yellow
            }
            
            exit 1
        }
    } else {
        # $pip is null or invalid. This means we couldn't find the specified public IP.
        Write-Host "✗ Could not retrieve valid details for Static Public IP '$($STATIC_PIP_NAME)' in resource group '$($STATIC_PIP_RG)'." -ForegroundColor Red
        
        # Check if resource group exists to provide a more specific message
        az group show --name $STATIC_PIP_RG --output none 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  The resource group '$($STATIC_PIP_RG)' was not found." -ForegroundColor Yellow
            Write-Host "  Please create the resource group first:" -ForegroundColor Yellow
            Write-Host "  az group create --name $STATIC_PIP_RG --location <your-desired-location>" -ForegroundColor Yellow
        } else {
            Write-Host "  The resource group '$($STATIC_PIP_RG)' exists, but the Public IP '$($STATIC_PIP_NAME)' might be missing or misconfigured." -ForegroundColor Yellow
        }
        
        # List all Public IPs across all resource groups
        Write-Host "`nAvailable Public IPs in your subscription:" -ForegroundColor Cyan
        
        if ($allPips -and $allPips.Count -gt 0) {
            # Create a formatted table with headers
            Write-Host "`n  #  | Name                | Resource Group        | IP Address      | SKU      | Allocation | Usage" -ForegroundColor Cyan
            Write-Host "-----+---------------------+----------------------+-----------------+----------+-----------+---------------------------" -ForegroundColor Cyan
            
            $i = 1
            foreach ($pipItem in $allPips) {
                $ipUsage = Get-PublicIpUsage -PipId $pipItem.id
                $usageInfo = "Not in use"
                if ($ipUsage.IsInUse) {
                    $usageInfo = "$($ipUsage.ResourceType): $($ipUsage.ResourceName)"
                }
                
                # Format the output as a table row with fixed-width columns
                $nameField = $pipItem.name.PadRight(20).Substring(0, 20)
                $rgField = $pipItem.resourceGroup.PadRight(20).Substring(0, 20)
                $ipField = ($pipItem.ipAddress ?? "Not assigned").PadRight(15).Substring(0, 15)
                $skuField = $pipItem.sku.name.PadRight(8).Substring(0, 8)
                $allocField = $pipItem.publicIPAllocationMethod.PadRight(9).Substring(0, 9)
                
                # Color the row based on whether it's Standard SKU and Static allocation
                $rowColor = "White"
                if ($pipItem.sku.name -eq "Standard" -and $pipItem.publicIPAllocationMethod -eq "Static" -and -not $ipUsage.IsInUse) {
                    $rowColor = "Green" # Highlight suitable options
                }
                
                # Highlight the IP that matches our target name and resource group
                if ($pipItem.name -eq $STATIC_PIP_NAME -and $pipItem.resourceGroup -eq $STATIC_PIP_RG) {
                    $rowColor = "Cyan" # Highlight the exact IP we're looking for
                    Write-Host "  $($i.ToString().PadLeft(2)) | $nameField | $rgField | $ipField | $skuField | $allocField | $usageInfo" -ForegroundColor $rowColor
                    Write-Host "`n  ⚠ Found the IP '$STATIC_PIP_NAME' in the resource group '$STATIC_PIP_RG' but couldn't retrieve its details directly." -ForegroundColor Yellow
                    Write-Host "    This might indicate an access issue or a recent creation that hasn't fully propagated." -ForegroundColor Yellow
                    Write-Host "    Try running the validation again in a few moments, or set the config.ps1 file to use this IP." -ForegroundColor Yellow
                } else {
                    Write-Host "  $($i.ToString().PadLeft(2)) | $nameField | $rgField | $ipField | $skuField | $allocField | $usageInfo" -ForegroundColor $rowColor
                }
                $i++
            }
        } else {
            Write-Host "  No Public IPs found in your subscription." -ForegroundColor Yellow
        }
        
        Write-Host "`nTo create a suitable Public IP for SirTunnel:" -ForegroundColor Cyan
        Write-Host "  az network public-ip create --name $STATIC_PIP_NAME --resource-group $STATIC_PIP_RG --sku Standard --allocation-method Static" -ForegroundColor Yellow
        
        exit 1
    }
} catch {
    # This catch block handles other unexpected PowerShell errors
    Write-Host "✗ An unexpected script error occurred while checking Static Public IP '$($STATIC_PIP_NAME)'." -ForegroundColor Red
    Write-Host "  Error details: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Please ensure the resource group '$($STATIC_PIP_RG)' exists and the Public IP '$($STATIC_PIP_NAME)' is a Standard SKU static IP." -ForegroundColor Yellow
    Write-Host "  Example command to create resource group:" -ForegroundColor Yellow
    Write-Host "  az group create --name $STATIC_PIP_RG --location <your-desired-location>" -ForegroundColor Yellow
    Write-Host "  Example command to create public IP:" -ForegroundColor Yellow
    Write-Host "  az network public-ip create --name $STATIC_PIP_NAME --resource-group $STATIC_PIP_RG --sku Standard --allocation-method Static" -ForegroundColor Yellow
    exit 1
}

# Check if DNS Zone exists
Update-ValidationProgress -Status "Verifying DNS configuration..."
Write-Progress -Id 1 -Activity "DNS Validation" -Status "Checking DNS Zone..." -PercentComplete 0
try {
    $dnsZoneExists = az network dns zone show --name $DNS_ZONE_NAME --resource-group $DNS_ZONE_RG --only-show-errors | ConvertFrom-Json -ErrorAction Stop
    Write-Host "✓ DNS Zone found: $DNS_ZONE_NAME" -ForegroundColor Green
    Write-Progress -Id 1 -Activity "DNS Validation" -Status "DNS Zone found" -PercentComplete 50
    
    # Check if the wildcard record already exists
    Write-Progress -Id 1 -Activity "DNS Validation" -Status "Checking wildcard DNS record..." -PercentComplete 60
    try {
        $record = az network dns record-set a show --name "*.tun" --zone-name $DNS_ZONE_NAME --resource-group $DNS_ZONE_RG --only-show-errors | ConvertFrom-Json -ErrorAction Stop
        Write-Host "✓ Wildcard DNS record found: *.tun.$DNS_ZONE_NAME (Points to: $($record.aRecords[0].ipv4Address))" -ForegroundColor Green
        Write-Progress -Id 1 -Activity "DNS Validation" -Status "Wildcard record found" -PercentComplete 100
        
        # Check if it points to the correct IP
        if ($record.aRecords -and $record.aRecords.Count -gt 0 -and $record.aRecords[0].ipv4Address -and $pip -and $pip.ipAddress) {
            if ($record.aRecords[0].ipv4Address -ne $pip.ipAddress) {
                Write-Host "⚠ Wildcard DNS record points to $($record.aRecords[0].ipv4Address), but static IP is $($pip.ipAddress)" -ForegroundColor Yellow
                Write-Host "  Consider updating the DNS record to match your static IP." -ForegroundColor Yellow
            }
        } else {
            Write-Host "⚠ Unable to compare DNS record IP with static IP due to missing data" -ForegroundColor Yellow
        }    } catch {
        Write-Host "⚠ Wildcard DNS record not found: *.tun.$DNS_ZONE_NAME" -ForegroundColor Yellow
        Write-Progress -Id 1 -Activity "DNS Validation" -Status "Wildcard record not found" -PercentComplete 75
        
        if ($pip -and -not [string]::IsNullOrEmpty($pip.ipAddress)) {
            Write-Host "  After deployment, create this record with:" -ForegroundColor Yellow
            Write-Host "  az network dns record-set a add-record --resource-group $DNS_ZONE_RG --zone-name $DNS_ZONE_NAME --record-set-name '*.tun' --ipv4-address $($pip.ipAddress)" -ForegroundColor Yellow
        } else {
            Write-Host "  After deployment, create this record with:" -ForegroundColor Yellow
            Write-Host "  az network dns record-set a add-record --resource-group $DNS_ZONE_RG --zone-name $DNS_ZONE_NAME --record-set-name '*.tun' --ipv4-address <your-static-ip>" -ForegroundColor Yellow
        }
    }
    Write-Progress -Id 1 -Completed
} catch {
    Write-Host "✗ DNS Zone not found: $DNS_ZONE_NAME in resource group $DNS_ZONE_RG" -ForegroundColor Red
    Write-Host "  Error details: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Please create the DNS Zone before proceeding." -ForegroundColor Yellow
    Write-Host "  Example command:" -ForegroundColor Yellow
    Write-Host "  az network dns zone create -g $DNS_ZONE_RG -n $DNS_ZONE_NAME" -ForegroundColor Yellow
    Write-Progress -Id 1 -Completed
    Write-Progress -Id 0 -Completed
    exit 1
}

# Check and install bicep if needed
Update-ValidationProgress -Status "Checking Bicep installation..."
Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Verifying Bicep installation..." -PercentComplete 0
try {
    # Use more robust detection and explicit version handling
    $bicepVersion = $null
    $bicepInstalled = $false
    
    try {
        # Try the bicep version command with error suppression
        Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Checking Bicep version..." -PercentComplete 25
        $bicepCmd = az bicep version --only-show-errors 2>$null
        
        # Check if the command succeeded
        if ($LASTEXITCODE -eq 0) {
            try {                # Try to parse as JSON
                $bicepVersion = $bicepCmd | ConvertFrom-Json -ErrorAction Stop
                Write-Host "✓ Bicep is installed: $($bicepVersion.version)" -ForegroundColor Green
                $bicepInstalled = $true
                Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Bicep is installed" -PercentComplete 100
            }
            catch {
                # Command succeeded but returned non-JSON (might be a version string directly)
                if ($bicepCmd -match '\d+\.\d+\.\d+') {
                    Write-Host "✓ Bicep is installed: $bicepCmd" -ForegroundColor Green
                    $bicepInstalled = $true
                    Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Bicep is installed" -PercentComplete 100
                }
                else {
                    Write-Host "⚠ Unable to determine Bicep version, but it appears to be installed" -ForegroundColor Yellow
                    $bicepInstalled = $true
                    Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Bicep appears to be installed" -PercentComplete 100
                }
            }
        }
        else {
            # Command failed - Bicep is likely not installed
            $bicepInstalled = $false
            Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Bicep not found" -PercentComplete 30
        }
    }
    catch {
        # An exception occurred during version check - Bicep is likely not installed
        $bicepInstalled = $false
    }
      if (-not $bicepInstalled) {
        # Bicep not installed. Let's install it automatically
        Write-Host "⚠ Bicep CLI not found, installing now..." -ForegroundColor Yellow
        Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Installing Bicep..." -PercentComplete 50
        
        # Install bicep with error handling
        try {
            $installOutput = az bicep install --only-show-errors 2>&1
              if ($LASTEXITCODE -eq 0) {
                # Installation succeeded
                Write-Host "✓ Bicep successfully installed" -ForegroundColor Green
                $bicepInstalled = $true # Ensure this is set immediately after successful install
                Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Bicep installation successful. Verifying version..." -PercentComplete 75
                
                # Attempt to get the installed version
                try {
                    Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Getting installed Bicep version..." -PercentComplete 85
                    $bicepVersionCmdOutput = az bicep version --only-show-errors 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        # Version command succeeded, try to parse
                        try {
                            $bicepVersionObj = $bicepVersionCmdOutput | ConvertFrom-Json -ErrorAction Stop
                            Write-Host "  Installed Bicep version: $($bicepVersionObj.version)" -ForegroundColor Green
                            Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Bicep version: $($bicepVersionObj.version)" -PercentComplete 100
                        } catch {
                            # Not JSON, try regex
                            if ($bicepVersionCmdOutput -match '\d+\.\d+\.\d+') {
                                Write-Host "  Installed Bicep version: $bicepVersionCmdOutput" -ForegroundColor Green
                                Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Bicep version: $bicepVersionCmdOutput" -PercentComplete 100
                            } else {
                                # Neither JSON nor recognizable string
                                Write-Host "  Bicep version retrieved, but format is unexpected: '$bicepVersionCmdOutput'" -ForegroundColor Yellow
                                Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Bicep version format unknown" -PercentComplete 100
                            }
                        }
                    } else {
                        # az bicep version command failed
                        Write-Host "  Could not retrieve Bicep version after installation (version command failed). Bicep should still be functional." -ForegroundColor Yellow
                        Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Bicep version check command failed" -PercentComplete 100
                    }
                } catch {
                    # Exception during the version retrieval/parsing logic
                    Write-Host "  An error occurred while trying to retrieve Bicep version: $($_.Exception.Message)" -ForegroundColor Yellow
                    Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Exception during Bicep version check" -PercentComplete 100
                }
            }
            else {
                # Installation failed but we'll continue with a warning
                Write-Host "⚠ Failed to install Bicep automatically" -ForegroundColor Yellow
                Write-Host "  This script can continue, but deployment may fail later. To install manually:" -ForegroundColor Yellow
                Write-Host "  az bicep install" -ForegroundColor Yellow
                Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Bicep installation failed" -PercentComplete 100
            }
        }
        catch {
            # Exception during installation
            Write-Host "⚠ Exception during Bicep installation: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  This script will continue, but deployment may fail later. To install manually:" -ForegroundColor Yellow
            Write-Host "  az bicep install" -ForegroundColor Yellow
            Write-Progress -Id 1 -Activity "Bicep Validation" -Status "Error during Bicep installation" -PercentComplete 100
        }
    }
    Write-Progress -Id 1 -Completed
} 
catch {
    # Continue even if we encounter an error with bicep detection or installation
    Write-Host "⚠ Error checking/installing Bicep: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  This script will continue, but deployment may fail later. To install manually:" -ForegroundColor Yellow
    Write-Host "  az bicep install" -ForegroundColor Yellow
    Write-Progress -Id 1 -Completed
}

# Add a validation summary section
$validationSummary = @{
    AzureLoggedIn = $true
    SshKeyValid = $true
    PublicIpExists = ($null -ne $pip)
    PublicIpStandard = ($pip -and $pip.sku -and $pip.sku.name -eq "Standard")
    DnsZoneExists = ($null -ne $dnsZoneExists)
    BicepInstalled = $bicepInstalled
    ReadyToDeploy = $true
}

# Function to format validation summary results
function Show-ValidationResult {
    param (
        [string]$Item,
        [bool]$Result,
        [string]$Details = ""
    )
    
    $color = if ($Result) { "Green" } else { "Red" }
    $symbol = if ($Result) { "✓" } else { "✗" }
    $resultText = if ($Result) { "Passed" } else { "Failed" }
    
    $message = "$symbol ${Item}: $resultText"
    if (-not [string]::IsNullOrEmpty($Details)) {
        $message += " ($Details)"
    }
    
    Write-Host $message -ForegroundColor $color
}

# If any check failed, mark as not ready to deploy
if (-not $validationSummary.AzureLoggedIn -or 
    -not $validationSummary.SshKeyValid -or
    -not $validationSummary.PublicIpExists -or
    -not $validationSummary.PublicIpStandard -or
    -not $validationSummary.DnsZoneExists) {
    $validationSummary.ReadyToDeploy = $false
}

# Display validation summary
Write-Host "`nValidation Summary:" -ForegroundColor Cyan
Write-Host "===================" -ForegroundColor Cyan
Show-ValidationResult -Item "Azure CLI Login" -Result $validationSummary.AzureLoggedIn
Show-ValidationResult -Item "SSH Key" -Result $validationSummary.SshKeyValid
Show-ValidationResult -Item "Public IP Exists" -Result $validationSummary.PublicIpExists
Show-ValidationResult -Item "Public IP is Standard SKU" -Result $validationSummary.PublicIpStandard
Show-ValidationResult -Item "DNS Zone Exists" -Result $validationSummary.DnsZoneExists
Show-ValidationResult -Item "Bicep Installed" -Result $validationSummary.BicepInstalled -Details $(if (-not $validationSummary.BicepInstalled) { "Will attempt to install during deployment" } else { "" })

# Final confirmation
Update-ValidationProgress -Status "Completing validation..." -Step $script:totalValidationSteps
Write-Progress -Id 0 -Activity "SirTunnel Validation" -Status "Validation complete" -Completed

if ($validationSummary.ReadyToDeploy) {
    Write-Host "`nAll prerequisites have been validated! You're ready to deploy." -ForegroundColor Green
    Write-Host "Run the following command to deploy SirTunnel:" -ForegroundColor Cyan
    Write-Host ".\scripts\deploy.ps1" -ForegroundColor Yellow
} else {
    Write-Host "`n⚠ Some validation checks failed. Please fix the issues above before deploying." -ForegroundColor Yellow
    exit 1
}
