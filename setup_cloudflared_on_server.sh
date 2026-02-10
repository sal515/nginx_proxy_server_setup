#!/bin/bash

set -e

# Checkpoint file to track completed steps
CHECKPOINT_FILE="./cloudflared_setup_checkpoints.log"
CONFIG_FILE="config_setup_nginx_proxy_server.conf"

# Cloudflare tunnel configuration (loaded from config file)
TUNNEL_NAME=""
TUNNEL_HOSTNAME=""
MYSQL_SERVER=""
MYSQL_PORT=""
CREDENTIALS_DIR="./cloudflared"
TUNNEL_CONFIG_FILE="$CREDENTIALS_DIR/config.yml"

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to mark checkpoint as complete
mark_checkpoint() {
    local step_name="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] COMPLETED: $step_name" | sudo tee -a "$CHECKPOINT_FILE" >/dev/null
    echo -e "${GREEN}✓ $step_name completed${NC}"
}

# Function to check if checkpoint exists
check_checkpoint() {
    local step_name="$1"
    if [[ -f "$CHECKPOINT_FILE" ]] && grep -q "COMPLETED: $step_name" "$CHECKPOINT_FILE"; then
        echo -e "${YELLOW}⊙ $step_name already completed (skipping)${NC}"
        return 0
    fi
    return 1
}

# Function to read config file
read_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        echo "✓ Configuration loaded from $CONFIG_FILE"
    else
        echo -e "${RED}ERROR: Config file $CONFIG_FILE not found!${NC}"
        exit 1
    fi
}

# Function to check OS compatibility
check_os() {
    if check_checkpoint "OS_CHECK"; then
        return 0
    fi

    echo "Checking OS compatibility..."
    case "$OSTYPE" in
    linux-gnu*)
        if [[ -f /etc/os-release ]]; then
            . /etc/os-release
            if [[ "$ID" != "ubuntu" ]]; then
                echo -e "${RED}Unsupported Linux distribution: $ID. Only Ubuntu is supported.${NC}"
                exit 1
            fi
            
            echo "✓ Ubuntu detected"
            echo "  Distribution: $NAME"
            echo "  Version: $VERSION_ID ($VERSION_CODENAME)"
            
            # Check for Ubuntu 22.04 (Jammy) - recommended version
            if [[ "$VERSION_ID" == "22.04" ]] && [[ "$VERSION_CODENAME" == "jammy" ]]; then
                echo -e "${GREEN}✓ Ubuntu 22.04 Jammy detected (recommended)${NC}"
            else
                echo -e "${YELLOW}⚠ Warning: This script is tested on Ubuntu 22.04 (Jammy Jellyfish)${NC}"
                echo -e "${YELLOW}  Your version: Ubuntu $VERSION_ID ($VERSION_CODENAME)${NC}"
                echo -e "${YELLOW}  Installation may still work but is not officially tested.${NC}"
                read -p "Continue anyway? (y/n): " continue_anyway
                if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
                    echo "Setup cancelled by user."
                    exit 0
                fi
            fi
        else
            echo -e "${RED}Cannot determine OS distribution. Only Ubuntu is supported.${NC}"
            exit 1
        fi
        ;;
    *)
        echo -e "${RED}Unsupported OS: $OSTYPE. Only Ubuntu is supported.${NC}"
        exit 1
        ;;
    esac

    mark_checkpoint "OS_CHECK"
}

# Function to install cloudflared
install_cloudflared() {
    if check_checkpoint "CLOUDFLARED_INSTALL"; then
        return 0
    fi

    echo "===================================================="
    echo "Installing Cloudflared..."
    echo "===================================================="

    if command -v cloudflared >/dev/null 2>&1; then
        echo "Cloudflared already installed: $(cloudflared --version)"
        mark_checkpoint "CLOUDFLARED_INSTALL"
        return 0
    fi

    # Add cloudflare gpg key
    sudo mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

    # Add repository to apt sources
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared jammy main' | sudo tee /etc/apt/sources.list.d/cloudflared.list

    # Update and install
    sudo apt-get update
    sudo apt-get install -y cloudflared

    # Verify installation
    if ! command -v cloudflared >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Cloudflared installation failed${NC}"
        exit 1
    fi

    echo "✓ Cloudflared installed: $(cloudflared --version)"
    mark_checkpoint "CLOUDFLARED_INSTALL"
}

# Function to authenticate with Cloudflare
authenticate_cloudflare() {
    if check_checkpoint "CLOUDFLARE_AUTH"; then
        return 0
    fi

    echo "===================================================="
    echo "Authenticating with Cloudflare..."
    echo "===================================================="

    # Check if already authenticated by looking for cert.pem
    if [[ -f "$HOME/.cloudflared/cert.pem" ]]; then
        echo "✓ Already authenticated (cert.pem exists)"
        mark_checkpoint "CLOUDFLARE_AUTH"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}IMPORTANT: A browser window will open for authentication.${NC}"
    echo -e "${YELLOW}If running on a headless server, you'll see a URL to copy.${NC}"
    echo -e "${YELLOW}Open that URL in a browser to complete authentication.${NC}"
    echo ""
    read -p "Press ENTER to continue..."

    # Run login command
    cloudflared tunnel login

    # Verify authentication
    if [[ ! -f "$HOME/.cloudflared/cert.pem" ]]; then
        echo -e "${RED}ERROR: Authentication failed. cert.pem not found.${NC}"
        exit 1
    fi

    echo "✓ Authentication successful"
    mark_checkpoint "CLOUDFLARE_AUTH"
}

