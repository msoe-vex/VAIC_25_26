#!/bin/bash
# wifi-hotspot.sh

set -euo pipefail

# --- CONFIG ---
SOURCE_IF="wlP1p1s0"
HOTSPOT_SSID="Jetson_Orin_AP"
HOTSPOT_PASS="password"
DRIVER_REPO="https://github.com/aircrack-ng/rtl8812au.git"
VER="5.6.4.2"
MODULE_NAME="88XXau"      # Kernel module name
DKMS_NAME="8812au"        # DKMS package name

echo "=== System Check ==="

# 1. Check for the Interface first
# This looks for any interface starting with wlx or wlan that isn't the internal card
GET_IF() {
    ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlan|^wlx' | grep -v "$SOURCE_IF" | head -n 1
}

HOTSPOT_IF=$(GET_IF)

if [ -z "$HOTSPOT_IF" ]; then
    echo "USB Interface not found in 'ip link'. Checking driver status..."
    
    # If interface is missing, check if module is even loaded
    if ! lsmod | grep -q "$MODULE_NAME"; then
        echo "Driver $MODULE_NAME not loaded. Checking DKMS..."
        
        if ! dkms status | grep -q "$DKMS_NAME"; then
            echo "Not in DKMS. Starting manual installation..."
            if ! ping -c 1 -W 2 google.com > /dev/null; then
                echo "ERROR: No internet connection on $SOURCE_IF. Needed for driver build."
                exit 1
            fi
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
        
        echo "Probing $MODULE_NAME..."
        sudo depmod -a
        sudo modprobe "$MODULE_NAME"
        sleep 2
    fi
    
    # Re-check for interface after driver load
    HOTSPOT_IF=$(GET_IF)
fi

if [ -z "$HOTSPOT_IF" ]; then
    echo "ERROR: Driver is ready but USB hardware still not found. Try replugging."
    exit 1
fi

echo "Interface Found: $HOTSPOT_IF"
echo "=== System Check Complete ==="

# 2. Network Configuration
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/90-hotspot-forwarding.conf > /dev/null

# 3. Setup Hotspot via NetworkManager
echo "Configuring NetworkManager Hotspot..."
sudo nmcli con delete Hotspot 2>/dev/null || true
sudo nmcli con add type wifi ifname "$HOTSPOT_IF" con-name Hotspot autoconnect yes ssid "$HOTSPOT_SSID"
sudo nmcli con modify Hotspot 802-11-wireless.mode ap 802-11-wireless.band bg
sudo nmcli con modify Hotspot 802-11-wireless-security.key-mgmt wpa-psk
sudo nmcli con modify Hotspot 802-11-wireless-security.psk "$HOTSPOT_PASS"
sudo nmcli con modify Hotspot ipv4.method shared ipv4.addresses "192.168.150.1/24"

# 4. Bring Hotspot Up
echo "Activating Hotspot..."
sudo nmcli device set "$HOTSPOT_IF" managed yes || true
sudo nmcli con up Hotspot

# 5. IPTables NAT
echo "Applying NAT rules..."
sudo iptables -t nat -F POSTROUTING
sudo iptables -t nat -A POSTROUTING -o "$SOURCE_IF" -j MASQUERADE
sudo iptables -A FORWARD -i "$SOURCE_IF" -o "$HOTSPOT_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i "$HOTSPOT_IF" -o "$SOURCE_IF" -j ACCEPT

echo "=== SUCCESS ==="
echo "Hotspot: $HOTSPOT_SSID active on $HOTSPOT_IF"