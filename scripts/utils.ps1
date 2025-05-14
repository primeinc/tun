# Utility functions for SirTunnel operations

# Create the base directory for SirTunnel
function Initialize-TunnelEnvironment {
    # Create the .tun directory if it doesn't exist
    $tunDir = "$HOME/.tun"
    if (-not (Test-Path $tunDir)) { 
        New-Item -ItemType Directory -Path $tunDir -Force | Out-Null 
        
        # Set appropriate permissions (Windows ACL) to ensure only the owner can access
        $acl = Get-Acl $tunDir
        $acl.SetAccessRuleProtection($true, $false)  # Disable inheritance, remove inherited permissions
        $ownerRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            "FullControl",
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )
        $acl.AddAccessRule($ownerRule)
        Set-Acl $tunDir $acl
        
        Write-Host "[INFO] Created secure tunnel state directory at $tunDir" -ForegroundColor Green
    }
    return $tunDir
}

# Function to save tunnel information to a JSON file
function Save-TunnelInfo {
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Info
    )
    
    # Create the .tun directory if it doesn't exist
    $tunDir = "$HOME/.tun"
    if (-not (Test-Path $tunDir)) { 
        New-Item -ItemType Directory -Path $tunDir -Force | Out-Null 
        
        # Set appropriate permissions (Windows ACL) to ensure only the owner can access
        $acl = Get-Acl $tunDir
        $acl.SetAccessRuleProtection($true, $false)  # Disable inheritance, remove inherited permissions
        $ownerRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            "FullControl",
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )
        $acl.AddAccessRule($ownerRule)
        Set-Acl $tunDir $acl
        
        Write-Host "[INFO] Created secure tunnel state directory at $tunDir" -ForegroundColor Green
    }
    
    # Save the info to a JSON file
    $Info | ConvertTo-Json | Set-Content "$tunDir/last.json"
    
    # Set appropriate file permissions
    $fileAcl = Get-Acl "$tunDir/last.json"
    $fileAcl.SetAccessRuleProtection($true, $false)  # Disable inheritance, remove inherited permissions
    $fileOwnerRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        "FullControl",
        "None",
        "None",
        "Allow"
    )
    $fileAcl.AddAccessRule($fileOwnerRule)
    Set-Acl "$tunDir/last.json" $fileAcl
    
    Write-Verbose "Tunnel information saved to $tunDir/last.json"
}

# Function to load tunnel information from a JSON file
function Get-TunnelInfo {
    param (
        [switch]$Silent
    )
    
    $path = "$HOME/.tun/last.json"
    if (Test-Path $path) {
        try {
            $tunnelInfo = Get-Content $path -Raw | ConvertFrom-Json
            return $tunnelInfo
        }
        catch {
            if (-not $Silent) {
                Write-Host "[ERR] Failed to load tunnel info: $($_.Exception.Message)" -ForegroundColor Red
            }
            return $null
        }
    } else {
        if (-not $Silent) {
            Write-Host "[ERR] No tunnel info found at $path. Run 'tun' first." -ForegroundColor Red
        }
        return $null
    }
}

# Function to list saved tunnel information
function Show-Tunnels {
    $tunDir = "$HOME/.tun"
    if (-not (Test-Path $tunDir)) {
        Write-Host "No tunnels have been created yet." -ForegroundColor Yellow
        return
    }

    $tunnelInfo = Get-TunnelInfo -Silent
    if ($tunnelInfo) {
        Write-Host "`nActive tunnel:" -ForegroundColor Cyan
        Write-Host "  URL:        https://$($tunnelInfo.domain)" -ForegroundColor White
        Write-Host "  Local:      $($tunnelInfo.localHost):$($tunnelInfo.localPort)" -ForegroundColor White
        Write-Host "  Remote:     $($tunnelInfo.vmIp):$($tunnelInfo.remotePort)" -ForegroundColor White
        Write-Host "  Created:    $($tunnelInfo.timestamp)" -ForegroundColor White
        
        # You could also add here code to scan multiple JSON files if you decide to keep history
    } else {
        Write-Host "No active tunnel information found." -ForegroundColor Yellow
    }
}

# Only export functions if this script is being imported as a module
# This avoids the "Export-ModuleMember can only be called from inside a module" error
# when the script is dot-sourced directly
if ($MyInvocation.Line -match 'Import-Module') {
    Export-ModuleMember -Function Save-TunnelInfo, Get-TunnelInfo, Show-Tunnels
}
