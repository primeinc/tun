<#
.SYNOPSIS
Redeploy the CustomScript extension for SirTunnel on an existing VM.

.DESCRIPTION
This script redeploys only the CustomScript extension—no changes to the VM, network, or disks.
It uses values from `config.ps1` and optionally persists tunnel metadata locally.
If tunnel files exist but cannot be persisted to your PowerShell profile, it prints a one-liner you can run.

.PARAMETER Force
Forces redeployment if extension is in a failed state.

.PARAMETER DryRun
Performs a dry run—no Azure operations, only local setup.

.PARAMETER IpOverride
Specifies a custom IP address to use instead of querying Azure or using a placeholder.

.EXAMPLE
.\redeploy-extension.ps1 -DryRun

.EXAMPLE
.\redeploy-extension.ps1 -DryRun -IpOverride "20.30.40.50"

.NOTES
Fails on unknown parameters. Requires AZ CLI and PowerShell 5+.
#>

[CmdletBinding()]
param(
  [switch]$Force,
  [switch]$DryRun,
  [string]$IpOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Fail fast if unknown parameters were passed (e.g., --DryRun instead of -DryRun)
$rawArgs = $MyInvocation.Line.Split() | Where-Object { $_ -like '--*' -or $_ -like '-*' }
$invalidArgs = $rawArgs | Where-Object {
  ($_ -notmatch '^-(Force|DryRun|IpOverride)$') -and ($_ -notmatch '^--(Force|DryRun|IpOverride)$')
}
if ($invalidArgs) {
  throw "Unknown parameter(s): $($invalidArgs -join ', '). Valid parameters: -Force, -DryRun, -IpOverride"
}

# Load deployment config
Write-Host "[DEBUG] Loading config from: $PSScriptRoot/config.ps1" -ForegroundColor Cyan
. "$PSScriptRoot/config.ps1"
Write-Host "[DEBUG] Config loaded, VM_RG_NAME: $VM_RG_NAME" -ForegroundColor Cyan

# Define VM_IP_OVERRIDE if it doesn't exist
if (-not (Get-Variable -Name VM_IP_OVERRIDE -ErrorAction SilentlyContinue)) {
  $VM_IP_OVERRIDE = $null
}

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

  $status = if ($null -ne $existing) { $existing.provisioningState } else { $null }
  if ($status -eq 'Failed' -and -not $Force) {
    Write-Host "[WARN] Extension is in a failed state. Use -Force to delete and redeploy." -ForegroundColor Yellow
    $confirm = Read-Host "Delete and redeploy extension? (y/N)"
    if ($confirm -ne 'y') { exit 1 }
  }

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

  Write-Host "[INFO] Redeploying CustomScript extension..." -ForegroundColor Cyan
  $tempSettingsFile = [System.IO.Path]::GetTempFileName()
  $tempProtectedFile = [System.IO.Path]::GetTempFileName()

  try {
    ConvertTo-Json $settings -Depth 5 | Out-File $tempSettingsFile -Encoding UTF8
    ConvertTo-Json $protected -Depth 5 | Out-File $tempProtectedFile -Encoding UTF8

    az vm extension set `
      --name customScript `
      --publisher Microsoft.Azure.Extensions `
      --version 2.1 `
      --resource-group $VM_RG_NAME `
      --vm-name $VM_NAME `
      --force `
      --settings "@$tempSettingsFile" `
      --protected-settings "@$tempProtectedFile"
  } finally {
    if (Test-Path $tempSettingsFile) { Remove-Item $tempSettingsFile -Force }
    if (Test-Path $tempProtectedFile) { Remove-Item $tempProtectedFile -Force }
  }

  Write-Host "[INFO] Extension redeploy complete. Check /lib/waagent/custom-script/handler.log on the VM for logs."
}

# Import tunnel utilities if available
$utilsPath = Join-Path $PSScriptRoot "utils.ps1"
if (Test-Path $utilsPath) {
  . $utilsPath
} else {
  Write-Host "[WARN] Utils.ps1 not found. Tunnel state will not be persisted." -ForegroundColor Yellow
}

