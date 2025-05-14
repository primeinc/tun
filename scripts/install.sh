#!/bin/bash
set -euo pipefail
set -x  # Verbose for debug builds

# Constants
readonly caddyVersion="2.1.1"
readonly caddyGz="caddy_${caddyVersion}_linux_amd64.tar.gz"
readonly sirtunnel_app_dir="/opt/sirtunnel"
readonly caddy_config_dir="/etc/caddy"
readonly run_script="${sirtunnel_app_dir}/run_server.sh"
readonly service_file="/etc/systemd/system/sirtunnel.service"
readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[*] Starting SirTunnel Setup Script"

# 1. Require root privileges
if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Must be run as root." >&2
  exit 1
fi

# 2. Prepare directories
echo "[*] Creating application and configuration directories..."
install -d -m 755 "$sirtunnel_app_dir"
install -d -m 755 "$caddy_config_dir"

# 3. Install Caddy binary
echo "[*] Installing Caddy v${caddyVersion}..."
curl -fsSLO "https://github.com/caddyserver/caddy/releases/download/v${caddyVersion}/${caddyGz}"
tar -xf "$caddyGz"
rm -f "$caddyGz" LICENSE README.md
install -m 755 caddy /usr/local/bin/caddy
rm -f caddy
if ! setcap 'cap_net_bind_service=+ep' /usr/local/bin/caddy 2>/dev/null; then
  echo "[!] Warning: setcap failed. Caddy may need sudo to bind to ports <1024."
fi

# 4. Move application scripts
echo "[*] Deploying scripts..."
if [[ -f "${script_dir}/run_server.sh" ]]; then
  install -m 755 "${script_dir}/run_server.sh" "$run_script"
else
  echo "[!] Missing run_server.sh" >&2
  exit 2
fi

if [[ -f "${script_dir}/sirtunnel.py" ]]; then
  install -m 755 "${script_dir}/sirtunnel.py" "${sirtunnel_app_dir}/sirtunnel.py"
else
  echo "[!] Missing sirtunnel.py" >&2
  exit 3
fi

if [[ -f "${script_dir}/caddy_config.json" ]]; then
  cp "${script_dir}/caddy_config.json" "${caddy_config_dir}/caddy_config.json"
  if ! command -v jq >/dev/null; then
    echo "[!] jq is not installed. Cannot validate Caddy config." >&2
  else
    if ! jq empty "${caddy_config_dir}/caddy_config.json"; then
      echo "[!] Invalid JSON in caddy_config.json" >&2
      exit 4
    fi
  fi
else
  echo "[!] Missing caddy_config.json. Caddy may fail to start." >&2
fi

# 5. Set environment for Caddy (if needed for TLS)
export HOME=/root

# 6. Create systemd service
echo "[*] Creating systemd service..."
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

# 7. Reload and start the service
echo "[*] Enabling and starting sirtunnel..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable sirtunnel.service

if systemctl is-active --quiet sirtunnel.service; then
  systemctl restart sirtunnel.service
else
  systemctl start sirtunnel.service
fi

# 8. Show status and logs
echo "[*] Checking sirtunnel service status..."
systemctl status sirtunnel.service --no-pager || true
journalctl -u sirtunnel.service --no-pager -n 20 || true

echo "[*] SirTunnel setup completed successfully."
