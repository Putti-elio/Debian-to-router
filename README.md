# Debian to Router

Transform a Debian PC or Raspberry Pi into a fully functional Wi-Fi router with DHCP, DNS (Technitium ad-blocking), and NAT capabilities.

## Features

- **Automatic interface detection**: Finds Wi-Fi adapters supporting AP mode and connected Ethernet interfaces
- **Complete router functionality**: Hostapd (access point), dnsmasq (DHCP), iptables (NAT/forwarding)
- **Technitium DNS integration**: Auto-installs and configures Technitium DNS for ad-blocking at the DNS level
- **Smart channel selection**: Automatically scans and picks the least congested 2.4GHz channel (1/6/11)
- **Persistent or temporary mode**: Choose between one-time setup or automatic startup on boot
- **Systemd service integration**: Single service manages all components in correct order
- **Resource optimization**: Optional TTY-only mode to disable GUI and save resources
- **Easy cleanup**: Remove all configurations and restore original state

## Requirements

- Debian/Ubuntu/Raspberry Pi OS (systemd-based)
- Root privileges
- Ethernet connection with internet access (WAN)
- Wi-Fi adapter supporting AP mode (nl80211 driver)
- NetworkManager installed

### Check Wi-Fi AP support

```bash
iw list | grep -A 10 "Supported interface modes"
# Look for "AP" in the output
```

## Installation

```bash
git clone https://github.com/StenguyzCSGO/Debian-to-router.git
cd Debian-to-router
chmod +x router.sh
sudo ./router.sh
```

## Usage

### Interactive Setup

The script will prompt you for:

1. **Wi-Fi network name (SSID)**: Your access point name
2. **Password**: Minimum 8 characters, WPA2-PSK encryption
3. **Persistent mode**: Enable automatic startup on boot
4. **TTY mode** (if persistent): Disable graphical interface to save resources

Technitium DNS is installed automatically if not present. If it's already installed, the script just ensures it's running.

### Post-Installation

```bash
sudo router-mode
```

Monitor services:

```bash
systemctl status router-mode.service
systemctl status hostapd dnsmasq dns
journalctl -u router-mode -f
```

### Technitium DNS Web Console

After setup, access the Technitium DNS web interface to configure ad-blocking:

```bash
http://192.168.50.1:5380/
```

Default login: `admin` / `admin` — **change this immediately**.

To add ad-blocking lists: Settings → Blocking → Quick Add → select "Default".

### Update Technitium DNS

```bash
sudo router-mode --update-technitium
```

### Change Wi-Fi Name/Password

To change the router SSID and password without rerunning full setup:

```bash
sudo router-mode --set-wifi
```

This updates `/etc/router-mode/config` and automatically restarts `router-mode.service`.

## Logs

- Main script logs: `router-mode.log` (inside project folder: `/home/routeur/Debian-to-router/router-mode.log`)
- Old legacy log `/var/log/router-mode.log` is deleted automatically
- On each run, the project log file is reset (old file removed, new one created)

### Remove Configuration

```bash
sudo router-mode
# Answer 'y' to cleanup prompt (5 second window)
```

This removes all configurations, restores NetworkManager control, resets iptables, and re-enables GUI if disabled.

## Default Configuration

| Setting | Value |
|---------|-------|
| LAN Gateway | 192.168.50.1 |
| LAN Subnet | 192.168.50.0/24 |
| DHCP Range | 192.168.50.50 - 192.168.50.150 |
| DNS | Technitium DNS (local, port 53) |
| Wi-Fi Band | 2.4 GHz |
| Wi-Fi Channel | Auto (scans 1/6/11 for least congestion) |
| Channel Width | 20 MHz (2.4GHz) / 40 MHz (5GHz) |
| Encryption | WPA2-PSK |

## Architecture

```
Internet ←→ [WAN eth0] ←→ NAT/iptables ←→ [LAN wlan0 192.168.50.1]
                                                    │
                                    ┌───────────────┼───────────────┐
                                    │               │               │
                              hostapd          dnsmasq        Technitium
                              (Wi-Fi AP)      (DHCP only)    (DNS, port 53)
```

- **dnsmasq** runs with `port=0` (DNS disabled) — it only handles DHCP
- **Technitium DNS** handles all DNS resolution on port 53
- **iptables** redirects any DNS traffic from clients to the local Technitium instance
- DNS bypass is blocked: forward rules drop any port 53 traffic not destined for the gateway

