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
WAN_IFACE_BOOT_WAIT=30

log() { 
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" 
}
error() { 
    echo -e "${RED}[ERROR]${NC} $1" >&2 
}
warning() { 
    echo -e "${YELLOW}[WARNING]${NC} $1" 
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root"
        exit 1
    fi
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
    return 0
}

save_config() {
	mkdir -p "$CONFIG_DIR"
	cat > "$CONFIG_FILE" <<EOF
AP_IFACE="$AP_IFACE"
WAN_IFACE="$WAN_IFACE"
AP_NAME="$AP_NAME"
AP_PASSWORD="$AP_PASSWORD"
LAN_GW="$LAN_GW"
LAN_DHCP_START="$LAN_DHCP_START"
LAN_DHCP_END="$LAN_DHCP_END"
DISABLE_GUI="$DISABLE_GUI"
ENABLE_AT_BOOT="$ENABLE_AT_BOOT"
EOF
	chmod 600 "$CONFIG_FILE"
}

cleanup_router() {
    log "Stop and disable at boot services for the AP..."
    systemctl disable --quiet router-mode.service 2>/dev/null || true
    systemctl stop --quiet router-mode.service 2>/dev/null || true
    systemctl disable --quiet hostapd dnsmasq netfilter-persistent 2>/dev/null || true
    systemctl stop --quiet hostapd dnsmasq netfilter-persistent 2>/dev/null || true

    log "Return control of the interface to NetworkManager..."
    if [ -f /etc/network/interfaces.d/ROUTER_MODE.conf ]; then
        AP_IFACE_CLEAN=$(awk '/iface/ {print $2}' /etc/network/interfaces.d/ROUTER_MODE.conf)
        if [ -n "$AP_IFACE_CLEAN" ]; then
            nmcli dev set "$AP_IFACE_CLEAN" managed yes 2>/dev/null || true
            ip addr flush dev "$AP_IFACE_CLEAN" 2>/dev/null || true
        fi
    fi

    log "Deleting conf file and restore default ones..."
    rm -f /etc/network/interfaces.d/${CONF_NAME_FILE}.conf
    rm -f /etc/NetworkManager/conf.d/${CONF_NAME_FILE}.conf
    rm -f /etc/hostapd/hostapd.conf
    rm -f /etc/dnsmasq.d/router.conf
    rm -f /etc/dnsmasq.conf
    rm -f /etc/sysctl.d/99-router-ipforward.conf
    rm -rf "$CONFIG_DIR"
    rm -f "$SCRIPT_INSTALL_PATH"
    [ -f /etc/hostapd/default_hostapd.conf ] && mv /etc/hostapd/default_hostapd.conf /etc/hostapd/hostapd.conf
    [ -f /etc/default_dnsmasq.conf ] && mv /etc/default_dnsmasq.conf /etc/dnsmasq.conf
    [ -f /etc/old_sysctl.conf ] && mv /etc/old_sysctl.conf /etc/sysctl.conf

    log "Resetting iptables rules..."
    iptables -F
    iptables -t nat -F
    iptables -t mangle -F
    iptables -X
    iptables -t nat -X
    iptables -t mangle -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT

    sysctl -w net.ipv4.ip_forward=0 >/dev/null
    sysctl --system >/dev/null

    netfilter-persistent save || true

    log "Restarting NetworkManager..."
    systemctl restart NetworkManager || true

    enable_graphical_interface
}

detect_interfaces() {
	log "Detecting network interfaces..."
	mapfile -t available_wifi_interfaces < <(nmcli -t -f DEVICE,TYPE,STATE device | awk -F: '$2=="wifi" {print $1}')
	supported_wifi_interfaces=()

	for iface in "${available_wifi_interfaces[@]:-}"; do
	if [ -z "$iface" ]; then continue; fi

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
			log "Waiting for WAN interface $WAN_IFACE to be connected (max ${WAN_IFACE_BOOT_WAIT}s)..."
			waited=0
			while [ "$waited" -lt "$WAN_IFACE_BOOT_WAIT" ]; do
				wan_state=$(cat /sys/class/net/${WAN_IFACE}/operstate 2>/dev/null || echo "unknown")
				if [ "$wan_state" = "up" ] || [ "$wan_state" = "unknown" ]; then
					log "WAN interface $WAN_IFACE is ready ($wan_state)"
					break
				fi
				sleep 1
				waited=$((waited + 1))
			done
			if [ "$waited" -ge "$WAN_IFACE_BOOT_WAIT" ]; then
				warning "WAN interface $WAN_IFACE did not come up within ${WAN_IFACE_BOOT_WAIT}s, proceeding anyway"
			fi
		else
			warning "Configured WAN interface $WAN_IFACE not found in /sys/class/net/"
		fi
		log "Using WAN interface: $WAN_IFACE"
	else
		mapfile -t source_eth_interfaces < <(nmcli -t -f DEVICE,TYPE,STATE device | awk -F: '$2=="ethernet" && $3=="connected" {print $1}')
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
    log "Updating system packages..."
    apt-get update -y
    apt-get install -y hostapd dnsmasq iptables-persistent iw
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
    ip addr add "${LAN_GW}/24" dev "$AP_IFACE"
    ip link set "$AP_IFACE" up
}