try {
  # Determine the IP address to use in the following priority:
  # 1. IpOverride parameter (if provided)
  # 2. VM_IP_OVERRIDE from config.ps1 (if defined)
  # 3. Existing tunnel info (if available)
  # 4. Query Azure (if not DryRun)
  # 5. Use VM_NAME as fallback (if DryRun)
  
  $ipToUse = $null
  
  # Check command line override
  if ($IpOverride) {
    $ipToUse = $IpOverride
    Write-Host "[INFO] Using IP override from parameter: $ipToUse" -ForegroundColor Cyan
  }
  # Check config file override
  elseif ($VM_IP_OVERRIDE) {
    $ipToUse = $VM_IP_OVERRIDE
    Write-Host "[INFO] Using IP override from config: $ipToUse" -ForegroundColor Cyan
  }
  # Check existing tunnel info
  elseif (Test-Path "$HOME/.tun/last.json") { 
    $existingTunnelInfo = Get-TunnelInfo -Silent
    if ($existingTunnelInfo -and $existingTunnelInfo.vmIp) {
      $ipToUse = $existingTunnelInfo.vmIp
      if ($DryRun) {
        Write-Host "[DRY RUN] Using existing VM IP from tunnel info: $ipToUse" -ForegroundColor Yellow
      } else {
        Write-Host "[INFO] Found existing VM IP: $ipToUse" -ForegroundColor Cyan
      }
    }
  }
    # If we still don't have an IP and not in DryRun mode, query Azure
  if (-not $ipToUse -and -not $DryRun) {
    try {
      # First try to get the public IP from the VM's network interface
      $networkInterfaceId = az vm show --resource-group $VM_RG_NAME --name $VM_NAME --query "networkProfile.networkInterfaces[0].id" -o tsv
      if ($networkInterfaceId) {
        $publicIpId = az network nic show --ids $networkInterfaceId --query "ipConfigurations[0].publicIpAddress.id" -o tsv
        if ($publicIpId) {
          $publicIp = az network public-ip show --ids $publicIpId --query "ipAddress" -o tsv
          if ($publicIp) {
            $ipToUse = $publicIp
            Write-Host "[INFO] Retrieved VM IP from Azure: $ipToUse" -ForegroundColor Cyan
          }
        }
      }
      
      # Fallback to the old method if the above didn't work
      if (-not $ipToUse) {
        $vmInfo = az vm show --resource-group $VM_RG_NAME --name $VM_NAME --show-details --query "{name:name, publicIps:publicIps}" --output json | ConvertFrom-Json
        if ($vmInfo -and $vmInfo.publicIps) {
          $ipToUse = $vmInfo.publicIps
          Write-Host "[INFO] Retrieved VM IP from Azure: $ipToUse" -ForegroundColor Cyan
        } else {
          Write-Warning "Could not retrieve VM IP from Azure using show-details"
        }
      }
    } catch {
      Write-Warning "Error retrieving VM IP from Azure: $($_.Exception.Message)"
    }
    
    # Verify we got a valid IP address and not just the VM name
    if ($ipToUse -and $ipToUse -eq $VM_NAME) {
      Write-Warning "Retrieved IP matches VM name, which is likely incorrect"
      $ipToUse = $null
    }
    
    # If we still don't have an IP address, prompt the user
    if (-not $ipToUse) {
      Write-Host "[WARN] Could not automatically determine VM IP address" -ForegroundColor Yellow
      $ipToUse = Read-Host "Please enter the VM's public IP address"
    }
  }
  
  # Final fallback for DryRun mode
  if (-not $ipToUse -and $DryRun) {
    $ipToUse = $VM_NAME
    Write-Host "[DRY RUN] Using VM name as placeholder IP: $ipToUse" -ForegroundColor Yellow
    Write-Host "[TIP] To use a specific IP, add VM_IP_OVERRIDE='your.ip.address' to config.ps1" -ForegroundColor Yellow
    Write-Host "[TIP] Or use -IpOverride parameter: -DryRun -IpOverride '1.2.3.4'" -ForegroundColor Yellow
  }
  
  # Create the vmInfo object used by the rest of the script
  $vmInfo = [PSCustomObject]@{ 
    name = $VM_NAME
    publicIps = $ipToUse
  }

  if ($vmInfo -and $vmInfo.publicIps) {
    # Check for security privileges before doing anything else
    $hasSecurityPrivilege = $false
    if (Get-Command -Name Test-SecurityPrivilege -ErrorAction SilentlyContinue) {
      $hasSecurityPrivilege = Test-SecurityPrivilege
      if (-not $hasSecurityPrivilege) {
        Write-Host "[INFO] Running without security privileges - secure permissions will be skipped" -ForegroundColor Yellow
      }
    }
    
    # Initialize the tunnel directory with appropriate permissions
    $tunDir = Initialize-TunnelEnvironment -SkipSecurePermissions:(-not $hasSecurityPrivilege)
    $modulePath = Join-Path $PSScriptRoot "TunModule.psm1"

    if (Test-Path $utilsPath) {
      $tunnelInfo = if (Test-Path "$HOME/.tun/last.json") { Get-TunnelInfo -Silent } else { @{} }
      $tunnelInfo = $tunnelInfo | Add-Member -NotePropertyName "vmIp" -NotePropertyValue $vmInfo.publicIps -Force -PassThru
      $tunnelInfo = $tunnelInfo | Add-Member -NotePropertyName "user" -NotePropertyValue $ADMIN_USER -Force -PassThru
      $tunnelInfo = $tunnelInfo | Add-Member -NotePropertyName "updated" -NotePropertyValue (Get-Date).ToString("o") -Force -PassThru
      
      # Pass the security privilege information to Save-TunnelInfo
      Save-TunnelInfo -Info $tunnelInfo -SkipSecurePermissions:(-not $hasSecurityPrivilege)
      
      $env:LAST_TUNNEL_VM = $vmInfo.publicIps
    }

    # Copy module files with error handling and ensure they're always updated
    try {
      # Always update the module files to ensure latest version
      Write-Host "[INFO] Updating module files in $tunDir..." -ForegroundColor Cyan
      
      # Create backup of existing files before overwriting
      if (Test-Path "$tunDir/TunModule.psm1") {
        Copy-Item -Path "$tunDir/TunModule.psm1" -Destination "$tunDir/TunModule.psm1.bak" -Force -ErrorAction SilentlyContinue
      }
      if (Test-Path "$tunDir/utils.ps1") {
        Copy-Item -Path "$tunDir/utils.ps1" -Destination "$tunDir/utils.ps1.bak" -Force -ErrorAction SilentlyContinue
      }
      
      # Copy the updated files
      Copy-Item -Path $modulePath -Destination "$tunDir/TunModule.psm1" -Force
      Copy-Item -Path $utilsPath -Destination "$tunDir/utils.ps1" -Force
      
      Write-Host "[INFO] Module files successfully updated" -ForegroundColor Green
    } catch {
      Write-Warning "Could not update module files: $($_.Exception.Message)"
    }
    
    # Create or update tunnel config
    try {
      $configPath = "$tunDir/config.json"
      $config = if (Test-Path $configPath) { Get-Content $configPath | ConvertFrom-Json } else { @{} }
      $config.Domain = "$DNS_ZONE_NAME"
      $config.AdminUser = "$ADMIN_USER"
      $config.LastVmIp = "$($vmInfo.publicIps)"
      $config | ConvertTo-Json | Set-Content $configPath
    } catch {
      Write-Warning "Could not update config file: $($_.Exception.Message)"
    }

    # Attempt to append import line to profile
    $importLine = "Import-Module `"$tunDir/TunModule.psm1`""
    $profilePath = $PROFILE
    $profileUpdated = $false

    try {
      if (-not (Test-Path $profilePath)) {
        try {
          New-Item -ItemType File -Path $profilePath -Force | Out-Null
        } catch {
          Write-Warning "Could not create profile file: $($_.Exception.Message)"
        }
      }

      $profileContent = ''
      $canRead = $false
      try {
        $profileContent = Get-Content $profilePath -Raw
        $canRead = $true
      } catch {
        Write-Warning "Profile exists but cannot be read: $($_.Exception.Message)"
      }

      if (-not $canRead -or ($profileContent -notmatch [regex]::Escape($importLine))) {
        try {
          Add-Content -Path $profilePath -Value "`n$importLine"
          $profileUpdated = $true
          Write-Host "[INFO] Import-Module line added to PowerShell profile." -ForegroundColor Green
        } catch {
          Write-Warning "Profile write failed: $($_.Exception.Message)"
        }
      } else {
        Write-Host "[INFO] Import line already present in PowerShell profile." -ForegroundColor Yellow
        $profileUpdated = $true
      }

    } catch {
      Write-Warning "Could not configure PowerShell profile: $($_.Exception.Message)"
    }

    # Summary and Manual Fallback if Needed
    if (-not $profileUpdated) {
      Write-Host "`n[MANUAL FIX REQUIRED]" -ForegroundColor Magenta
      Write-Host "To enable 'tun' in future sessions, run this command once:" -ForegroundColor Green
      Write-Host "`n  Add-Content -Path `"$PROFILE`" -Value 'Import-Module `"$tunDir/TunModule.psm1`"'" -ForegroundColor Yellow
    }

    Write-Host "`n[SUMMARY]" -ForegroundColor Cyan
    Write-Host "Tunnel module path: $tunDir" -ForegroundColor DarkCyan
    Write-Host "VM IP: $($vmInfo.publicIps)" -ForegroundColor Cyan
    Write-Host "`nTo use SirTunnel immediately, run:" -ForegroundColor Green
    Write-Host "  Import-Module `"$tunDir/TunModule.psm1`"" -ForegroundColor Yellow
    Write-Host "`nExample commands:" -ForegroundColor Green
    Write-Host "  tun api 3000           → https://api.tun.$DNS_ZONE_NAME" -ForegroundColor Cyan
    Write-Host "  tun dashboard 8080     → https://dashboard.tun.$DNS_ZONE_NAME" -ForegroundColor Cyan
  }
} catch {
  if ($_.Exception.Message -match "SeSecurityPrivilege") {
    Write-Warning "Could not set security permissions. Try running with admin privileges or use regular permissions instead."
    Write-Warning "Original error: $($_.Exception.Message)"
  } else {
    Write-Warning "Could not retrieve or configure tunnel alias: $($_.Exception.Message)"
  }
}
