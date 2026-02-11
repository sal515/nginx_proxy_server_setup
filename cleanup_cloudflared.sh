#!/bin/bash

set -e

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "===================================================="
echo "Cloudflare Tunnel Cleanup Script"
echo "===================================================="
echo ""
echo -e "${RED}WARNING: This will completely remove all Cloudflare Tunnel configurations${NC}"
echo "This includes:"
echo "  - Tunnel service (systemd)"
echo "  - Cloudflared binary"
echo "  - Configuration files"
echo "  - Credentials"
echo "  - APT repository"
echo ""
read -p "Are you sure you want to continue? (type 'yes' to confirm): " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo "===================================================="
echo "Starting cleanup..."
echo "===================================================="
echo ""

# 1. Stop and uninstall service
echo "1. Stopping and uninstalling cloudflared service..."
if sudo systemctl is-active --quiet cloudflared 2>/dev/null; then
    sudo systemctl stop cloudflared
    echo "   ✓ Service stopped"
else
    echo "   ⊙ Service not running"
fi

if sudo systemctl is-enabled --quiet cloudflared 2>/dev/null; then
    sudo systemctl disable cloudflared
    echo "   ✓ Service disabled"
else
    echo "   ⊙ Service not enabled"
fi

# Try uninstall via cloudflared command
if command -v cloudflared >/dev/null 2>&1; then
    sudo cloudflared service uninstall 2>/dev/null || true
    echo "   ✓ Service uninstalled"
fi

# 2. Remove systemd service file
echo ""
echo "2. Removing systemd service files..."
if [[ -f /etc/systemd/system/cloudflared.service ]]; then
    sudo rm /etc/systemd/system/cloudflared.service
    echo "   ✓ Removed /etc/systemd/system/cloudflared.service"
fi

sudo systemctl daemon-reload 2>/dev/null || true

# 3. Remove APT repository
echo ""
echo "3. Removing APT repository..."
if [[ -f /etc/apt/sources.list.d/cloudflared.list ]]; then
    sudo rm /etc/apt/sources.list.d/cloudflared.list
    echo "   ✓ Removed /etc/apt/sources.list.d/cloudflared.list"
fi

if [[ -f /usr/share/keyrings/cloudflare-main.gpg ]]; then
    sudo rm /usr/share/keyrings/cloudflare-main.gpg
    echo "   ✓ Removed /usr/share/keyrings/cloudflare-main.gpg"
fi

# 4. Uninstall cloudflared package
echo ""
echo "4. Uninstalling cloudflared package..."
if command -v cloudflared >/dev/null 2>&1; then
    sudo apt-get remove -y cloudflared 2>/dev/null || true
    echo "   ✓ Cloudflared package removed"
fi

sudo apt-get update >/dev/null 2>&1 || true

# 5. Remove configuration files
echo ""
echo "5. Removing configuration files..."
if [[ -d /etc/cloudflared ]]; then
    sudo rm -rf /etc/cloudflared
    echo "   ✓ Removed /etc/cloudflared"
fi

# 6. Remove user credentials
echo ""
echo "6. Removing user credentials..."
if [[ -d ~/.cloudflared ]]; then
    echo -e "${YELLOW}   Note: Keeping ~/.cloudflared for potential recovery${NC}"
    echo "   To remove: rm -rf ~/.cloudflared"
else
    echo "   ⊙ ~/.cloudflared not found"
fi

# 7. Remove checkpoint file
echo ""
echo "7. Removing checkpoint file..."
if [[ -f ./cloudflared_setup_checkpoints.log ]]; then
    rm ./cloudflared_setup_checkpoints.log
    echo "   ✓ Removed ./cloudflared_setup_checkpoints.log"
fi

# 8. Summary
echo ""
echo "===================================================="
echo "✓ Cloudflare Tunnel Cleanup Complete!"
echo "===================================================="
echo ""
echo "What was removed:"
echo "  ✓ Cloudflared service"
echo "  ✓ Cloudflared binary"
echo "  ✓ Configuration files (/etc/cloudflared)"
echo "  ✓ APT repository and GPG key"
echo "  ✓ Checkpoint files"
echo ""
echo "What was NOT removed (for recovery):"
echo "  - ~/.cloudflared (tunnel credentials and certificates)"
echo ""
echo "To also remove credentials:"
echo "  rm -rf ~/.cloudflared"
echo ""
echo "To delete the tunnel from Cloudflare:"
echo "  cloudflared tunnel delete precisiontime-db"
echo ""
echo "===================================================="
