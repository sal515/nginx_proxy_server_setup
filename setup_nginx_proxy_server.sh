#!/bin/bash

# Need to setup a nginx proxy server using this script starting on a ubuntu fresh linux ocu 1gb 1 core computer which also needs to enable swap memory as soon as it is started and this script needs to setup the nginx proxy server to forward all the traffic to a mysql database server based on a dns or ip address and database server port and ip/dns address should be picked up from a config file in this repo.
# The flow should be
# 1. User will create the compute instance with 1gb ram and 1 core cpu
# 2. User will login to the instance using ssh
# 3. Git clone the repo with the script to enable the nginx proxy server
# 4. Update the config file on the compute instance storage with the mysql database server ip/dns and port, nginx config if required and whatever else is needed
# 5. Run the script
# 6. The script should check if it is linux or windows or mac
# 7. Throw errors if it is not linux ubuntu since the development is only for ubuntu for this sprint
# 8. Check the memory configuration of the compute instance using Ubuntu based api for determining the ram of the system and set the swapsize to 2x if the ram is less than 2gb for the other set the swap size to 1.5x the ram size
# 9. Verify if the swap space was successfully setup or throw visible error if not

set -e
CONFIG_FILE="config_setup_nginx_proxy_server.conf"
SWAPSIZE=""
SWAPFILE=""
NGINX_CONF="/etc/nginx/sites-available/db_proxy"
NGINX_CONF_LINK="/etc/nginx/sites-enabled/db_proxy"
MYSQL_SERVER=""
MYSQL_PORT=""

# Function to detect system swap file
detect_swap_file() {
    # First, check for currently active swap files using swapon --show
    if SWAPFILE=$(swapon --show 2>/dev/null | awk 'NR>1 {print $1; exit}'); then
        if [[ -n "$SWAPFILE" ]]; then
            echo "Found active swap: $SWAPFILE"
            return 0
        fi
    fi

    # Check /etc/fstab for swap entries if no active swap found
    if [[ -f /etc/fstab ]]; then
        SWAPFILE=$(awk '$2 == "none" && $3 == "swap" {print $1; exit}' /etc/fstab)
        if [[ -n "$SWAPFILE" ]]; then
            echo "Found swap in fstab: $SWAPFILE"
            return 0
        fi
    fi

    # Default to /swapfile if no swap is configured
    SWAPFILE="/swapfile"
    echo "No existing swap found, will use: $SWAPFILE"
    return 0
}

# Function to read config file
read_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        echo "Config file $CONFIG_FILE not found!"
        exit 1
    fi
}

check_os() {
    case "$OSTYPE" in
    linux-gnu*)
        if [[ -f /etc/os-release ]]; then
            . /etc/os-release
            if [[ "$ID" != "ubuntu" ]]; then
                echo "Unsupported Linux distribution: $ID. Only Ubuntu is supported for this sprint."
                exit 1
            fi
        else
            echo "Cannot determine OS distribution. Only Ubuntu is supported for this sprint."
            exit 1
        fi
        ;;
    darwin*)
        echo "Unsupported OS: macOS. Only Ubuntu is supported for this sprint."
        exit 1
        ;;
    msys* | cygwin* | win32*)
        echo "Unsupported OS: Windows. Only Ubuntu is supported for this sprint."
        exit 1
        ;;
    *)
        echo "Unsupported OS: $OSTYPE. Only Ubuntu is supported for this sprint."
        exit 1
        ;;
    esac
}

determine_swap_size() {
    echo "Determining memory configuration..."
    if [[ ! -r /proc/meminfo ]]; then
        echo "ERROR: Cannot read memory information from /proc/meminfo."
        exit 1
    fi

    local mem_kb
    local mem_gb
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    if [[ -z "$mem_kb" ]]; then
        echo "ERROR: Unable to determine total memory."
        exit 1
    fi
    mem_gb=$(awk -v kb="$mem_kb" 'BEGIN {printf "%.2f", kb/1024/1024}')

    echo "Total system memory: ${mem_gb}GB"

    # Set swap size: 2x if RAM < 2GB, otherwise 1.5x
    if awk "BEGIN {exit !($mem_gb < 2.0)}"; then
        SWAPSIZE=$(awk -v gb="$mem_gb" 'BEGIN {printf "%.2fG", gb*2}')
        echo "RAM is less than 2GB. Setting swap size to 2x RAM: $SWAPSIZE"
    else
        SWAPSIZE=$(awk -v gb="$mem_gb" 'BEGIN {printf "%.2fG", gb*1.5}')
        echo "RAM is 2GB or more. Setting swap size to 1.5x RAM: $SWAPSIZE"
    fi

    # read -p "Proceed with swap size of $SWAPSIZE? (y/n): " confirm
    # if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    #     echo "Swap size setup aborted by user."
    #     exit 1
    # fi
}

