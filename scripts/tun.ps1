function Create-Tunnel {
    param(
        [Parameter(Mandatory=$true)][string]$Subdomain,
        [Parameter()][int]$LocalPort = 0,
        [string]$LocalHost = "localhost",
        [int]$RemotePort = 0,
        [switch]$Force
    )

    $domain = "$env:DNS_ZONE_NAME"
    $user = "$env:ADMIN_USER"
    $ip = "$env:LAST_TUNNEL_VM"

    if (-not $ip) {
        Write-Host "[ERR] LAST_TUNNEL_VM env var not set. Cannot proceed." -ForegroundColor Red
        return
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
    Write-Host "Creating tunnel: $tunnelUrl -> $localEndpoint" -ForegroundColor Cyan

    try {
        ssh -o "StrictHostKeyChecking=accept-new" -t -R "`$RemotePort```:`$LocalHost:$LocalPort" "$user@$ip" "/opt/sirtunnel/sirtunnel.py $Subdomain.tun.$domain $RemotePort"
    } catch {
        Write-Host "Error establishing tunnel: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Use -Force if host key mismatch is suspected." -ForegroundColor Yellow
    }
}

Set-Alias -Name tun -Value Create-Tunnel
