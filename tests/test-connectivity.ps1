# PowerShell script to test SirTunnel connectivity

param(
    [Parameter(Mandatory = $true)]
    [string]$Subdomain,
    
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = (Join-Path $PSScriptRoot "..\scripts\config.ps1")
)

# Source configuration if file exists
if (Test-Path $ConfigFile) {
    . $ConfigFile
} else {
    Write-Warning "Configuration file not found at $ConfigFile. Will use parameters only."
}

# Use DNS_ZONE_NAME from config or prompt for domain
if (-not $DNS_ZONE_NAME) {
    $DNS_ZONE_NAME = Read-Host -Prompt "Enter your base domain name (e.g. example.com)"
}

# Format the full domain name
$FullDomain = "$Subdomain.tun.$DNS_ZONE_NAME"

Write-Host "Testing connectivity to $FullDomain..." -ForegroundColor Cyan

# Test DNS resolution
Write-Host "Testing DNS resolution..." -ForegroundColor Yellow
try {
    $dnsResult = Resolve-DnsName -Name $FullDomain -Type A -ErrorAction Stop
    Write-Host "✓ DNS resolves to: $($dnsResult.IPAddress)" -ForegroundColor Green
} catch {
    Write-Host "✗ DNS resolution failed: $_" -ForegroundColor Red
    Write-Host "  Make sure the wildcard DNS record *.tun.$DNS_ZONE_NAME exists and points to your static IP" -ForegroundColor Yellow
    exit 1
}

# Test HTTPS connectivity
Write-Host "Testing HTTPS connectivity..." -ForegroundColor Yellow
try {
    # Skip certificate validation as we might hit this before the certificate is fully issued
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    
    $webRequest = Invoke-WebRequest -Uri "https://$FullDomain" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    
    Write-Host "✓ HTTPS connection succeeded with status code: $($webRequest.StatusCode)" -ForegroundColor Green
    
    # Check if we got a Caddy default page or error
    if ($webRequest.Content -match "Caddy" -or $webRequest.Content -match "404") {
        Write-Host "  Note: Received Caddy default page or error. This is expected if no active tunnel exists." -ForegroundColor Yellow
    }
} catch {
    Write-Host "✗ HTTPS connection failed: $_" -ForegroundColor Red
    
    if ($_.Exception.Message -match "certificate") {
        Write-Host "  Certificate issue detected. This may be normal if:" -ForegroundColor Yellow
        Write-Host "  - The tunnel was just set up and Let's Encrypt hasn't issued a certificate yet" -ForegroundColor Yellow
        Write-Host "  - There's an issue with the certificate issuance process" -ForegroundColor Yellow
    } elseif ($_.Exception.Message -match "timeout") {
        Write-Host "  Connection timed out. Make sure:" -ForegroundColor Yellow
        Write-Host "  - The VM is running" -ForegroundColor Yellow
        Write-Host "  - Port 443 is open in the Network Security Group" -ForegroundColor Yellow
        Write-Host "  - Caddy is running on the VM" -ForegroundColor Yellow
    }
} finally {
    # Reset certificate validation to default
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
}

Write-Host "`nTo start a tunnel using this subdomain, run:" -ForegroundColor Cyan
Write-Host "ssh -t -R 9001:localhost:3000 $ADMIN_USER@$($dnsResult.IPAddress) sirtunnel.py $FullDomain 9001" -ForegroundColor Yellow