enable_ip_forwarding() {
    log "Enabling IP forwarding..."
    [ -f /etc/sysctl.conf ] && [ ! -f /etc/old_sysctl.conf ] && mv /etc/sysctl.conf /etc/old_sysctl.conf
    cat > /etc/sysctl.conf <<EOF
net.ipv4.ip_forward=1
EOF
    mkdir -p /etc/sysctl.d/
    cat > /etc/sysctl.d/99-router-ipforward.conf <<EOF
net.ipv4.ip_forward=1
EOF
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl --system >/dev/null
}

configure_hostapd() {
    log "Configuring hostapd..."
    [ -f /etc/hostapd/hostapd.conf ] && [ ! -f /etc/hostapd/default_hostapd.conf ] && \
        mv /etc/hostapd/hostapd.conf /etc/hostapd/default_hostapd.conf

    cat > /etc/hostapd/hostapd.conf <<EOF
interface=$AP_IFACE
driver=nl80211

ssid=$AP_NAME
hw_mode=g
channel=7

ieee80211n=1
wmm_enabled=1

auth_algs=1
wpa=2
wpa_passphrase=$AP_PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP

ignore_broadcast_ssid=0
macaddr_acl=0
EOF

    cat > /etc/default/hostapd <<EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF
}

configure_dnsmasq() {
    log "Configuring dnsmasq..."
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
	log "Configuring iptables..."
	iptables -F
	iptables -t nat -F
	iptables -t mangle -F
	iptables -X
	iptables -t nat -X
	iptables -t mangle -X

	iptables -P INPUT ACCEPT
	iptables -P FORWARD ACCEPT
	iptables -P OUTPUT ACCEPT

	iptables -t nat -A PREROUTING -i "$AP_IFACE" -p udp --dport 53 -j DNAT --to-destination "$LAN_GW":53
	iptables -t nat -A PREROUTING -i "$AP_IFACE" -p tcp --dport 53 -j DNAT --to-destination "$LAN_GW":53

	iptables -A FORWARD -i "$AP_IFACE" -p udp --dport 53 ! -d "$LAN_GW" -j DROP
	iptables -A FORWARD -i "$AP_IFACE" -p tcp --dport 53 ! -d "$LAN_GW" -j DROP

	iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
	iptables -A FORWARD -i "$AP_IFACE" -o "$WAN_IFACE" -j ACCEPT
	iptables -A FORWARD -i "$WAN_IFACE" -o "$AP_IFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

	netfilter-persistent save
}

