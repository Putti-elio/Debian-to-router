#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
WATCHDOG_SCRIPT_SRC="$SCRIPT_DIR/watchdog-ap.sh"
WATCHDOG_SCRIPT_DST="/usr/local/sbin/router-ap-watchdog"
SERVICE_SRC="$SCRIPT_DIR/systemd/router-ap-watchdog.service"
SERVICE_DST="/etc/systemd/system/router-ap-watchdog.service"
TIMER_SRC="$SCRIPT_DIR/systemd/router-ap-watchdog.timer"
TIMER_DST="/etc/systemd/system/router-ap-watchdog.timer"
ROUTER_CONFIG_FILE="/etc/router-mode/config"
ROUTER_SERVICE="router-mode.service"
AP_IFACE=""

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$command_name" >&2
        exit 1
    fi
}

require_router_config() {
    if [ ! -f "$ROUTER_CONFIG_FILE" ]; then
        printf 'Missing router config: %s\n' "$ROUTER_CONFIG_FILE" >&2
        printf 'Run the router setup first so AP_IFACE is saved.\n' >&2
        exit 1
    fi

    if ! grep -q '^AP_IFACE=".*"$' "$ROUTER_CONFIG_FILE"; then
        printf 'AP_IFACE is missing from %s\n' "$ROUTER_CONFIG_FILE" >&2
        exit 1
    fi

    AP_IFACE=$(sed -n 's/^AP_IFACE="\(.*\)"$/\1/p' "$ROUTER_CONFIG_FILE" | head -n 1)
    if [ -z "$AP_IFACE" ]; then
        printf 'AP_IFACE could not be parsed from %s\n' "$ROUTER_CONFIG_FILE" >&2
        exit 1
    fi
}

require_ap_interface_present() {
    if ! ip link show "$AP_IFACE" >/dev/null 2>&1; then
        printf 'Configured AP interface is missing: %s\n' "$AP_IFACE" >&2
        printf 'Plug the Wi-Fi adapter back in and rerun the installer.\n' >&2
        exit 1
    fi
}

require_router_service() {
    if ! systemctl list-unit-files "$ROUTER_SERVICE" >/dev/null 2>&1; then
        printf 'Missing required systemd unit: %s\n' "$ROUTER_SERVICE" >&2
        printf 'Install or enable the router service before the watchdog.\n' >&2
        exit 1
    fi
}

if [ "$(id -u)" -ne 0 ]; then
    printf 'This script must be run as root.\n' >&2
    exit 1
fi

for required_command in install systemctl systemd-analyze bash ip sed; do
    require_command "$required_command"
done

for required_file in "$WATCHDOG_SCRIPT_SRC" "$SERVICE_SRC" "$TIMER_SRC"; do
    if [ ! -f "$required_file" ]; then
        printf 'Missing required file: %s\n' "$required_file" >&2
        exit 1
    fi
done

require_router_service
require_router_config
require_ap_interface_present

bash -n "$WATCHDOG_SCRIPT_SRC"

install -m 755 "$WATCHDOG_SCRIPT_SRC" "$WATCHDOG_SCRIPT_DST"
install -D -m 644 "$SERVICE_SRC" "$SERVICE_DST"
install -D -m 644 "$TIMER_SRC" "$TIMER_DST"

systemctl daemon-reload
systemd-analyze verify "$SERVICE_DST" "$TIMER_DST"
systemctl enable --now router-ap-watchdog.timer

systemctl is-enabled router-ap-watchdog.timer >/dev/null
systemctl is-active router-ap-watchdog.timer >/dev/null

printf 'AP watchdog installed and enabled.\n'
printf 'Check status with:\n'
printf '  systemctl status router-ap-watchdog.timer router-ap-watchdog.service --no-pager\n'
printf '  journalctl -u router-ap-watchdog.service -n 50 --no-pager\n'
