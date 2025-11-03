#!/bin/bash
# Purpose: Installs dependencies and configures an *ISOLATED* Bluetooth PAN
#          server (NAP profile) with a DHCP server (dnsmasq) on a bridge (br0).
#          This script *DOES NOT* provide internet access/forwarding to clients.
#          Uses a "Just Works" (NoInputNoOutput) pairing agent.

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
# Removed iptables-persistent
PACKAGES_NEEDED="bluez bluez-tools openssh-server dnsmasq bridge-utils ifupdown"
PACKAGES_TO_INSTALL=()

for pack in $PACKAGES_NEEDED; do
    if ! dpkg -l | grep -q "^ii[[:space:]]\+$pack[[:space:]]"; then
        echo "Package $pack not found."
        PACKAGES_TO_INSTALL+=("$pack")
    fi
done

if [ ${#PACKAGES_TO_INSTALL[@]} -ne 0 ]; then
    echo "Installing missing packages: ${PACKAGES_TO_INSTALL[*]}"
    sudo apt-get update
    sudo apt-get install -y "${PACKAGES_TO_INSTALL[@]}"
fi

echo "Ensuring socat is removed (no longer needed)..."
if dpkg -l | grep -q "^ii[[:space:]]\+socat[[:space:]]"; then
    sudo apt-get remove -y socat
fi

# --- 2. System Service Setup ---
echo "Ensuring SSH service is enabled and running..."
sudo systemctl enable --now ssh

if ! sudo systemctl is-active --quiet ssh; then
    echo "ERROR: SSH service failed to start. Check configuration."
    exit 1
fi

BT_ADDR=""
for i in {1..3}; do
    BT_ADDR=$(sudo bluetoothctl show | grep -i "Controller" | awk '{print $2}' || echo "")
    if [[ -n "$BT_ADDR" ]]; then
        break
    fi
    echo "Retrying Bluetooth controller detection (attempt $i)..."
    sleep 2
done

if [[ -z "$BT_ADDR" ]]; then
    echo "ERROR: Could not detect Bluetooth MAC address. Exiting."
    exit 1
fi

echo "Jetson Bluetooth MAC address: $BT_ADDR"

# --- 3. Create Bridge Network Interface (br0) ---
PAN_NET_IP="192.168.100.1"
PAN_NET_MASK="255.255.255.0"
PAN_NET_RANGE="192.168.100.50,192.168.100.150,12h"

echo "Creating bridge interface config at /etc/network/interfaces.d/br0..."
sudo mkdir -p /etc/network/interfaces.d/
sudo tee /etc/network/interfaces.d/br0 > /dev/null <<'EOF'
# Bluetooth PAN Bridge
auto br0
iface br0 inet static
    address 192.168.100.1
    netmask 255.255.255.0
    bridge_ports none
    bridge_stp off
    bridge_fd 0
EOF

echo "Bringing up br0 interface..."
sudo systemctl stop dnsmasq.service 2>/dev/null || true
sudo ifdown br0 2>/dev/null || true
sudo ifup br0

# --- 4. Configure dnsmasq (DHCP Server) for br0 ---
echo "Configuring dnsmasq for br0..."
sudo tee /etc/dnsmasq.d/bt-pan.conf > /dev/null <<EOF
# Config for Bluetooth PAN (ISOLATED)
interface=br0
bind-interfaces
dhcp-range=$PAN_NET_RANGE
# Provide router (Jetson) but no external DNS to keep network isolated
dhcp-option=option:router,$PAN_NET_IP
dhcp-option=option:dns-server,$PAN_NET_IP
# Act as a DNS server for the PAN (for local names)
listen-address=127.0.0.1,$PAN_NET_IP
EOF

# --- 5. Configure Bluetooth Daemon for PAN ---
echo "Configuring Bluetooth daemon (bluetoothd) for networking..."
sudo tee /etc/bluetooth/network.conf > /dev/null <<'EOF'
[General]
# Use br0 as the PAN interface
Interface=br0
EOF

# --- 6. Create "Just Works" Agent Service ---
AGENT_SERVICE_FILE="/etc/systemd/system/bluetooth-pairing-agent.service"

echo "Creating systemd service file at $AGENT_SERVICE_FILE..."
sudo tee "$AGENT_SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Bluetooth Auto-Pairing Agent (Just Works)
After=bluetooth.target
Requires=bluetooth.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'killall bt-agent 2>/dev/null || true'
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/bt-agent --capability=NoInputNoOutput
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
StartLimitInterval=200
StartLimitBurst=5

[Install]
WantedBy=bluetooth.target
EOF

# --- 7. Clean Up Old/Modify Main Configs ---
echo "Cleaning up old config files and processes..."
sudo killall bt-agent 2>/dev/null || true
sudo killall rfcomm 2>/dev/null || true

sudo systemctl stop bluetooth-ssh-bridge.service 2>/dev/null || true
sudo systemctl disable bluetooth-ssh-bridge.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/bluetooth-ssh-bridge.service
sudo rm -f /etc/iptables/rules.v4 # Remove old NAT rules

sudo cp /etc/bluetooth/main.conf /etc/bluetooth/main.conf.backup 2>/dev/null || true
sudo sed -i '/^JustWorksRepairing/d' /etc/bluetooth/main.conf
sudo sed -i '/^SecureSimplePairing = false/d' /etc/bluetooth/main.conf

if ! grep -q "^Class" /etc/bluetooth/main.conf; then
    echo "Class = 0x00020104" | sudo tee -a /etc/bluetooth/main.conf > /dev/null
else
    sudo sed -i 's/^Class.*/Class = 0x00020104/' /etc/bluetooth/main.conf
fi

if ! grep -q "^ClassicBondedOnly" /etc/bluetooth/main.conf; then
    echo "ClassicBondedOnly = false" | sudo tee -a /etc/bluetooth/main.conf > /dev/null
else
    sudo sed -i 's/^ClassicBondedOnly.*/ClassicBondedOnly = false/' /etc/bluetooth/main.conf
fi

if ! grep -q "^DiscoverableTimeout" /etc/bluetooth/main.conf; then
    echo "DiscoverableTimeout = 0" | sudo tee -a /etc/bluetooth/main.conf > /dev/null
else
    sudo sed -i 's/^DiscoverableTimeout.*/DiscoverableTimeout = 0/' /etc/bluetooth/main.conf
fi

if ! grep -q "^DisablePlugins" /etc/bluetooth/main.conf; then
    echo "DisablePlugins = " | sudo tee -a /etc/bluetooth/main.conf > /dev/null
else
    sudo sed -i 's/network//g' /etc/bluetooth/main.conf
fi

if ! grep -q "^PageTimeout" /etc/bluetooth/main.conf; then
    echo "PageTimeout = 8192" | sudo tee -a /etc/bluetooth/main.conf > /dev/null
else
    sudo sed -i 's/^PageTimeout.*/PageTimeout = 8192/' /etc/bluetooth/main.conf
fi

# --- 8. (REMOVED) IP Forwarding and NAT Section ---
# This section is intentionally left blank as per your request.

# --- 9. Disable Bluetooth USB autosuspend ---
echo "Disabling USB autosuspend for Bluetooth..."
for device in /sys/bus/usb/devices/*/power/control; do
    if [ -f "$device" ]; then
        echo "on" | sudo tee "$device" > /dev/null 2>&1 || true
    fi
done

# --- 10. Service Enable and Start ---
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Enabling and (re)starting all services in correct order..."
sudo systemctl enable bluetooth-pairing-agent.service
sudo systemctl enable dnsmasq.service
sudo systemctl enable bluetooth.service

sudo systemctl stop bluetooth-pairing-agent.service 2>/dev/null || true
sudo systemctl stop dnsmasq.service 2>/dev/null || true
sudo systemctl stop bluetooth.service

sudo systemctl start bluetooth.service
sleep 2
sudo systemctl start bluetooth-pairing-agent.service
sleep 1
sudo systemctl start dnsmasq.service

echo "Restarting Bluetooth service to apply all network settings..."
sudo systemctl restart bluetooth.service

echo "Waiting for services to stabilize..."
sleep 3

if ! sudo systemctl is-active --quiet bluetooth.service; then
    echo "WARNING: Bluetooth service is not running!"
fi
if ! sudo systemctl is-active --quiet bluetooth-pairing-agent.service; then
    echo "WARNING: Pairing agent is not running!"
fi
if ! sudo systemctl is-active --quiet dnsmasq.service; then
    echo "WARNING: dnsmasq service is not running!"
fi

# --- 11. Bluetooth Controller Config ---
echo "Setting up Bluetooth controller configuration..."
sleep 2 

sudo hciconfig hci0 down 2>/dev/null || true
sleep 1
sudo hciconfig hci0 up
sudo hciconfig hci0 piscan
sudo hciconfig hci0 sspmode 1
sudo hciconfig hci0 class 0x00020104

echo "Creating udev rule to disable USB autosuspend for Bluetooth..."
sudo tee /etc/udev/rules.d/99-bluetooth-no-autosuspend.rules > /dev/null <<'UDEV_EOF'
# Disable autosuspend for all Bluetooth USB devices
ACTION=="add", SUBSYSTEM=="usb", ATTR{bDeviceClass}=="e0", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", DRIVERS=="btusb", ATTR{power/control}="on"
UDEV_EOF

sudo udevadm control --reload-rules
sudo udevadm trigger

timeout 10 sudo bluetoothctl << EOF || true
power on
pairable on
discoverable on
discoverable-timeout 0
advertise on
exit
EOF

sleep 2
POWER_STATE=$(sudo bluetoothctl show | grep "Powered:" | awk '{print $2}')
PAIRABLE_STATE=$(sudo bluetoothctl show | grep "Pairable:" | awk '{print $2}')
DISCOVERABLE_STATE=$(sudo bluetoothctl show | grep "Discoverable:" | awk '{print $2}')

# --- 12. Create Troubleshooting Helper Script ---
echo "Creating troubleshooting helper script..."
sudo tee /usr/local/bin/bt-pan-debug > /dev/null <<'DEBUG_EOF'
#!/bin/bash
echo "=== Bluetooth PAN Server Diagnostics (ISOLATED) ==="
echo ""
echo "--- Service Status ---"
systemctl status bluetooth.service bluetooth-pairing-agent.service dnsmasq.service --no-pager
echo ""
echo "--- Bluetooth Controller Info ---"
bluetoothctl show
hciconfig -a
echo ""
echo "--- Bridge & IP Info ---"
brctl show
ip a show br0
echo ""
echo "--- DHCP Leases ---"
cat /var/lib/dnsmasq/dnsmasq.leases
echo ""
echo "--- IP Forwarding Status ---"
echo "IP Forwarding: $(cat /proc/sys/net/ipv4/ip_forward) (0 = disabled, 1 = enabled)"
echo ""
echo "--- Recent Errors (last 30 lines) ---"
journalctl -u bluetooth.service -u bluetooth-pairing-agent.service -u dnsmasq.service -n 30 --no-pager
DEBUG_EOF

sudo chmod +x /usr/local/bin/bt-pan-debug

echo ""
echo "========================================================================="
echo "           SETUP COMPLETE - *ISOLATED* PAN SERVER READY"
echo "========================================================================="
echo "Jetson Bluetooth MAC: $BT_ADDR"
echo "Pairing Mode: Just Works (No PIN required)"
echo "PAN Network: 192.168.100.0/24"
echo "Jetson PAN IP (SSH Target): $PAN_NET_IP"
echo ""
echo "** This network DOES NOT provide internet access. **"
echo ""
echo "Bluetooth Controller Status:"
echo " - Powered: $POWER_STATE"
echo " - Pairable: $PAIRABLE_STATE"
echo " - Discoverable: $DISCOVERABLE_STATE"
echo ""
echo "How to Connect:"
echo " 1. On your client (phone/laptop), pair with the Jetson."
echo " 2. Join the 'Personal Area Network' or 'Network Access Point'."
echo " 3. Your client will get an IP (e.g., 192.168.100.x)."
echo " 4. You can now SSH to the Jetson at: ssh <your_user>@$PAN_NET_IP"
echo ""
echo "Debug: sudo bt-pan-debug"
echo "========================================================================="