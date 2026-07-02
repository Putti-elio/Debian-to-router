#!/bin/bash
set -euo pipefail

WATCHDOG_SCRIPT_DST="/usr/local/sbin/router-ap-watchdog"
SERVICE_DST="/etc/systemd/system/router-ap-watchdog.service"
TIMER_DST="/etc/systemd/system/router-ap-watchdog.timer"

if [ "$(id -u)" -ne 0 ]; then
    printf 'This script must be run as root.\n' >&2
    exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now router-ap-watchdog.timer 2>/dev/null || true
    systemctl stop router-ap-watchdog.service 2>/dev/null || true
fi

rm -f "$WATCHDOG_SCRIPT_DST" "$SERVICE_DST" "$TIMER_DST"

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
fi

printf 'AP watchdog uninstalled.\n'
