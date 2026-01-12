#!/bin/bash
# Load Balancer Test Harness
# Simulates various failure scenarios for testing the load balancer

if [ "$EUID" -ne 0 ]; then
    echo "Error: Must be run as root."
    exit 1
fi

LOG_FILE="/var/log/load_balancer_test.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Get list of interfaces with default routes
get_interfaces() {
    ip route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | sort | uniq
}

# Test functions
test_interface_down_up() {
    local iface="$1"
    local duration="${2:-10}"

    log "Test: Bringing $iface down for $duration seconds"
    ip link set dev "$iface" down
    sleep "$duration"
    ip link set dev "$iface" up
    log "Test: $iface brought back up"
}

test_route_flapping() {
    local iface="$1"
    local count="${2:-5}"

    log "Test: Route flapping on $iface ($count times)"
    for ((i=1; i<=count; i++)); do
        log "  Flap $i: bringing down"
        ip link set dev "$iface" down
        sleep 2
        log "  Flap $i: bringing up"
        ip link set dev "$iface" up
        sleep 5
    done
}

test_neighbor_failure() {
    local iface="$1"
    local gw

    # Find gateway for interface
    gw=$(ip route show default dev "$iface" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
    if [ -z "$gw" ]; then
        log "Error: No gateway found for $iface"
        return 1
    fi

    log "Test: Simulating neighbor failure for $iface gateway $gw"
    # Flush neighbor entry to simulate failure
    ip neigh flush dev "$iface" "$gw"
    log "Test: Neighbor entry flushed, waiting for recovery..."
    sleep 30
}

test_health_check_failure() {
    local duration="${1:-30}"

    log "Test: Blocking health check target for $duration seconds"
    # Add a temporary rule to block the health check target
    # This assumes HEALTH_PROBE_TARGET is 1.1.1.1
    iptables -I OUTPUT -d 1.1.1.1 -j DROP 2>/dev/null || true
    sleep "$duration"
    iptables -D OUTPUT -d 1.1.1.1 -j DROP 2>/dev/null || true
    log "Test: Health check target unblocked"
}

show_status() {
    log "Current status:"
    echo "Active interfaces:"
    get_interfaces | while read -r iface; do
        local state=$(ip link show "$iface" | grep -o "state [A-Z]*" | cut -d' ' -f2)
        local gw=$(ip route show default dev "$iface" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
        echo "  $iface: $state, GW: $gw"
    done

    echo "Routing table 200:"
    ip route show table 200

    echo "NFT rules:"
    nft list table ip loadbalancing 2>/dev/null || echo "  No loadbalancing table"
}

run_comprehensive_test() {
    local interfaces
    mapfile -t interfaces < <(get_interfaces)

    if [ ${#interfaces[@]} -lt 2 ]; then
        log "Warning: Only ${#interfaces[@]} interfaces found. Some tests may not be meaningful."
    fi

    log "Starting comprehensive test suite..."

    # Test 1: Basic interface failover
    if [ ${#interfaces[@]} -ge 1 ]; then
        test_interface_down_up "${interfaces[0]}" 15
        sleep 10
    fi

    # Test 2: Route flapping
    if [ ${#interfaces[@]} -ge 1 ]; then
        test_route_flapping "${interfaces[0]}" 3
        sleep 10
    fi

    # Test 3: Neighbor failure simulation
    if [ ${#interfaces[@]} -ge 1 ]; then
        test_neighbor_failure "${interfaces[0]}"
        sleep 10
    fi

    # Test 4: Health check failure
    test_health_check_failure 20
    sleep 10

    # Test 5: Multiple interface coordination
    if [ ${#interfaces[@]} -ge 2 ]; then
        log "Test: Coordinating multiple interfaces"
        test_interface_down_up "${interfaces[0]}" 10 &
        sleep 5
        test_interface_down_up "${interfaces[1]}" 10 &
        wait
        sleep 15
    fi

    log "Comprehensive test suite completed"
    show_status
}

usage() {
    echo "Load Balancer Test Harness"
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  status                    Show current load balancer status"
    echo "  down-up IFACE [SECONDS]   Bring interface down then up"
    echo "  flap IFACE [COUNT]        Simulate route flapping"
    echo "  neighbor-fail IFACE       Simulate neighbor unreachability"
    echo "  health-block [SECONDS]    Block health check target"
    echo "  comprehensive             Run full test suite"
    echo ""
    echo "Examples:"
    echo "  $0 status"
    echo "  $0 down-up wlan0 30"
    echo "  $0 flap eth0 5"
    echo "  $0 comprehensive"
}

case "${1:-comprehensive}" in
    "status")
        show_status
        ;;
    "down-up")
        if [ -z "$2" ]; then
            echo "Error: Interface name required"
            exit 1
        fi
        test_interface_down_up "$2" "${3:-10}"
        ;;
    "flap")
        if [ -z "$2" ]; then
            echo "Error: Interface name required"
            exit 1
        fi
        test_route_flapping "$2" "${3:-5}"
        ;;
    "neighbor-fail")
        if [ -z "$2" ]; then
            echo "Error: Interface name required"
            exit 1
        fi
        test_neighbor_failure "$2"
        ;;
    "health-block")
        test_health_check_failure "${2:-30}"
        ;;
    "comprehensive")
        run_comprehensive_test
        ;;
    *)
        usage
        exit 1
        ;;
esac