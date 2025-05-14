

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
      throw "Missing required config value: $var"
    }
  }

  # Resolve SSH public key contents
  if (-not (Test-Path $SSH_PUB_KEY_PATH)) {
    throw "SSH public key file not found: $SSH_PUB_KEY_PATH"
  }
  $key = Get-Content -Raw -Path $SSH_PUB_KEY_PATH
  if ([string]::IsNullOrWhiteSpace($key)) {
    throw "SSH public key file is empty: $SSH_PUB_KEY_PATH"
  }
  $script:ResolvedSshKey = $key

# Ensure resource group exists
Write-Host "Ensuring resource group exists: $VM_RG_NAME..."
az group create --name $VM_RG_NAME --location $LOCATION --output none

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

# Check existing deployment stack status
Write-Host "Checking status of existing Deployment Stack: $STACK_NAME in resource group $VM_RG_NAME..."
$rawAzOutput = az stack group show --name $STACK_NAME --resource-group $VM_RG_NAME --output json 2>$null
$azExitCode = $LASTEXITCODE # Capture exit code immediately

$stackStatus = $null # Initialize $stackStatus

if ($azExitCode -eq 0) {
    $jsonInputString = $rawAzOutput | Out-String # Ensure $jsonInputString is a single string
    if (-not [string]::IsNullOrWhiteSpace($jsonInputString)) {
        try {
            $stackObject = $jsonInputString | ConvertFrom-Json -ErrorAction Stop
            # Check if $stackObject itself is null, and if 'provisioningState' property exists directly on the object
            if (($null -ne $stackObject) -and ($null -ne $stackObject.PSObject.Properties['provisioningState'])) {
                $stackStatus = $stackObject.provisioningState # Corrected: provisioningState is a direct property
            } else {
                 Write-Host "Stack '$STACK_NAME' found, but its structure is unexpected or provisioningState is missing. JSON content: $jsonInputString"
            }
        } catch {
            Write-Warning "Failed to parse JSON output for stack '$STACK_NAME': $($_.Exception.Message). Raw content: $jsonInputString"
            # $stackStatus remains $null, leading to the 'else' block of the next 'if' statement
        }
    } else {
        Write-Host "Stack '$STACK_NAME' query returned no content, though command succeeded (exit code 0). Assuming stack does not exist or is in an indeterminate state."
        # $stackStatus remains $null, leading to the 'else' block of the next 'if' statement
    }
}

