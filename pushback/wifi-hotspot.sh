#!/bin/bash
# install-and-hostspot.sh
# 1. Installs RTL8811AU driver if missing
# 2. Configures WiFi-to-WiFi Bridge

set -euo pipefail

# --- CONFIG ---
SOURCE_IF="wlP1p1s0"      # Internal (Internet)
HOTSPOT_IF="wlan0"        # USB (To be created)
HOTSPOT_SSID="Jetson_Orin_AP"
HOTSPOT_PASS="msoe_password"
DRIVER_REPO="https://github.com/aircrack-ng/rtl8812au.git"

echo "=== System Check ==="

# 1. Check for Driver
if ! lsmod | grep -q "8812au"; then
    echo "Driver 8812au not loaded. Starting installation..."
    
    # Ensure we have internet
    if ! ping -c 1 -W 2 google.com > /dev/null; then
        echo "ERROR: No internet connection on $SOURCE_IF. Please connect to WiFi first."
        exit 1
    fi

    sudo apt update
    sudo apt install -y git dkms build-essential bc
    
    # Clone and install
    if [ ! -d "rtl8812au" ]; then
        git clone "$DRIVER_REPO"
    fi
    cd rtl8812au
    sudo ./dkms-install.sh
    cd ..
    
    echo "Driver installed. Probing module..."
    sudo modprobe 8812au
    sleep 3
else
    echo "Driver 8812au is already installed and loaded."
fi

# 2. Identify the Hotspot Interface
# The USB stick usually becomes wlan0 or wlan1 once the driver loads
HOTSPOT_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlan|^wlxf' | grep -v "$SOURCE_IF" | head -n 1)

if [ -z "$HOTSPOT_IF" ]; then
    echo "ERROR: USB Hotspot interface not found even after driver install."
    exit 1
fi

echo "Using $HOTSPOT_IF for Access Point."

# 3. Enable IP Forwarding
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

# 5. Fire it up
sudo nmcli con up Hotspot

# 6. IPTables NAT (The "Bridge")
sudo iptables -t nat -A POSTROUTING -o "$SOURCE_IF" -j MASQUERADE
sudo iptables -A FORWARD -i "$SOURCE_IF" -o "$HOTSPOT_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i "$HOTSPOT_IF" -o "$SOURCE_IF" -j ACCEPT

echo "=== SUCCESS ==="
echo "Hotspot: $HOTSPOT_SSID"
echo "Interface: $HOTSPOT_IF"