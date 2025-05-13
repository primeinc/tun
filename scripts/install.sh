#!/bin/bash
set -e

caddyVersion=2.1.1
caddyGz="caddy_${caddyVersion}_linux_amd64.tar.gz"

echo "[*] Downloading Caddy v$caddyVersion..."
curl -s -O -L "https://github.com/caddyserver/caddy/releases/download/v${caddyVersion}/${caddyGz}"
tar xf "${caddyGz}"

echo "[*] Cleaning up..."
rm -f "${caddyGz}" LICENSE README.md

echo "[*] Enabling Caddy to bind low ports..."
sudo setcap 'cap_net_bind_service=+ep' caddy

# Move Caddy binary to /usr/local/bin if needed
# sudo mv caddy /usr/local/bin/
# sudo chmod +x /usr/local/bin/caddy

# Ensure HOME is defined (required for config resolution)
export HOME=/root
