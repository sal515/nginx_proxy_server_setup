# nginx_proxy_server_setup

Tested on OCI VM

## Overview

This project provides automated setup scripts for creating a secure MySQL database proxy and Cloudflare Tunnel configuration on Ubuntu 22.04 (Jammy).

## Components

### 1. Configuration File
**`config_setup_nginx_proxy_server.conf`**
- Central configuration file for MySQL proxy and Cloudflare Tunnel settings
- Configure MySQL server IP, port, connection timeouts, and tunnel details
- All scripts read from this file for consistent configuration

### 2. Nginx Proxy Setup
**`setup_nginx_proxy_server.sh`**
- Installs and configures Nginx as a TCP proxy for MySQL connections
- Sets up stream module for Layer 4 (TCP) proxying
- Creates proxy configuration based on settings in config file
- Useful for local network MySQL proxying

### 3. Cloudflare Tunnel Setup
**`setup_cloudflared_on_server.sh`**
- Installs and configures Cloudflare Tunnel (cloudflared)
- Securely exposes MySQL database through Cloudflare's network
- No need to open firewall ports or expose public IPs
- Includes checkpoint system to track setup progress
- Can be re-run safely; skips completed steps

## Usage

1. **Edit configuration file:**
   ```bash
   nano config_setup_nginx_proxy_server.conf
   ```
   Update MYSQL_SERVER, MYSQL_PORT, and Cloudflare tunnel settings

2. **Run Nginx proxy setup (optional):**
   ```bash
   chmod +x setup_nginx_proxy_server.sh
   sudo ./setup_nginx_proxy_server.sh
   ```

3. **Run Cloudflare tunnel setup:**
   ```bash
   chmod +x setup_cloudflared_on_server.sh
   sudo ./setup_cloudflared_on_server.sh
   ```

## Architecture

```
Internet → Cloudflare Tunnel (proxy.precisiontime.ca) → MySQL Server (10.0.1.55:3306)
```

## Requirements

- Ubuntu 22.04 (Jammy Jellyfish) recommended
- Root or sudo access
- Cloudflare account (for tunnel setup)
