#!/bin/bash
# Network Auto-Balancer Daemon
# Monitors 'main' routing table and maintains a load-balanced overlay in Table 200.

# Config
LB_TABLE=200
LB_PREF=90
DEBOUNCE_TIME=2  # seconds to wait after an event before reconfiguring

# Logging and metrics config
LOG_LEVEL="info"  # debug, info, warn, error
METRICS_ENABLED=false
METRICS_PORT=9090
METRICS_FILE="/var/run/load_balancer_metrics.prom"

# Health check config
HEALTH_CHECK_ENABLED=true
HEALTH_CHECK_INTERVAL=30  # seconds between health checks
HEALTH_CHECK_TIMEOUT=3    # seconds for probe timeout
HEALTH_CHECK_FAILURE_THRESHOLD=2  # consecutive failures before marking down
HEALTH_CHECK_RECOVERY_THRESHOLD=1 # consecutive successes before marking up
HEALTH_PROBE_TARGET="1.1.1.1"  # target for connectivity checks
HEALTH_PROBE_PORT=53     # DNS port for TCP checks

# Connection draining config
CONNECTION_DRAINING_ENABLED=true
DRAINING_MARK=0x10000000  # fwmark for draining connections
ACTIVE_MARK=0x20000000   # fwmark for active connections

# Session affinity config
SESSION_AFFINITY_ENABLED=false  # Temporarily disabled for testing
SESSION_AFFINITY_MASK=0x0000FFFF  # Mask for session hash (lower 16 bits)

# Failover hysteresis config
FAILOVER_HYSTERESIS_ENABLED=true
FAILOVER_BACKOFF_BASE=30     # Base backoff time in seconds
FAILOVER_BACKOFF_MAX=300     # Maximum backoff time in seconds
FAILOVER_HOLD_DOWN=60        # Hold-down period before re-enabling interface

# Consistent NAT config
CONSISTENT_NAT_ENABLED=true  # Ensure connections maintain same source IP

# Neighbor reachability config
NEIGHBOR_REACHABILITY_ENABLED=true  # Monitor ARP/NDP for gateway reachability

# State tracking
LAST_STATE=""
LAST_EVENT_TIME=0

# Health tracking
declare -A INTERFACE_HEALTH
declare -A INTERFACE_FAILURE_COUNT
declare -A INTERFACE_SUCCESS_COUNT
declare -A INTERFACE_BACKOFF_COUNT
declare -A INTERFACE_LAST_FAILURE
declare -A INTERFACE_HOLD_DOWN_UNTIL
LAST_HEALTH_CHECK=0

# Logging levels: debug, info, warn, error
log() {
    local level="${2:-info}"
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Check if this log level should be shown
    case "$LOG_LEVEL" in
        "error") [ "$level" != "error" ] && return ;;
        "warn") [[ "$level" =~ ^(debug|info)$ ]] && return ;;
        "info") [ "$level" = "debug" ] && return ;;
        "debug") ;; # Show all
        *) return ;;
    esac

    echo "[$timestamp] [$level] $message" >&2

    # Update metrics if enabled
    if [ "$METRICS_ENABLED" = "true" ]; then
        update_metrics "$level" "$message"
    fi
}

# Metrics collection
declare -A METRICS_COUNTERS
declare -A METRICS_GAUGES

update_metrics() {
    local level="$1"
    local message="$2"

    # Initialize metrics if needed
    [ -z "${METRICS_COUNTERS[log_messages_total]}" ] && METRICS_COUNTERS[log_messages_total]=0
    [ -z "${METRICS_COUNTERS[log_${level}_total]}" ] && METRICS_COUNTERS[log_${level}_total]=0
    [ -z "${METRICS_GAUGES[active_interfaces]}" ] && METRICS_GAUGES[active_interfaces]=0

    ((METRICS_COUNTERS[log_messages_total]++))
    ((METRICS_COUNTERS[log_${level}_total]++))

    write_metrics_file
}

