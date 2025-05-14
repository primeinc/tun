# Redeploy the CustomScript extension for SirTunnel on an existing VM, using config.ps1 for all values.
# This script does NOT touch the VM, network, or disks—just the extension layer.
# Usage: pwsh ./scripts/redeploy-extension.ps1 [-Force]

param(
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Load deployment config
Write-Host "[DEBUG] Loading config from: $PSScriptRoot/config.ps1" -ForegroundColor Cyan
. "$PSScriptRoot/config.ps1"
Write-Host "[DEBUG] Config loaded, VM_RG_NAME: $VM_RG_NAME" -ForegroundColor Cyan

# Build settings and protectedSettings objects
$settings = @{
  fileUris = @(
    "https://raw.githubusercontent.com/$GITHUB_REPO/main/scripts/install.sh",
    "https://raw.githubusercontent.com/$GITHUB_REPO/main/scripts/run_server.sh",
    "https://raw.githubusercontent.com/$GITHUB_REPO/main/scripts/caddy_config.json",
    "https://raw.githubusercontent.com/$GITHUB_REPO/main/scripts/sirtunnel.py"
  )
  skipDos2Unix = $false
}

$protected = @{
  commandToExecute = "bash install.sh $DNS_ZONE_RG $DNS_ZONE_NAME"
}

# Check current extension state
$existing = $null
try {
  Write-Host "[INFO] Checking for existing extension..." -ForegroundColor Cyan
  $existingResult = az vm extension show `
    --resource-group $VM_RG_NAME `
    --vm-name $VM_NAME `
    --name customScript `
    --output json 2>&1
  
  # Check if the command was successful
  if ($LASTEXITCODE -eq 0) {
    $existing = $existingResult | ConvertFrom-Json
    Write-Host "[INFO] Found existing extension with status: $($existing.provisioningState)" -ForegroundColor Cyan
  } else {
    Write-Host "[INFO] No existing extension found, will deploy new one" -ForegroundColor Cyan
  }
} catch {
  Write-Host "[INFO] Error checking extension state, assuming it doesn't exist: $($_.Exception.Message)" -ForegroundColor Yellow
  $existing = $null
}

# Safely access provisioningState without using the null-conditional operator
$status = if ($null -ne $existing) { $existing.provisioningState } else { $null }
if ($status -eq 'Failed' -and -not $Force) {
  Write-Host "[WARN] Extension is in a failed state. Use -Force to delete and redeploy." -ForegroundColor Yellow
  $confirm = Read-Host "Delete and redeploy extension? (y/N)"
  if ($confirm -ne 'y') { exit 1 }
}

# Always delete the existing extension if it exists before redeploying
if ($null -ne $existing) {
  Write-Host "[INFO] Deleting existing extension before redeploy..." -ForegroundColor Cyan
  try {
    az vm extension delete `
      --resource-group $VM_RG_NAME `
      --vm-name $VM_NAME `
      --name customScript | Out-Null
    Write-Host "[INFO] Successfully deleted existing extension" -ForegroundColor Green
  } catch {
    Write-Host "[WARN] Failed to delete extension, but continuing with deployment: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

# Redeploy the extension
Write-Host "[INFO] Redeploying CustomScript extension..." -ForegroundColor Cyan

# Create temporary files for settings and protected settings
$tempSettingsFile = [System.IO.Path]::GetTempFileName()
$tempProtectedFile = [System.IO.Path]::GetTempFileName()

try {
  # Convert settings and protected settings to JSON and save to temp files
  ConvertTo-Json $settings -Depth 5 | Out-File $tempSettingsFile -Encoding UTF8
  ConvertTo-Json $protected -Depth 5 | Out-File $tempProtectedFile -Encoding UTF8
  
  # Use the temp files with az cli
  # Note: For Linux VMs, use Microsoft.Azure.Extensions as the publisher
  az vm extension set `
    --name customScript `
    --publisher Microsoft.Azure.Extensions `
    --version 2.1 `
    --resource-group $VM_RG_NAME `
    --vm-name $VM_NAME `
    --force `
    --settings "@$tempSettingsFile" `
    --protected-settings "@$tempProtectedFile"
} 
finally {
  # Clean up temp files
  if (Test-Path $tempSettingsFile) { Remove-Item -Path $tempSettingsFile -Force }
  if (Test-Path $tempProtectedFile) { Remove-Item -Path $tempProtectedFile -Force }
}

Write-Host "[INFO] Extension redeploy complete. Check /lib/waagent/custom-script/handler.log on the VM for logs."

# Get VM public IP and output alias creation command
try {
  $vmInfo = az vm show --resource-group $VM_RG_NAME --name $VM_NAME --show-details --query "{name:name, publicIps:publicIps}" --output json | ConvertFrom-Json
    if ($vmInfo -and $vmInfo.publicIps) {
    Write-Host "`nTo create an easy-to-use alias for tunneling, add the following to your PowerShell profile:" -ForegroundColor Green
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkGray    $functionText = @"
function Create-Tunnel {
    param(
        [Parameter(Mandatory=`$true)][string]`$Subdomain,
        [Parameter(Mandatory=`$true)][int]`$LocalPort,
        [string]`$LocalHost = "localhost",
        [int]`$RemotePort = `$LocalPort + 6000,
        [switch]`$Force
    )
    
    `$domain = "$DNS_ZONE_NAME"
    `$user = "$ADMIN_USER"
    `$ip = "$($vmInfo.publicIps)"
    
    # Handle host key issues if requested via Force
    if (`$Force) {
        Write-Host "Removing previous host keys for `$ip..." -ForegroundColor Yellow
        ssh-keygen -R `$ip 2>&1 | Out-Null
    }
    
    # Create tunnel display string for output
    `$tunnelUrl = "https://`$Subdomain.tun.`$domain"
    `$localEndpoint = "`$LocalHost```:`$LocalPort"
    Write-Host "Creating tunnel: `$tunnelUrl -> `$localEndpoint" -ForegroundColor Cyan
    
    try {
        # Use StrictHostKeyChecking=accept-new to automatically add new host keys
        # This eliminates the "Host key verification failed" errors when VM is redeployed
        ssh -o "StrictHostKeyChecking=accept-new" -t -R `${RemotePort}```:`$LocalHost```:`$LocalPort `$user@`$ip /opt/sirtunnel/sirtunnel.py `$Subdomain.tun.`$domain `$RemotePort
    }
    catch {
        Write-Host "Error establishing tunnel: `$(`$_.Exception.Message)" -ForegroundColor Red
        Write-Host "If you're seeing host key verification errors, try using the -Force switch:" -ForegroundColor Yellow
        Write-Host "  tun `$Subdomain `$LocalPort -Force" -ForegroundColor Yellow
    }
}

Set-Alias -Name tun -Value Create-Tunnel
"@
    Write-Host $functionText -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "Usage examples:" -ForegroundColor Green
    Write-Host "tun api 3000                 # Exposes localhost:3000 as https://api.tun.$DNS_ZONE_NAME" -ForegroundColor Cyan
    Write-Host "tun dashboard 8080           # Exposes localhost:8080 as https://dashboard.tun.$DNS_ZONE_NAME" -ForegroundColor Cyan
    Write-Host "tun api 3000 192.168.1.10    # Exposes 192.168.1.10:3000 as https://api.tun.$DNS_ZONE_NAME" -ForegroundColor Cyan
  }
} catch {
  Write-Warning "Could not retrieve VM information for alias suggestion: $($_.Exception.Message)"
}
