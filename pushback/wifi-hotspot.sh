#!/bin/bash
# wifi-hotspot.sh

set -euo pipefail

# --- CONFIG ---
# 1. Find the Internet Source
SOURCE_IF=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
SOURCE_IF=${SOURCE_IF:-"wlP1p1s0"}

HOTSPOT_SSID="$(hostname)"
HOTSPOT_PASS="RAIDER_ROBOTICS"

DRIVER_REPO="https://github.com/aircrack-ng/rtl8812au.git"
VER="5.6.4.2"
MODULE_NAME="88XXau"
DKMS_NAME="8812au"

echo "=== System Check ==="
echo "Internet Source (Untouchable): $SOURCE_IF"

GET_IF() {
    ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlan|^wlx' | grep -v "$SOURCE_IF" | head -n 1
}

HOTSPOT_IF=$(GET_IF)

# 2. Driver/Hardware Logic
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

# 3. SAFE CLEANUP: Only delete connections that are set to 'ap' mode
echo "Cleaning up old Access Point profiles..."
# Get all connection names
mapfile -t ALL_CONS < <(nmcli -g NAME connection show)
for con in "${ALL_CONS[@]}"; do
    # Check if this connection is an Access Point mode
    IS_AP=$(nmcli -g 802-11-wireless.mode connection show "$con" 2>/dev/null || echo "client")
    if [ "$IS_AP" == "ap" ]; then
        echo "Removing old hotspot profile: $con"
        sudo nmcli con delete "$con" > /dev/null 2>&1 || true
    fi
done

# 4. Network Configuration
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/90-hotspot-forwarding.conf > /dev/null

# 5. Setup Hotspot
echo "Creating Hotspot: $HOTSPOT_SSID"
sudo nmcli con add type wifi ifname "$HOTSPOT_IF" con-name "Hotspot" autoconnect yes ssid "$HOTSPOT_SSID"
sudo nmcli con modify "Hotspot" 802-11-wireless.mode ap 802-11-wireless.band bg
sudo nmcli con modify "Hotspot" 802-11-wireless-security.key-mgmt wpa-psk
sudo nmcli con modify "Hotspot" 802-11-wireless-security.psk "$HOTSPOT_PASS"
sudo nmcli con modify "Hotspot" ipv4.method shared ipv4.addresses "192.168.150.1/24"

# 6. Activation
sudo nmcli device set "$HOTSPOT_IF" managed yes || true
sudo nmcli con up "Hotspot"

# 7. IPTables NAT
sudo iptables -t nat -F POSTROUTING
sudo iptables -t nat -A POSTROUTING -o "$SOURCE_IF" -j MASQUERADE
sudo iptables -A FORWARD -i "$SOURCE_IF" -o "$HOTSPOT_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i "$HOTSPOT_IF" -o "$SOURCE_IF" -j ACCEPT

# 8. FINAL PRINT
echo ""
echo "=========================================="
echo "          HOTSPOT IS NOW ACTIVE           "
echo "=========================================="
echo " Network Name (SSID): $HOTSPOT_SSID"
echo " Password:            $HOTSPOT_PASS"
echo " Gateway IP:          192.168.150.1"
echo " Interface:           $HOTSPOT_IF"
echo "=========================================="