write_metrics_file() {
    if [ "$METRICS_ENABLED" != "true" ]; then
        return
    fi

    cat > "$METRICS_FILE" << EOF
# HELP load_balancer_log_messages_total Total number of log messages
# TYPE load_balancer_log_messages_total counter
load_balancer_log_messages_total ${METRICS_COUNTERS[log_messages_total]:-0}

# HELP load_balancer_log_error_total Total number of error log messages
# TYPE load_balancer_log_error_total counter
load_balancer_log_error_total ${METRICS_COUNTERS[log_error_total]:-0}

# HELP load_balancer_log_warn_total Total number of warning log messages
# TYPE load_balancer_log_warn_total counter
load_balancer_log_warn_total ${METRICS_COUNTERS[log_warn_total]:-0}

# HELP load_balancer_log_info_total Total number of info log messages
# TYPE load_balancer_log_info_total counter
load_balancer_log_info_total ${METRICS_COUNTERS[log_info_total]:-0}

# HELP load_balancer_active_interfaces Number of active interfaces
# TYPE load_balancer_active_interfaces gauge
load_balancer_active_interfaces ${METRICS_GAUGES[active_interfaces]:-0}
EOF
}

start_metrics_server() {
    if [ "$METRICS_ENABLED" != "true" ]; then
        return
    fi

    # Simple HTTP server for Prometheus metrics
    (
        while true; do
            nc -l -p $METRICS_PORT -q 1 < "$METRICS_FILE" 2>/dev/null || true
        done
    ) &
    log "Metrics server started on port $METRICS_PORT" "info"
}

