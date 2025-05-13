#!/bin/bash
set -e
set -x # Enable command tracing

# Variables
caddyVersion=2.1.1
caddyGz="caddy_${caddyVersion}_linux_amd64.tar.gz"
sirtunnel_app_dir="/opt/sirtunnel"
caddy_config_dir="/etc/caddy"

echo "[*] SirTunnel Setup Script"

# Ensure script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "[!] This script must be run as root. Aborting." >&2
  exit 1
fi

echo "[*] Creating application and configuration directories..."
mkdir -p "${sirtunnel_app_dir}"
mkdir -p "${caddy_config_dir}"

# --- Caddy Installation ---
echo "[*] Downloading Caddy v${caddyVersion}..."
curl -s -O -L "https://github.com/caddyserver/caddy/releases/download/v${caddyVersion}/${caddyGz}"
tar xf "${caddyGz}"

echo "[*] Cleaning up Caddy archive and license files..."
rm -f "${caddyGz}" LICENSE README.md

echo "[*] Moving Caddy binary to /usr/local/bin/..."
mv caddy /usr/local/bin/
chmod +x /usr/local/bin/caddy

echo "[*] Enabling Caddy to bind to low ports..."
setcap 'cap_net_bind_service=+ep' /usr/local/bin/caddy

# --- Application Script and Config Deployment ---
echo "[*] Moving application scripts and Caddy config to their persistent locations..."

echo "[DEBUG] Listing files in current directory (pwd: $(pwd)) before moving:"
ls -la ./
echo "[DEBUG] Content of ./run_server.sh before move:"
cat ./run_server.sh || echo "[DEBUG] ./run_server.sh not found or cat failed"

if [ -f "./run_server.sh" ]; then
    mv ./run_server.sh "${sirtunnel_app_dir}/run_server.sh"
    chmod +x "${sirtunnel_app_dir}/run_server.sh"
    echo "    - Moved run_server.sh to ${sirtunnel_app_dir} and made executable."
    echo "[DEBUG] Content of ${sirtunnel_app_dir}/run_server.sh after move:"
    cat "${sirtunnel_app_dir}/run_server.sh" || echo "[DEBUG] cat ${sirtunnel_app_dir}/run_server.sh failed"
else
    echo "[!] run_server.sh not found in current directory. Skipping." >&2
fi

if [ -f "./sirtunnel.py" ]; then
    mv ./sirtunnel.py "${sirtunnel_app_dir}/sirtunnel.py"
    chmod +x "${sirtunnel_app_dir}/sirtunnel.py"
    echo "    - Moved sirtunnel.py to ${sirtunnel_app_dir} and made executable."
    echo "[DEBUG] Content of ${sirtunnel_app_dir}/sirtunnel.py after move:"
    cat "${sirtunnel_app_dir}/sirtunnel.py" || echo "[DEBUG] cat ${sirtunnel_app_dir}/sirtunnel.py failed"
else
    echo "[!] sirtunnel.py not found in current directory. Skipping." >&2
fi

if [ -f "./caddy_config.json" ]; then
    mv ./caddy_config.json "${caddy_config_dir}/caddy_config.json"
    echo "    - Moved caddy_config.json to ${caddy_config_dir}."
    echo "[DEBUG] Content of ${caddy_config_dir}/caddy_config.json after move:"
    cat "${caddy_config_dir}/caddy_config.json" || echo "[DEBUG] cat ${caddy_config_dir}/caddy_config.json failed"
else
    echo "[!] caddy_config.json not found in current directory. Caddy might not start correctly." >&2
fi

# Ensure HOME is defined (required for Caddy's config resolution, especially for TLS)
export HOME=/root
echo "[*] Set HOME to /root for Caddy."

echo "[*] Installation script finished."
echo "[DEBUG] install.sh finished. About to attempt execution of /opt/sirtunnel/run_server.sh via Bicep command."