configure_persistent() {
    log "Configuring persistent router functionality..."

    log "Prevent NetworkManager from managing the interface"
    mkdir -p /etc/NetworkManager/conf.d/
    cat > /etc/NetworkManager/conf.d/${CONF_NAME_FILE}.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:${AP_IFACE}
EOF
    systemctl reload NetworkManager || true

    log "Creating persistent network configuration..."
    mkdir -p /etc/network/interfaces.d/
    cat > /etc/network/interfaces.d/${CONF_NAME_FILE}.conf <<EOF
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
    rfkill unblock wifi || true

    log "Starting services..."
    if systemctl restart dnsmasq; then
        log "dnsmasq started successfully"
    else
        error "Failed to start dnsmasq"
        systemctl status dnsmasq --no-pager
        return 1
    fi

    if systemctl restart hostapd; then
        log "hostapd started successfully"
    else
        error "Failed to start hostapd"
        systemctl status hostapd --no-pager
        return 1
    fi

    sleep 3
    if ! systemctl is-active --quiet hostapd; then
        error "hostapd is not running properly"
        log "Checking hostapd status..."
        systemctl status hostapd --no-pager
        journalctl -u hostapd --no-pager -n 20
        return 1
    fi

    if ! systemctl is-active --quiet dnsmasq; then
        error "dnsmasq is not running properly"
        log "Checking dnsmasq status..."
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

apply_router_config() {
	if ! detect_interfaces; then
		return 1
	fi

	if systemctl is-active --quiet systemd-resolved; then
		warning "systemd-resolved is running and may conflict with Technitium DNS on port 53"
		log "Stopping systemd-resolved..."
		systemctl stop systemd-resolved 2>/dev/null || true
		systemctl disable systemd-resolved 2>/dev/null || true
		if [ -L /etc/resolv.conf ]; then
			rm -f /etc/resolv.conf
			echo "nameserver 127.0.0.1" > /etc/resolv.conf
		fi
	fi

	configure_network_interface
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

	if ! systemctl is-active --quiet "$TECHNITIUM_DNS_SERVICE"; then
		warning "Technitium DNS service is not running, attempting to start..."
		if systemctl start "$TECHNITIUM_DNS_SERVICE"; then
			log "Technitium DNS started successfully"
		else
			error "Failed to start Technitium DNS - DNS resolution for clients will not work"
		fi
	fi

	if apply_router_config; then
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
        log "Graphical interface disabled to save resources"

        return 0
    else
        log "No graphical interface detected, system already in console mode"
        return 0
    fi
}

enable_graphical_interface() {
    log "Re-enabling graphical interface..."

    systemctl set-default graphical.target
    log "System will boot to graphical mode on next restart"

    return 0
}

interactive_mode() {
	LAN_GW="192.168.50.1"
	LAN_DHCP_START="192.168.50.50"
	LAN_DHCP_END="192.168.50.150"

    cleanup() {
        warning "Cleaning up..."
        systemctl stop hostapd 2>/dev/null || true
        systemctl stop dnsmasq 2>/dev/null || true
        if [ -n "${AP_IFACE:-}" ]; then
            nmcli dev set "$AP_IFACE" managed yes 2>/dev/null || true
            ip addr flush dev "$AP_IFACE" 2>/dev/null || true
        fi
    }

    trap cleanup EXIT

    install_packages
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
            warning "Configuration file found but invalid (missing data)"
        else
            warning "No configuration file found"
        fi
        log "Requesting information from user..."

        AP_NAME=""
        while [ -z "$AP_NAME" ]; do
            read -p "Enter Access Point name (SSID): " AP_NAME
            if [ -z "$AP_NAME" ]; then
                error "SSID cannot be empty"
            fi
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

    configure_persistent
    install_script

    if apply_router_config; then
        save_config
        log "Configuration saved in $CONFIG_FILE"

        if [ "$CONFIG_VALID" = true ] || [[ ${ENABLE_AT_BOOT^^} == "Y" ]]; then
            create_systemd_service

            if [[ ${DISABLE_GUI^^} == "Y" ]]; then
                disable_graphical_interface
            else
                enable_graphical_interface
            fi

            log "Services are enabled for automatic startup via router-mode.service"
            log "Script installed as: $SCRIPT_INSTALL_PATH"
        else
            log "Router will NOT persist after reboot. Run this script again after restart if needed."
            systemctl disable hostapd 2>/dev/null || true
            systemctl disable dnsmasq 2>/dev/null || true
            systemctl disable netfilter-persistent 2>/dev/null || true
        fi

        trap - EXIT

        log "Router configuration completed successfully!"
        echo
        echo "================================================"
        echo "Access Point: $AP_NAME"
        echo "Password: $AP_PASSWORD"
        echo "Interface: $AP_IFACE"
        echo "Internet via: $WAN_IFACE"
	echo "LAN Gateway: $LAN_GW"
	echo "DHCP Range: $LAN_DHCP_START - $LAN_DHCP_END"
	echo "DNS: Technitium DNS ($LAN_GW:53)"
	echo "Enable at boot: $ENABLE_AT_BOOT"
        if [[ ${DISABLE_GUI^^} == "Y" ]]; then
            echo "Boot Mode: Console (TTY) - Graphical interface disabled"
        else
            echo "Boot Mode: Graphical interface enabled"
        fi
        echo "================================================"
        echo
        log "You can check the status with:"
        echo "  systemctl status router-mode.service"
        echo "  systemctl status hostapd dnsmasq"
        echo "  journalctl -u router-mode -f"
        echo "  journalctl -u hostapd -f"
        echo "  journalctl -u dnsmasq -f"
        echo
        log "To manage router mode manually:"
        echo "  sudo $SCRIPT_INSTALL_PATH"

        if [[ ${DISABLE_GUI^^} == "Y" ]]; then
            echo
            warning "System will boot to console mode (TTY) after restart"
            log "To access TTY, use Ctrl+Alt+F1 to F6"
            log "To temporarily start GUI: sudo systemctl start gdm3 (or lightdm/sddm)"
            log "To permanently re-enable GUI: sudo systemctl set-default graphical.target"
        fi
    else
        error "Failed to configure router"
        exit 1
    fi
}

check_root

if [ "${1:-}" = "--service" ]; then
    service_mode_start
elif [ "${1:-}" = "--service-stop" ]; then
    service_mode_stop
    exit 0
fi

main() {
    AP_CLEAN=""
    echo "You have 5 seconds to respond..."
    echo "Do you wish to delete the configurations previously made with this script? (y/N): "
    if read -t 5 -p "Do you wish to delete the configurations previously made with this script? (y/N): " AP_CLEAN 2>/dev/null; then
        if [[ ${AP_CLEAN^^} == "Y" ]]; then
            cleanup_router

            log "Cleaning complete"
            warning "A restart is recommended..."
            read -p "Would you like to restart? (y/N): " AP_RESTART
            if [[ ${AP_RESTART^^} == "Y" ]]; then
                log "Restarting in 3 seconds..."
                sleep 3
                shutdown -r now
            fi

            exit 0
        fi
    else
        echo
        log "Timeout - No cleanup, continuing script..."
    fi

    interactive_mode
}

main
