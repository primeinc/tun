# Import utility functions
$utilsPath = Join-Path $PSScriptRoot "utils.ps1"
if (Test-Path $utilsPath) {
    . $utilsPath
} else {
    Write-Error "Utils.ps1 not found at $utilsPath. Cannot proceed."
    exit 1
}

function New-Tunnel {
    param(
        [Parameter(Mandatory=$true)][string]$Subdomain,
        [Parameter()][int]$LocalPort = 0,
        [string]$LocalHost = "localhost",
        [int]$RemotePort = 0,
        [switch]$Force,
        [string]$Ip = ""
    )

    # First try to get values from environment variables
    $domain = "$env:DNS_ZONE_NAME"
    $user = "$env:ADMIN_USER"
    
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
        if (-not $ip) {            $tunnelInfo = Get-TunnelInfo -Silent
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
        }
    }

    if ($Subdomain -eq "diag") {
        Write-Host "[*] Running diagnostics on $ip..." -ForegroundColor Cyan

        $logCommand = @'
echo "===== handler.log ====="
sudo tail -n 50 /var/lib/waagent/custom-script/handler.log
echo ""
echo "===== stdout ====="
sudo tail -n 20 /var/lib/waagent/custom-script/download/0/stdout
echo ""
echo "===== stderr ====="
sudo tail -n 20 /var/lib/waagent/custom-script/download/0/stderr
echo ""
echo "===== uptime/hostname ====="
uptime && hostname
'@

        ssh "$user@$ip" "$logCommand"
        return
    }

    if ($RemotePort -eq 0) {
        $RemotePort = $LocalPort + 6000
    }

    if ($Force) {
        Write-Host "Removing previous host keys for $ip..." -ForegroundColor Yellow
        ssh-keygen -R $ip 2>&1 | Out-Null
    }

    $tunnelUrl = "https://$Subdomain.tun.$domain"
    $localEndpoint = "$LocalHost`:$LocalPort"
    Write-Host "Creating tunnel: $tunnelUrl -> $localEndpoint" -ForegroundColor Cyan    try {
        ssh -o "StrictHostKeyChecking=accept-new" -t -R "`$RemotePort```:`$LocalHost:$LocalPort" "$user@$ip" "/opt/sirtunnel/sirtunnel.py $Subdomain.tun.$domain $RemotePort"
        
        # Save successful tunnel info to persistent storage
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
        $env:LAST_TUNNEL_VM = $ip
        
    } catch {
        Write-Host "Error establishing tunnel: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Use -Force if host key mismatch is suspected." -ForegroundColor Yellow
    }
}

# Add an alias for the Show-Tunnels function from utils.ps1
Set-Alias -Name ls-tun -Value Show-Tunnels

Set-Alias -Name tun -Value New-Tunnel
