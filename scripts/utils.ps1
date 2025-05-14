# Utility functions for SirTunnel operations

# Function to check if the current session has SeSecurityPrivilege
function Test-SecurityPrivilege {
    try {
        $tempFile = [System.IO.Path]::GetTempFileName()
        $acl = Get-Acl $tempFile
        $acl.SetAccessRuleProtection($true, $false)
        Set-Acl $tempFile $acl
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        if ($_.Exception.Message -match "SeSecurityPrivilege") {
            return $false
        }
        # If the error is unrelated to security privileges, assume we have the privilege
        return $true
    }
}

# Create the base directory for SirTunnel
function Initialize-TunnelEnvironment {
    param (
        [switch]$SkipSecurePermissions
    )
    
    # Auto-detect if we should skip secure permissions
    if (-not $SkipSecurePermissions) {
        # Use the global Test-SecurityPrivilege function defined at the top of this file
        $hasPrivilege = Test-SecurityPrivilege
        if (-not $hasPrivilege) {
            $SkipSecurePermissions = $true
            Write-Verbose "Automatically skipping secure permissions due to lack of SeSecurityPrivilege"
        }
    }

    # Create the .tun directory if it doesn't exist
    $tunDir = "$HOME/.tun"
    if (-not (Test-Path $tunDir)) { 
        New-Item -ItemType Directory -Path $tunDir -Force | Out-Null 
        
        # Set appropriate permissions (Windows ACL) to ensure only the owner can access
        if (-not $SkipSecurePermissions) {
            try {
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
            } catch {
                Write-Host "[INFO] Created tunnel state directory at $tunDir (without secure permissions)" -ForegroundColor Yellow
                Write-Verbose "Could not set ACL permissions: $($_.Exception.Message)"
            }
        } else {
            Write-Host "[INFO] Created tunnel state directory at $tunDir (skipped secure permissions)" -ForegroundColor Yellow
        }
    }
    return $tunDir
}

# Function to save tunnel information to a JSON file
function Save-TunnelInfo {
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Info,
        
        [switch]$SkipSecurePermissions
    )
    
    # Before doing anything else, check if we have security privileges
    # This ensures we don't attempt operations that would fail
    if (-not $SkipSecurePermissions) {
        $SkipSecurePermissions = -not (Test-SecurityPrivilege)
    }
    
    # Create the .tun directory if it doesn't exist
    # Pass our updated SkipSecurePermissions value so we don't check twice
    $tunDir = Initialize-TunnelEnvironment -SkipSecurePermissions:$SkipSecurePermissions
    
    # Save the info to a JSON file
    try {
        $Info | ConvertTo-Json | Set-Content "$tunDir/last.json"
        
        # Only attempt to set file permissions if we have the privilege
        # This avoids the error completely rather than trying and catching
        if (-not $SkipSecurePermissions) {
            try {
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
                Write-Verbose "Secure permissions set on $tunDir/last.json"
            } catch {
                # This catch should never execute since we check for privileges beforehand
                # But keep it as a safeguard
                Write-Verbose "Could not set secure permissions on file: $($_.Exception.Message)"
            }
        } else {
            Write-Verbose "Skipping secure permissions for last.json due to lack of privileges"
        }
        
        Write-Verbose "Tunnel information saved to $tunDir/last.json"
    } catch {
        Write-Warning "Failed to save tunnel information: $($_.Exception.Message)"
    }
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
