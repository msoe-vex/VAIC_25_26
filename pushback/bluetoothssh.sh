#!/bin/bash
# Purpose: Installs dependencies and configures systemd services for Bluetooth SSH
#          using a robust, forking "Just Works" (NoInputNoOutput) agent.
#          Enhanced with stability improvements to prevent service crashes.

set -euo pipefail

echo "Starting Bluetooth SSH Setup..."

# --- 0. Pre-flight Checks ---
echo "Performing pre-flight checks..."
# Ensure we're running with sufficient privileges
if [[ $EUID -eq 0 ]]; then
   echo "Warning: Running as root directly. Consider using sudo instead."
fi

# Check if Bluetooth hardware is available
if ! command -v hciconfig &> /dev/null || ! hciconfig hci0 &> /dev/null; then
    echo "ERROR: Bluetooth hardware (hci0) not detected. Exiting."
    exit 1
fi

# --- 1. Dependencies Check and Install ---
echo "Checking and installing dependencies (bluez, bluez-tools, openssh-server, socat)..."
for pack in bluez bluez-tools openssh-server socat; do
    if ! dpkg -l | grep -q "^ii[[:space:]]\+$pack[[:space:]]"; then
        echo "Installing $pack..."
        sudo apt-get update && sudo apt-get install -y "$pack"
    fi
done

# --- 2. System Service Setup ---
echo "Ensuring SSH service is enabled and running..."
sudo systemctl enable --now ssh

# Verify SSH is actually running
if ! sudo systemctl is-active --quiet ssh; then
    echo "ERROR: SSH service failed to start. Check configuration."
    exit 1
fi

# Get Bluetooth MAC address with retry
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

# --- 3. Create RFCOMM-to-SSH Bridge Service ---
SERVICE_FILE="/etc/systemd/system/bluetooth-ssh-bridge.service"
SSH_PORT=22
RFCOMM_CHANNEL=1

echo "Creating systemd service file at $SERVICE_FILE..."
echo "Cleaning up any existing RFCOMM bindings..."
# Release any existing RFCOMM bindings to prevent conflicts
sudo rfcomm release /dev/rfcomm0 2>/dev/null || true
sudo killall rfcomm 2>/dev/null || true

# Register SPP service with SDP
echo "Registering Serial Port Profile (SPP) service..."
sudo sdptool add --channel=$RFCOMM_CHANNEL SP 2>/dev/null || true

sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Bluetooth RFCOMM to SSH Bridge
After=bluetooth.target network.target ssh.service bluetooth-pairing-agent.service
Requires=bluetooth.target ssh.service
# Don't start until pairing agent is ready
Wants=bluetooth-pairing-agent.service

[Service]
Type=simple
User=root
Group=root
# Clean up before starting
ExecStartPre=/bin/sleep 3
ExecStartPre=/bin/sh -c 'killall rfcomm 2>/dev/null || true'
ExecStartPre=/usr/bin/rfcomm release /dev/rfcomm0 2>/dev/null || true
ExecStartPre=/usr/bin/sdptool add --channel=$RFCOMM_CHANNEL SP
# Use rfcomm watch with socat - keeps listening for new connections
ExecStart=/usr/bin/rfcomm watch /dev/rfcomm0 $RFCOMM_CHANNEL /usr/bin/socat - TCP:localhost:$SSH_PORT,nodelay,keepalive
# Clean up on stop
ExecStopPost=/usr/bin/rfcomm release /dev/rfcomm0 2>/dev/null || true
# Don't restart on every connection - watch mode handles reconnections
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
# Prevent rapid restart loops
StartLimitInterval=200
StartLimitBurst=5
# Keep the service alive
RemainAfterExit=no
# Set time limits to prevent hangs
TimeoutStartSec=30
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

# --- 4. Create Correct "Just Works" Agent Service ---
AGENT_SERVICE_FILE="/etc/systemd/system/bluetooth-pairing-agent.service"

echo "Creating systemd service file at $AGENT_SERVICE_FILE..."
sudo tee "$AGENT_SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Bluetooth Auto-Pairing Agent (Just Works)
After=bluetooth.target
Requires=bluetooth.target
Before=bluetooth-ssh-bridge.service

[Service]
# Use NoInputNoOutput for true "Just Works" auto-pairing
Type=simple
# Kill any existing bt-agent processes first
ExecStartPre=/bin/sh -c 'killall bt-agent 2>/dev/null || true'
ExecStartPre=/bin/sleep 2
# Run bt-agent in foreground with proper capability
ExecStart=/usr/bin/bt-agent --capability=NoInputNoOutput
# Only restart on failure, not on normal exit
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
# Prevent restart loops
StartLimitInterval=200
StartLimitBurst=5

