#!/bin/bash
# wifi-hotspot.sh

set -euo pipefail

# --- CONFIG ---
# 1. Automatically find the Internet Source (Ethernet or Internal WiFi)
SOURCE_IF=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
# Fallback to internal card if no internet is found yet
SOURCE_IF=${SOURCE_IF:-"wlP1p1s0"}

# 2. Set SSID to Hostname (e.g., msoe-nano2)
HOTSPOT_SSID="$(hostname)"
HOTSPOT_PASS="password"

DRIVER_REPO="https://github.com/aircrack-ng/rtl8812au.git"
VER="5.6.4.2"
MODULE_NAME="88XXau"
DKMS_NAME="8812au"

echo "=== System Check ==="
echo "Detected Internet Source: $SOURCE_IF"

GET_IF() {
    ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlan|^wlx' | grep -v "$SOURCE_IF" | head -n 1
}

HOTSPOT_IF=$(GET_IF)

# 3. Driver/Hardware Logic
if [ -z "$HOTSPOT_IF" ]; then
    if ! lsmod | grep -q "$MODULE_NAME"; then
        if ! dkms status | grep -q "$DKMS_NAME"; then
            sudo apt update && sudo apt install -y git dkms build-essential bc
            [ ! -d "rtl8812au" ] && git clone "$DRIVER_REPO"
            cd rtl8812au
            sudo mkdir -p /usr/src/${DKMS_NAME}-${VER}
            sudo cp -r . /usr/src/${DKMS_NAME}-${VER}
            sudo dkms add -m $DKMS_NAME -v ${VER} || true
            sudo dkms build -m $DKMS_NAME -v ${VER}
            sudo dkms install -m $DKMS_NAME -v ${VER}
            cd ..
        fi
        sudo depmod -a
        sudo modprobe "$MODULE_NAME"
        sleep 2
    fi
    HOTSPOT_IF=$(GET_IF)
fi

if [ -z "$HOTSPOT_IF" ]; then
    echo "ERROR: USB hardware not detected."
    exit 1
fi

echo "Hotspot Interface: $HOTSPOT_IF"

# 4. CLEANUP: Delete ALL existing hotspot connections to prevent dual-SSIDs
echo "Cleaning up old profiles..."
OLD_CONS=$(nmcli -g NAME,TYPE connection show | grep ":802-11-wireless" | cut -d: -f1) || true
for con in $OLD_CONS; do
    # We delete it if it's a hotspot/AP type to keep things clean
    sudo nmcli con delete "$con" 2>/dev/null || true
done

# 5. Network Configuration
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/90-hotspot-forwarding.conf > /dev/null

# 6. Setup Hotspot
echo "Creating Hotspot: $HOTSPOT_SSID"
sudo nmcli con add type wifi ifname "$HOTSPOT_IF" con-name "Hotspot" autoconnect yes ssid "$HOTSPOT_SSID"
sudo nmcli con modify "Hotspot" 802-11-wireless.mode ap 802-11-wireless.band bg
sudo nmcli con modify "Hotspot" 802-11-wireless-security.key-mgmt wpa-psk
sudo nmcli con modify "Hotspot" 802-11-wireless-security.psk "$HOTSPOT_PASS"
sudo nmcli con modify "Hotspot" ipv4.method shared ipv4.addresses "192.168.150.1/24"

# 7. Activation
sudo nmcli device set "$HOTSPOT_IF" managed yes || true
sudo nmcli con up "Hotspot"

# 8. IPTables NAT
sudo iptables -t nat -F POSTROUTING
sudo iptables -t nat -A POSTROUTING -o "$SOURCE_IF" -j MASQUERADE
sudo iptables -A FORWARD -i "$SOURCE_IF" -o "$HOTSPOT_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i "$HOTSPOT_IF" -o "$SOURCE_IF" -j ACCEPT

echo "=== SUCCESS ==="
echo "Active SSID: $HOTSPOT_SSID"