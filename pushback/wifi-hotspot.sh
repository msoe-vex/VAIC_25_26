#!/bin/bash
# wifi-hotspot.sh

# set -euo pipefail

# --- CONFIG ---
SOURCE_IF="wlP1p1s0"
HOTSPOT_SSID="Jetson_Orin_AP"
HOTSPOT_PASS="msoe_password"
DRIVER_REPO="https://github.com/aircrack-ng/rtl8812au.git"
VER="5.6.4.2"
MODULE_NAME="88XXau"      # The name the kernel uses
DKMS_NAME="8812au"        # The name the DKMS system uses

echo "=== System Check ==="

# 1. Driver Installation/Loading Logic
if ! lsmod | grep -q "$MODULE_NAME"; then
    echo "Driver $MODULE_NAME not loaded. Checking DKMS..."
    
    # Check if ALREADY in DKMS (using the correct DKMS name)
    if ! dkms status | grep -q "$DKMS_NAME"; then
        echo "Not in DKMS. Starting manual installation..."
        
        if ! ping -c 1 -W 2 google.com > /dev/null; then
            echo "ERROR: No internet connection on $SOURCE_IF."
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
    else
        echo "Driver already in DKMS tree. Skipping build."
    fi
    
    echo "Updating module dependencies and probing $MODULE_NAME..."
    sudo depmod -a
    sudo modprobe "$MODULE_NAME"
else
    echo "Driver $MODULE_NAME is already installed and loaded."
fi

echo "=== Driver Check Complete ==="

# 2. Identify the Hotspot Interface
# Using a loop to wait for hardware registration
echo "Waiting for hardware to register..."
for i in {1..5}; do
    HOTSPOT_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlan|^wlxf' | grep -v "$SOURCE_IF" | head -n 1)
    [ -n "$HOTSPOT_IF" ] && break
    sleep 1
done

if [ -z "$HOTSPOT_IF" ]; then
    echo "ERROR: USB interface not found. Try replugging the TP-Link adapter."
    exit 1
fi

echo "Using $HOTSPOT_IF for Access Point."

# 3. Network Configuration
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/90-hotspot-forwarding.conf > /dev/null

# 4. Setup Hotspot via NetworkManager
echo "Configuring NetworkManager Hotspot..."
sudo nmcli con delete Hotspot 2>/dev/null || true
sudo nmcli con add type wifi ifname "$HOTSPOT_IF" con-name Hotspot autoconnect yes ssid "$HOTSPOT_SSID"
sudo nmcli con modify Hotspot 802-11-wireless.mode ap 802-11-wireless.band bg
sudo nmcli con modify Hotspot 802-11-wireless-security.key-mgmt wpa-psk
sudo nmcli con modify Hotspot 802-11-wireless-security.psk "$HOTSPOT_PASS"
sudo nmcli con modify Hotspot ipv4.method shared ipv4.addresses "192.168.150.1/24"

# 5. Bring Hotspot Up
echo "Activating Hotspot..."
sudo nmcli con up Hotspot

# 6. IPTables NAT
echo "Applying NAT rules..."
sudo iptables -t nat -F POSTROUTING
sudo iptables -t nat -A POSTROUTING -o "$SOURCE_IF" -j MASQUERADE
sudo iptables -A FORWARD -i "$SOURCE_IF" -o "$HOTSPOT_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i "$HOTSPOT_IF" -o "$SOURCE_IF" -j ACCEPT

echo "=== SUCCESS ==="
echo "Hotspot: $HOTSPOT_SSID"
echo "Interface: $HOTSPOT_IF"
echo "Gateway: 192.168.150.1"