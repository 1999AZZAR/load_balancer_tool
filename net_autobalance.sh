#!/bin/bash
# Network Auto-Balancer Daemon
# Monitors 'main' routing table and maintains a load-balanced overlay in Table 200.

# Config
LB_TABLE=200
LB_PREF=90
CHECK_INTERVAL=5

# State tracking
LAST_STATE=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
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

    # 1. Partial Cleanup (remove our overlay, keep main)
    ip rule del pref $LB_PREF 2>/dev/null || true
    ip route flush table $LB_TABLE 2>/dev/null || true
    nft delete table ip loadbalancing 2>/dev/null || true
    
    # 2. Parse State
    # State format: "iface1,gw1,ip1 iface2,gw2,ip2 ..."
    declare -a IFACES
    declare -a GWS
    declare -a IPS
    local COUNT=0
    
    IFS=' ' read -r -a ENTRIES <<< "$STATE_STRING"
    for entry in "${ENTRIES[@]}"; do
        IFS=',' read -r iface gw ip <<< "$entry"
        IFACES[$COUNT]=$iface
        GWS[$COUNT]=$gw
        IPS[$COUNT]=$ip
        
        # Flush the specific table for this index before using
        local T_ID=$((100 + COUNT))
        ip route flush table $T_ID 2>/dev/null || true
        while ip rule show | grep -q "lookup $T_ID"; do
            ip rule del table $T_ID 2>/dev/null || true
        done
        
        ((COUNT++))
    done

    if [ "$COUNT" -eq 0 ]; then
        log "No active connections. Waiting..."
        return
    fi

    # 3. Configure Per-Interface Tables (For Return Traffic)
    for ((i=0; i<COUNT; i++)); do
        local IFACE=${IFACES[$i]}
        local GW=${GWS[$i]}
        local IP=${IPS[$i]}
        local T_ID=$((100 + i))

        # Add routes to specific table
        ip route add "$GW" dev "$IFACE" src "$IP" table "$T_ID"
        ip route add default via "$GW" dev "$IFACE" table "$T_ID"
        
        # Add rule for return traffic
        ip rule add from "$IP" table "$T_ID" priority $((100 + i))
    done

    # 4. Configure Multipath (Load Balancing) in Table 200
    local MP_CMD="ip route add default scope global table $LB_TABLE"
    for ((i=0; i<COUNT; i++)); do
        local IFACE_NAME=${IFACES[$i]}
        local WEIGHT=1
        
        # Heuristic for weighting
        if [[ "$IFACE_NAME" =~ ^(eno|ens|enp|eth) ]]; then
            WEIGHT=5 # Wired Ethernet (PCI/PCIe/Onboard)
        elif [[ "$IFACE_NAME" =~ ^(wlan|wlp|wlx|wl) ]]; then
            WEIGHT=3 # Wi-Fi
        elif [[ "$IFACE_NAME" =~ ^(enx) ]]; then
            WEIGHT=2 # USB Ethernet / Tethering often shows as enx...
        else
            WEIGHT=1 # Fallback (usb0, tun, etc)
        fi

        MP_CMD="$MP_CMD nexthop via ${GWS[$i]} dev ${IFACES[$i]} weight $WEIGHT"
    done
    
    eval "$MP_CMD"

    # 5. Activate Overlay
    # Traffic not matched by specific IP rules falls through to here
    ip rule add pref $LB_PREF lookup $LB_TABLE

    # 6. Configure NAT
    nft add table ip loadbalancing
    nft add chain ip loadbalancing postrouting { type nat hook postrouting priority 100 \; }
    for ((i=0; i<COUNT; i++)); do
        nft add rule ip loadbalancing postrouting oifname "${IFACES[$i]}" masquerade
    done
    
    ip route flush cache
    log "Configuration applied. Active interfaces: ${IFACES[*]}"
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

# --- Main Loop ---
log "Starting Network Auto-Balancer..."

# Force initial cleanup/check
LAST_STATE="FORCE_INIT"

while true; do
    CURRENT_STATE=$(get_current_state)
    
    if [ "$CURRENT_STATE" != "$LAST_STATE" ]; then
        update_balancing "$CURRENT_STATE"
        LAST_STATE="$CURRENT_STATE"
    fi
    
    sleep $CHECK_INTERVAL
done
