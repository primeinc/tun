#!/bin/bash
set -e
set -x  # Enable verbose tracing for debugging

# Constants
caddyVersion="2.1.1"
caddyGz="caddy_${caddyVersion}_linux_amd64.tar.gz"
sirtunnel_app_dir="/opt/sirtunnel"
caddy_config_dir="/etc/caddy"
run_script="${sirtunnel_app_dir}/run_server.sh"
service_file="/etc/systemd/system/sirtunnel.service"

echo "[*] Starting SirTunnel Setup Script"

# 1. Require root privileges
if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Must be run as root." >&2
  exit 1
fi

# 2. Prepare directories
echo "[*] Creating application and configuration directories..."
mkdir -p "$sirtunnel_app_dir"
mkdir -p "$caddy_config_dir"

# 3. Install Caddy binary
echo "[*] Installing Caddy v${caddyVersion}..."
curl -sSL -O "https://github.com/caddyserver/caddy/releases/download/v${caddyVersion}/${caddyGz}"
tar -xf "$caddyGz"
rm -f "$caddyGz" LICENSE README.md
mv caddy /usr/local/bin/
chmod +x /usr/local/bin/caddy
setcap 'cap_net_bind_service=+ep' /usr/local/bin/caddy

# 4. Move application scripts
echo "[*] Deploying scripts..."
if [ -f "./run_server.sh" ]; then
  mv ./run_server.sh "$run_script"
  chmod +x "$run_script"
else
  echo "[!] Missing run_server.sh" >&2
  exit 2
fi

if [ -f "./sirtunnel.py" ]; then
  mv ./sirtunnel.py "${sirtunnel_app_dir}/sirtunnel.py"
  chmod +x "${sirtunnel_app_dir}/sirtunnel.py"
else
  echo "[!] Missing sirtunnel.py" >&2
  exit 3
fi

if [ -f "./caddy_config.json" ]; then
  mv ./caddy_config.json "${caddy_config_dir}/caddy_config.json"
else
  echo "[!] Missing caddy_config.json. Caddy may fail to start." >&2
fi

# 5. Set environment for Caddy (in case TLS resolution needs HOME)
export HOME=/root

# 6. Create systemd service to run the tunnel in background
echo "[*] Creating systemd service for sirtunnel..."

cat > "$service_file" <<EOF
[Unit]
Description=SirTunnel Proxy Service
After=network.target

[Service]
ExecStart=$run_script
Restart=on-failure
User=root
WorkingDirectory=$sirtunnel_app_dir

[Install]
WantedBy=multi-user.target
EOF

# 7. Enable and start the service
echo "[*] Enabling and starting sirtunnel..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable sirtunnel.service
systemctl start sirtunnel.service

# 8. Check service status (optional: can be removed to avoid failing the script)
echo "[*] Verifying sirtunnel service status..."
systemctl status sirtunnel.service --no-pager || true

# 9. Final log and exit
echo "[*] SirTunnel setup completed. Service should be running in background."
exit 0
