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
# Nginx stream (TCP) config path for MySQL proxy
# Using stream.d so we don't touch HTTP server files
NGINX_STREAM_CONF=""
MYSQL_SERVER=""
MYSQL_PORT=""
LISTEN_PORT=""
UPSTREAM_NAME=""
PROXY_CONFIG_FILE=""
PROXY_CONNECT_TIMEOUT=""
PROXY_TIMEOUT=""
UPSTREAM_KEEPALIVE=""
UPSTREAM_MAX_FAILS=""
UPSTREAM_FAIL_TIMEOUT=""

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

# Function to allow MySQL port via iptables (OCI images prefer iptables)
setup_iptables_mysql_port() {
    echo "===================================================="
    echo "Configuring iptables to allow configured TCP port..."
    echo "===================================================="

    if ! command -v iptables >/dev/null 2>&1; then
        echo "ERROR: iptables is not available on this system."
        exit 1
    fi

    # Determine desired port from config: prefer LISTEN_PORT, fallback to MYSQL_PORT
    local port
    if [[ -n "$LISTEN_PORT" ]]; then
        port="$LISTEN_PORT"
    elif [[ -n "$MYSQL_PORT" ]]; then
        port="$MYSQL_PORT"
        echo "NOTE: LISTEN_PORT not set; using MYSQL_PORT=$MYSQL_PORT"
    else
        echo "ERROR: No port configured. Set LISTEN_PORT (preferred) or MYSQL_PORT in $CONFIG_FILE."
        exit 1
    fi

    # Validate port is numeric and within range
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        echo "ERROR: Invalid port '$port'. Must be an integer between 1 and 65535."
        exit 1
    fi

    # Add IPv4 rule only if not already present
    if sudo iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
        echo "IPv4 rule already present: ACCEPT tcp dport $port"
    else
        echo "Adding IPv4 rule: ACCEPT tcp dport $port on INPUT chain..."
        sudo iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
    fi

    # Add IPv6 rule if ip6tables exists
    if command -v ip6tables >/dev/null 2>&1; then
        if sudo ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            echo "IPv6 rule already present: ACCEPT tcp dport $port"
        else
            echo "Adding IPv6 rule: ACCEPT tcp dport $port on INPUT chain..."
            sudo ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT
        fi
    fi

    # Persist rules only if /etc/iptables/rules.v4 exists; otherwise warn and exit
    echo "Preparing to persist iptables rules..."
    if [[ -f /etc/iptables/rules.v4 ]]; then
        echo "Updating /etc/iptables/rules.v4 with current rules..."
        sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
        # Optionally update IPv6 persistence if rules.v6 exists
        if [[ -f /etc/iptables/rules.v6 ]] && command -v ip6tables >/dev/null 2>&1; then
            echo "Updating /etc/iptables/rules.v6 with current IPv6 rules..."
            sudo ip6tables-save | sudo tee /etc/iptables/rules.v6 >/dev/null
        fi
        echo "✓ Persistence updated."
    else
        echo "WARNING: /etc/iptables/rules.v4 not found. Persistence is not configured on this system."
        echo "Please ensure iptables-persistent is installed and rules.v4 exists before running this setup."
        read -p "Press ENTER to acknowledge this warning. The setup will now quit." _ack
        exit 1
    fi

    echo "Verifying rule (IPv4)..."
    sudo iptables -L INPUT -n -v | awk -v p="$port" '$0 ~ /tcp/ && $0 ~ (p "\\b") {print}' || true
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
    # sudo systemctl disable --now snap.oracle-cloud-agent.oracle-cloud-agent.service || true
    # sudo systemctl disable --now snap.oracle-cloud-agent.oracle-cloud-agent-updater.service || true

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

    echo "Configuring Nginx TCP stream proxy to $MYSQL_SERVER:$MYSQL_PORT..."

    # ============================================================
    # STEP 1: Ensure stream block exists with stream.d includes
    # ============================================================
    if ! grep -q "^stream\s*{" /etc/nginx/nginx.conf; then
        echo "  [STEP 1] Adding stream block to nginx.conf..."
        sudo tee -a /etc/nginx/nginx.conf >/dev/null <<'CONF_APPEND'

# ============================================================
# STREAM CONFIGURATION - TCP PROXY
# Managed by: setup_nginx_proxy_server.sh
# Purpose: Include all TCP stream proxy configs (e.g., MySQL)
# ============================================================
stream {
    include /etc/nginx/stream.d/*.conf;
}
# ============================================================
CONF_APPEND
    else
        # Verify include line exists inside stream block
        if ! awk '/^stream\s*{/{f=1} f && /}/ {exit} f && /include \/etc\/nginx\/stream.d\/\*\.conf;/{found=1} END{exit !found}' /etc/nginx/nginx.conf; then
            echo "  [STEP 1] Adding include directive to existing stream block..."
            sudo awk 'BEGIN{added=0} /^stream\s*{/{print; print "    include /etc/nginx/stream.d/*.conf;"; added=1; next} {print} END{if(!added) exit 1}' /etc/nginx/nginx.conf | sudo tee /etc/nginx/nginx.conf.tmp >/dev/null && sudo mv /etc/nginx/nginx.conf.tmp /etc/nginx/nginx.conf
        fi
    fi

    # ============================================================
    # STEP 2: Disable HTTP - comment out site/conf includes
    # ============================================================
    echo "  [STEP 2] Disabling HTTP virtual hosts..."
    
    # Comment out sites-enabled and conf.d includes in http block
    # (Default site symlink remains in place but is not loaded)
    if grep -q "include /etc/nginx/sites-enabled/\*;" /etc/nginx/nginx.conf; then
        sudo sed -i \
            -e 's~^\s*include /etc/nginx/sites-enabled/\*;~    # DISABLED: include /etc/nginx/sites-enabled/*;~' \
            -e 's~^\s*include /etc/nginx/conf.d/\*\.conf;~    # DISABLED: include /etc/nginx/conf.d/*.conf;~' \
            /etc/nginx/nginx.conf
        echo "    HTTP includes disabled (commented out)"
    fi
    
    # Note: Default HTTP site symlink left in place but disabled via commented includes above
    if [[ -L "/etc/nginx/sites-enabled/default" ]]; then
        echo "    Default site symlink exists but is inactive (HTTP disabled)"
    fi

    # ============================================================
    # STEP 3: Create TCP stream proxy config for MySQL
    # ============================================================
    echo "  [STEP 3] Creating stream proxy config at $NGINX_STREAM_CONF..."
    
    # Ensure stream.d directory exists
    sudo mkdir -p /etc/nginx/stream.d
    
    sudo tee "$NGINX_STREAM_CONF" >/dev/null <<EOL
# ============================================================
# Stream Proxy Configuration
# Managed by: setup_nginx_proxy_server.sh
# Backend: $MYSQL_SERVER:$MYSQL_PORT
# Local Listen Port: $LISTEN_PORT
# ============================================================

upstream $UPSTREAM_NAME {
    # Backend server
    server $MYSQL_SERVER:$MYSQL_PORT max_fails=$UPSTREAM_MAX_FAILS fail_timeout=$UPSTREAM_FAIL_TIMEOUT;
    
    # NOTE: 'keepalive' directive is NOT supported in stream module
    # Stream connections are handled differently than HTTP
}

server {
    # Accept incoming connections on local port
    listen $LISTEN_PORT;
    
    # Forward TCP stream to remote backend server
    proxy_pass $UPSTREAM_NAME;
    
    # Connection establishment timeout
    proxy_connect_timeout $PROXY_CONNECT_TIMEOUT;
    
    # Read/write timeout between client and upstream
    # Set to 1h for long-running MySQL queries
    proxy_timeout $PROXY_TIMEOUT;
}
# ============================================================
EOL

    # ============================================================
    # STEP 4: Validate and restart Nginx
    # ============================================================
    echo "  [STEP 4] Validating Nginx configuration..."
    if ! sudo nginx -t; then
        echo "ERROR: Nginx configuration validation failed."
        exit 1
    fi
    echo "    Configuration valid"
    
    echo "  [STEP 4] Restarting Nginx..."
    sudo systemctl restart nginx
    
    # Verify Nginx started successfully
    if sudo systemctl is-active --quiet nginx; then
        echo "✓ SUCCESS: Nginx stream proxy setup complete!"
        echo ""
        echo "  Proxy Configuration:"
        echo "    Backend:      $MYSQL_SERVER:$MYSQL_PORT"
        echo "    Local Port:   $LISTEN_PORT (TCP)"
        echo "    Upstream:     $UPSTREAM_NAME"
        echo "    Config File:  $NGINX_STREAM_CONF"
        echo "    Timeouts:     connect=$PROXY_CONNECT_TIMEOUT, proxy=$PROXY_TIMEOUT"
        echo "    Resilience:   max_fails=$UPSTREAM_MAX_FAILS, fail_timeout=$UPSTREAM_FAIL_TIMEOUT"
        echo "    HTTP:         DISABLED (by design)"
    else
        echo "ERROR: Nginx failed to start after configuration."
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
echo "  Listen Port: $LISTEN_PORT"
echo "  Upstream Name: $UPSTREAM_NAME"
echo ""

# Set full path to nginx stream config file
NGINX_STREAM_CONF="/etc/nginx/stream.d/${PROXY_CONFIG_FILE}"

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

# Step 7: Configure iptables for MySQL (3306)
echo "STEP 7: Configuring iptables to allow 3306/tcp..."
setup_iptables_mysql_port
echo ""

# Step 8: Setup Nginx proxy
echo "STEP 8: Setting up Nginx proxy server..."
setup_nginx_proxy
echo ""

echo "===================================================="
echo "✓ Setup complete successfully!"
echo "===================================================="
echo ""
echo "Summary:"
echo "  - OS: Ubuntu (verified)"
echo "  - Swap: Configured and active"
echo "  - Firewall: iptables allows ${LISTEN_PORT:-$MYSQL_PORT}/tcp (others unchanged)"
echo "  - Nginx: Running and configured"
echo "  - Proxy: Forwarding to $MYSQL_SERVER:$MYSQL_PORT"
echo ""
echo "To verify the setup, run:"
echo "  swapon --show  (to check swap)"
echo "  sudo systemctl status nginx  (to check Nginx)"
echo "  sudo iptables -L -n -v | grep ${LISTEN_PORT:-$MYSQL_PORT}  (to check firewall)"
echo "===================================================="