# Function to create tunnel
create_tunnel() {
    if check_checkpoint "TUNNEL_CREATE"; then
        return 0
    fi

    echo "===================================================="
    echo "Creating Cloudflare Tunnel..."
    echo "===================================================="

    if [[ -z "$TUNNEL_NAME" ]]; then
        echo -e "${RED}ERROR: TUNNEL_NAME not set in config file${NC}"
        exit 1
    fi

    # Check if tunnel already exists
    if cloudflared tunnel list 2>/dev/null | grep -q "$TUNNEL_NAME"; then
        echo "✓ Tunnel '$TUNNEL_NAME' already exists"
        mark_checkpoint "TUNNEL_CREATE"
        return 0
    fi

    # Create the tunnel
    echo "Creating tunnel: $TUNNEL_NAME"
    cloudflared tunnel create "$TUNNEL_NAME"

    # Verify tunnel creation
    if ! cloudflared tunnel list 2>/dev/null | grep -q "$TUNNEL_NAME"; then
        echo -e "${RED}ERROR: Tunnel creation failed${NC}"
        exit 1
    fi

    echo "✓ Tunnel created successfully"
    echo ""
    echo "Tunnel details:"
    cloudflared tunnel list | grep "$TUNNEL_NAME"
    
    mark_checkpoint "TUNNEL_CREATE"
}

# Function to setup tunnel configuration
setup_tunnel_config() {
    if check_checkpoint "TUNNEL_CONFIG"; then
        return 0
    fi

    echo "===================================================="
    echo "Setting up tunnel configuration..."
    echo "===================================================="

    # Validate required config variables
    if [[ -z "$TUNNEL_NAME" ]] || [[ -z "$TUNNEL_HOSTNAME" ]] || [[ -z "$MYSQL_SERVER" ]] || [[ -z "$MYSQL_PORT" ]]; then
        echo -e "${RED}ERROR: Required config variables not set:${NC}"
        echo "  TUNNEL_NAME: $TUNNEL_NAME"
        echo "  TUNNEL_HOSTNAME: $TUNNEL_HOSTNAME"
        echo "  MYSQL_SERVER: $MYSQL_SERVER"
        echo "  MYSQL_PORT: $MYSQL_PORT"
        exit 1
    fi

    # Create cloudflared directory if it doesn't exist
    sudo mkdir -p "$CREDENTIALS_DIR"

    # Find the credentials file for this tunnel
    TUNNEL_UUID=$(cloudflared tunnel list 2>/dev/null | grep "$TUNNEL_NAME" | awk '{print $1}')
    if [[ -z "$TUNNEL_UUID" ]]; then
        echo -e "${RED}ERROR: Could not find tunnel UUID for $TUNNEL_NAME${NC}"
        exit 1
    fi

    # Locate credentials file in ~/.cloudflared/
    CREDENTIALS_FILE="$HOME/.cloudflared/$TUNNEL_UUID.json"
    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        echo -e "${RED}ERROR: Credentials file not found: $CREDENTIALS_FILE${NC}"
        exit 1
    fi

    # Copy credentials to /etc/cloudflared/
    TUNNEL_CREDENTIALS_FILE="$CREDENTIALS_DIR/${TUNNEL_NAME}.json"
    sudo cp "$CREDENTIALS_FILE" "$TUNNEL_CREDENTIALS_FILE"
    sudo chmod 600 "$TUNNEL_CREDENTIALS_FILE"

    # Create config.yml
    echo "Creating tunnel configuration file..."
    sudo tee "$TUNNEL_CONFIG_FILE" >/dev/null <<EOF
# ============================================================
# Cloudflare Tunnel Configuration
# Managed by: setup_cloudflared_on_server.sh
# Tunnel: $TUNNEL_NAME
# Backend Service: $MYSQL_SERVER:$MYSQL_PORT
# Public Hostname: $TUNNEL_HOSTNAME
# ============================================================

tunnel: $TUNNEL_NAME
credentials-file: $TUNNEL_CREDENTIALS_FILE

ingress:
  # Route traffic from public hostname to MySQL server
  - hostname: $TUNNEL_HOSTNAME
    service: tcp://$MYSQL_SERVER:$MYSQL_PORT
  
  # Catch-all rule (required)
  - service: http_status:404

# ============================================================
EOF

    sudo chmod 644 "$TUNNEL_CONFIG_FILE"

    echo "✓ Tunnel configuration created at $TUNNEL_CONFIG_FILE"
    echo ""
    echo "Configuration summary:"
    echo "  Tunnel Name: $TUNNEL_NAME"
    echo "  Tunnel UUID: $TUNNEL_UUID"
    echo "  Public Hostname: $TUNNEL_HOSTNAME"
    echo "  Backend MySQL Server: $MYSQL_SERVER:$MYSQL_PORT"
    echo "  Credentials: $TUNNEL_CREDENTIALS_FILE"
    
    mark_checkpoint "TUNNEL_CONFIG"
}

