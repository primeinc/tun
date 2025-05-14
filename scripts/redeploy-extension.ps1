# Redeploy the CustomScript extension for SirTunnel on an existing VM, using config.ps1 for all values.
# This script does NOT touch the VM, network, or disks—just the extension layer.
# Usage: pwsh ./scripts/redeploy-extension.ps1 [-Force] [-DryRun]

param(
  [switch]$Force,
  [switch]$DryRun
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

# If this is a dry run, skip all Azure operations
if ($DryRun) {
  Write-Host "[DRY RUN] Skipping Azure operations. Will only set up local files." -ForegroundColor Yellow
} else {
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
if (-not $DryRun) {
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
} else {
  Write-Host "[DRY RUN] Skipping extension deployment" -ForegroundColor Yellow
}
}

Write-Host "[INFO] Extension redeploy complete. Check /lib/waagent/custom-script/handler.log on the VM for logs."

# Get VM public IP and output alias creation command
# Import utility functions for saving tunnel state
$utilsPath = Join-Path $PSScriptRoot "utils.ps1"
if (Test-Path $utilsPath) {
    . $utilsPath
} else {
    Write-Host "[WARN] Utils.ps1 not found. Tunnel state will not be persisted." -ForegroundColor Yellow
}

try {
  if ($DryRun) {
    # In dry-run mode, use example values for local development
    $vmInfo = [PSCustomObject]@{ 
      name = "VM_NAME_PLACEHOLDER"
      publicIps = "10.20.30.40"  # Placeholder IP for dry-run
    }
    Write-Host "[DRY RUN] Using placeholder VM IP: $($vmInfo.publicIps)" -ForegroundColor Yellow
  } else {
    # Get actual VM info from Azure
    $vmInfo = az vm show --resource-group $VM_RG_NAME --name $VM_NAME --show-details --query "{name:name, publicIps:publicIps}" --output json | ConvertFrom-Json
  }
    if ($vmInfo -and $vmInfo.publicIps) {
    # Save VM information to persistent storage if utils.ps1 is available
    if (Test-Path $utilsPath) {
        # Either load existing info or create new object        $tunnelInfo = if (Test-Path "$HOME/.tun/last.json") {
            Get-TunnelInfo -Silent
        } 
        
        if (-not $tunnelInfo) {
            $tunnelInfo = @{}
        }
        
        # Update or add properties
        $tunnelInfo = $tunnelInfo | Add-Member -NotePropertyName "vmIp" -NotePropertyValue $vmInfo.publicIps -Force -PassThru
        $tunnelInfo = $tunnelInfo | Add-Member -NotePropertyName "user" -NotePropertyValue $ADMIN_USER -Force -PassThru
        $tunnelInfo = $tunnelInfo | Add-Member -NotePropertyName "updated" -NotePropertyValue (Get-Date).ToString("o") -Force -PassThru
        
    # Save back to file
        Save-TunnelInfo -Info $tunnelInfo
        
        # Set environment variable for backward compatibility in current session
        $env:LAST_TUNNEL_VM = $vmInfo.publicIps
        
        Write-Host "`nVM IP saved to ~/.tun/last.json for use with 'tun' command" -ForegroundColor Green
    }
    
    # Copy the module files to the ~/.tun directory
    $tunDir = Initialize-TunnelEnvironment
    $modulePath = Join-Path $PSScriptRoot "TunModule.psm1"
    $utilsPath = Join-Path $PSScriptRoot "utils.ps1"
    
    if (Test-Path $modulePath) {
        Copy-Item -Path $modulePath -Destination "$tunDir/TunModule.psm1" -Force
        Copy-Item -Path $utilsPath -Destination "$tunDir/utils.ps1" -Force
        
        # Create a clean and minimal config file if it doesn't exist
        if (-not (Test-Path "$tunDir/config.json")) {
            @{
                Domain = "$DNS_ZONE_NAME"
                AdminUser = "$ADMIN_USER"
                LastVmIp = "$($vmInfo.publicIps)"
            } | ConvertTo-Json | Set-Content "$tunDir/config.json"
        } else {
            # Update existing config
            $config = Get-Content "$tunDir/config.json" | ConvertFrom-Json
            $config.LastVmIp = "$($vmInfo.publicIps)"
            $config | ConvertTo-Json | Set-Content "$tunDir/config.json"
        }
        
        Write-Host "`nTo use SirTunnel, add the following line to your PowerShell profile:" -ForegroundColor Green
        Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "Import-Module `"$tunDir/TunModule.psm1`"" -ForegroundColor Yellow
        Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkGray    } else {
        Write-Host "`nTo create an easy-to-use alias for tunneling, copy the TunModule.psm1 and utils.ps1 to ~/.tun/ manually:" -ForegroundColor Green
        Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "mkdir -Force ~/.tun" -ForegroundColor Yellow
        Write-Host "Copy-Item `"$PSScriptRoot/TunModule.psm1`" -Destination `"$HOME/.tun/`" -Force" -ForegroundColor Yellow  
        Write-Host "Copy-Item `"$PSScriptRoot/utils.ps1`" -Destination `"$HOME/.tun/`" -Force" -ForegroundColor Yellow
        Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkGray
        
        # Create a minimal config file for reference
        @{
            Domain = "$DNS_ZONE_NAME"
            AdminUser = "$ADMIN_USER"
            LastVmIp = "$($vmInfo.publicIps)"
        } | ConvertTo-Json | Out-File "$PSScriptRoot/config.example.json" -Force
        
        Write-Host "`nThen add this line to your PowerShell profile:" -ForegroundColor Green
        Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "Import-Module `"$HOME/.tun/TunModule.psm1`"" -ForegroundColor Yellow
        Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "Usage examples:" -ForegroundColor Green
        Write-Host "tun api 3000                 # Exposes localhost:3000 as https://api.tun.$DNS_ZONE_NAME" -ForegroundColor Cyan
        Write-Host "tun dashboard 8080           # Exposes localhost:8080 as https://dashboard.tun.$DNS_ZONE_NAME" -ForegroundColor Cyan
        Write-Host "tun api 3000 192.168.1.10    # Exposes 192.168.1.10:3000 as https://api.tun.$DNS_ZONE_NAME" -ForegroundColor Cyan
  }
} catch {
  Write-Warning "Could not retrieve VM information for alias suggestion: $($_.Exception.Message)"
}