# Health check functions
check_interface_health() {
    local iface="$1"
    local gw="$2"
    local src_ip="$3"
    local CURRENT_TIME=$(date +%s)

    # Skip health checks if disabled
    if [ "$HEALTH_CHECK_ENABLED" != "true" ]; then
        return 0
    fi

    # Initialize health tracking if not exists
    if [ -z "${INTERFACE_HEALTH[$iface]}" ]; then
        INTERFACE_HEALTH[$iface]="up"
        INTERFACE_FAILURE_COUNT[$iface]=0
        INTERFACE_SUCCESS_COUNT[$iface]=0
        INTERFACE_BACKOFF_COUNT[$iface]=0
        INTERFACE_LAST_FAILURE[$iface]=0
        INTERFACE_HOLD_DOWN_UNTIL[$iface]=0
    fi

    # Check if interface is in hold-down period
    if [ "$FAILOVER_HYSTERESIS_ENABLED" = "true" ] && \
       [ "${INTERFACE_HEALTH[$iface]}" = "hold_down" ] && \
       [ $CURRENT_TIME -lt ${INTERFACE_HOLD_DOWN_UNTIL[$iface]} ]; then
        return 0  # Still in hold-down
    fi

    # Check exponential backoff for failed interfaces
    if [ "$FAILOVER_HYSTERESIS_ENABLED" = "true" ] && \
       [ "${INTERFACE_HEALTH[$iface]}" = "backoff" ]; then
        local backoff_time=$((FAILOVER_BACKOFF_BASE * (2 ** INTERFACE_BACKOFF_COUNT[$iface])))
        [ $backoff_time -gt $FAILOVER_BACKOFF_MAX ] && backoff_time=$FAILOVER_BACKOFF_MAX

        if [ $((CURRENT_TIME - INTERFACE_LAST_FAILURE[$iface])) -lt $backoff_time ]; then
            return 0  # Still in backoff
        fi
    fi

    # Rate limit health checks
    if [ $((CURRENT_TIME - LAST_HEALTH_CHECK)) -lt $HEALTH_CHECK_INTERVAL ]; then
        return 0
    fi

    LAST_HEALTH_CHECK=$CURRENT_TIME

    # First check neighbor reachability
    if ! check_neighbor_reachability "$iface" "$gw"; then
        # Neighbor unreachable - immediate failure
        ((INTERFACE_FAILURE_COUNT[$iface]++))
        INTERFACE_SUCCESS_COUNT[$iface]=0

        if [ "${INTERFACE_HEALTH[$iface]}" = "up" ] && \
           [ "${INTERFACE_FAILURE_COUNT[$iface]}" -ge "$HEALTH_CHECK_FAILURE_THRESHOLD" ]; then
            INTERFACE_HEALTH[$iface]="down"
            INTERFACE_LAST_FAILURE[$iface]=$CURRENT_TIME
            ((INTERFACE_BACKOFF_COUNT[$iface]++))
            log "Interface $iface marked down due to neighbor unreachability"
            return 1  # Interface failed
        fi
        return 0  # Still within threshold
    fi

    log "Health check: probing $HEALTH_PROBE_TARGET:$HEALTH_PROBE_PORT via $iface ($src_ip)"

    # Try TCP connect with timeout and source IP binding
    if timeout $HEALTH_CHECK_TIMEOUT bash -c "
        exec 3<>/dev/tcp/$HEALTH_PROBE_TARGET/$HEALTH_PROBE_PORT 2>/dev/null &&
        echo -e '\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x03www\x06google\x03com\x00\x00\x01\x00\x01' >&3 &&
        timeout 1 cat <&3 >/dev/null 2>&1 &&
        exec 3>&-
    " 2>/dev/null; then
        # Success
        ((INTERFACE_SUCCESS_COUNT[$iface]++))
        INTERFACE_FAILURE_COUNT[$iface]=0

        if [ "${INTERFACE_HEALTH[$iface]}" = "down" ] || \
           [ "${INTERFACE_HEALTH[$iface]}" = "backoff" ] || \
           [ "${INTERFACE_HEALTH[$iface]}" = "hold_down" ]; then
            if [ "${INTERFACE_SUCCESS_COUNT[$iface]}" -ge "$HEALTH_CHECK_RECOVERY_THRESHOLD" ]; then
                if [ "$FAILOVER_HYSTERESIS_ENABLED" = "true" ]; then
                    # Enter hold-down period before enabling
                    INTERFACE_HEALTH[$iface]="hold_down"
                    INTERFACE_HOLD_DOWN_UNTIL[$iface]=$((CURRENT_TIME + FAILOVER_HOLD_DOWN))
                    INTERFACE_BACKOFF_COUNT[$iface]=0
                    log "Interface $iface recovering - hold-down until $(date -d @${INTERFACE_HOLD_DOWN_UNTIL[$iface]})"
                else
                    INTERFACE_HEALTH[$iface]="up"
                    log "Interface $iface recovered (success count: ${INTERFACE_SUCCESS_COUNT[$iface]})"
                    return 2  # Interface recovered
                fi
            fi
        elif [ "${INTERFACE_HEALTH[$iface]}" = "hold_down" ]; then
            # Hold-down period expired, enable interface
            INTERFACE_HEALTH[$iface]="up"
            log "Interface $iface enabled after hold-down period"
            return 2  # Interface recovered
        fi
        return 0  # Healthy
    else
        # Failure
        ((INTERFACE_FAILURE_COUNT[$iface]++))
        INTERFACE_SUCCESS_COUNT[$iface]=0

        if [ "${INTERFACE_HEALTH[$iface]}" = "up" ] && \
           [ "${INTERFACE_FAILURE_COUNT[$iface]}" -ge "$HEALTH_CHECK_FAILURE_THRESHOLD" ]; then
            INTERFACE_HEALTH[$iface]="down"
            INTERFACE_LAST_FAILURE[$iface]=$CURRENT_TIME
            ((INTERFACE_BACKOFF_COUNT[$iface]++))
            log "Interface $iface marked down (failure count: ${INTERFACE_FAILURE_COUNT[$iface]})"
            return 1  # Interface failed
        elif [ "${INTERFACE_HEALTH[$iface]}" = "down" ]; then
            # Check if we should start backoff recovery attempts
            local backoff_time=$((FAILOVER_BACKOFF_BASE * (2 ** INTERFACE_BACKOFF_COUNT[$iface])))
            [ $backoff_time -gt $FAILOVER_BACKOFF_MAX ] && backoff_time=$FAILOVER_BACKOFF_MAX

            if [ $((CURRENT_TIME - INTERFACE_LAST_FAILURE[$iface])) -ge $backoff_time ]; then
                INTERFACE_HEALTH[$iface]="backoff"
                log "Interface $iface entering backoff recovery (attempt ${INTERFACE_BACKOFF_COUNT[$iface]})"
            fi
        fi
        return 0  # Still in failure state
    fi
}

