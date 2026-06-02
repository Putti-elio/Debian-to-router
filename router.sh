#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONF_NAME_FILE="ROUTER_MODE"
CONFIG_FILE="/etc/router-mode/config"
CONFIG_DIR="/etc/router-mode"
SCRIPT_INSTALL_PATH="/usr/local/sbin/router-mode"
TECHNITIUM_DNS_SERVICE="dns.service"
TECHNITIUM_INSTALL_DIR="/opt/technitium/dns"
WAN_IFACE_BOOT_WAIT=30
WIFI_BAND="2.4"
WIFI_CHANNEL="1"
LAN_GW="192.168.50.1"
LAN_SUBNET="24"
LAN_DHCP_START="192.168.50.50"
LAN_DHCP_END="192.168.50.150"

SYSCTL_DROPIN="/etc/sysctl.d/99-router-ipforward.conf"
ROUTER_CHAIN="ROUTER_FORWARD"
PROJECT_LOG_DIR="/home/routeur/Debian-to-router"
LEGACY_LOG_FILE="/var/log/router-mode.log"
LOG_FILE=""

init_logging() {
    if [ -d "$PROJECT_LOG_DIR" ]; then
        LOG_FILE="$PROJECT_LOG_DIR/router-mode.log"
    else
        LOG_FILE="$LEGACY_LOG_FILE"
    fi

    if [ "$LOG_FILE" != "$LEGACY_LOG_FILE" ] && [ -f "$LEGACY_LOG_FILE" ]; then
        rm -f "$LEGACY_LOG_FILE" 2>/dev/null || true
    fi

    rm -f "$LOG_FILE" 2>/dev/null || true
}