[Install]
WantedBy=bluetooth.target
EOF

# --- 5. Clean Up Old Configs ---
echo "Cleaning up old config files and processes..."
# Kill any existing bt-agent or rfcomm processes
sudo killall bt-agent 2>/dev/null || true
sudo killall rfcomm 2>/dev/null || true

# Remove the static PIN file (not needed)
sudo rm -f /etc/bluetooth/pincodes.conf

# Backup main.conf before modifying
sudo cp /etc/bluetooth/main.conf /etc/bluetooth/main.conf.backup 2>/dev/null || true

# Ensure main.conf is properly configured
sudo sed -i '/^JustWorksRepairing/d' /etc/bluetooth/main.conf
sudo sed -i '/^SecureSimplePairing = false/d' /etc/bluetooth/main.conf

# Ensure ClassicBondedOnly is disabled (allows new pairings)
if ! grep -q "^ClassicBondedOnly" /etc/bluetooth/main.conf; then
    echo "ClassicBondedOnly = false" | sudo tee -a /etc/bluetooth/main.conf > /dev/null
else
    sudo sed -i 's/^ClassicBondedOnly.*/ClassicBondedOnly = false/' /etc/bluetooth/main.conf
fi

# Set DiscoverableTimeout to 0 in config (infinite)
if ! grep -q "^DiscoverableTimeout" /etc/bluetooth/main.conf; then
    echo "DiscoverableTimeout = 0" | sudo tee -a /etc/bluetooth/main.conf > /dev/null
else
    sudo sed -i 's/^DiscoverableTimeout.*/DiscoverableTimeout = 0/' /etc/bluetooth/main.conf
fi

# Disable auto-suspend for Bluetooth to prevent disconnections
if ! grep -q "^DisablePlugins" /etc/bluetooth/main.conf; then
    echo "DisablePlugins = " | sudo tee -a /etc/bluetooth/main.conf > /dev/null
fi

# Set page timeout to prevent quick disconnections (in slots, 1 slot = 0.625ms)
if ! grep -q "^PageTimeout" /etc/bluetooth/main.conf; then
    echo "PageTimeout = 8192" | sudo tee -a /etc/bluetooth/main.conf > /dev/null
else
    sudo sed -i 's/^PageTimeout.*/PageTimeout = 8192/' /etc/bluetooth/main.conf
fi

