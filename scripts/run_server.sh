#!/bin/bash
set -e
set -x  # Enable verbose tracing for debugging

echo "[*] script run_server.sh started"

# Check if Caddy is already running
if pgrep -x "caddy" > /dev/null; then
    echo "[*] Caddy server is already running. Reusing existing instance."
else
    echo "[*] Starting Caddy server..."
    # Start Caddy in the background
    /usr/local/bin/caddy run --config /etc/caddy/caddy_config.json &
    # Wait a moment for Caddy to initialize
    sleep 2
    # Check if Caddy started successfully
    if pgrep -x "caddy" > /dev/null; then
        echo "[+] Caddy server started successfully"
    else
        echo "[-] Failed to start Caddy server"
        exit 1
    fi
fi

# Keep the script running to maintain the service
echo "[*] SirTunnel service is now running. Press Ctrl+C to stop."
# Use tail -f /dev/null as a simple way to keep the script running indefinitely
# This ensures the systemd service stays active
tail -f /dev/null

echo "[*] script run_server.sh completed"