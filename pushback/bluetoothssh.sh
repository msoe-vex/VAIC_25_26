#!/bin/bash
# Purpose: Installs dependencies and configures an *ISOLATED* Bluetooth PAN
#          server (NAP profile) with a DHCP server (dnsmasq) on a bridge (br0).
#          This script *DOES NOT* provide internet access/forwarding to clients.
#          Uses "Just Works" (NoInputNoOutput) pairing via bluetoothd.
#
# Changes:
# - Now uses NetworkManager (nmcli) to create the br0 bridge.
# - Removed bridge-utils and ifupdown dependencies to avoid conflicts.
# - Removed deprecated 'bt-agent' service.
# - Configured 'bluetoothd' directly for "Just Works" pairing.
# - Adds NetworkManager config to ignore 'bnep*' devices.
# - Explicitly disables kernel IP forwarding.
# - NEW: Creates a dedicated systemd service (bt-controller-config.service)
#        to apply hciconfig and bluetoothctl settings AFTER bluetooth.service
#        starts. This fixes settings being reset (e.g., by nv-bluetooth-service.conf).

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

# --- 3. Create Bridge Network Interface (br0) via NetworkManager ---
PAN_NET_IP="192.168.100.1"
PAN_NET_MASK="255.255.255.0"
PAN_NET_RANGE="192.168.100.50,192.168.100.150,12h"

echo "Configuring br0 bridge via NetworkManager (nmcli)..."

# Clean up any old manual/ifupdown configs
sudo rm -f /etc/network/interfaces.d/br0

# Forcefully remove any old 'br0' connection or device
echo "Cleaning up any existing 'br0' connections or devices..."
sudo nmcli con down br0 2>/dev/null || true
sudo nmcli con delete br0 2>/dev/null || true
sudo ip link delete br0 2>/dev/null || true # Brute-force delete stray device

echo "Creating new 'br0' NetworkManager connection..."

# 1. Create the bridge connection profile and the 'br0' device
sudo nmcli con add type bridge ifname br0 con-name br0

# 2. Set the static IP configuration
sudo nmcli con modify br0 ipv4.method manual ipv4.addresses 192.168.100.1/24

# 3. Set bridge parameters (STP off, forward-delay 0)
sudo nmcli con modify br0 bridge.stp no
sudo nmcli con modify br0 bridge.forward-delay 0

# 4. Bring the new connection up
sudo nmcli con up br0

echo "NetworkManager bridge 'br0' is active."


# --- 3.5. Tell NetworkManager to IGNORE bnep devices ---
# This is CRITICAL to prevent NetworkManager from fighting with bluetoothd.
echo "Telling NetworkManager to ignore bnep* interfaces..."
sudo tee /etc/NetworkManager/conf.d/99-unmanaged-devices.conf > /dev/null <<'NM_EOF'
[keyfile]
unmanaged-devices=interface-name:bnep*
NM_EOF

echo "Restarting NetworkManager to apply unmanaged device rules..."
sudo systemctl restart NetworkManager
sleep 2


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

# --- 6. (REMOVED) "Just Works" Agent Service ---
echo "Skipping deprecated bt-agent service. Will configure bluetoothd directly."

# --- 7. Clean Up Old/Modify Main Configs ---
echo "Cleaning up old config files and processes..."
sudo killall bt-agent 2>/dev/null || true
sudo killall rfcomm 2>/dev/null || true

sudo systemctl stop bluetooth-ssh-bridge.service 2>/dev/null || true
sudo systemctl disable bluetooth-ssh-bridge.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/bluetooth-ssh-bridge.service
sudo rm -f /etc/systemd/system/bluetooth-pairing-agent.service # Clean up old file
sudo rm -f /etc/iptables/rules.v4 # Remove old NAT rules

sudo cp /etc/bluetooth/main.conf /etc/bluetooth/main.conf.backup 2>/dev/null || true

if ! grep -q "^JustWorksRepairing" /etc/bluetooth/main.conf; then
    echo "JustWorksRepairing = always" | sudo tee -a /etc/bluetooth/main.conf > /dev/null
else
    sudo sed -i 's/^JustWorksRepairing.*/JustWorksRepairing = always/' /etc/bluetooth/main.conf
