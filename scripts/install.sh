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

# 3. Install Python dependencies for SMTP sink
echo "[*] Installing Python dependencies..."
apt-get update
apt-get install -y python3 python3-pip

# Install from requirements file if it exists, otherwise install directly
if [[ -f "${script_dir}/requirements-smtp.txt" ]]; then
  echo "[*] Installing from requirements-smtp.txt..."
  pip3 install -r "${script_dir}/requirements-smtp.txt"
else
  echo "[*] Installing aiosmtpd directly..."
  pip3 install aiosmtpd==1.4.6
fi

# 4. Install Caddy binary
echo "[*] Installing Caddy v${caddyVersion}..."
curl -fsSLO "https://github.com/caddyserver/caddy/releases/download/v${caddyVersion}/${caddyGz}"
tar -xf "$caddyGz"
rm -f "$caddyGz" LICENSE README.md
install -m 755 caddy /usr/local/bin/caddy
rm -f caddy
if ! setcap 'cap_net_bind_service=+ep' /usr/local/bin/caddy 2>/dev/null; then
  echo "[!] Warning: setcap failed. Caddy may need sudo to bind to ports <1024."
fi

# 5. Move application scripts
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

# Deploy SMTP sink script
if [[ -f "${script_dir}/smtp_sink.py" ]]; then
  install -m 755 "${script_dir}/smtp_sink.py" "${sirtunnel_app_dir}/smtp_sink.py"
else
  echo "[!] Missing smtp_sink.py" >&2
fi

# 6. Set environment for Caddy (if needed for TLS)
export HOME=/root

# 7. Create systemd services
echo "[*] Creating systemd services..."
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

# Create SMTP sink service
smtp_service_file="/etc/systemd/system/smtpsink.service"
cat > "$smtp_service_file" <<EOF
[Unit]
Description=Temporary SMTP Sink Service
After=network.target

[Service]
Type=exec
ExecStart=/usr/bin/python3 ${sirtunnel_app_dir}/smtp_sink.py
Restart=on-failure
RestartSec=5
User=root
WorkingDirectory=$sirtunnel_app_dir

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
RestrictSUIDSGID=true

# Resource limits
LimitNOFILE=1024
MemoryLimit=512M
CPUQuota=50%

# Capability to bind to port 25
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

# 8. Reload and start the services
echo "[*] Enabling and starting services..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable sirtunnel.service
systemctl enable smtpsink.service

if systemctl is-active --quiet sirtunnel.service; then
  systemctl restart sirtunnel.service
else
  systemctl start sirtunnel.service
fi

if systemctl is-active --quiet smtpsink.service; then
  systemctl restart smtpsink.service
else
  systemctl start smtpsink.service
fi

# 9. Show status and logs
echo "[*] Checking service statuses..."
systemctl status sirtunnel.service --no-pager || true
journalctl -u sirtunnel.service --no-pager -n 20 || true

echo "[*] Checking SMTP sink service status..."
systemctl status smtpsink.service --no-pager || true
journalctl -u smtpsink.service --no-pager -n 10 || true

# 10. Block port 25 by default with iptables
echo "[*] Blocking port 25 by default (will be opened when tunnel is active)..."
iptables -I INPUT -p tcp --dport 25 -j DROP

echo "[*] SirTunnel and SMTP sink setup completed successfully."
