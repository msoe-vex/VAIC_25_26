#!/bin/bash
# Purpose: Installs dependencies and configures an *ISOLATED* Bluetooth PAN
#          server (NAP profile) with a DHCP server (dnsmasq) on a bridge (br0).
#          This script *DOES NOT* provide internet access/forwarding to clients.
#          Uses a "Just Works" (NoInputNoOutput) pairing agent.
#
# Changes:
# - Uses NetworkManager (nmcli) for br0 bridge.
# - Replaces deprecated bt-agent with a modern bluetoothctl-based agent.

set -euo pipefail

echo "Starting ISOLATED Bluetooth PAN Server Setup..."

# --- 0. Pre-flight Checks ---
echo "Performing pre-flight checks..."
if [[ $EUID -eq 0 ]]; then
    echo "Warning: Running as root directly. Consider using sudo instead."
fi

if ! command -v hciconfig &> /dev/null || ! hciconfig hci0 &> /dev/null; then
    echo "ERROR: Bluetooth hardware (hci0) not detected. Exiting."
    exit 1
fi

# --- 1. Dependencies Check and Install ---
echo "Checking and installing dependencies..."
PACKAGES_NEEDED="bluez bluez-tools openssh-server dnsmasq"
PACKAGES_TO_INSTALL=()

for pack in $PACKAGES_NEEDED; do
    if ! dpkg -l | grep -q "^ii[[:space:]]\+$pack[[:space:]]"; then
        PACKAGES_TO_INSTALL+=("$pack")
    fi
done

if [ ${#PACKAGES_TO_INSTALL[@]} -ne 0 ]; then
    echo "Installing missing packages: ${PACKAGES_TO_INSTALL[*]}"
    sudo apt-get update
    sudo apt-get install -y "${PACKAGES_TO_INSTALL[@]}"
fi

# --- 2. System Service Setup ---
echo "Ensuring SSH service is enabled and running..."
sudo systemctl enable --now ssh

if ! sudo systemctl is-active --quiet ssh; then
    echo "ERROR: SSH service failed to start."
    exit 1
fi

BT_ADDR=$(sudo bluetoothctl show | grep -i "Controller" | awk '{print $2}' || true)
if [[ -z "$BT_ADDR" ]]; then
    echo "ERROR: Could not detect Bluetooth MAC address."
    exit 1
fi
echo "Jetson Bluetooth MAC address: $BT_ADDR"

# --- 3. Create Bridge (br0) via NetworkManager ---
echo "Creating 'br0' bridge via NetworkManager..."
sudo nmcli con down br0 2>/dev/null || true
sudo nmcli con delete br0 2>/dev/null || true
sudo ip link delete br0 2>/dev/null || true

sudo nmcli con add type bridge ifname br0 con-name br0
sudo nmcli con modify br0 ipv4.method manual ipv4.addresses 192.168.100.1/24
sudo nmcli con modify br0 bridge.stp no
sudo nmcli con modify br0 bridge.forward-delay 0
sudo nmcli con up br0

# --- 4. Configure dnsmasq ---
echo "Configuring dnsmasq..."
sudo tee /etc/dnsmasq.d/bt-pan.conf > /dev/null <<'EOF'
interface=br0
bind-interfaces
dhcp-range=192.168.100.50,192.168.100.150,12h
dhcp-option=option:router,192.168.100.1
dhcp-option=option:dns-server,192.168.100.1
listen-address=127.0.0.1,192.168.100.1
EOF

# --- 5. Configure Bluetooth Network Daemon ---
echo "Configuring Bluetooth network.conf..."
sudo tee /etc/bluetooth/network.conf > /dev/null <<'EOF'
[General]
Interface=br0
EOF

# --- 6. Replace bt-agent with a modern bluetoothctl agent ---
AGENT_SERVICE_FILE="/etc/systemd/system/bluetooth-autopair.service"

echo "Creating bluetoothctl-based pairing agent service..."
sudo tee "$AGENT_SERVICE_FILE" > /dev/null <<'EOF'
[Unit]
Description=Bluetooth Auto-Pairing Agent (Just Works)
After=bluetooth.target
Requires=bluetooth.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'bluetoothctl agent NoInputNoOutput && bluetoothctl default-agent'
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=bluetooth.target
EOF

# --- 7. Update main.conf for discoverability ---
echo "Updating /etc/bluetooth/main.conf..."
sudo cp /etc/bluetooth/main.conf /etc/bluetooth/main.conf.backup 2>/dev/null || true
sudo sed -i '/^Class/d;/^DiscoverableTimeout/d;/^PairableTimeout/d;/^AutoEnable/d' /etc/bluetooth/main.conf
sudo tee -a /etc/bluetooth/main.conf > /dev/null <<'EOF'
[General]
Class = 0x00020104
DiscoverableTimeout = 0
PairableTimeout = 0
AutoEnable = true
EOF

# --- 8. Disable USB autosuspend for Bluetooth ---
echo "Disabling USB autosuspend for Bluetooth..."
for device in /sys/bus/usb/devices/*/power/control; do
    echo "on" | sudo tee "$device" >/dev/null 2>&1 || true
done

# --- 9. Enable Services ---
echo "Reloading and enabling services..."
sudo systemctl daemon-reload
sudo systemctl enable --now bluetooth-autopair.service
sudo systemctl enable --now dnsmasq.service
sudo systemctl enable --now bluetooth.service

# --- 10. Configure Controller ---
echo "Configuring Bluetooth controller..."
sudo hciconfig hci0 down || true
sleep 1
sudo hciconfig hci0 up
sudo hciconfig hci0 piscan
sudo hciconfig hci0 sspmode 1
sudo hciconfig hci0 class 0x00020104

# --- 11. Make persistent discoverability ---
timeout 10 sudo bluetoothctl << EOF || true
power on
pairable on
discoverable on
discoverable-timeout 0
advertise on
EOF

# --- 12. Debug helper script ---
sudo tee /usr/local/bin/bt-pan-debug > /dev/null <<'EOF'
#!/bin/bash
echo "=== Bluetooth PAN Server Diagnostics ==="
systemctl status bluetooth bluetooth-autopair dnsmasq --no-pager
echo ""
bluetoothctl show
hciconfig -a
echo ""
ip a show br0
nmcli con show br0
echo ""
cat /var/lib/dnsmasq/dnsmasq.leases 2>/dev/null || echo "No leases yet."
EOF
sudo chmod +x /usr/local/bin/bt-pan-debug

echo ""
echo "====================================================================="
echo "  SETUP COMPLETE - ISOLATED PAN SERVER READY"
echo "====================================================================="
echo "Jetson Bluetooth MAC: $BT_ADDR"
echo "Pairing Mode: Just Works (bluetoothctl agent)"
echo "PAN Network: 192.168.100.0/24"
echo "Jetson PAN IP (SSH Target): 192.168.100.1"
echo ""
echo "** No Internet forwarding enabled (ISOLATED MODE). **"
echo ""
echo "To debug: sudo bt-pan-debug"
echo "====================================================================="
