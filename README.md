# Linux Network Load Balancer

This package provides advanced tools to implement Layer 3 load balancing on a Linux system using `iproute2` and `nftables`. It allows for the simultaneous use of multiple network interfaces (e.g., Wi-Fi, Ethernet, USB tethering) to distribute outbound traffic with enterprise-grade features including real-time monitoring, health checks, session affinity, and graceful failover.

## Contents

1. `universal_load_balancer.sh`: A standalone script for one-time configuration.
2. `net_autobalance.sh`: The core logic script for the systemd service with advanced features.
3. `net_balancer.service`: The systemd unit file for persistent background monitoring.
4. `test_harness.sh`: Comprehensive test harness for simulating failure scenarios.
5. `install.sh`: Installation script for automated setup.
6. `uninstall.sh`: Complete uninstallation script to remove all components.

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

## Configuration

The load balancer can be configured via environment variables or by editing the script directly. Key configuration options:

### Core Settings
- `LB_TABLE=200`: Routing table ID for load balancing
- `LB_PREF=90`: IP rule preference for load balancing

### Real-time Monitoring
- `DEBOUNCE_TIME=2`: Seconds to wait after network events before reconfiguration

### Health Checks
- `HEALTH_CHECK_ENABLED=true`: Enable/disable active health monitoring
- `HEALTH_CHECK_INTERVAL=30`: Seconds between health checks
- `HEALTH_CHECK_TIMEOUT=3`: Timeout for health probes
- `HEALTH_CHECK_FAILURE_THRESHOLD=2`: Consecutive failures before marking interface down
- `HEALTH_CHECK_RECOVERY_THRESHOLD=1`: Consecutive successes before marking interface up
- `HEALTH_PROBE_TARGET="1.1.1.1"`: Target for connectivity checks
- `HEALTH_PROBE_PORT=53`: TCP port for health probes

### Connection Management
- `CONNECTION_DRAINING_ENABLED=true`: Enable graceful connection draining
- `SESSION_AFFINITY_ENABLED=true`: Enable sticky routing per connection
- `CONSISTENT_NAT_ENABLED=true`: Ensure consistent source IPs

### Failover Control
- `FAILOVER_HYSTERESIS_ENABLED=true`: Enable hysteresis to prevent flapping
- `FAILOVER_BACKOFF_BASE=30`: Base backoff time in seconds
- `FAILOVER_BACKOFF_MAX=300`: Maximum backoff time
- `FAILOVER_HOLD_DOWN=60`: Hold-down period before re-enabling interfaces

### Neighbor Monitoring
- `NEIGHBOR_REACHABILITY_ENABLED=true`: Monitor ARP/NDP for gateway reachability

### Logging & Metrics
- `LOG_LEVEL="info"`: Logging level (debug/info/warn/error)
- `METRICS_ENABLED=false`: Enable Prometheus metrics
- `METRICS_PORT=9090`: Port for metrics HTTP server
- `METRICS_FILE="/var/run/load_balancer_metrics.prom"`: Metrics file path

## Usage (Standalone Script)

If you prefer not to install the service, you can run the configuration once manually:

```bash
sudo ./universal_load_balancer.sh
```

## Testing

Use the included test harness to simulate various failure scenarios:

```bash
sudo ./test_harness.sh status                    # Show current status
sudo ./test_harness.sh down-up wlan0 30          # Bring interface down then up
sudo ./test_harness.sh flap eth0 5               # Simulate route flapping
sudo ./test_harness.sh neighbor-fail eth0        # Simulate neighbor failure
sudo ./test_harness.sh health-block 30           # Block health check target
sudo ./test_harness.sh comprehensive             # Run full test suite
```

## Metrics & Monitoring

When `METRICS_ENABLED=true`, the service exposes Prometheus metrics on the configured port:

```
# HELP load_balancer_log_messages_total Total number of log messages
# TYPE load_balancer_log_messages_total counter
load_balancer_log_messages_total 42

# HELP load_balancer_active_interfaces Number of active interfaces
# TYPE load_balancer_active_interfaces gauge
load_balancer_active_interfaces 2
```

Access metrics at: `http://localhost:9090/metrics`

## Technical Details

- **Real-time Monitoring:** Uses `ip monitor route link` for instant detection of network changes instead of polling.
- **Health Checks:** Active per-interface connectivity monitoring with TCP probes, configurable thresholds, and failure recovery.
- **Connection Draining:** Graceful handling of existing connections during interface failures to prevent session drops.
- **Session Affinity:** Optional sticky routing ensures consistent interface usage per connection flow.
- **Failover Hysteresis:** Prevents flapping with exponential backoff, hold-down periods, and configurable recovery logic.
- **Consistent NAT:** Per-interface SNAT ensures connections maintain the same source IP throughout their lifetime.
- **Neighbor Reachability:** ARP/NDP monitoring detects layer-2 gateway reachability issues.
- **Routing:** Separate routing tables (IDs 100+) for each interface ensure correct return-path routing.
- **Load Balancing:** Multipath default routes with configurable weighting distribute connections across healthy interfaces.
- **NAT:** `nftables` masquerading with connection tracking for consistent address translation.
- **Metrics & Monitoring:** Optional Prometheus metrics endpoint and structured logging with configurable levels.

## Uninstallation

To completely remove the load balancer and restore your system to its original state:

```bash
sudo ./uninstall.sh
```

This script will:
- Stop and disable the systemd service
- Remove all installed files
- Clean up routing rules and tables
- Remove nftables rules
- Delete metrics files
- Provide a detailed status report

The uninstallation is designed to be safe and thorough, ensuring no leftover configuration affects your system.
