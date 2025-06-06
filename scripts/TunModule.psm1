# SirTunnel PowerShell Module

# Import utility functions
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$utilsPath = Join-Path $scriptPath "utils.ps1"
if (Test-Path $utilsPath) {
    . $utilsPath
} else {
    Write-Error "Required utilities file not found at: $utilsPath"
    throw "Unable to load required utility functions"
}

# Function to create a new tunnel
function New-Tunnel {
    param(
        [Parameter(Mandatory=$true)][string]$Subdomain,
        [Parameter()][int]$LocalPort = 0,
        [string]$LocalHost = "localhost",
        [int]$RemotePort = 0,
        [switch]$Force,
        [string]$Ip = ""
    )

    # First try to get values from environment variables or config
    $config = Get-TunnelConfig
    $domain = $config.Domain
    $user = $config.AdminUser
    
    # Resolve the IP with fallback chain:
    # 1. If explicitly provided, use that
    # 2. If environment variable exists, use that
    # 3. If persisted state exists, use that
    # 4. Otherwise, error out
    if ($Ip) {
        $ip = $Ip
    } else {
        # Try environment variable first for backward compatibility
        $ip = "$env:LAST_TUNNEL_VM"
        
        # If not in env var, try to load from state file
        if (-not $ip) {
            $tunnelInfo = Get-TunnelInfo -Silent
            if ($tunnelInfo) {
                $ip = $tunnelInfo.vmIp
                # Optionally restore other settings if needed
                if (-not $user -and $tunnelInfo.user) { $user = $tunnelInfo.user }
                if (-not $domain -and $tunnelInfo.domain) {
                    # Extract domain from full domain (e.g., "api.tun.example.com" -> "example.com")
                    $domainParts = $tunnelInfo.domain.Split('.')
                    if ($domainParts.Length -ge 3) {
                        $domain = $domainParts[-2..-1] -join '.'
                    }
                }
            }
        }
        # If still no IP, we can't proceed
        if (-not $ip) {
            Write-Host "[ERR] No tunnel VM IP found. Cannot proceed." -ForegroundColor Red
            Write-Host "Either set the LAST_TUNNEL_VM environment variable or run redeploy-extension.ps1 first." -ForegroundColor Yellow
            return
        }    }    
    if ($Subdomain -eq "diag") {
        Write-Host "[*] Running diagnostics on $ip..." -ForegroundColor Cyan

        # Single line command with semicolons to avoid CRLF issues
        $logCommand = "echo '===== handler.log ====='; sudo tail -n 100 /log/azure/custom-script/handler.log || echo 'File not found'; " +
                      "echo ''; echo '===== stdout ====='; sudo tail -n 20 /var/lib/waagent/custom-script/download/0/stdout || echo 'File not found'; " +
                      "echo ''; echo '===== stderr ====='; sudo tail -n 20 /var/lib/waagent/custom-script/download/0/stderr || echo 'File not found'; " +
                      "echo ''; echo '===== caddy logs ====='; sudo journalctl -u caddy --no-pager -n 20 || echo 'Caddy logs not available'; " +
                      "echo ''; echo '===== sirtunnel service ====='; sudo systemctl status sirtunnel || echo 'SirTunnel status not available'; " +
                      "echo ''; echo '===== uptime/hostname ====='; uptime && hostname"


        ssh "$user@$ip" $logCommand
        return
    }
    
    if ($RemotePort -eq 0) {
        $RemotePort = $LocalPort + 6000
    }
    
    # Check if we have a known_hosts file with entries for this IP
    $knownHostsFile = "$HOME/.ssh/known_hosts"
    $hostKeyMayNeedReset = $false
    
    # Only do this check if the known_hosts file exists
    if (Test-Path $knownHostsFile) {
        $content = Get-Content $knownHostsFile -Raw -ErrorAction SilentlyContinue
        # Check if the IP is already in known_hosts
        if ($content -and $content -match [regex]::Escape($ip)) {
            # We found the IP in known_hosts
            $hostKeyMayNeedReset = $true
        }
    }
    
    # Handle host key verification based on Force flag or auto-detection
    if ($Force -or $hostKeyMayNeedReset) {
        Write-Host "Removing previous host keys for $ip..." -ForegroundColor Yellow
        try {
            ssh-keygen -R $ip 2>&1 | Out-Null
            # Also remove by IP address in case the hostname doesn't match
            if ($ip -match "\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b") {
                # This is an IP address, try to find any matching entries
                if (Test-Path $knownHostsFile) {
                    $content = Get-Content $knownHostsFile -Raw -ErrorAction SilentlyContinue
                    if ($content -and $content -match [regex]::Escape($ip)) {
                        Write-Host "IP address found in known_hosts, removing all matching entries..." -ForegroundColor Yellow
                        $newContent = ($content -split "`n") | Where-Object { $_ -notmatch [regex]::Escape($ip) }
                        $newContent | Set-Content $knownHostsFile -Force
                    }
                }
            }
        } catch {
            Write-Host "Warning: Error removing host key: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "Will continue with StrictHostKeyChecking=no" -ForegroundColor Yellow
        }
    }    $tunnelUrl = "https://$Subdomain.tun.$domain"
    $localEndpoint = "$LocalHost`:$LocalPort"
    Write-Host "Creating tunnel: $tunnelUrl -> $localEndpoint (remote port: $RemotePort)" -ForegroundColor Cyan
    
    try {
        # Use StrictHostKeyChecking=no if -Force is used or if we detected a potential host key issue
        # This provides more reliability by default without requiring users to remember the -Force flag
        $sshOptions = if ($Force -or $hostKeyMayNeedReset) {
            "-o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes"
        } else {
            "-o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes"
        }        # Use the constructed SSH options
        # Pass RemotePort as the second argument to match the actual listening port in the SSH tunnel
        Write-Verbose "Using remote port $RemotePort for the tunnel"
          # Use specific interface binding to ensure consistent networking between remote and local
        # This helps especially when the local service is only bound to 127.0.0.1
        Invoke-Expression "ssh $sshOptions -t -R 127.0.0.1:${RemotePort}:127.0.0.1:${LocalPort} ${user}@${ip} /opt/sirtunnel/sirtunnel.py $Subdomain.tun.$domain $RemotePort"
        $exitCode = $LASTEXITCODE
        
        # Verify SSH completed successfully
        if ($exitCode -ne 0) {
            Write-Host "[ERR] SSH tunnel failed with exit code $exitCode" -ForegroundColor Red
            return  # Do not proceed to save state
        }
        
        # Only on success, save tunnel info to persistent storage
        $tunnelInfo = @{
            domain = "$Subdomain.tun.$domain"
            localHost = $LocalHost
            localPort = $LocalPort
            remotePort = $RemotePort
            vmIp = $ip
            user = $user
            timestamp = (Get-Date).ToString("o")
        }
        
        # Save to persistent file and maintain env var for backward compatibility
        Save-TunnelInfo -Info $tunnelInfo
        $env:LAST_TUNNEL_VM = $ip          } catch {
        $errorMessage = $_.Exception.Message
        Write-Host "Error establishing tunnel: $errorMessage" -ForegroundColor Red
        
        # Provide specific guidance based on error type
        if ($errorMessage -match "Host key verification failed") {
            Write-Host "Host key verification failed. The VM's SSH key has likely changed." -ForegroundColor Yellow
            Write-Host "Try running the command again with the -Force parameter:" -ForegroundColor Yellow
            Write-Host "  tun $Subdomain $LocalPort -Force" -ForegroundColor Cyan
        } elseif ($errorMessage -match "Connection refused") {
            Write-Host "Connection refused. The VM might be down or the SSH service is not running." -ForegroundColor Yellow
            Write-Host "Try redeploying the VM extension:" -ForegroundColor Yellow
            Write-Host "  ./scripts/redeploy-extension.ps1 -Force" -ForegroundColor Cyan
        } elseif ($errorMessage -match "forward failed" -or $errorMessage -match "remote port forwarding failed") {
            Write-Host "Remote port forwarding failed. Port $RemotePort might already be in use on the server." -ForegroundColor Yellow
            Write-Host "Try a different port by explicitly specifying the remote port:" -ForegroundColor Yellow
            Write-Host "  tun $Subdomain $LocalPort -RemotePort $($RemotePort + 1)" -ForegroundColor Cyan
        } elseif ($errorMessage -match "Permission denied") {
            Write-Host "Permission denied. Check your SSH credentials or key." -ForegroundColor Yellow
            Write-Host "If using key authentication, ensure your key is properly configured." -ForegroundColor Yellow
        } else {
            Write-Host "Try using -Force to reset any SSH connection issues." -ForegroundColor Yellow
        }
    }
}

