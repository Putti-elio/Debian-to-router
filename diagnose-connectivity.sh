#!/bin/bash
set -euo pipefail

LAN_IFACE="wlan1"
WAN_IFACE="eth0"
LAN_GW="192.168.50.1"
UPLINK_GW="10.100.0.1"
EXTERNAL_IP="1.1.1.1"
DNS_NAME="google.com"
INTERVAL=5
COUNT=0
OUTPUT_FILE=""
CLIENT_IP=""

usage() {
    cat <<'EOF'
Usage: sudo ./diagnose-connectivity.sh [options]

Capture recurring router snapshots to debug "connected but no Internet" failures.

Options:
  --lan-iface IFACE     LAN/AP interface (default: wlan1)
  --wan-iface IFACE     WAN/uplink interface (default: eth0)
  --lan-gw IP           LAN gateway IP to test (default: 192.168.50.1)
  --uplink-gw IP        WAN gateway IP to test (default: 10.100.0.1)
  --external-ip IP      External IP to test (default: 1.1.1.1)
  --dns-name NAME       Hostname to resolve (default: google.com)
  --client-ip IP        Optional LAN client IP to probe
  --interval SECONDS    Delay between snapshots (default: 5)
  --count N             Number of snapshots, 0 = run until Ctrl-C (default: 0)
  --output FILE         Write logs to FILE as well as stdout
  --help                Show this help

Examples:
  sudo ./diagnose-connectivity.sh --client-ip 192.168.50.104
  sudo ./diagnose-connectivity.sh --interval 2 --count 30 --output /tmp/router-diag.log
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --lan-iface)
            LAN_IFACE="$2"
            shift 2
            ;;
        --wan-iface)
            WAN_IFACE="$2"
            shift 2
            ;;
        --lan-gw)
            LAN_GW="$2"
            shift 2
            ;;
        --uplink-gw)
            UPLINK_GW="$2"
            shift 2
            ;;
        --external-ip)
            EXTERNAL_IP="$2"
            shift 2
            ;;
        --dns-name)
            DNS_NAME="$2"
            shift 2
            ;;
        --client-ip)
            CLIENT_IP="$2"
            shift 2
            ;;
        --interval)
            INTERVAL="$2"
            shift 2
            ;;
        --count)
            COUNT="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
    printf 'interval and count must be integers\n' >&2
    exit 1
fi

if [ -n "$OUTPUT_FILE" ]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    touch "$OUTPUT_FILE"
    exec > >(tee -a "$OUTPUT_FILE") 2>&1
fi

log_section() {
    printf '\n===== %s =====\n' "$1"
}

run_or_note() {
    local label="$1"
    local status=0
    shift

    log_section "$label"
    if "$@"; then
        return 0
    fi

    status=$?

    printf 'command failed with exit %s\n' "$status"
}

probe_ping() {
    local label="$1"
    local target="$2"
    local status=0

    log_section "$label"
    if ping -c 2 -W 1 "$target"; then
        return 0
    fi

    status=$?

    printf 'ping failed for %s with exit %s\n' "$target" "$status"
}

snapshot() {
    printf '\n\n######## %s ########\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"

    run_or_note "IP addresses" ip -br addr
    run_or_note "LAN interface details" ip -s link show "$LAN_IFACE"
    run_or_note "WAN interface details" ip -s link show "$WAN_IFACE"
    run_or_note "Routes" ip route
    run_or_note "Route to LAN client" ip route get "${CLIENT_IP:-$LAN_GW}"
    run_or_note "Route to external IP" ip route get "$EXTERNAL_IP"
    run_or_note "Wireless devices" iw dev
    run_or_note "Associated stations" iw dev "$LAN_IFACE" station dump
    run_or_note "Wireless driver info" ethtool -i "$LAN_IFACE"
    run_or_note "USB runtime power state" sh -c "for file in /sys/class/net/$LAN_IFACE/device/power/control /sys/class/net/$LAN_IFACE/device/power/runtime_status /sys/class/net/$LAN_IFACE/device/power/autosuspend_delay_ms; do [ -e \"\$file\" ] && printf '%s: ' \"\$file\" && cat \"\$file\"; done"
    run_or_note "NetworkManager devices" nmcli device status
    run_or_note "RFKill state" rfkill list
    run_or_note "Listening UDP sockets" ss -lunp
    run_or_note "Systemd service states" systemctl --no-pager --full status hostapd dnsmasq dns router-mode.service NetworkManager

    probe_ping "Ping LAN gateway" "$LAN_GW"
    probe_ping "Ping uplink gateway" "$UPLINK_GW"
    probe_ping "Ping external IP" "$EXTERNAL_IP"

    if [ -n "$CLIENT_IP" ]; then
        probe_ping "Ping LAN client" "$CLIENT_IP"
    fi

    run_or_note "DNS resolution" getent hosts "$DNS_NAME"
    run_or_note "hostapd and router logs" journalctl -u hostapd -u dnsmasq -u dns -u router-mode.service -u NetworkManager -n 60 --no-pager
    run_or_note "Recent kernel Wi-Fi/USB logs" journalctl -k -n 120 --no-pager
}

iteration=0
while :; do
    snapshot

    iteration=$((iteration + 1))
    if [ "$COUNT" -gt 0 ] && [ "$iteration" -ge "$COUNT" ]; then
        break
    fi

    sleep "$INTERVAL"
done
