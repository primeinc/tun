#!/bin/bash
set -e

export HOME=/root
CADDY_CONFIG="./caddy_config.json"

# Ensure config exists
if [[ ! -f "$CADDY_CONFIG" ]]; then
  echo "[ERROR] Config file '$CADDY_CONFIG' not found!"
  exit 1
fi

# Kill any existing Caddy instance
if pgrep -x caddy >/dev/null; then
  echo "[*] Killing existing Caddy instance..."
  pkill -f caddy
  sleep 2
fi

# Start in background
echo "[*] Starting Caddy with config $CADDY_CONFIG..."
nohup caddy run --config "$CADDY_CONFIG" --adapter json > /var/log/caddy.log 2>&1 &
