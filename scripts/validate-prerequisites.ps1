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

# Configure Azure CLI to allow preview extensions if needed
Write-Host "Configuring Azure CLI extension settings..." -ForegroundColor Cyan
az config set extension.dynamic_install_allow_preview=true --only-show-errors
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors
Write-Host "✓ Azure CLI extension settings configured" -ForegroundColor Green

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
        }        # Cache resource groups for later use
        $resourceGroups = ConvertFrom-JsonSafely -JsonString (az group list --only-show-errors) -ResourceType "Resource Group"
        
        # Check NICs
        $nics = ConvertFrom-JsonSafely -JsonString (az network nic list --only-show-errors) -ResourceType "Network Interface"
        foreach ($nic in $nics) {
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
                    return $result
                }
            }
        }

        # Check Load Balancers
        $lbs = ConvertFrom-JsonSafely -JsonString (az network lb list --only-show-errors) -ResourceType "Load Balancer"
        foreach ($lb in $lbs) {
            foreach ($config in $lb.frontendIpConfigurations) {
                if ($config.publicIpAddress -and ($config.publicIpAddress.id.ToLower() -eq $normalizedPipId)) {
                    $result.IsInUse      = $true
                    $result.ResourceName = $lb.name
                    $result.ResourceType = "Load Balancer"
                    $result.ResourceId   = $lb.id
                    return $result
                }
            }
        }

        # Check Application Gateways
        $agws = ConvertFrom-JsonSafely -JsonString (az network application-gateway list --only-show-errors) -ResourceType "Application Gateway"
        foreach ($agw in $agws) {
            foreach ($config in $agw.frontendIPConfigurations) {
                if ($config.publicIPAddress -and ($config.publicIPAddress.id.ToLower() -eq $normalizedPipId)) {
                    $result.IsInUse      = $true
                    $result.ResourceName = $agw.name
                    $result.ResourceType = "Application Gateway"
                    $result.ResourceId   = $agw.id
                    return $result
                }
            }
        }

        # Check NAT Gateways
        $nats = ConvertFrom-JsonSafely -JsonString (az network nat gateway list --only-show-errors) -ResourceType "NAT Gateway"
        foreach ($nat in $nats) {
            foreach ($pip in $nat.publicIpAddresses) {
                if ($pip.id.ToLower() -eq $normalizedPipId) {
                    $result.IsInUse      = $true
                    $result.ResourceName = $nat.name
                    $result.ResourceType = "NAT Gateway"
                    $result.ResourceId   = $nat.id
                    return $result
                }
            }
        }

        # Check Azure Firewalls
        $fws = ConvertFrom-JsonSafely -JsonString (az network firewall list --only-show-errors) -ResourceType "Azure Firewall"
        foreach ($fw in $fws) {
            foreach ($ipConfig in $fw.ipConfigurations) {
                if ($ipConfig.publicIpAddress -and ($ipConfig.publicIpAddress.id.ToLower() -eq $normalizedPipId)) {
                    $result.IsInUse      = $true
                    $result.ResourceName = $fw.name
                    $result.ResourceType = "Firewall"
                    $result.ResourceId   = $fw.id
                    return $result
                }
            }
        }

        # Check Bastion Hosts
        $bastions = ConvertFrom-JsonSafely -JsonString (az network bastion list --only-show-errors) -ResourceType "Bastion Host"
        foreach ($bastion in $bastions) {
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
        }        # Check VPN Gateways - We need to list resource groups first and then check each one
        try {
            $resourceGroups = ConvertFrom-JsonSafely -JsonString (az group list --only-show-errors) -ResourceType "Resource Group"
            foreach ($rg in $resourceGroups) {
                $rgName = $rg.name
                $vpngws = ConvertFrom-JsonSafely -JsonString (az network vnet-gateway list --resource-group $rgName --only-show-errors 2>$null) -ResourceType "VPN Gateway in $rgName"
                foreach ($vpngw in $vpngws) {
                    foreach ($ipConfig in $vpngw.ipConfigurations) {
                        if ($ipConfig.publicIpAddress -and ($ipConfig.publicIpAddress.id.ToLower() -eq $normalizedPipId)) {
                            $result.IsInUse      = $true
                            $result.ResourceName = $vpngw.name
                            $result.ResourceType = "VPN Gateway"
                            $result.ResourceId   = $vpngw.id
                            return $result
                        }
                    }
                }
            }
        } catch {
            Write-Host "⚠ Error checking VPN Gateways: $($_.Exception.Message)" -ForegroundColor Yellow
        }        # Check ExpressRoute Gateways - Also requires resource group iteration
        try {
            # We've already retrieved resource groups for VPN gateways above
            if (-not $resourceGroups) {
                $resourceGroups = ConvertFrom-JsonSafely -JsonString (az group list --only-show-errors) -ResourceType "Resource Group"
            }
            
            foreach ($rg in $resourceGroups) {
                $rgName = $rg.name
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
                                        return $result
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            Write-Host "⚠ Error checking ExpressRoute Gateways: $($_.Exception.Message)" -ForegroundColor Yellow
        }

    } catch {
        Write-Host "⚠ Error while resolving Public IP usage: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    return $result
}