_log_to_file() {
    [ -z "${LOG_FILE:-}" ] && return 0
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '[%s] %s\n' "$timestamp" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

log() {
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    echo -e "${GREEN}[${msg%% *}]${NC} ${msg#* }"
    _log_to_file "$1"
}

error() {
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    echo -e "${RED}[ERROR]${NC} ${msg#* }" >&2
    _log_to_file "ERROR: $1"
}

warning() {
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    echo -e "${YELLOW}[WARNING]${NC} ${msg#* }"
    _log_to_file "WARNING: $1"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root"
        exit 1
    fi
}

escape_shell_value() {
    local val="$1"
    val="${val//\\/\\\\}"
    val="${val//\$/\\\$}"
    val="${val//\`/\\\`}"
    val="${val//\"/\\\"}"
    printf '%s' "$val"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

validate_config() {
    if [ -z "${AP_NAME:-}" ] || [ -z "${AP_PASSWORD:-}" ]; then
        return 1
    fi
    if [ ${#AP_PASSWORD} -lt 8 ]; then
        return 1
    fi
    return 0
}

validate_ssid() {
    local ssid="$1"
    if [ -z "$ssid" ]; then
        error "SSID cannot be empty"
        return 1
    fi
    if printf '%s' "$ssid" | grep -qP '[\x00-\x1F\x7F]'; then
        error "SSID cannot contain control characters"
        return 1
    fi
    local len
    len=$(printf '%s' "$ssid" | wc -c)
    if [ "$len" -gt 32 ]; then
        error "SSID cannot exceed 32 bytes"
        return 1
    fi
    return 0
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
AP_IFACE="$(escape_shell_value "$AP_IFACE")"
WAN_IFACE="$(escape_shell_value "$WAN_IFACE")"
AP_NAME="$(escape_shell_value "$AP_NAME")"
AP_PASSWORD="$(escape_shell_value "$AP_PASSWORD")"
LAN_GW="$(escape_shell_value "$LAN_GW")"
LAN_DHCP_START="$(escape_shell_value "$LAN_DHCP_START")"
LAN_DHCP_END="$(escape_shell_value "$LAN_DHCP_END")"
WIFI_BAND="$(escape_shell_value "$WIFI_BAND")"
WIFI_CHANNEL="$(escape_shell_value "$WIFI_CHANNEL")"
DISABLE_GUI="$(escape_shell_value "$DISABLE_GUI")"
ENABLE_AT_BOOT="$(escape_shell_value "$ENABLE_AT_BOOT")"
EOF
    chmod 600 "$CONFIG_FILE"
}

cleanup_router() {
    log "Stopping and disabling router services..."
    systemctl disable --quiet router-mode.service 2>/dev/null || true
    systemctl stop --quiet router-mode.service 2>/dev/null || true
    systemctl disable --quiet hostapd dnsmasq netfilter-persistent 2>/dev/null || true
    systemctl stop --quiet hostapd dnsmasq netfilter-persistent 2>/dev/null || true

    log "Returning AP interface control to NetworkManager..."
    local ap_iface_conf="/etc/network/interfaces.d/${CONF_NAME_FILE}.conf"
    if [ -f "$ap_iface_conf" ]; then
        local ap_iface_clean
        ap_iface_clean=$(awk '/iface/ {print $2}' "$ap_iface_conf")
        if [ -n "$ap_iface_clean" ]; then
            nmcli dev set "$ap_iface_clean" managed yes 2>/dev/null || true
            ip addr flush dev "$ap_iface_clean" 2>/dev/null || true
        fi
    fi

    log "Removing configuration files and restoring defaults..."
    rm -f "/etc/network/interfaces.d/${CONF_NAME_FILE}.conf"
    rm -f "/etc/NetworkManager/conf.d/${CONF_NAME_FILE}.conf"
    rm -f /etc/hostapd/hostapd.conf
    rm -f /etc/dnsmasq.d/router.conf
    rm -f /etc/default/hostapd
    rm -f "$SYSCTL_DROPIN"
    rm -f /etc/systemd/system/router-mode.service
    rm -rf "$CONFIG_DIR"
    rm -f "$SCRIPT_INSTALL_PATH"

    [ -f /etc/hostapd/default_hostapd.conf ] && mv /etc/hostapd/default_hostapd.conf /etc/hostapd/hostapd.conf
    [ -f /etc/default_dnsmasq.conf ] && mv /etc/default_dnsmasq.conf /etc/dnsmasq.conf

    log "Restoring sysctl configuration..."
    if [ -f /etc/old_sysctl.conf ]; then
        mv /etc/old_sysctl.conf /etc/sysctl.conf
    fi
    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true

    log "Flushing iptables router rules..."
    iptables -F "$ROUTER_CHAIN" 2>/dev/null || true
    iptables -D FORWARD -j "$ROUTER_CHAIN" 2>/dev/null || true
    iptables -X "$ROUTER_CHAIN" 2>/dev/null || true
    iptables -t nat -F "$ROUTER_CHAIN" 2>/dev/null || true
    iptables -t nat -D PREROUTING -j "$ROUTER_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$ROUTER_CHAIN" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j "$ROUTER_CHAIN" 2>/dev/null || true
    iptables -t mangle -F "$ROUTER_CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$ROUTER_CHAIN" 2>/dev/null || true

    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -P FORWARD ACCEPT 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true

    netfilter-persistent save 2>/dev/null || true

    systemctl daemon-reload 2>/dev/null || true

    log "Restarting NetworkManager..."
    systemctl restart NetworkManager || true

    enable_graphical_interface
}

detect_interfaces() {
    log "Detecting network interfaces..."

    mapfile -t available_wifi_interfaces < <(
        nmcli -t -f DEVICE,TYPE,STATE device | awk -F: '$2=="wifi" {print $1}'
    )
    local supported_wifi_interfaces=()

    for iface in "${available_wifi_interfaces[@]:-}"; do
        [ -z "$iface" ] && continue
        local phy
        phy="phy$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/ {print $2}' || echo "")"
        if [ -n "$phy" ] && iw "$phy" info 2>/dev/null | grep -q 'AP$'; then
            supported_wifi_interfaces+=("$iface")
            log "Found AP-capable interface: $iface"
        fi
    done

    if [ "${#supported_wifi_interfaces[@]}" -eq 0 ]; then
        error "No Wi-Fi interface supporting AP mode found"
        return 1
    fi

    AP_IFACE="${supported_wifi_interfaces[0]}"
    log "Using Wi-Fi interface: $AP_IFACE"

    if [ -n "${WAN_IFACE:-}" ] && [ "${WAN_IFACE}" != "" ]; then
        if [ -f "/sys/class/net/${WAN_IFACE}/operstate" ]; then
            if [ "${1:-}" = "--boot" ]; then
                log "Waiting for WAN interface $WAN_IFACE (max ${WAN_IFACE_BOOT_WAIT}s)..."
                local waited=0
                while [ "$waited" -lt "$WAN_IFACE_BOOT_WAIT" ]; do
                    local wan_state
                    wan_state=$(cat "/sys/class/net/${WAN_IFACE}/operstate" 2>/dev/null || echo "unknown")
                    if [ "$wan_state" = "up" ] || [ "$wan_state" = "unknown" ]; then
                        log "WAN interface $WAN_IFACE is ready ($wan_state)"
                        break
                    fi
                    sleep 1
                    waited=$((waited + 1))
                done
                if [ "$waited" -ge "$WAN_IFACE_BOOT_WAIT" ]; then
                    warning "WAN interface $WAN_IFACE did not come up within ${WAN_IFACE_BOOT_WAIT}s"
                fi
            else
                local wan_state
                wan_state=$(cat "/sys/class/net/${WAN_IFACE}/operstate" 2>/dev/null || echo "unknown")
                log "WAN interface $WAN_IFACE state: $wan_state"
            fi
        else
            warning "Configured WAN interface $WAN_IFACE not found in /sys/class/net/"
        fi
        log "Using WAN interface: $WAN_IFACE"
    else
        mapfile -t source_eth_interfaces < <(
            nmcli -t -f DEVICE,TYPE,STATE device | awk -F: '$2=="ethernet" && $3=="connected" {print $1}'
        )
        if [ "${#source_eth_interfaces[@]}" -eq 0 ]; then
            error "No connected ethernet interface found for internet access"
            return 1
        fi
        WAN_IFACE="${source_eth_interfaces[0]}"
        log "Using WAN interface: $WAN_IFACE"
    fi

    return 0
}

install_packages() {
    log "Installing required packages..."
    apt-get update -y
    apt-get install -y hostapd dnsmasq iptables-persistent iw
}

install_technitium() {
    if systemctl list-unit-files "$TECHNITIUM_DNS_SERVICE" &>/dev/null; then
        log "Technitium DNS is already installed"
        if ! systemctl is-active --quiet "$TECHNITIUM_DNS_SERVICE"; then
            log "Starting Technitium DNS..."
            systemctl start "$TECHNITIUM_DNS_SERVICE" || error "Failed to start Technitium DNS"
        fi
        return 0
    fi

    if [ -d "$TECHNITIUM_INSTALL_DIR" ] && [ -f "${TECHNITIUM_INSTALL_DIR}/systemd.service" ]; then
        log "Technitium DNS directory found but service not registered, registering..."
        if [ -f "${TECHNITIUM_INSTALL_DIR}/systemd.service" ]; then
            cp "${TECHNITIUM_INSTALL_DIR}/systemd.service" /etc/systemd/system/dns.service
            systemctl daemon-reload
            systemctl enable "$TECHNITIUM_DNS_SERVICE"
            systemctl start "$TECHNITIUM_DNS_SERVICE" || error "Failed to start Technitium DNS"
        fi
        return 0
    fi

    log "Technitium DNS not found. Installing..."
    warning "This will download and install Technitium DNS from download.technitium.com"

    if command -v curl &>/dev/null; then
        curl -sSL https://download.technitium.com/dns/install.sh | bash
    elif command -v wget &>/dev/null; then
        wget -qO- https://download.technitium.com/dns/install.sh | bash
    else
        apt-get install -y curl
        curl -sSL https://download.technitium.com/dns/install.sh | bash
    fi

    if systemctl list-unit-files "$TECHNITIUM_DNS_SERVICE" &>/dev/null; then
        log "Technitium DNS installed successfully"
        systemctl enable "$TECHNITIUM_DNS_SERVICE"
        systemctl start "$TECHNITIUM_DNS_SERVICE" || error "Failed to start Technitium DNS"
    else
        error "Technitium DNS installation may have failed"
        return 1
    fi
}

update_technitium() {
    if ! systemctl list-unit-files "$TECHNITIUM_DNS_SERVICE" &>/dev/null; then
        warning "Technitium DNS is not installed, skipping update"
        return 0
    fi

    log "Checking for Technitium DNS update..."
    if command -v curl &>/dev/null; then
        curl -sSL https://download.technitium.com/dns/update.sh | bash
    else
        wget -qO- https://download.technitium.com/dns/update.sh | bash
    fi
    log "Technitium DNS update completed"
}

stop_services() {
    log "Stopping existing services..."
    systemctl stop hostapd 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true
    systemctl unmask hostapd 2>/dev/null || true
    systemctl unmask dnsmasq 2>/dev/null || true
    systemctl unmask netfilter-persistent 2>/dev/null || true
}

configure_network_interface() {
    log "Configuring network interface..."
    nmcli dev set "$AP_IFACE" managed no 2>/dev/null || true
    ip link set "$AP_IFACE" down 2>/dev/null || true
    ip addr flush dev "$AP_IFACE" 2>/dev/null || true
    ip addr add "${LAN_GW}/${LAN_SUBNET}" dev "$AP_IFACE"
    ip link set "$AP_IFACE" up
}

enable_ip_forwarding() {
    log "Enabling IP forwarding..."
    mkdir -p /etc/sysctl.d/
    cat > "$SYSCTL_DROPIN" <<EOF
net.ipv4.ip_forward=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.netdev_max_backlog=5000
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fastopen=3
EOF
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl --system >/dev/null
}

configure_hostapd() {
    log "Configuring hostapd..."
    [ -f /etc/hostapd/hostapd.conf ] && [ ! -f /etc/hostapd/default_hostapd.conf ] && \
        mv /etc/hostapd/hostapd.conf /etc/hostapd/default_hostapd.conf

    local channel="${WIFI_CHANNEL:-1}"

    if [ "${WIFI_BAND}" = "5" ]; then
        cat > /etc/hostapd/hostapd.conf <<EOF
interface=$AP_IFACE
driver=nl80211
country_code=CA
ieee80211d=1

ssid=$AP_NAME
hw_mode=a
channel=${channel:-36}

ieee80211n=1
ieee80211ac=1
wmm_enabled=1
ht_capab=[HT40+][SHORT-GI-20][SHORT-GI-40][MAX-AMSDU-7935]
vht_capab=[SHORT-GI-80][MAX-MPDU-3895]

auth_algs=1
wpa=2
wpa_passphrase=$AP_PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP

ignore_broadcast_ssid=0
macaddr_acl=0
EOF
    else
        cat > /etc/hostapd/hostapd.conf <<EOF
interface=$AP_IFACE
driver=nl80211
country_code=CA
ieee80211d=1

ssid=$AP_NAME
hw_mode=g
channel=$channel

ieee80211n=1
wmm_enabled=1
ht_capab=[SHORT-GI-20]

auth_algs=1
wpa=2
wpa_passphrase=$AP_PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP

ignore_broadcast_ssid=0
macaddr_acl=0
EOF
    fi

    cat > /etc/default/hostapd <<EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF
}

configure_dnsmasq() {
    log "Configuring dnsmasq (DHCP only, DNS via Technitium)..."
    [ -f /etc/dnsmasq.conf ] && [ ! -f /etc/default_dnsmasq.conf ] && \
        mv /etc/dnsmasq.conf /etc/default_dnsmasq.conf

    mkdir -p /etc/dnsmasq.d
    cat > /etc/dnsmasq.conf <<EOF
conf-dir=/etc/dnsmasq.d
EOF

    cat > /etc/dnsmasq.d/router.conf <<EOF
interface=$AP_IFACE
bind-interfaces

port=0

domain-needed
bogus-priv

dhcp-range=$LAN_DHCP_START,$LAN_DHCP_END,255.255.255.0,12h
dhcp-option=option:router,$LAN_GW
dhcp-option=option:dns-server,$LAN_GW

log-facility=/var/log/dnsmasq.log
log-dhcp
EOF
}

configure_iptables() {
    log "Configuring iptables (using dedicated chain $ROUTER_CHAIN)..."

    iptables -F "$ROUTER_CHAIN" 2>/dev/null || true
    iptables -D FORWARD -j "$ROUTER_CHAIN" 2>/dev/null || true
    iptables -X "$ROUTER_CHAIN" 2>/dev/null || true

    iptables -t nat -F "$ROUTER_CHAIN" 2>/dev/null || true
    iptables -t nat -D PREROUTING -j "$ROUTER_CHAIN" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j "$ROUTER_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$ROUTER_CHAIN" 2>/dev/null || true

    iptables -N "$ROUTER_CHAIN"
    iptables -A FORWARD -j "$ROUTER_CHAIN"

    iptables -A "$ROUTER_CHAIN" -i "$AP_IFACE" -o "$WAN_IFACE" -j ACCEPT
    iptables -A "$ROUTER_CHAIN" -i "$WAN_IFACE" -o "$AP_IFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A "$ROUTER_CHAIN" -i "$AP_IFACE" -p udp --dport 53 ! -d "$LAN_GW" -j DROP
    iptables -A "$ROUTER_CHAIN" -i "$AP_IFACE" -p tcp --dport 53 ! -d "$LAN_GW" -j DROP

    iptables -t nat -N "$ROUTER_CHAIN"
    iptables -t nat -A PREROUTING -j "$ROUTER_CHAIN"
    iptables -t nat -A "$ROUTER_CHAIN" -i "$AP_IFACE" -p udp --dport 53 -j DNAT --to-destination "$LAN_GW":53
    iptables -t nat -A "$ROUTER_CHAIN" -i "$AP_IFACE" -p tcp --dport 53 -j DNAT --to-destination "$LAN_GW":53

    iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE

    netfilter-persistent save
}

configure_persistent() {
    log "Configuring persistent router functionality..."

    mkdir -p /etc/NetworkManager/conf.d/
    cat > "/etc/NetworkManager/conf.d/${CONF_NAME_FILE}.conf" <<EOF
[keyfile]
unmanaged-devices=interface-name:${AP_IFACE}
EOF
    systemctl reload NetworkManager || true

    mkdir -p /etc/network/interfaces.d/
    cat > "/etc/network/interfaces.d/${CONF_NAME_FILE}.conf" <<EOF
auto ${AP_IFACE}
iface ${AP_IFACE} inet static
address ${LAN_GW}
netmask 255.255.255.0
EOF
}

install_script() {
    log "Installing script to system location..."
    cp "$0" "$SCRIPT_INSTALL_PATH"
    chmod +x "$SCRIPT_INSTALL_PATH"
    log "Script installed to $SCRIPT_INSTALL_PATH"
}

start_services() {
    rfkill unblock wifi 2>/dev/null || true

    log "Starting services..."
    if ! systemctl restart dnsmasq; then
        error "Failed to start dnsmasq"
        systemctl status dnsmasq --no-pager
        return 1
    fi
    log "dnsmasq started"

    if ! systemctl restart hostapd; then
        error "Failed to start hostapd"
        systemctl status hostapd --no-pager
        return 1
    fi
    log "hostapd started"

    sleep 3
    if ! systemctl is-active --quiet hostapd; then
        error "hostapd crashed after start"
        systemctl status hostapd --no-pager
        journalctl -u hostapd --no-pager -n 20
        return 1
    fi

    if ! systemctl is-active --quiet dnsmasq; then
        error "dnsmasq crashed after start"
        systemctl status dnsmasq --no-pager
        journalctl -u dnsmasq --no-pager -n 20
        return 1
    fi

    return 0
}

create_systemd_service() {
    log "Creating systemd service..."

    cat > /etc/systemd/system/router-mode.service <<EOF
[Unit]
Description=Router Mode Service
After=network.target NetworkManager.service NetworkManager-wait-online.service dns.service
Wants=network.target NetworkManager-wait-online.service dns.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SCRIPT_INSTALL_PATH --service
ExecStop=$SCRIPT_INSTALL_PATH --service-stop
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable router-mode.service
    log "Systemd service created and enabled"
}

stop_systemd_resolved() {
    if systemctl is-active --quiet systemd-resolved; then
        warning "systemd-resolved is running and will conflict with Technitium DNS on port 53"
        log "Stopping systemd-resolved..."
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        if [ -L /etc/resolv.conf ]; then
            rm -f /etc/resolv.conf
            echo "nameserver 127.0.0.1" > /etc/resolv.conf
        fi
    fi
}

apply_router_config() {
    if ! detect_interfaces "${1:-}"; then
        return 1
    fi

    stop_systemd_resolved
    configure_network_interface
    iw dev "$AP_IFACE" set power_save off 2>/dev/null || true
    enable_ip_forwarding
    configure_hostapd
    configure_dnsmasq
    configure_iptables

    if ! start_services; then
        return 1
    fi

    return 0
}

service_mode_start() {
    log "Router mode service starting..."

    if ! load_config; then
        error "No configuration found. Run script interactively first."
        exit 1
    fi

    LAN_GW="${LAN_GW:-192.168.50.1}"
    LAN_DHCP_START="${LAN_DHCP_START:-192.168.50.50}"
    LAN_DHCP_END="${LAN_DHCP_END:-192.168.50.150}"
    WIFI_BAND="${WIFI_BAND:-2.4}"
    WIFI_CHANNEL="${WIFI_CHANNEL:-1}"

    install_technitium || warning "Technitium DNS install failed, DNS may not work"

    if ! systemctl is-active --quiet "$TECHNITIUM_DNS_SERVICE"; then
        warning "Technitium DNS service is not running, attempting to start..."
        if systemctl start "$TECHNITIUM_DNS_SERVICE"; then
            log "Technitium DNS started"
        else
            error "Failed to start Technitium DNS - DNS for clients will not work"
        fi
    fi

    if apply_router_config --boot; then
        log "Router mode service started successfully"
        exit 0
    else
        error "Failed to start router mode service"
        exit 1
    fi
}

service_mode_stop() {
    log "Router mode service stopping..."
    systemctl stop hostapd 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true
    log "Router mode service stopped"
}

disable_graphical_interface() {
    log "Disabling graphical interface for lower resource usage..."
    if systemctl is-active --quiet gdm3 || \
       systemctl is-active --quiet lightdm || \
       systemctl is-active --quiet sddm || \
       systemctl is-active --quiet display-manager; then
        systemctl set-default multi-user.target
        log "System will boot to console mode (TTY) on next restart"
    else
        log "No graphical interface detected, already in console mode"
    fi
}

enable_graphical_interface() {
    log "Re-enabling graphical interface..."
    systemctl set-default graphical.target 2>/dev/null || true
    log "System will boot to graphical mode on next restart"
}

pick_wifi_channel() {
    log "Scanning for best Wi-Fi channel..."
    local scan_output
    scan_output=$(iw dev "$AP_IFACE" scan 2>/dev/null || true)

    local ch1_count=0 ch6_count=0 ch11_count=0
    ch1_count=$(echo "$scan_output" | grep -c "freq: 2412" || true)
    ch6_count=$(echo "$scan_output" | grep -c "freq: 2437" || true)
    ch11_count=$(echo "$scan_output" | grep -c "freq: 2462" || true)

    local best_channel=1
    local best_count=$ch1_count

    if [ "$ch6_count" -lt "$best_count" ]; then
        best_channel=6
        best_count=$ch6_count
    fi
    if [ "$ch11_count" -lt "$best_count" ]; then
        best_channel=11
        best_count=$ch11_count
    fi

    log "Channel usage: Ch1=$ch1_count Ch6=$ch6_count Ch11=$ch11_count"
    log "Auto-selected channel $best_channel (least congested)"
    WIFI_CHANNEL="$best_channel"
}

interactive_mode() {
    LAN_GW="${LAN_GW:-192.168.50.1}"
    LAN_DHCP_START="${LAN_DHCP_START:-192.168.50.50}"
    LAN_DHCP_END="${LAN_DHCP_END:-192.168.50.150}"

    install_packages
    install_technitium || warning "Technitium DNS install failed, DNS may not work"
    stop_services

    if ! detect_interfaces; then
        exit 1
    fi

    CONFIG_VALID=false
    ENABLE_AT_BOOT="n"
    DISABLE_GUI="n"

    if load_config && validate_config; then
        log "Valid configuration found in $CONFIG_FILE"
        log "AP_NAME: $AP_NAME"

        ENABLE_AT_BOOT="${ENABLE_AT_BOOT:-y}"
        DISABLE_GUI="${DISABLE_GUI:-n}"

        log "Starting hotspot with existing configuration..."
        CONFIG_VALID=true
    else
        if [ -f "$CONFIG_FILE" ]; then
            warning "Configuration file found but invalid"
        else
            warning "No configuration file found"
        fi
        log "Requesting information from user..."

        AP_NAME=""
        while ! validate_ssid "$AP_NAME"; do
            read -p "Enter Access Point name (SSID): " AP_NAME
        done

        AP_PASSWORD=""
        while [ -z "$AP_PASSWORD" ] || [ ${#AP_PASSWORD} -lt 8 ]; do
            read -s -p "Enter Access Point password (minimum 8 characters): " AP_PASSWORD
            echo
            if [ -z "$AP_PASSWORD" ]; then
                error "Password cannot be empty"
            elif [ ${#AP_PASSWORD} -lt 8 ]; then
                error "Password must be at least 8 characters long"
                AP_PASSWORD=""
            fi
        done

        echo
        read -p "Enable router functionality after reboot? (y/N): " ENABLE_AT_BOOT
        echo

        if [[ ${ENABLE_AT_BOOT^^} == "Y" ]]; then
            read -p "Disable graphical interface to save resources (boot to TTY)? (y/N): " DISABLE_GUI
            echo
        fi
    fi

    if [ "${WIFI_BAND}" = "2.4" ]; then
        pick_wifi_channel
        log "Using channel $WIFI_CHANNEL for 2.4GHz (non-overlapping)"
    fi

    configure_persistent
    install_script

    if apply_router_config; then
        trap - EXIT

        save_config
        log "Configuration saved in $CONFIG_FILE"

        if [ "$CONFIG_VALID" = true ] || [[ ${ENABLE_AT_BOOT^^} == "Y" ]]; then
            create_systemd_service

            if [[ ${DISABLE_GUI^^} == "Y" ]]; then
                disable_graphical_interface
            else
                enable_graphical_interface
            fi

            log "Services enabled for automatic startup via router-mode.service"
            log "Script installed as: $SCRIPT_INSTALL_PATH"
        else
            log "Router will NOT persist after reboot. Run this script again if needed."
            systemctl disable hostapd 2>/dev/null || true
            systemctl disable dnsmasq 2>/dev/null || true
            systemctl disable netfilter-persistent 2>/dev/null || true
        fi

        echo
        echo "================================================"
        echo "Access Point: $AP_NAME"
        echo "Password: $AP_PASSWORD"
        echo "Interface: $AP_IFACE"
        echo "Internet via: $WAN_IFACE"
        echo "LAN Gateway: $LAN_GW"
        echo "DHCP Range: $LAN_DHCP_START - $LAN_DHCP_END"
        echo "DNS: Technitium DNS ($LAN_GW:53)"
        echo "Wi-Fi Band: ${WIFI_BAND}GHz"
        echo "Wi-Fi Channel: $WIFI_CHANNEL"
        echo "Enable at boot: $ENABLE_AT_BOOT"
        if [[ ${DISABLE_GUI^^} == "Y" ]]; then
            echo "Boot Mode: Console (TTY)"
        else
            echo "Boot Mode: Graphical"
        fi
        echo "================================================"
        echo

        log "Status commands:"
        echo "  systemctl status router-mode.service"
        echo "  systemctl status hostapd dnsmasq"
        echo "  journalctl -u router-mode -f"
        echo
        log "Technitium DNS web console:"
        echo "  http://${LAN_GW}:5380/"
        echo

        if [[ ${DISABLE_GUI^^} == "Y" ]]; then
            warning "System will boot to console mode (TTY) after restart"
            log "Ctrl+Alt+F1 to F6: access TTY consoles"
            log "Temp GUI: sudo systemctl start gdm3"
            log "Re-enable GUI: sudo systemctl set-default graphical.target"
        fi
    else
        error "Failed to configure router"
        exit 1
    fi
}

set_wifi_credentials() {
    check_root

    if ! load_config; then
        error "No configuration found. Run the setup first."
        exit 1
    fi

    local new_ssid=""
    while ! validate_ssid "$new_ssid"; do
        read -p "New SSID: " new_ssid
    done

    local new_password=""
    while [ -z "$new_password" ] || [ ${#new_password} -lt 8 ]; do
        read -s -p "New Wi-Fi password (min 8 chars): " new_password
        echo
        if [ -z "$new_password" ]; then
            error "Password cannot be empty"
        elif [ ${#new_password} -lt 8 ]; then
            error "Password must be at least 8 characters"
            new_password=""
        fi
    done

    AP_NAME="$new_ssid"
    AP_PASSWORD="$new_password"
    save_config

    log "Wi-Fi credentials updated in $CONFIG_FILE"
    if systemctl restart router-mode.service; then
        log "router-mode.service restarted successfully"
    else
        warning "Failed to restart router-mode.service automatically"
        warning "Run manually: sudo systemctl restart router-mode.service"
        return 1
    fi
}

init_logging
check_root

if [ "${1:-}" = "--service" ]; then
    service_mode_start
elif [ "${1:-}" = "--service-stop" ]; then
    service_mode_stop
    exit 0
elif [ "${1:-}" = "--update-technitium" ]; then
    check_root
    update_technitium
    exit 0
elif [ "${1:-}" = "--set-wifi" ]; then
    set_wifi_credentials
    exit 0
fi

main() {
    AP_CLEAN=""
    if read -t 5 -p "Delete previous router configurations? (y/N): " AP_CLEAN 2>/dev/null; then
        if [[ ${AP_CLEAN^^} == "Y" ]]; then
            cleanup_router
            log "Cleanup complete"
            warning "A restart is recommended"
            read -p "Restart now? (y/N): " AP_RESTART
            if [[ ${AP_RESTART^^} == "Y" ]]; then
                log "Restarting in 3 seconds..."
                sleep 3
                shutdown -r now
            fi
            exit 0
        fi
    else
        echo
        log "Timeout - continuing without cleanup"
    fi

    interactive_mode
}

main