### Persistent Mode (Systemd Service)

1. Script copies itself to `/usr/local/sbin/router-mode`
2. Creates `router-mode.service` systemd unit
3. Service starts after network, NetworkManager, and Technitium DNS
4. Configuration saved to `/etc/router-mode/config`
5. On boot: loads config, detects interfaces, starts hostapd/dnsmasq

### Network Configuration

- Wi-Fi interface configured with static IP (192.168.50.1/24)
- NetworkManager releases control of Wi-Fi interface
- IPv4 forwarding enabled via sysctl drop-in
- NAT configured with iptables MASQUERADE
- iptables uses a dedicated chain (`ROUTER_FORWARD`) to avoid destroying existing rules
- Hostapd creates WPA2 access point
- Dnsmasq provides DHCP only (DNS disabled via `port=0`)
- Technitium DNS provides DNS resolution and ad-blocking

## File Locations

```
/usr/local/sbin/router-mode          # Installed script
/etc/router-mode/config              # Saved configuration (chmod 600)
/etc/systemd/system/router-mode.service
/etc/hostapd/hostapd.conf            # Access point config
/etc/dnsmasq.d/router.conf           # DHCP config
/etc/NetworkManager/conf.d/ROUTER_MODE.conf
/etc/network/interfaces.d/ROUTER_MODE.conf
/etc/sysctl.d/99-router-ipforward.conf
/opt/technitium/dns/                 # Technitium DNS installation
```

## 2.4GHz Optimization

The script is optimized for 2.4GHz operation:

- **20 MHz channel width**: Uses only `ht_capab=[SHORT-GI-20][MAX-AMSDU-7935]` — no HT40. 40 MHz on 2.4GHz wastes 2/3 of the band and causes interference with neighboring networks.
- **Non-overlapping channels only**: Automatically scans and selects from channels 1, 6, or 11 (the only non-overlapping 2.4GHz channels).
- **Power save disabled**: Wi-Fi power save is turned off on the AP interface for stability.

## TTY Mode (Console Only)

When enabled, the system boots to text console (TTY) instead of graphical interface:

- `Ctrl+Alt+F1` to `F6`: Access TTY1-6
- `Alt+F1` to `F6`: Switch TTY (when already in console)

Temporarily start GUI:

```bash
sudo systemctl start gdm3  # or lightdm/sddm
```

Permanently re-enable GUI:

```bash
sudo systemctl set-default graphical.target
sudo reboot
```

## Troubleshooting

**Service won't start:**

```bash
journalctl -u router-mode -n 50
systemctl status hostapd --no-pager
```

**Wi-Fi adapter not detected:**

```bash
iw list
nmcli device
```

**No internet on connected devices:**

```bash
sudo iptables -t nat -L -n -v
cat /proc/sys/net/ipv4/ip_forward  # Should be 1
ping -I eth0 8.8.8.8
```

**DNS not working:**

```bash
systemctl status dns  # Technitium DNS service
curl http://192.168.50.1:5380/  # Web console
```

**Interface blocked:**

```bash
rfkill list
rfkill unblock wifi
```

## Security Notes

- Use strong WPA2 passwords (minimum 8 characters)
- Configuration file is chmod 600 (root only), with proper shell escaping
- DNS bypass is blocked via iptables — clients cannot use external DNS servers
- Default Technitium login is admin/admin — change it immediately after setup
- Consider adding iptables INPUT rules to restrict access to the router itself

## Advanced Configuration

Edit `/etc/hostapd/hostapd.conf` for:

- Channel selection (`channel=1` or `6` or `11`)
- Wi-Fi band (`hw_mode=g` for 2.4GHz, `hw_mode=a` for 5GHz)
- Country code (`country_code=CA`)
- Hidden SSID (`ignore_broadcast_ssid=1`)

Edit `/etc/dnsmasq.d/router.conf` for:

- DHCP lease time (`12h`)
- Static IP assignments
- Custom domain name

Restart services after changes:

```bash
sudo systemctl restart router-mode.service
```

## License

MIT License - See LICENSE file for details

## Contributing

Pull requests welcome. For major changes, please open an issue first.