is_interface_healthy() {
    local iface="$1"
    [ "${INTERFACE_HEALTH[$iface]}" = "up" ]
}

# Check neighbor (ARP/NDP) reachability for gateway
check_neighbor_reachability() {
    local iface="$1"
    local gw="$2"

    if [ "$NEIGHBOR_REACHABILITY_ENABLED" != "true" ]; then
        return 0  # Consider reachable if disabled
    fi

    # Check neighbor state for the gateway
    local neigh_state=$(ip neigh show dev "$iface" "$gw" | awk '{print $6}')

    case "$neigh_state" in
        "REACHABLE"|"DELAY"|"PROBE")
            return 0  # Good states
            ;;
        "FAILED"|"INCOMPLETE")
            log "Neighbor reachability: $iface gateway $gw is $neigh_state"
            return 1  # Bad states
            ;;
        "STALE")
            # Stale might be OK, but let's trigger a probe
            ip neigh flush dev "$iface" "$gw" 2>/dev/null || true
            return 0  # Give it a chance
            ;;
        *)
            return 0  # Unknown states considered OK
            ;;
    esac
}

cleanup() {
    log "Stopping... Cleaning up rules."
    ip rule del pref $LB_PREF 2>/dev/null || true
    ip route flush table $LB_TABLE 2>/dev/null || true
    # Flush per-interface tables (100-110)
    for i in {100..110}; do
        ip route flush table $i 2>/dev/null || true
        while ip rule show | grep -q "lookup $i"; do
            ip rule del table $i 2>/dev/null || true
        done
    done
    nft delete table ip loadbalancing 2>/dev/null || true
    # Clear cache
    ip route flush cache
    exit 0
}

# Trap exit signals to ensure cleanup
trap cleanup SIGINT SIGTERM

