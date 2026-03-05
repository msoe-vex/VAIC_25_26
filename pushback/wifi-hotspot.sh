#!/bin/bash
# wifi-hotspot.sh
# 1. Installs RTL8811AU driver (88XXau) using manual DKMS steps
# 2. Configures WiFi-to-WiFi Bridge

set -euo pipefail

# --- CONFIG ---
SOURCE_IF="wlP1p1s0"      # Internal Realtek (Internet Source)
HOTSPOT_SSID="Jetson_Orin_AP"
HOTSPOT_PASS="msoe_password"
DRIVER_REPO="https://github.com/aircrack-ng/rtl8812au.git"
VER="5.6.4.2"             # Target version for DKMS
MODULE_NAME="88XXau"      # Confirmed kernel module name

echo "=== System Check ==="

# 1. Driver Installation Logic
if ! lsmod | grep -q "$MODULE_NAME"; then
    echo "Driver $MODULE_NAME not loaded. Checking installation..."
    
    # Check if the driver is already installed in DKMS but just not loaded
    if ! dkms status | grep -q "$MODULE_NAME"; then
        echo "Starting manual DKMS installation..."
        
        # Ensure we have internet to download tools/repo
        if ! ping -c 1 -W 2 google.com > /dev/null; then
            echo "ERROR: No internet connection on $SOURCE_IF. Please connect to WiFi first."
            exit 1
        fi

        sudo apt update
        sudo apt install -y git dkms build-essential bc

        # Clone the repo if it doesn't exist
        if [ ! -d "rtl8812au" ]; then
            git clone "$DRIVER_REPO"
        fi
        
        cd rtl8812au
        
        echo "Preparing DKMS source directory..."
        sudo mkdir -p /usr/src/8812au-${VER}
        sudo cp -r . /usr/src/8812au-${VER}

        echo "Adding, Building, and Installing driver (This takes 5-10 mins)..."
        # We use 8812au for the DKMS registration name, but the MODULE is 88XXau
        sudo dkms add -m 8812au -v ${VER} || true
        sudo dkms build -m 8812au -v ${VER}
        sudo dkms install -m 8812au -v ${VER}
        cd ..
    fi
    
    echo "Updating module dependencies and probing $MODULE_NAME..."
    sudo depmod -a
    sudo modprobe "$MODULE_NAME"
    sleep 3
else
    echo "Driver $MODULE_NAME is already installed and loaded."
fi

# 2. Identify the Hotspot Interface
# Finds any wlan/wlxf interface that is NOT the internal PCIe card
HOTSPOT_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlan|^wlxf' | grep -v "$SOURCE_IF" | head -n 1)

if [ -z "$HOTSPOT_IF" ]; then
    echo "ERROR: USB Hotspot interface not found. Try replugging the TP-Link adapter."
    exit 1
fi

echo "Using $HOTSPOT_IF for Access Point."

# 3. Network Configuration (IP Forwarding)
echo "Enabling IP Forwarding..."
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

# 6. IPTables NAT (The Bridge)
echo "Applying NAT rules..."
sudo iptables -t nat -F POSTROUTING
sudo iptables -t nat -A POSTROUTING -o "$SOURCE_IF" -j MASQUERADE
sudo iptables -A FORWARD -i "$SOURCE_IF" -o "$HOTSPOT_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i "$HOTSPOT_IF" -o "$SOURCE_IF" -j ACCEPT

echo "=== SUCCESS ==="
echo "Hotspot: $HOTSPOT_SSID"
echo "Interface: $HOTSPOT_IF"
echo "Gateway: 192.168.150.1"