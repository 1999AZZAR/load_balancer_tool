# Linux Network Load Balancer

This package provides tools to implement Layer 3 load balancing on a Linux system using `iproute2` and `nftables`. It allows for the simultaneous use of multiple network interfaces (e.g., Wi-Fi, Ethernet, USB tethering) to distribute outbound traffic.

## Contents

1. `universal_load_balancer.sh`: A standalone script for one-time configuration.
2. `net_autobalance.sh`: The core logic script for the systemd service.
3. `net_balancer.service`: The systemd unit file for persistent background monitoring.

## System Requirements

- Root privileges (sudo).
- `iproute2` (installed by default on most distributions).
- `nftables` (for NAT/Masquerading).
- `bash`.

## Installation (Recommended)

The easiest way to install or update the load balancer is using the provided installation script:

```bash
sudo ./install.sh
```

This script will:

- Detect if the service is already installed and perform an update if necessary.
- Copy scripts to `/usr/local/bin/`.
- Set up and start the systemd service.

## Installation (Manual Service Method)

If you prefer manual steps:

1. Copy the script to the executable path:
   
   ```bash
   sudo cp net_autobalance.sh /usr/local/bin/
   sudo chmod +x /usr/local/bin/net_autobalance.sh
   ```

2. Copy the service file to the systemd directory:
   
   ```bash
   sudo cp net_balancer.service /etc/systemd/system/
   ```

3. Reload the systemd daemon, enable the service on boot, and start it:
   
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable net_balancer.service
   sudo systemctl start net_balancer.service
   ```

4. Verify status:
   
   ```bash
   sudo systemctl status net_balancer.service
   ```

## Usage (Standalone Script)

If you prefer not to install the service, you can run the configuration once manually:

```bash
sudo ./universal_load_balancer.sh
```

## Technical Details

- **Routing:** The system creates a separate routing table (IDs 100+) for each detected interface to ensure correct return-path routing.
- **Load Balancing:** A multipath default route is created in a separate table (ID 200) or the main table (standalone mode), utilizing `nexthop` weighting to distribute connections.
- **NAT:** `nftables` masquerading is applied to outbound traffic on all active interfaces to allow proper address translation.
- **Monitoring:** The service checks the main routing table every 5 seconds for changes in default gateways and reconfigures the routing policy dynamically.
