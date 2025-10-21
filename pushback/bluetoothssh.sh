#!/bin/bash
# Purpose: Installs dependencies and configures the systemd service for Bluetooth SSH.
# IMPORTANT: This script MUST be run as root (e.g., "sudo ./setup_bluetooth_ssh.sh")

set -euo pipefail

# Set this for the whole script
export DEBIAN_FRONTEND=noninteractive

echo "Starting Bluetooth SSH Setup..."

# --- 1. Dependencies Check and Install ---
echo "Checking and installing dependencies (bluez, openssh-server, socat)..."
for pack in bluez openssh-server socat; do
    if ! dpkg -l | grep -q "^ii[[:space:]]\+$pack[[:space:]]"; then
        echo "Installing $pack..."
        apt-get update && apt-get install -y "$pack"
    fi
done

# --- 2. System Service Setup ---
echo "Packages installed. Setting up Bluetooth SSH service..."
sleep 2

# Get the Bluetooth MAC address (no sudo needed, script is root)
BT_ADDR=$(bluetoothctl show | grep -i "Controller" | awk '{print $2}' || echo "UNKNOWN_MAC")
echo "Jetson Bluetooth MAC address: $BT_ADDR"

# --- 3. Create RFCOMM-to-SSH Bridge Systemd Service ---
SERVICE_FILE="/etc/systemd/system/bluetooth-ssh-bridge.service"
SSH_PORT=22

echo "Creating systemd service file at $SERVICE_FILE..."
# No 'sudo' needed, tee is running as root
tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Bluetooth RFCOMM to SSH Bridge
After=bluetooth.target network.target ssh.service
Requires=bluetooth.target

[Service]
User=root
Group=root
ExecStart=/usr/bin/rfcomm listen /dev/rfcomm0 1 /usr/bin/socat STDIO TCP:localhost:$SSH_PORT
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# --- 4. Service Enable and Start ---
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling and starting bluetooth-ssh-bridge.service..."
systemctl enable bluetooth-ssh-bridge.service
systemctl restart bluetooth-ssh-bridge.service

# --- 5. Bluetooth Agent/Config (separate step for pairing) ---
echo "Setting up Bluetooth discoverability and agent..."
# No 'sudo' needed, script is root
bluetoothctl << EOF
power on
pairable on
discoverable on
discoverable-timeout 0
EOF

# Use bt-agent for auto-pairing
echo "Starting Bluetooth agent in background for auto-accept pairing..."
pkill -f "bt-agent" || true # No 'sudo' needed
nohup bt-agent -c NoInputNoOutput & disown

echo "Setup complete! The RFCOMM bridge is running."
echo ""
echo "======================== CONNECTION INSTRUCTIONS ========================"
echo "Jetson Bluetooth MAC: $BT_ADDR"
echo ""
echo "To check service status: sudo systemctl status bluetooth-ssh-bridge.service"
echo "To view logs: journalctl -u bluetooth-ssh-bridge.service -f"
echo "Please pair the devices now."
echo ""
echo "FROM CLIENT DEVICE (Linux/Termux):"
echo "1. Pair and Trust the Jetson ($BT_ADDR) using bluetoothctl/Android settings."
echo "2. Connect: sudo rfcomm connect /dev/rfcomm0 $BT_ADDR 1"
echo "3. SSH: ssh <username>@localhost -o ProxyCommand='socat - /dev/rfcomm0'"
echo "========================================================================="