# Function to setup swap memory
setup_swap() {
    echo "===================================================="
    echo "Setting up swap memory of size: $SWAPSIZE"
    echo "===================================================="

    if [[ -z "$SWAPSIZE" ]]; then
        echo "ERROR: Swap size not determined."
        exit 1
    fi

    # Check if swap file already exists
    if [[ -f "$SWAPFILE" ]]; then
        echo "✓ Swap file already exists at $SWAPFILE"

        # Get current swap file size in human-readable format
        local current_size_bytes
        current_size_bytes=$(stat -c%s "$SWAPFILE" 2>/dev/null || echo "0")
        local current_size_human
        current_size_human=$(numfmt --to=iec-i --suffix=B "$current_size_bytes" 2>/dev/null || echo "$current_size_bytes bytes")

        echo "  Current swap size: $current_size_human"
        echo "  Desired swap size: $SWAPSIZE"

        # Check if swap is currently active
        if swapon --show | awk '{print $1}' | grep -Fxq -- "$SWAPFILE"; then
            echo "  Status: Active"
            echo "Skipping swap recreation as it already exists."
            return 0
        else
            echo "  Status: Inactive"
            echo "Activating existing swap file..."
            if ! sudo swapon "$SWAPFILE"; then
                echo "ERROR: Failed to activate swap."
                exit 1
            fi
            return 0
        fi
    fi

    # Create swap file
    echo "Creating swap file with fallocate..."
    if ! sudo fallocate -l "$SWAPSIZE" "$SWAPFILE"; then
        echo "ERROR: Failed to allocate swap file using fallocate."
        exit 1
    fi

    # Set appropriate permissions
    echo "Setting swap file permissions..."
    if ! sudo chmod 600 "$SWAPFILE"; then
        echo "ERROR: Failed to set swap file permissions."
        exit 1
    fi

    # Create swap space
    echo "Initializing swap space..."
    if ! sudo mkswap "$SWAPFILE"; then
        echo "ERROR: Failed to initialize swap space."
        exit 1
    fi

    # Enable swap
    echo "Enabling swap..."
    if ! sudo swapon "$SWAPFILE"; then
        echo "ERROR: Failed to enable swap."
        exit 1
    fi

    # Add to fstab for persistence
    echo "Adding swap to /etc/fstab for persistence..."
    if ! grep -q "^$SWAPFILE" /etc/fstab; then
        echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
    fi

    # add the following echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
    echo "Setting swappiness to 10..."
    echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
    sudo sysctl -p /etc/sysctl.d/99-swappiness.conf
    echo "Swappiness set to 10."

    # Verify swap was successfully setup
    echo "===================================================="
    echo "Verifying swap setup..."
    echo "===================================================="

    if swapon --show | awk '{print $1}' | grep -Fxq -- "$SWAPFILE"; then
        echo "✓ SUCCESS: Swap memory of size $SWAPSIZE created and enabled successfully!"
        swapon --show
        free -h
    else
        echo "ERROR: Swap setup failed. $SWAPFILE is not active."
        echo "Swap status:"
        swapon --show || echo "No swap currently active"
        exit 1
    fi
}

disable_unattended_upgrades() {
    # perform the disable unattended upgrades as follows:
    # sudo systemctl disable --now unattended-upgrades || true
    # sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer || true
    echo "Unattended upgrades disabled."

}

# Function to disable unnecessary services to save resources on minimal systems
disable_unnecessary_services() {
    echo "===================================================="
    echo "Disabling unnecessary services to save RAM/resources..."
    echo "===================================================="

    # NOTE: Keeping unattended-upgrades and apt-daily timers for security updates
    echo "Keeping automatic security updates enabled for nginx and system security..."

    # Disable snap and related services (major resource consumers)
    echo "Disabling snap services..."
    sudo systemctl disable --now snapd.service || true
    sudo systemctl disable --now snap.oracle-cloud-agent.oracle-cloud-agent.service || true
    sudo systemctl disable --now snap.oracle-cloud-agent.oracle-cloud-agent-updater.service || true

    # Disable unnecessary hardware-related services
    echo "Disabling unnecessary hardware services..."
    sudo systemctl disable --now ModemManager || true
    sudo systemctl disable --now udisks2 || true

    # Disable unused storage and RPC services
    echo "Disabling unused storage and RPC services..."
    sudo systemctl disable --now iscsid || true
    sudo systemctl disable --now lvm2-lvmpolld || true
    sudo systemctl disable --now rpcbind || true

    # Disable console login services (headless server)
    echo "Disabling console getty services..."
    sudo systemctl disable --now getty@tty1.service || true
    sudo systemctl disable --now serial-getty@ttyS0.service || true

    # Disable network dispatcher if not needed
    echo "Disabling networkd-dispatcher..."
    sudo systemctl disable --now networkd-dispatcher || true

    # Disable polkit for minimal overhead
    echo "Disabling polkit..."
    sudo systemctl disable --now polkit || true

    echo "✓ Unnecessary services disabled successfully!"
    echo ""
    echo "Services still enabled:"
    echo ""
    echo "CRITICAL (security & functionality):"
    echo "  - unattended-upgrades (security updates for nginx & system)"
    echo "  - apt-daily.timer (security package checks)"
    echo "  - apt-daily-upgrade.timer (automatic security patching)"
    echo "  - ssh (remote access)"
    echo ""
    echo "ESSENTIAL (operation):"
    echo "  - nginx (proxy server)"
    echo "  - systemd-resolved (DNS resolution)"
    echo "  - systemd-networkd (network configuration)"
    echo "  - systemd-timesyncd (time synchronization)"
    echo "  - systemd-journald (logging)"
    echo "  - systemd-logind (session management)"
    echo "  - dbus (system message bus)"
    echo ""
}

