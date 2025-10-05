#!/bin/bash

set -e

SCRIPT_URL="https://raw.githubusercontent.com/softsweb/traefik-setup/main/scripts/traefik-setup.sh"
INSTALL_DIR="/tmp/traefik-setup"

echo "🚀 Traefik Automated Setup by SoftsWeb"
echo "======================================"
echo "• Traefik reverse proxy with HTTPS"
echo "• Optional test page (auto-removes in 10 min)" 
echo "• Let's Encrypt SSL certificates"
echo ""

# Create temp directory
mkdir -p "$INSTALL_DIR"

# Download the main script
echo "📥 Downloading setup script..."
curl -fsSL "$SCRIPT_URL" -o "$INSTALL_DIR/traefik-setup.sh"
chmod +x "$INSTALL_DIR/traefik-setup.sh"

# Run the setup script
sudo "$INSTALL_DIR/traefik-setup.sh"

# Cleanup
rm -rf "$INSTALL_DIR"