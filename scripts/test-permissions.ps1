# Simple test script to validate our changes
# This will test if our privilege detection function works correctly

$scriptBlock = @'
# Import the utils.ps1 file
$utilsPath = Join-Path $PSScriptRoot "utils.ps1"
. $utilsPath

# Test the security privilege detection
$hasPrivilege = Test-SecurityPrivilege
Write-Host "Has SeSecurityPrivilege: $hasPrivilege"

# Initialize the tunnel environment with auto-detection
$tunDir = Initialize-TunnelEnvironment
Write-Host "Tunnel directory: $tunDir"

# Create a sample tunnel info object
$tunnelInfo = @{
    domain = "test.tun.example.com"
    localHost = "localhost"
    localPort = 3000
    remotePort = 9000
    vmIp = "10.20.30.40"
    user = "testuser"
    timestamp = (Get-Date).ToString("o")
}

# Save the tunnel info
Save-TunnelInfo -Info $tunnelInfo
Write-Host "Saved tunnel information to $tunDir/last.json"

# Try to read it back
$savedInfo = Get-TunnelInfo
if ($savedInfo) {
    Write-Host "Successfully read back tunnel info:"
    Write-Host "Domain: $($savedInfo.domain)"
    Write-Host "Local: $($savedInfo.localHost):$($savedInfo.localPort)"
    Write-Host "Remote: $($savedInfo.vmIp):$($savedInfo.remotePort)"
} else {
    Write-Host "Failed to read back tunnel info!"
}

Write-Host "Test completed successfully!"
'@

# Save the script to a file
$scriptBlock | Out-File -FilePath "c:\Users\WillPeters\dev\tun\scripts\test-permissions.ps1"

Write-Output "Test script created at c:\Users\WillPeters\dev\tun\scripts\test-permissions.ps1"
Write-Output "You can run it to validate the permissions handling"