# Get all Public IPs in the subscription and check if our target IP exists
$allPips = @()
try {
    $allPips = az network public-ip list --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($null -eq $allPips) {
        Write-Host "⚠ Unable to retrieve the list of all Public IPs. Continuing with limited functionality." -ForegroundColor Yellow
        $allPips = @()
    }
} catch {
    Write-Host "⚠ Error retrieving Public IP list: $($_.Exception.Message)" -ForegroundColor Yellow
    $allPips = @()
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
    # If we already found the IP in our list, use that instead of querying again
    if ($targetPipExists -and $null -ne $targetPip) {
        $pip = $targetPip
    } else {
        # Traditional approach - attempt to get the specific public IP
        $pip = az network public-ip show --name $STATIC_PIP_NAME --resource-group $STATIC_PIP_RG 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
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
try {
    $dnsZoneExists = az network dns zone show --name $DNS_ZONE_NAME --resource-group $DNS_ZONE_RG --only-show-errors | ConvertFrom-Json -ErrorAction Stop
    Write-Host "✓ DNS Zone found: $DNS_ZONE_NAME" -ForegroundColor Green
    
    # Check if the wildcard record already exists
    try {
        $record = az network dns record-set a show --name "*.tun" --zone-name $DNS_ZONE_NAME --resource-group $DNS_ZONE_RG --only-show-errors | ConvertFrom-Json -ErrorAction Stop
        Write-Host "✓ Wildcard DNS record found: *.tun.$DNS_ZONE_NAME (Points to: $($record.aRecords[0].ipv4Address))" -ForegroundColor Green
        
        # Check if it points to the correct IP
        if ($record.aRecords -and $record.aRecords.Count -gt 0 -and $record.aRecords[0].ipv4Address -and $pip -and $pip.ipAddress) {
            if ($record.aRecords[0].ipv4Address -ne $pip.ipAddress) {
                Write-Host "⚠ Wildcard DNS record points to $($record.aRecords[0].ipv4Address), but static IP is $($pip.ipAddress)" -ForegroundColor Yellow
                Write-Host "  Consider updating the DNS record to match your static IP." -ForegroundColor Yellow
            }
        } else {
            Write-Host "⚠ Unable to compare DNS record IP with static IP due to missing data" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "⚠ Wildcard DNS record not found: *.tun.$DNS_ZONE_NAME" -ForegroundColor Yellow
        
        if ($pip -and -not [string]::IsNullOrEmpty($pip.ipAddress)) {
            Write-Host "  After deployment, create this record with:" -ForegroundColor Yellow
            Write-Host "  az network dns record-set a add-record --resource-group $DNS_ZONE_RG --zone-name $DNS_ZONE_NAME --record-set-name '*.tun' --ipv4-address $($pip.ipAddress)" -ForegroundColor Yellow
        } else {
            Write-Host "  After deployment, create this record with:" -ForegroundColor Yellow
            Write-Host "  az network dns record-set a add-record --resource-group $DNS_ZONE_RG --zone-name $DNS_ZONE_NAME --record-set-name '*.tun' --ipv4-address <your-static-ip>" -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "✗ DNS Zone not found: $DNS_ZONE_NAME in resource group $DNS_ZONE_RG" -ForegroundColor Red
    Write-Host "  Error details: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Please create the DNS Zone before proceeding." -ForegroundColor Yellow
    Write-Host "  Example command:" -ForegroundColor Yellow
    Write-Host "  az network dns zone create -g $DNS_ZONE_RG -n $DNS_ZONE_NAME" -ForegroundColor Yellow
    exit 1
}

# Check and install bicep if needed
try {
    # Use more robust detection and explicit version handling
    $bicepVersion = $null
    $bicepInstalled = $false
    
    try {
        # Try the bicep version command with error suppression
        $bicepCmd = az bicep version --only-show-errors 2>$null
        
        # Check if the command succeeded
        if ($LASTEXITCODE -eq 0) {
            try {
                # Try to parse as JSON
                $bicepVersion = $bicepCmd | ConvertFrom-Json -ErrorAction Stop
                Write-Host "✓ Bicep is installed: $($bicepVersion.version)" -ForegroundColor Green
                $bicepInstalled = $true
            }
            catch {
                # Command succeeded but returned non-JSON (might be a version string directly)
                if ($bicepCmd -match '\d+\.\d+\.\d+') {
                    Write-Host "✓ Bicep is installed: $bicepCmd" -ForegroundColor Green
                    $bicepInstalled = $true
                }
                else {
                    Write-Host "⚠ Unable to determine Bicep version, but it appears to be installed" -ForegroundColor Yellow
                    $bicepInstalled = $true
                }
            }
        }
        else {
            # Command failed - Bicep is likely not installed
            $bicepInstalled = $false
        }
    }
    catch {
        # An exception occurred during version check - Bicep is likely not installed
        $bicepInstalled = $false
    }
    
    if (-not $bicepInstalled) {
        # Bicep not installed. Let's install it automatically
        Write-Host "⚠ Bicep CLI not found, installing now..." -ForegroundColor Yellow
        
        # Install bicep with error handling
        try {
            $installOutput = az bicep install --only-show-errors 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                # Installation succeeded
                Write-Host "✓ Bicep successfully installed" -ForegroundColor Green
                
                # Get the installed version with error handling
                try {
                    $bicepVersionCmd = az bicep version --only-show-errors 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        try {
                            $bicepVersion = $bicepVersionCmd | ConvertFrom-Json -ErrorAction Stop
                            Write-Host "✓ Bicep version: $($bicepVersion.version)" -ForegroundColor Green
                        }
                        catch {
                            Write-Host "✓ Bicep has been installed (version info not available)" -ForegroundColor Green
                        }
                    }
                }
                catch {
                    Write-Host "✓ Bicep has been installed (version check failed)" -ForegroundColor Green
                }
            }
            else {
                # Installation failed but we'll continue with a warning
                Write-Host "⚠ Failed to install Bicep automatically" -ForegroundColor Yellow
                Write-Host "  This script can continue, but deployment may fail later. To install manually:" -ForegroundColor Yellow
                Write-Host "  az bicep install" -ForegroundColor Yellow
            }
        }
        catch {
            # Exception during installation
            Write-Host "⚠ Exception during Bicep installation: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  This script will continue, but deployment may fail later. To install manually:" -ForegroundColor Yellow
            Write-Host "  az bicep install" -ForegroundColor Yellow
        }
    }
} 
catch {
    # Continue even if we encounter an error with bicep detection or installation
    Write-Host "⚠ Error checking/installing Bicep: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  This script will continue, but deployment may fail later. To install manually:" -ForegroundColor Yellow
    Write-Host "  az bicep install" -ForegroundColor Yellow
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
if ($validationSummary.ReadyToDeploy) {
    Write-Host "`nAll prerequisites have been validated! You're ready to deploy." -ForegroundColor Green
    Write-Host "Run the following command to deploy SirTunnel:" -ForegroundColor Cyan
    Write-Host ".\scripts\deploy.ps1" -ForegroundColor Yellow
} else {
    Write-Host "`n⚠ Some validation checks failed. Please fix the issues above before deploying." -ForegroundColor Yellow
    exit 1
}
