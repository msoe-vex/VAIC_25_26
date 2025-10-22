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
# Use bash wrapper to handle errors gracefully
ExecStartPre=/bin/sleep 3
ExecStartPre=/usr/bin/rfcomm release /dev/rfcomm0
ExecStart=/bin/bash -c 'while true; do /usr/bin/rfcomm watch /dev/rfcomm0 $RFCOMM_CHANNEL /usr/bin/socat STDIO TCP:localhost:$SSH_PORT 2>&1 | logger -t bluetooth-ssh-bridge; sleep 2; done'
# Don't restart on every connection - use watch mode instead
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
# Prevent rapid restart loops
StartLimitInterval=200
StartLimitBurst=5

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

# Use bluetoothctl with proper error handling
sudo bluetoothctl << EOF
power on
pairable on
discoverable on
discoverable-timeout 0
exit
EOF

# Verify controller is powered on
POWER_STATE=$(sudo bluetoothctl show | grep "Powered:" | awk '{print $2}')
if [[ "$POWER_STATE" != "yes" ]]; then
    echo "WARNING: Bluetooth controller may not be powered on properly!"
fi

echo ""
echo "========================================================================="
echo "                    SETUP COMPLETE - BLUETOOTH SSH READY"
echo "========================================================================="
echo "Jetson Bluetooth MAC: $BT_ADDR"
echo "Pairing Mode: Just Works (No PIN required)"
echo "RFCOMM Channel: 1"
echo ""
echo "Service Status Commands:"
echo "  - Bridge:  sudo systemctl status bluetooth-ssh-bridge.service"
echo "  - Agent:   sudo systemctl status bluetooth-pairing-agent.service"
echo "  - Logs:    sudo journalctl -u bluetooth-ssh-bridge.service -f"
echo ""
echo "Troubleshooting:"
echo "  1. On Windows: Remove device completely before pairing"
echo "  2. Check logs if connection drops: journalctl -xe"
echo "  3. Verify SSH is accessible locally: ssh localhost"
echo "  4. Check power supply if disconnections persist (5V/4A recommended)"
echo ""
echo "The services are configured to prevent restart loops on connection."
echo "========================================================================="