update_balancing() {
    local STATE_STRING="$1"

    log "Change detected! New state: $STATE_STRING"
    log "Re-configuring load balancing..."

    # 1. Parse State
    # State format: "iface1,gw1,ip1,health iface2,gw2,ip2,health ..."
    declare -a ALL_IFACES
    declare -a ALL_GWS
    declare -a ALL_IPS
    declare -a ALL_HEALTHS
    declare -a ACTIVE_IFACES
    declare -a ACTIVE_GWS
    declare -a ACTIVE_IPS
    local ALL_COUNT=0
    local ACTIVE_COUNT=0

    IFS=' ' read -r -a ENTRIES <<< "$STATE_STRING"
    for entry in "${ENTRIES[@]}"; do
        IFS=',' read -r iface gw ip health <<< "$entry"

        ALL_IFACES[$ALL_COUNT]=$iface
        ALL_GWS[$ALL_COUNT]=$gw
        ALL_IPS[$ALL_COUNT]=$ip
        ALL_HEALTHS[$ALL_COUNT]=$health

        if [ "$health" = "up" ]; then
            ACTIVE_IFACES[$ACTIVE_COUNT]=$iface
            ACTIVE_GWS[$ACTIVE_COUNT]=$gw
            ACTIVE_IPS[$ACTIVE_COUNT]=$ip
            ((ACTIVE_COUNT++))
        else
            log "Interface $iface is unhealthy (status: $health) - will drain existing connections"
        fi

        ((ALL_COUNT++))
    done

    # 2. Partial Cleanup (keep existing rules for connection draining)
    if [ "$CONNECTION_DRAINING_ENABLED" = "true" ]; then
        # Remove old active routing rules but keep draining ones
        ip rule del pref $LB_PREF 2>/dev/null || true
        ip route flush table $LB_TABLE 2>/dev/null || true
    else
        # Full cleanup if draining disabled
        ip rule del pref $LB_PREF 2>/dev/null || true
        ip route flush table $LB_TABLE 2>/dev/null || true
        nft delete table ip loadbalancing 2>/dev/null || true
    fi

    if [ "$ACTIVE_COUNT" -eq 0 ]; then
        log "No healthy interfaces available. Keeping existing connections draining..."
        return
    fi

    # 3. Configure Per-Interface Tables (For Return Traffic)
    for ((i=0; i<ALL_COUNT; i++)); do
        local IFACE=${ALL_IFACES[$i]}
        local GW=${ALL_GWS[$i]}
        local IP=${ALL_IPS[$i]}
        local T_ID=$((100 + i))

        # Flush and recreate table
        ip route flush table $T_ID 2>/dev/null || true
        while ip rule show | grep -q "lookup $T_ID"; do
            ip rule del table $T_ID 2>/dev/null || true
        done

        # Add routes to specific table
        ip route add "$GW" dev "$IFACE" src "$IP" table "$T_ID"
        ip route add default via "$GW" dev "$IFACE" table "$T_ID"

        # Add rule for return traffic
        ip rule add from "$IP" table "$T_ID" priority $((100 + i))
    done

    if [ "$CONNECTION_DRAINING_ENABLED" = "true" ]; then
        # 4. Configure Connection Draining with fwmark
        # Create separate tables for active and draining connections
        local ACTIVE_TABLE=$LB_TABLE
        local DRAINING_TABLE=$((LB_TABLE + 1))

        # Clear tables
        ip route flush table $ACTIVE_TABLE 2>/dev/null || true
        ip route flush table $DRAINING_TABLE 2>/dev/null || true

        # Configure routing based on session affinity setting
        if [ "$SESSION_AFFINITY_ENABLED" = "true" ] && [ "$ACTIVE_COUNT" -gt 1 ]; then
            # Session affinity: create individual tables for each interface
            for ((i=0; i<ACTIVE_COUNT; i++)); do
                local IFACE_TABLE=$((ACTIVE_TABLE + i + 1))
                ip route flush table $IFACE_TABLE 2>/dev/null || true
                ip route add default via ${ACTIVE_GWS[$i]} dev ${ACTIVE_IFACES[$i]} table $IFACE_TABLE

                # Add fwmark rule for this interface (matches mark with interface index i)
                ip rule add fwmark $((ACTIVE_MARK | i))/$SESSION_AFFINITY_MASK pref $((LB_PREF + i + 1)) lookup $IFACE_TABLE
            done
        else
            # Traditional multipath load balancing
            if [ "$ACTIVE_COUNT" -gt 0 ]; then
                local MP_CMD="ip route add default scope global table $ACTIVE_TABLE"
                for ((i=0; i<ACTIVE_COUNT; i++)); do
                    local IFACE_NAME=${ACTIVE_IFACES[$i]}
                    local WEIGHT=1

                    # Heuristic for weighting
                    if [[ "$IFACE_NAME" =~ ^(eno|ens|enp|eth) ]]; then
                        WEIGHT=5 # Wired Ethernet
                    elif [[ "$IFACE_NAME" =~ ^(wlan|wlp|wlx|wl) ]]; then
                        WEIGHT=3 # Wi-Fi
                    elif [[ "$IFACE_NAME" =~ ^(enx) ]]; then
                        WEIGHT=2 # USB Ethernet
                    else
                        WEIGHT=1 # Fallback
                    fi

                    MP_CMD="$MP_CMD nexthop via ${ACTIVE_GWS[$i]} dev ${ACTIVE_IFACES[$i]} weight $WEIGHT"
                done
                eval "$MP_CMD"
                ip rule add fwmark $ACTIVE_MARK pref $LB_PREF lookup $ACTIVE_TABLE
            fi
        fi

        # Configure draining multipath (for existing connections on unhealthy interfaces)
        local unhealthy_found=false
        for ((i=0; i<ALL_COUNT; i++)); do
            if [ "${ALL_HEALTHS[$i]}" != "up" ]; then
                if [ "$unhealthy_found" = "false" ]; then
                    unhealthy_found=true
                    local MP_CMD="ip route add default scope global table $DRAINING_TABLE"
                fi
                MP_CMD="$MP_CMD nexthop via ${ALL_GWS[$i]} dev ${ALL_IFACES[$i]} weight 1"
            fi
        done
        if [ "$unhealthy_found" = "true" ]; then
            eval "$MP_CMD"
        fi

        # Add fwmark-based routing rules
        ip rule add fwmark $ACTIVE_MARK pref $LB_PREF lookup $ACTIVE_TABLE
        if [ "$unhealthy_found" = "true" ]; then
            ip rule add fwmark $DRAINING_MARK pref $((LB_PREF + 1)) lookup $DRAINING_TABLE
        fi

        # Configure nftables for connection marking and NAT
        nft delete table ip loadbalancing 2>/dev/null || true
        nft add table ip loadbalancing

        # Mangle chain for marking connections
        nft add chain ip loadbalancing mangle { type route hook output priority -150 \; }

        if [ "$SESSION_AFFINITY_ENABLED" = "true" ] && [ "$ACTIVE_COUNT" -gt 1 ]; then
            # Session affinity: use symmetric hash for consistent interface selection
            # Hash result will be 0 to (ACTIVE_COUNT-1), we add ACTIVE_MARK to identify active connections
            nft add rule ip loadbalancing mangle tcp dport != 53 ct state new \
                ct mark set jhash ip saddr . ip daddr . tcp sport . tcp dport mod $ACTIVE_COUNT
            nft add rule ip loadbalancing mangle tcp dport != 53 ct state new \
                ct mark set ct mark or $ACTIVE_MARK
            nft add rule ip loadbalancing mangle udp dport != 53 ct state new \
                ct mark set jhash ip saddr . ip daddr . udp sport . udp dport mod $ACTIVE_COUNT
            nft add rule ip loadbalancing mangle udp dport != 53 ct state new \
                ct mark set ct mark or $ACTIVE_MARK
            nft add rule ip loadbalancing mangle icmp type echo-request ct state new \
                ct mark set jhash ip saddr . ip daddr mod $ACTIVE_COUNT
            nft add rule ip loadbalancing mangle icmp type echo-request ct state new \
                ct mark set ct mark or $ACTIVE_MARK
        else
            # Simple marking without affinity
            nft add rule ip loadbalancing mangle tcp dport != 53 ct state new ct mark set $ACTIVE_MARK
            nft add rule ip loadbalancing mangle udp dport != 53 ct state new ct mark set $ACTIVE_MARK
            nft add rule ip loadbalancing mangle icmp type echo-request ct state new ct mark set $ACTIVE_MARK
        fi

        # NAT chain - consistent NAT via conntrack (connections maintain same source IP)
        nft add chain ip loadbalancing postrouting { type nat hook postrouting priority 100 \; }
        if [ "$CONSISTENT_NAT_ENABLED" = "true" ]; then
            # Per-interface NAT ensures connection consistency via conntrack
            for ((i=0; i<ACTIVE_COUNT; i++)); do
                nft add rule ip loadbalancing postrouting oifname "${ACTIVE_IFACES[$i]}" masquerade
            done
            # Also allow NAT for draining interfaces to maintain existing connections
            for ((i=0; i<ALL_COUNT; i++)); do
                if [ "${ALL_HEALTHS[$i]}" != "up" ]; then
                    nft add rule ip loadbalancing postrouting oifname "${ALL_IFACES[$i]}" masquerade
                fi
            done
        else
            # Traditional NAT
            nft add rule ip loadbalancing postrouting masquerade
        fi

    else
        # 4. Traditional multipath without connection draining
        local MP_CMD="ip route add default scope global table $LB_TABLE"
        for ((i=0; i<ACTIVE_COUNT; i++)); do
            local IFACE_NAME=${ACTIVE_IFACES[$i]}
            local WEIGHT=1

            # Heuristic for weighting
            if [[ "$IFACE_NAME" =~ ^(eno|ens|enp|eth) ]]; then
                WEIGHT=5 # Wired Ethernet
            elif [[ "$IFACE_NAME" =~ ^(wlan|wlp|wlx|wl) ]]; then
                WEIGHT=3 # Wi-Fi
            elif [[ "$IFACE_NAME" =~ ^(enx) ]]; then
                WEIGHT=2 # USB Ethernet
            else
                WEIGHT=1 # Fallback
            fi

            MP_CMD="$MP_CMD nexthop via ${ACTIVE_GWS[$i]} dev ${ACTIVE_IFACES[$i]} weight $WEIGHT"
        done

        eval "$MP_CMD"
        ip rule add pref $LB_PREF lookup $LB_TABLE

        # Configure NAT
        nft add table ip loadbalancing
        nft add chain ip loadbalancing postrouting { type nat hook postrouting priority 100 \; }
        for ((i=0; i<ACTIVE_COUNT; i++)); do
            nft add rule ip loadbalancing postrouting oifname "${ACTIVE_IFACES[$i]}" masquerade
        done
    fi

    ip route flush cache

    # Update metrics
    if [ "$METRICS_ENABLED" = "true" ]; then
        METRICS_GAUGES[active_interfaces]=$ACTIVE_COUNT
        write_metrics_file
    fi

    log "Configuration applied. Active interfaces: ${ACTIVE_IFACES[*]} (draining enabled: $CONNECTION_DRAINING_ENABLED)"
}

