# PowerShell script to prepare for deployment by updating Bicep files

# Source configuration variables
$configFile = Join-Path $PSScriptRoot "config.ps1"
if (Test-Path $configFile) {
    . $configFile
} else {
    Write-Error "Configuration file not found at $configFile. Please create it based on config.sample.ps1."
    exit 1
}

$bicepFile = Join-Path $PSScriptRoot "..\infra\main.bicep"

if (-not (Test-Path $bicepFile)) {
    Write-Error "Bicep file not found at: $bicepFile"
    exit 1
}

Write-Host "Preparing deployment files..." -ForegroundColor Cyan

# Update the GitHub repository reference in main.bicep
if ($GITHUB_REPO -eq "YOUR_USERNAME/YOUR_REPO") {
    Write-Host "GitHub repository in config.ps1 is not configured. Using local file upload instead." -ForegroundColor Yellow
    
    # Modify the main.bicep to use VM runCommand for script upload instead of GitHub
    $originalBicep = Get-Content $bicepFile -Raw
    
    # Check if the file needs updating
    if ($originalBicep -match "var githubRepo = 'YOUR_USERNAME/YOUR_REPO'") {
        Write-Host "Updating main.bicep to use direct file uploads instead of GitHub URLs..." -ForegroundColor Cyan
        
        # Find the VM Extension section and replace it
        $pattern = @"
// --- VM Extension for Setup ---
resource vmExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: virtualMachine
  name: 'installSirtunnelCaddy'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: \[
        'https://raw.githubusercontent.com/\$\{githubRepo\}/main/scripts/install.sh'
      \]
      commandToExecute: 'bash install.sh \$\{subscription\(\).subscriptionId\} \$\{dnsZoneResourceGroupName\}'
    \}
  \}
\}

// GitHub repository variable for install script URL
var githubRepo = 'YOUR_USERNAME/YOUR_REPO'  // REPLACE with your actual GitHub username/repo
"@

        $replacement = @"
// --- VM Custom Script Extension ---
resource runCommand 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: virtualMachine
  name: 'uploadScripts'
  location: location
  properties: {
    source: {
      script: '''
      # Create directory for scripts
      mkdir -p /tmp/sirtunnel-setup

      # Create install.sh
      cat > /tmp/sirtunnel-setup/install.sh << 'INSTALLSCRIPT'
$(Get-Content -Path "$PSScriptRoot\install.sh" -Raw)
INSTALLSCRIPT

      # Create sirtunnel.py
      cat > /tmp/sirtunnel-setup/sirtunnel.py << 'SIRTUNNELSCRIPT'
$(Get-Content -Path "$PSScriptRoot\sirtunnel.py" -Raw)
SIRTUNNELSCRIPT

      # Make them executable
      chmod +x /tmp/sirtunnel-setup/install.sh
      chmod +x /tmp/sirtunnel-setup/sirtunnel.py

      # Execute the installation script
      /tmp/sirtunnel-setup/install.sh ${subscription().subscriptionId} ${dnsZoneResourceGroupName} /tmp/sirtunnel-setup/sirtunnel.py
      '''
    }
    timeoutInSeconds: 600
    asyncExecution: false
  }
}
"@

        # Update the bicep file
        $newBicep = $originalBicep -replace [regex]::Escape($pattern), $replacement
        
        # Write the updated content back to the file
        Set-Content -Path $bicepFile -Value $newBicep
        
        Write-Host "Updated main.bicep to use direct file uploads" -ForegroundColor Green
    } else {
        Write-Host "main.bicep already updated or uses a different format" -ForegroundColor Yellow
    }
    
    # Update install.sh to support the local sirtunnel.py file path
    $installShPath = Join-Path $PSScriptRoot "install.sh"
    $installShContent = Get-Content $installShPath -Raw
    
    if ($installShContent -match "# Script arguments passed from Bicep VM Extension") {
    $updatedInstallSh = $installShContent -replace 'AZURE_RESOURCE_GROUP_NAME="\$2" # DNS Zone RG Name', @'
AZURE_RESOURCE_GROUP_NAME="$2" # DNS Zone RG Name
SIRTUNNEL_SCRIPT_PATH="$3" # Path to sirtunnel.py script (if provided)
'@

    $updatedInstallSh = $updatedInstallSh -replace '# Install SirTunnel script.*?sudo wget -O /usr/local/bin/sirtunnel\.py "\$SIRTUNNEL_URL"', @'
# Install SirTunnel script
echo "Installing SirTunnel script..."
if [ -n "$SIRTUNNEL_SCRIPT_PATH" ] && [ -f "$SIRTUNNEL_SCRIPT_PATH" ]; then
    echo "Using provided SirTunnel script at $SIRTUNNEL_SCRIPT_PATH"
    sudo cp "$SIRTUNNEL_SCRIPT_PATH" /usr/local/bin/sirtunnel.py
else
    echo "Downloading SirTunnel script from GitHub..."
    SIRTUNNEL_URL="https://raw.githubusercontent.com/anderspitman/SirTunnel/master/sirtunnel.py"
    sudo wget -O /usr/local/bin/sirtunnel.py "$SIRTUNNEL_URL"
fi
'@
        
        Set-Content -Path $installShPath -Value $updatedInstallSh
        Write-Host "Updated install.sh to support local sirtunnel.py" -ForegroundColor Green
    }

} else {
    # Update the GitHub repository in main.bicep
    $originalBicep = Get-Content $bicepFile -Raw
    if ($originalBicep -match "var githubRepo = 'YOUR_USERNAME/YOUR_REPO'") {
        $updatedBicep = $originalBicep -replace "var githubRepo = 'YOUR_USERNAME/YOUR_REPO'", "var githubRepo = '$GITHUB_REPO'"
        Set-Content -Path $bicepFile -Value $updatedBicep
        Write-Host "Updated GitHub repository in main.bicep to: $GITHUB_REPO" -ForegroundColor Green
    } else {
        Write-Host "GitHub repository already configured in main.bicep" -ForegroundColor Yellow
    }
}

Write-Host "`nDeployment files prepared successfully!" -ForegroundColor Green
Write-Host "Next step: Run .\scripts\deploy.ps1 to deploy SirTunnel" -ForegroundColor Yellow
