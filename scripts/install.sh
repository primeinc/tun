#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# Script arguments passed from Bicep VM Extension
AZURE_SUBSCRIPTION_ID="$1"
AZURE_RESOURCE_GROUP_NAME="$2" # DNS Zone RG Name
DNS_ZONE_NAME="$3" # DNS Zone Name

echo "Starting Caddy and SirTunnel installation..."
echo "Azure Subscription ID: ${AZURE_SUBSCRIPTION_ID}"
echo "Azure DNS Zone Resource Group: ${AZURE_RESOURCE_GROUP_NAME}"
echo "DNS Zone Name: ${DNS_ZONE_NAME}"

# Update package list and install dependencies
echo "Updating packages and installing dependencies..."
sudo apt-get update -y
sudo apt-get install -y curl wget gnupg apt-transport-https debian-keyring debian-archive-keyring python3 python3-pip

# Install Caddy using the official Cloudsmith repository
echo "Installing Caddy..."
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update -y
sudo apt-get install caddy -y

# Enable and start Caddy service
echo "Enabling and starting Caddy service..."
sudo systemctl enable --now caddy
sudo systemctl status caddy --no-pager

# Configure Caddy systemd service to include Azure environment variables for DNS plugin
# This allows Caddy to use Managed Identity for Azure DNS challenges
echo "Configuring Caddy service environment variables..."
SERVICE_FILE="/etc/systemd/system/caddy.service"
if [ -f "$SERVICE_FILE" ]; then
    # Check if Environment lines already exist to avoid duplicates
    if ! grep -q "Environment=AZURE_SUBSCRIPTION_ID=" "$SERVICE_FILE"; then
        sudo sed -i "/\[Service\]/a Environment=AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}" "$SERVICE_FILE"
    fi
    if ! grep -q "Environment=AZURE_RESOURCE_GROUP_NAME=" "$SERVICE_FILE"; then
        sudo sed -i "/\[Service\]/a Environment=AZURE_RESOURCE_GROUP_NAME=${AZURE_RESOURCE_GROUP_NAME}" "$SERVICE_FILE"
    fi
    sudo systemctl daemon-reload
    sudo systemctl restart caddy # Restart Caddy to apply environment variables
    echo "Caddy service environment variables configured and service restarted."
else
    echo "WARNING: Caddy service file not found at ${SERVICE_FILE}. Cannot set environment variables."
fi

# Install SirTunnel script
echo "Installing SirTunnel script..."
# Use the SirTunnel script from the same repository
SIRTUNNEL_URL="https://raw.githubusercontent.com/primeinc/tun/main/scripts/sirtunnel.py"
# Fallback to the original version if our enhanced version is not available
SIRTUNNEL_FALLBACK_URL="https://raw.githubusercontent.com/anderspitman/SirTunnel/master/sirtunnel.py"
echo "Downloading SirTunnel script from ${SIRTUNNEL_URL}..."
if ! sudo wget -O /usr/local/bin/sirtunnel.py "$SIRTUNNEL_URL"; then
    echo "Failed to download from primary source. Using fallback URL..."
    sudo wget -O /usr/local/bin/sirtunnel.py "$SIRTUNNEL_FALLBACK_URL"
fi
sudo chmod +x /usr/local/bin/sirtunnel.py
sudo ln -sf /usr/local/bin/sirtunnel.py /usr/local/bin/sirtunnel

# Verify server name in SirTunnel script
echo "Verifying Caddy server name in SirTunnel script..."
if grep -q "servers/srv0/routes" /usr/local/bin/sirtunnel.py; then
    echo "Updating server name in SirTunnel script from 'srv0' to 'sirtunnel'..."
    sudo sed -i 's|servers/srv0/routes|servers/sirtunnel/routes|g' /usr/local/bin/sirtunnel.py
fi

# Configure Caddy initial state via Admin API
echo "Configuring Caddy initial state via API..."
CADDY_CONFIG_JSON=$(cat <<EOF
{
  "admin": {
    "listen": "localhost:2019"
  },
  "logging": {
    "logs": {
      "default": {
        "level": "INFO"
      }
    }
  },
  "apps": {
    "http": {
      "servers": {
        "sirtunnel": {
          "listen": [":443"],
          "routes": []
        }
      }
    },
    "tls": {
      "automation": {
        "policies": [
          {
            "subjects": ["*.tun.$3"],
            "issuer": {
              "module": "acme"
            },
            "challenges": {
              "dns": {
                "provider": {
                  "name": "azure",
                  "subscription_id": "{env.AZURE_SUBSCRIPTION_ID}",
                  "resource_group_name": "{env.AZURE_RESOURCE_GROUP_NAME}"
                }
              }
            }
          }
        ]
      }
    }
  }
}
EOF
)

# Wait a moment for Caddy API to be ready after restart
sleep 5

# Load the initial configuration using curl to the admin API
curl -X POST "http://localhost:2019/load" \
  -H "Content-Type: application/json" \
  -d "${CADDY_CONFIG_JSON}" --fail --silent --show-error || \
  echo "Failed to load initial Caddy config via API. Check Caddy status and logs."

echo "Installation and initial configuration complete."
