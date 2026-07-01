#!/bin/bash
set -euo pipefail

PROJECT_ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
# shellcheck source=../router.sh
source "$PROJECT_ROOT/router.sh"

TMPDIR_TEST=""

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    if [ "$expected" != "$actual" ]; then
        fail "$message (expected: '$expected', got: '$actual')"
    fi
}

assert_ok() {
    local message="$1"
    shift
    if ! "$@"; then
        fail "$message"
    fi
}

assert_fail() {
    local message="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$message"
    fi
}

run_tests() {
    TMPDIR_TEST=$(mktemp -d)
    trap 'rm -rf "$TMPDIR_TEST"' EXIT

    CONFIG_DIR="$TMPDIR_TEST/config-dir"
    CONFIG_FILE="$CONFIG_DIR/config"
    LOG_FILE="$TMPDIR_TEST/test.log"

    AP_IFACE='wlan0'
    WAN_IFACE='eth0'
    AP_NAME='Cafe "Routeur" $5'
    AP_PASSWORD='pass\word$9'
    LAN_GW='192.168.50.1'
    LAN_DHCP_START='192.168.50.50'
    LAN_DHCP_END='192.168.50.150'
    WIFI_BAND='2.4'
    WIFI_CHANNEL='11'
    WIFI_COUNTRY_CODE='CA'
    DISABLE_GUI='n'
    ENABLE_AT_BOOT='y'

    assert_ok "save_config should write config" save_config

    AP_IFACE=''
    WAN_IFACE=''
    AP_NAME=''
    AP_PASSWORD=''
    LAN_GW=''
    LAN_DHCP_START=''
    LAN_DHCP_END=''
    WIFI_BAND=''
    WIFI_CHANNEL=''
    WIFI_COUNTRY_CODE=''
    DISABLE_GUI=''
    ENABLE_AT_BOOT=''

    assert_ok "load_config should parse known keys" load_config
    assert_eq 'wlan0' "$AP_IFACE" 'AP_IFACE round-trip failed'
    assert_eq 'eth0' "$WAN_IFACE" 'WAN_IFACE round-trip failed'
    assert_eq 'Cafe "Routeur" $5' "$AP_NAME" 'AP_NAME round-trip failed'
    assert_eq 'pass\word$9' "$AP_PASSWORD" 'AP_PASSWORD round-trip failed'
    assert_eq '11' "$WIFI_CHANNEL" 'WIFI_CHANNEL round-trip failed'
    assert_eq 'y' "$ENABLE_AT_BOOT" 'ENABLE_AT_BOOT round-trip failed'

    printf 'EVIL_KEY="oops"\n' >> "$CONFIG_FILE"
    assert_fail "load_config should reject unexpected keys" load_config

    assert_eq '2412' "$(channel_to_frequency 1)" 'Channel 1 frequency mismatch'
    assert_eq '2472' "$(channel_to_frequency 13)" 'Channel 13 frequency mismatch'
    assert_eq '2484' "$(channel_to_frequency 14)" 'Channel 14 frequency mismatch'
    assert_fail "Invalid channel should fail" channel_to_frequency 15

    local sysfs_root="$TMPDIR_TEST/sys"
    mkdir -p "$sysfs_root/wlan0/device/power"
    printf 'auto' > "$sysfs_root/wlan0/device/power/control"
    printf '2000' > "$sysfs_root/wlan0/device/power/autosuspend_delay_ms"

    SYSFS_NET_DIR="$sysfs_root"
    LOG_FILE="$TMPDIR_TEST/power.log"
    assert_ok "disable_interface_runtime_power_management should succeed" disable_interface_runtime_power_management wlan0
    assert_eq 'on' "$(cat "$sysfs_root/wlan0/device/power/control")" 'runtime PM control should be forced on'
    assert_eq '-1' "$(cat "$sysfs_root/wlan0/device/power/autosuspend_delay_ms")" 'autosuspend delay should be disabled'

    printf 'PASS\n'
}

run_tests