# Main decision logic based on $azExitCode and having successfully retrieved a $stackStatus
if ($azExitCode -eq 0 -and $stackStatus) { # True if 'az stack show' succeeded AND we got a non-null stackStatus
    Write-Host "Current stack status: $stackStatus"

    if ($stackStatus -eq 'Deploying' -or $stackStatus -eq 'Provisioning') {
        Write-Warning "The deployment stack '$STACK_NAME' is currently in '$stackStatus' state. Azure is actively working on it."
        $confirmation = Read-Host "This stack is actively being modified by Azure. Do you want to attempt to cancel this operation and then update the stack? (y/n) (Choosing 'n' will abort)"
        if ($confirmation -eq 'y') {
            Write-Warning "Attempting to cancel the active underlying deployment for stack '$STACK_NAME'..."
            
            # --- BEGIN CANCELLATION LOGIC ---
            $deploymentName = $null
            if (($null -ne $stackObject) -and ($null -ne $stackObject.properties) -and ($null -ne $stackObject.properties.deploymentId)) {
                $deploymentId = $stackObject.properties.deploymentId
                $deploymentName = ($deploymentId -split '/')[-1]
                Write-Host "Retrieved deploymentId directly from stack properties: $deploymentName"
            } else {
                Write-Warning "deploymentId not found in stack object properties. Falling back to querying active deployments in resource group..."
                $activeDeploymentsJson = az deployment group list --resource-group $VM_RG_NAME --query "[?contains(name, '$STACK_NAME') && properties.provisioningState=='Running']" --output json
                $activeDeployments = $activeDeploymentsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($activeDeployments -and ($activeDeployments.GetType().Name -ne 'String') -and $activeDeployments.Count -gt 0) {
                    try {
                       $deploymentName = ($activeDeployments | Sort-Object { $_.properties.timestamp } -Descending)[0].name
                       Write-Host "Identified fallback active deployment: $deploymentName"
                    } catch {
                       Write-Warning "Error processing active deployments list: $($_.Exception.Message). Could not determine fallback deployment name."
                       $deploymentName = $null
                    }
                } else {
                    Write-Warning "No active deployments found matching '$STACK_NAME' in state 'Running' in resource group '$VM_RG_NAME', or error parsing deployment list. Cannot auto-cancel."
                    if (($null -ne $activeDeployments) -and ($activeDeployments.GetType().Name -eq 'String')) { Write-Warning "Deployment list query output (if it was an error string): $activeDeployments" }
                }
            }

            $cancellationProcessedSuccessfully = $false 

            if ($deploymentName) {
                Write-Host "Attempting to cancel deployment: $deploymentName"
                $tempCancelErrorFile = New-TemporaryFile
                az deployment group cancel --resource-group $VM_RG_NAME --name $deploymentName --output none 2> $tempCancelErrorFile.FullName
                $azCancelExitCode = $LASTEXITCODE
                $cancelErrorOutput = Get-Content $tempCancelErrorFile.FullName -Raw -ErrorAction SilentlyContinue
                Remove-Item $tempCancelErrorFile.FullName -Force -ErrorAction SilentlyContinue

                if ($azCancelExitCode -eq 0) {
                    Write-Host "Cancellation request for deployment '$deploymentName' successfully sent."
                    Write-Host "Waiting for Azure to process the cancellation (up to 5 minutes)..."
                    $pollingStartTime = Get-Date
                    $timeoutSeconds = 300 # 5 minutes
                    $pollIntervalSeconds = 15
                    
                    while ((Get-Date -UFormat %s) -lt ($pollingStartTime.AddSeconds($timeoutSeconds) | Get-Date -UFormat %s)) {
                        Write-Host "Checking status of deployment '$deploymentName'..."
                        $deploymentStatusJson = az deployment group show --resource-group $VM_RG_NAME --name $deploymentName --output json 2>$null
                        $deploymentShowExitCode = $LASTEXITCODE

                        if ($deploymentShowExitCode -eq 0) {
                            $deploymentObject = $deploymentStatusJson | ConvertFrom-Json -ErrorAction SilentlyContinue
                            if ($deploymentObject -and $deploymentObject.properties -and $deploymentObject.properties.provisioningState) {
                                $currentDeploymentState = $deploymentObject.properties.provisioningState
                                Write-Host "Current deployment state: $currentDeploymentState"
                                if ($currentDeploymentState -eq 'Canceled' -or $currentDeploymentState -eq 'Failed' -or $currentDeploymentState -eq 'Succeeded') {
                                    Write-Host "Deployment '$deploymentName' has reached a terminal state: $currentDeploymentState."
                                    $cancellationProcessedSuccessfully = $true
                                    break
                                }
                            } else {
                                Write-Warning "Could not parse status for deployment '$deploymentName', or provisioningState missing. Retrying..."
                            }
                        } else {
                            Write-Warning "Failed to get status for deployment '$deploymentName' (az deployment group show exit code: $deploymentShowExitCode). It might have been deleted or an error occurred. Assuming cancellation is effective."
                            $cancellationProcessedSuccessfully = $true 
                            break 
                        }
                        Start-Sleep -Seconds $pollIntervalSeconds
                        Write-Host "Still waiting for deployment '$deploymentName' to complete cancellation..."
                    }

                    if (-not $cancellationProcessedSuccessfully -and ((Get-Date -UFormat %s) -ge ($pollingStartTime.AddSeconds($timeoutSeconds) | Get-Date -UFormat %s))) {
                        Write-Error "Timed out waiting for deployment '$deploymentName' to cancel/terminate. Aborting update. Please check the Azure portal."
                        exit 1
                    } elseif ($cancellationProcessedSuccessfully) {
                        Write-Host "Deployment '$deploymentName' cancellation/termination processed."
                    }
                } else {
                    Write-Error "Failed to send cancellation request for deployment '$deploymentName'. Azure CLI error: $cancelErrorOutput. Aborting update."
                    exit 1
                }
            } else {
                Write-Warning "Could not determine an active deployment name to cancel. Proceeding with update attempt, but it might fail."
                # If no deployment name, we assume we can proceed with the update attempt.
            }
            # --- END CANCELLATION LOGIC ---
            Write-Host "Proceeding with stack update."

        } else {
            Write-Host "Update aborted by user. Please monitor the stack '$STACK_NAME' in the Azure portal."
            exit 1
        }
    } elseif ($stackStatus -eq 'Failed' -or `
               $stackStatus -eq 'DeletingFailed' -or `
               $stackStatus -eq 'Cancelling' -or `
               $stackStatus -eq 'CreateFailed' -or `
               $stackStatus -eq 'UpdateFailed') {
        
        Write-Warning "The deployment stack '$STACK_NAME' is in a non-terminal/failed state: '$stackStatus'."
        $confirmation = Read-Host "Do you want to attempt to update the stack '$STACK_NAME'? (y/n) (Choosing 'n' will abort)"
        if ($confirmation -eq 'y') {
            Write-Host "Proceeding with update for stack in '$stackStatus' state."
            # No deletion, just proceed to the update command later in the script.
        } else {
            Write-Host "Deployment aborted by user. Please monitor the stack '$STACK_NAME' in the Azure portal."
            exit 1
        }
    } elseif ($stackStatus -eq 'Succeeded' -or $stackStatus -eq 'Canceled') {
        Write-Host "Stack '$STACK_NAME' is in a terminal state '$stackStatus'. Proceeding with update."
    } else {
        # Handle any other unexpected (but potentially terminal) states by attempting an update.
        Write-Warning "Stack '$STACK_NAME' is in an unexpected state: '$stackStatus'. Attempting to proceed with update."
    }
} else { # This 'else' covers: $azExitCode -ne 0 (az command failed) OR $stackStatus is $null (JSON parsing/access failed, or stack not found)
    Write-Host "Deployment Stack '$STACK_NAME' not found, its status could not be reliably determined, or it's in an empty/initial state. Proceeding with creation/update attempt."
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