fi

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

# --- 8. Disable IP Forwarding for ISOLATED Network ---
echo "Disabling Kernel IP Forwarding for isolated network..."
sudo sysctl -w net.ipv4.ip_forward=0
# Make it persistent
echo "net.ipv4.ip_forward=0" | sudo tee /etc/sysctl.d/98-pan-isolated.conf > /dev/null


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
sudo systemctl enable dnsmasq.service
sudo systemctl enable bluetooth.service
# bt-controller-config.service will be enabled in Section 11

sudo systemctl stop dnsmasq.service 2>/dev/null || true
sudo systemctl stop bluetooth.service

sudo systemctl start bluetooth.service
sleep 2
sudo systemctl start dnsmasq.service

echo "Restarting Bluetooth service to apply all network settings..."
sudo systemctl restart bluetooth.service

echo "Waiting for services to stabilize..."
sleep 3


# --- 11. *** NEW *** Create persistent service for Controller Settings ---
# This service runs AFTER bluetooth.service to apply settings that
# might be clobbered by other configs (like nv-bluetooth-service.conf).
echo "Creating persistent service to configure Bluetooth controller..."

sudo tee /etc/systemd/system/bt-controller-config.service > /dev/null <<'BT_CONF_EOF'
[Unit]
Description=Apply Bluetooth Controller Settings for PAN
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 2
ExecStart=/bin/sh -c "\
    /usr/bin/hciconfig hci0 up; \
    /usr/bin/hciconfig hci0 lm MASTER,ACCEPT; \
    /usr/bin/hciconfig hci0 piscan; \
    /usr/bin/hciconfig hci0 sspmode 1; \
    /usr/bin/hciconfig hci0 class 0x00020104; \
    /usr/bin/bluetoothctl power on; \
    /usr/bin/bluetoothctl pairable on; \
    /usr/bin/bluetoothctl discoverable on; \
    /usr/bin/bluetoothctl discoverable-timeout 0; \
    /usr/bin/bluetoothctl advertise on"
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
BT_CONF_EOF

echo "Enabling and starting bt-controller-config service..."
sudo systemctl daemon-reload
sudo systemctl enable --now bt-controller-config.service
sudo systemctl restart bt-controller-config.service

# --- 11.5. Clean up old UDEV rule ---
# The new service handles this, so the udev rule is redundant
sudo rm -f /etc/udev/rules.d/99-bluetooth-no-autosuspend.rules
sudo udevadm control --reload-rules
sudo udevadm trigger

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
systemctl status bluetooth.service dnsmasq.service NetworkManager.service bt-controller-config.service --no-pager
echo ""
echo "--- Bluetooth Controller Info ---"
bluetoothctl show
hciconfig -a
echo ""
echo "--- Bridge & IP Info (NetworkManager) ---"
ip a show br0
echo ""
echo "--- NetworkManager Status ---"
nmcli con show br0
echo ""
echo "--- NetworkManager Unmanaged Devices ---"
cat /etc/NetworkManager/conf.d/99-unmanaged-devices.conf
echo ""
echo "--- DHCP Leases ---"
cat /var/lib/dnsmasq/dnsmasq.leases
echo ""
echo "--- IP Forwarding Status ---"
echo "IP Forwarding: $(cat /proc/sys/net/ipv4/ip_forward) (0 = disabled, 1 = enabled)"
echo ""
echo "--- Recent Errors (last 30 lines) ---"
journalctl -u bluetooth.service -u dnsmasq.service -u bt-controller-config.service -n 30 --no-pager
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
echo " 1. **IMPORTANT:** On your client, 'Forget' the Jetson first."
echo " 2. On the Jetson, run 'sudo bluetoothctl' and 'remove <CLIENT_MAC>'."
echo " 3. On your client (phone/laptop), pair with the Jetson."
echo " 4. Join the 'Personal Area Network' or 'Network Access Point'."
echo " 5. Your client will get an IP (e.g., 192.168.100.x)."
echo " 6. You can now SSH to the Jetson at: ssh <your_user>@$PAN_NET_IP"
echo ""
echo "Debug: sudo bt-pan-debug"
echo "========================================================================="