# Function to get the current configuration
function Get-TunnelConfig {
    $configPath = "$HOME/.tun/config.json"
    if (Test-Path $configPath) {
        return Get-Content $configPath | ConvertFrom-Json
    } else {
        # Default config with placeholders
        return @{
            Domain = "$env:DNS_ZONE_NAME"
            AdminUser = "$env:ADMIN_USER"
        }
    }
}

# Make sure Initialize-TunnelEnvironment is available in the module
# even if utils.ps1 was not loaded correctly
if (-not (Get-Command -Name Initialize-TunnelEnvironment -ErrorAction SilentlyContinue)) {
    function Initialize-TunnelEnvironment {
        # Create the .tun directory if it doesn't exist
        $tunDir = "$HOME/.tun"
        if (-not (Test-Path $tunDir)) { 
            New-Item -ItemType Directory -Path $tunDir -Force | Out-Null 
            Write-Host "[INFO] Created tunnel state directory at $tunDir" -ForegroundColor Green
        }
        return $tunDir
    }
}

# Export functions
Export-ModuleMember -Function New-Tunnel, Get-TunnelInfo, Show-Tunnels, Save-TunnelInfo, Get-TunnelConfig, Initialize-TunnelEnvironment
# Export aliases
New-Alias -Name tun -Value New-Tunnel -Force
New-Alias -Name tun-ls -Value Show-Tunnels -Force

# Create a script block for the diag command
$diagScript = {
    param($RemainderArgs)
    New-Tunnel -Subdomain "diag"
}

# Register the script as a named function
Set-Item -Path function:global:Invoke-TunnelDiag -Value $diagScript

# Export aliases
Export-ModuleMember -Alias tun, tun-ls
Export-ModuleMember -Function Invoke-TunnelDiag
New-Alias -Name tun-diag -Value Invoke-TunnelDiag -Force
Export-ModuleMember -Alias tun-diag