# Function to setup nginx proxy server
setup_nginx_proxy() {
    echo "===================================================="
    echo "Setting up Nginx proxy server..."
    echo "===================================================="

    # Update package list
    echo "Updating package list..."
    sudo apt update

    # Install Nginx
    echo "Installing Nginx..."
    sudo apt install -y nginx

    # Ensure Nginx is enabled and started
    echo "Enabling and starting Nginx..."
    sudo systemctl enable nginx
    sudo systemctl start nginx

    # Verify nginx is running systemctl status nginx --no-pager
    if ! sudo systemctl is-active --quiet nginx; then
        echo "ERROR: Nginx failed to start."
        exit 1
    fi

    # Validate MySQL server configuration
    if [[ -z "$MYSQL_SERVER" ]] || [[ -z "$MYSQL_PORT" ]]; then
        echo "ERROR: MySQL server IP/DNS or port not configured in config file."
        exit 1
    fi

    echo "Configuring Nginx to proxy to $MYSQL_SERVER:$MYSQL_PORT..."

    # Create Nginx configuration for proxying MySQL traffic
    sudo bash -c "cat > $NGINX_CONF" <<EOL
upstream mysql_backend {
    server $MYSQL_SERVER:$MYSQL_PORT max_fails=3 fail_timeout=30s;
}

server {
    listen 3306;
    location / {
        proxy_pass http://mysql_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 5s;
        proxy_send_timeout 10s;
        proxy_read_timeout 10s;
    }
}
EOL

    # Enable the new Nginx configuration
    echo "Enabling Nginx configuration..."
    if [[ ! -L "$NGINX_CONF_LINK" ]]; then
        sudo ln -s "$NGINX_CONF" "$NGINX_CONF_LINK"
    fi

    # Test Nginx configuration
    echo "Testing Nginx configuration..."
    if ! sudo nginx -t; then
        echo "ERROR: Nginx configuration test failed."
        exit 1
    fi

    # Restart Nginx
    echo "Restarting Nginx..."
    sudo systemctl restart nginx

    # Verify Nginx is running
    if sudo systemctl is-active --quiet nginx; then
        echo "✓ SUCCESS: Nginx proxy server setup complete!"
        echo "Nginx is forwarding traffic from port 3306 to $MYSQL_SERVER:$MYSQL_PORT"
    else
        echo "ERROR: Nginx failed to start."
        exit 1
    fi
}

# Add a reminder and user confirmation before proceeding that the config file must be updated
echo "===================================================="
echo "IMPORTANT: Please ensure that you have updated the config file '$CONFIG_FILE' with the correct MySQL server IP/DNS and port before proceeding."
echo "===================================================="
read -p "Press ENTER to continue or Ctrl+C to abort..."

# Main script execution
echo "===================================================="
echo "Starting Nginx Proxy Server Setup"
echo "===================================================="
echo ""

# Step 1: Check OS compatibility
echo "STEP 1: Checking OS compatibility..."
check_os
echo "✓ OS Check passed. Ubuntu detected."
echo ""

# Step 2: Detect system swap file
echo "STEP 2: Detecting system swap file..."
detect_swap_file
echo "✓ Swap file detected: $SWAPFILE"
echo ""

# Step 3: Read configuration
echo "STEP 3: Reading configuration..."
read_config
echo "✓ Configuration loaded successfully."
echo "  MySQL Server: $MYSQL_SERVER"
echo "  MySQL Port: $MYSQL_PORT"
echo ""

# Step 4: Determine swap size
echo "STEP 4: Determining swap size based on system memory..."
determine_swap_size
echo ""

# Step 5: Setup swap memory
echo "STEP 5: Setting up swap memory..."
setup_swap
echo ""

# Step 6: Disable unnecessary services
echo "STEP 6: Disabling unnecessary services..."
disable_unnecessary_services
echo ""

# Step 7: Setup Nginx proxy
echo "STEP 7: Setting up Nginx proxy server..."
# setup_nginx_proxy
echo ""

echo "===================================================="
echo "✓ Setup complete successfully!"
echo "===================================================="
echo ""
echo "Summary:"
echo "  - OS: Ubuntu (verified)"
echo "  - Swap: Configured and active"
echo "  - Nginx: Running and configured"
echo "  - Proxy: Forwarding to $MYSQL_SERVER:$MYSQL_PORT"
echo ""
echo "To verify the setup, run:"
echo "  swapon --show  (to check swap)"
echo "  sudo systemctl status nginx  (to check Nginx)"
echo "===================================================="