# Function to test tunnel (temporary run)
test_tunnel() {
    if check_checkpoint "TUNNEL_TEST"; then
        return 0
    fi

    echo "===================================================="
    echo "Testing tunnel (temporary run)..."
    echo "===================================================="
    echo ""
    echo -e "${YELLOW}The tunnel will start in test mode.${NC}"
    echo -e "${YELLOW}Press Ctrl+C to stop the test after verification.${NC}"
    echo ""
    read -p "Press ENTER to start test..."

    # Run tunnel in foreground
    echo "Starting tunnel: $TUNNEL_NAME"
    echo "Monitor the output for any errors..."
    echo ""
    
    cloudflared tunnel run "$TUNNEL_NAME" || true

    echo ""
    read -p "Did the tunnel start successfully? (y/n): " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        mark_checkpoint "TUNNEL_TEST"
        echo "✓ Tunnel test completed"
    else
        echo -e "${YELLOW}⚠ Tunnel test marked as incomplete. You can re-run this script to retry.${NC}"
    fi
}

# Function to install tunnel as service
install_tunnel_service() {
    if check_checkpoint "TUNNEL_SERVICE"; then
        return 0
    fi

    echo "===================================================="
    echo "Installing tunnel as systemd service..."
    echo "===================================================="

    # Install service
    sudo cloudflared service install

    # Enable and start service
    sudo systemctl enable cloudflared
    sudo systemctl start cloudflared

    # Verify service is running
    sleep 3
    if sudo systemctl is-active --quiet cloudflared; then
        echo "✓ Cloudflared service installed and running"
        sudo systemctl status cloudflared --no-pager
    else
        echo -e "${RED}ERROR: Cloudflared service failed to start${NC}"
        sudo systemctl status cloudflared --no-pager
        exit 1
    fi

    mark_checkpoint "TUNNEL_SERVICE"
}

# Function to show checkpoint status
show_checkpoint_status() {
    echo "===================================================="
    echo "Setup Checkpoint Status"
    echo "===================================================="
    
    if [[ ! -f "$CHECKPOINT_FILE" ]]; then
        echo "No checkpoints found. Setup not started."
        return
    fi

    echo ""
    cat "$CHECKPOINT_FILE"
    echo ""
}

# Main script execution
main() {
    echo "===================================================="
    echo "Cloudflare Tunnel Setup Script"
    echo "===================================================="
    echo ""

    # Show current checkpoint status
    show_checkpoint_status

    echo ""
    echo -e "${YELLOW}IMPORTANT: Ensure config file '$CONFIG_FILE' is updated with:${NC}"
    echo "  - TUNNEL_NAME (e.g., precisiontime-db)"
    echo "  - TUNNEL_HOSTNAME (e.g., proxy.precisiontime.ca)"
    echo "  - MYSQL_SERVER (e.g., 10.0.1.55)"
    echo "  - MYSQL_PORT (e.g., 3306)"
    echo ""
    read -p "Press ENTER to continue or Ctrl+C to abort..."
    echo ""

    # Execute setup steps
    check_os
    read_config
    install_cloudflared
    authenticate_cloudflare
    create_tunnel
    setup_tunnel_config
    test_tunnel

    echo ""
    read -p "Install tunnel as systemd service for automatic startup? (y/n): " install_service
    if [[ "$install_service" =~ ^[Yy]$ ]]; then
        install_tunnel_service
    fi

    echo ""
    echo "===================================================="
    echo "✓ Cloudflare Tunnel Setup Complete!"
    echo "===================================================="
    echo ""
    echo "Summary:"
    echo "  - Tunnel Name: $TUNNEL_NAME"
    echo "  - Public Hostname: $TUNNEL_HOSTNAME"
    echo "  - Backend MySQL Server: $MYSQL_SERVER:$MYSQL_PORT"
    echo "  - Config File: $TUNNEL_CONFIG_FILE"
    echo "  - Checkpoint File: $CHECKPOINT_FILE"
    echo ""
    echo "Next steps:"
    echo "  1. Configure DNS: Point $TUNNEL_HOSTNAME to tunnel (via Cloudflare dashboard)"
    echo "  2. Test connection: mysql -h $TUNNEL_HOSTNAME -P 3306 -u user -p"
    echo "  3. Monitor service: sudo systemctl status cloudflared"
    echo ""
    echo "To view checkpoint status: cat $CHECKPOINT_FILE"
    echo "To reset checkpoints: sudo rm $CHECKPOINT_FILE"
    echo "===================================================="
}

# Run main function
main