get_current_state() {
    # Scans 'main' table for default routes
    # Returns sorted string: "iface,gw,ip iface,gw,ip"
    local OUTPUT=""

    # Read explicitly from table main to see what NetworkManager sees
    local RAW_ROUTES=$(ip route show table main | grep "default via")

    while read -r line; do
        if [[ "$line" != *"via "* ]] || [[ "$line" != *"dev "* ]]; then continue; fi

        local IFACE=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
        local GW=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
        local IP=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

        if [ -n "$IFACE" ] && [ -n "$GW" ] && [ -n "$IP" ]; then
            # Format: "iface,gw,ip"
            OUTPUT="$OUTPUT $IFACE,$GW,$IP"
        fi
    done <<< "$RAW_ROUTES"

    # Sort to ensure consistency (order changes shouldn't trigger reload)
    echo "$OUTPUT" | tr ' ' '\n' | sort | xargs
}

get_current_state_with_health() {
    # Gets current state and performs health checks
    # Returns sorted string: "iface,gw,ip,health iface,gw,ip,health"
    local OUTPUT=""
    local CURRENT_STATE=$(get_current_state)

    IFS=' ' read -r -a ENTRIES <<< "$CURRENT_STATE"
    for entry in "${ENTRIES[@]}"; do
        IFS=',' read -r iface gw ip <<< "$entry"

        # Perform health check
        check_interface_health "$iface" "$gw" "$ip"
        local HEALTH_STATUS="${INTERFACE_HEALTH[$iface]:-up}"

        # Format: "iface,gw,ip,health"
        OUTPUT="$OUTPUT $iface,$gw,$ip,$HEALTH_STATUS"
    done

    # Sort to ensure consistency
    echo "$OUTPUT" | tr ' ' '\n' | sort | xargs
}

# --- Main Loop ---
log "Starting Network Auto-Balancer with real-time monitoring..."

# Start metrics server if enabled
start_metrics_server

# Force initial configuration
LAST_STATE="FORCE_INIT"
CURRENT_STATE=$(get_current_state_with_health)
update_balancing "$CURRENT_STATE"
LAST_STATE="$CURRENT_STATE"

# Monitor netlink events in real-time
log "Monitoring network events..."
ip monitor route link | while read -r line; do
    CURRENT_TIME=$(date +%s)

    # Debounce events to avoid rapid reconfiguration
    if [ $((CURRENT_TIME - LAST_EVENT_TIME)) -lt $DEBOUNCE_TIME ]; then
        continue
    fi

    log "Network event detected: $line"
    LAST_EVENT_TIME=$CURRENT_TIME

    # Check current state after debouncing
    CURRENT_STATE=$(get_current_state_with_health)

    if [ "$CURRENT_STATE" != "$LAST_STATE" ]; then
        update_balancing "$CURRENT_STATE"
        LAST_STATE="$CURRENT_STATE"
    fi
done