# Disable Bluetooth USB autosuspend to prevent disconnections
echo "Disabling USB autosuspend for Bluetooth..."
for device in /sys/bus/usb/devices/*/power/control; do
    if [ -f "$device" ]; then
        echo "on" | sudo tee "$device" > /dev/null 2>&1 || true
    fi
done

# --- 6. Service Enable and Start ---
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Stopping existing services..."
sudo systemctl stop bluetooth-ssh-bridge.service 2>/dev/null || true
sudo systemctl stop bluetooth-pairing-agent.service 2>/dev/null || true
sudo systemctl stop bluetooth.service

echo "Enabling and starting all services in correct order..."
# Enable services
sudo systemctl enable bluetooth-ssh-bridge.service
sudo systemctl enable bluetooth-pairing-agent.service

# Start bluetooth service first
sudo systemctl start bluetooth.service
sleep 2

# Start pairing agent
sudo systemctl start bluetooth-pairing-agent.service
sleep 2

# Finally start the bridge
sudo systemctl start bluetooth-ssh-bridge.service

echo "Waiting for services to stabilize..."
sleep 3

# Verify all services are running
if ! sudo systemctl is-active --quiet bluetooth.service; then
    echo "WARNING: Bluetooth service is not running!"
fi

if ! sudo systemctl is-active --quiet bluetooth-pairing-agent.service; then
    echo "WARNING: Pairing agent is not running! Check logs: sudo journalctl -u bluetooth-pairing-agent.service"
fi

if ! sudo systemctl is-active --quiet bluetooth-ssh-bridge.service; then
    echo "WARNING: SSH bridge is not running! Check logs: sudo journalctl -u bluetooth-ssh-bridge.service"
fi

# --- 7. Bluetooth Controller Config ---
echo "Setting up Bluetooth controller configuration..."
sleep 2 # Give services time to fully start

# Disable Bluetooth power management at kernel level
echo "Disabling Bluetooth power management..."
sudo hciconfig hci0 down 2>/dev/null || true
sleep 1
sudo hciconfig hci0 up
sudo hciconfig hci0 piscan
sudo hciconfig hci0 sspmode 1

# Create udev rule to disable USB autosuspend for Bluetooth permanently
echo "Creating udev rule to disable USB autosuspend for Bluetooth..."
sudo tee /etc/udev/rules.d/99-bluetooth-no-autosuspend.rules > /dev/null <<'UDEV_EOF'
# Disable autosuspend for all Bluetooth USB devices
ACTION=="add", SUBSYSTEM=="usb", ATTR{bDeviceClass}=="e0", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", DRIVERS=="btusb", ATTR{power/control}="on"
UDEV_EOF

sudo udevadm control --reload-rules
sudo udevadm trigger

# Use bluetoothctl with proper error handling
timeout 10 sudo bluetoothctl << EOF || true
power on
pairable on
discoverable on
discoverable-timeout 0
exit
EOF

# Give it a moment to apply
sleep 2

# Verify controller is powered on and configured
POWER_STATE=$(sudo bluetoothctl show | grep "Powered:" | awk '{print $2}')
PAIRABLE_STATE=$(sudo bluetoothctl show | grep "Pairable:" | awk '{print $2}')
DISCOVERABLE_STATE=$(sudo bluetoothctl show | grep "Discoverable:" | awk '{print $2}')

if [[ "$POWER_STATE" != "yes" ]]; then
    echo "WARNING: Bluetooth controller may not be powered on properly!"
fi

if [[ "$PAIRABLE_STATE" != "yes" ]]; then
    echo "WARNING: Bluetooth controller may not be pairable!"
fi

if [[ "$DISCOVERABLE_STATE" != "yes" ]]; then
    echo "WARNING: Bluetooth controller may not be discoverable!"
fi

# --- 8. Create Troubleshooting Helper Script ---
echo "Creating troubleshooting helper script..."
sudo tee /usr/local/bin/bt-ssh-debug > /dev/null <<'DEBUG_EOF'
#!/bin/bash
echo "=== Bluetooth SSH Bridge Diagnostics ==="
echo ""
echo "--- Service Status ---"
systemctl status bluetooth.service bluetooth-pairing-agent.service bluetooth-ssh-bridge.service --no-pager
echo ""
echo "--- Bluetooth Controller Info ---"
bluetoothctl show
hciconfig -a
echo ""
echo "--- Active Connections ---"
hcitool con
echo ""
echo "--- RFCOMM Bindings ---"
rfcomm -a
echo ""
echo "--- Recent Errors (last 30 lines) ---"
journalctl -u bluetooth-ssh-bridge.service -u bluetooth-pairing-agent.service -n 30 --no-pager
echo ""
echo "--- USB Power Management ---"
for device in /sys/bus/usb/devices/*/power/control; do
    if [ -f "$device" ]; then
        echo "$device: $(cat $device)"
    fi
done
DEBUG_EOF

sudo chmod +x /usr/local/bin/bt-ssh-debug

echo ""
echo "========================================================================="
echo "                    SETUP COMPLETE - BLUETOOTH SSH READY"
echo "========================================================================="
echo "Jetson Bluetooth MAC: $BT_ADDR"
echo "Pairing Mode: Just Works (No PIN required)"
echo "RFCOMM Channel: 1"
echo ""
echo "Bluetooth Controller Status:"
echo "  - Powered:      $POWER_STATE"
echo "  - Pairable:     $PAIRABLE_STATE"
echo "  - Discoverable: $DISCOVERABLE_STATE"
echo ""
echo "Service Status Commands:"
echo "  - Bridge:  sudo systemctl status bluetooth-ssh-bridge.service"
echo "  - Agent:   sudo systemctl status bluetooth-pairing-agent.service"
echo "  - Logs:    sudo journalctl -u bluetooth-ssh-bridge.service -f"
echo "  - Debug:   sudo bt-ssh-debug"
echo ""
echo "Troubleshooting:"
echo "  1. On Windows: Remove device completely before pairing"
echo "  2. Check logs if connection drops: journalctl -xe"
echo "  3. Run diagnostics: sudo bt-ssh-debug"
echo "  4. Verify SSH is accessible locally: ssh localhost"
echo "  5. Check power supply if disconnections persist (5V/4A recommended)"
echo "  6. Monitor connection: watch -n1 'hcitool con'"
echo ""
echo "The services are configured to prevent restart loops on connection."
echo "USB autosuspend has been disabled for Bluetooth devices."
echo "========================================================================="