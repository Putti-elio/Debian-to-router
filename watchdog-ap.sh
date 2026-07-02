#!/bin/bash
set -euo pipefail

CONFIG_FILE="/etc/router-mode/config"
ROUTER_SERVICE="router-mode.service"
HOSTAPD_SERVICE="hostapd.service"
LOG_TAG="router-ap-watchdog"

log() {
    logger -t "$LOG_TAG" "$1"
    printf '%s\n' "$1"
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "Config file $CONFIG_FILE not found"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    if [ -z "${AP_IFACE:-}" ]; then
        log "AP_IFACE missing from $CONFIG_FILE"
        return 1
    fi
}

ap_iface_present() {
    ip link show "$AP_IFACE" >/dev/null 2>&1
}

ap_iface_is_up() {
    ip -br link show dev "$AP_IFACE" 2>/dev/null | grep -Eq '\bUP\b'
}

ap_is_advertised() {
    iw dev "$AP_IFACE" info >/dev/null 2>&1
}

restart_router() {
    log "Restarting $ROUTER_SERVICE because AP health check failed"
    systemctl restart "$ROUTER_SERVICE"
}

main() {
    if ! load_config; then
        exit 1
    fi

    if ! systemctl is-active --quiet "$HOSTAPD_SERVICE"; then
        log "$HOSTAPD_SERVICE is not active"
        restart_router
        exit 0
    fi

    if ! ap_iface_present; then
        log "AP interface $AP_IFACE is missing"
        restart_router
        exit 0
    fi

    if ! ap_iface_is_up; then
        log "AP interface $AP_IFACE is not UP"
        restart_router
        exit 0
    fi

    if ! ap_is_advertised; then
        log "AP interface $AP_IFACE is not usable via iw"
        restart_router
        exit 0
    fi

    log "AP health check OK on $AP_IFACE"
}

main "$@"
