#!/bin/bash
# Purpose: Installs dependencies and configures systemd services for Bluetooth SSH.

set -euo pipefail

echo "Starting Bluetooth SSH Setup..."

# --- 1. Dependencies Check and Install ---
echo "Checking and installing dependencies (bluez, openssh-server, socat)..."
for pack in bluez openssh-server socat; do
    if ! dpkg -l | grep -q "^ii[[:space:]]\+$pack[[:space:]]"; then
        echo "Installing $pack..."
        sudo apt-get update && sudo apt-get install -y "$pack"
    fi
done

# --- 2. System Service Setup ---

# Ensure SSH is enabled and running
echo "Ensuring SSH service is enabled and running..."
sudo systemctl enable --now ssh

# Get the Bluetooth MAC address for instructions (needs sudo)
BT_ADDR=$(sudo bluetoothctl show | grep -i "Controller" | awk '{print $2}' || echo "UNKNOWN_MAC")
echo "Jetson Bluetooth MAC address: $BT_ADDR"

# --- 3. Create Systemd Services ---

# --- 3a. RFCOMM-to-SSH Bridge Service ---
SERVICE_FILE="/etc/systemd/system/bluetooth-ssh-bridge.service"
SSH_PORT=22 # Standard SSH port

echo "Creating systemd service file at $SERVICE_FILE..."
sudo tee "$SERVICE_FILE" > /dev/null <<EOF
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

# --- 3b. Bluetooth Auto-Pairing Agent Service ---
AGENT_SERVICE_FILE="/etc/systemd/system/bluetooth-pairing-agent.service"

echo "Creating systemd service file at $AGENT_SERVICE_FILE..."
sudo tee "$AGENT_SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Bluetooth Auto-Pairing Agent
After=bluetooth.target
Requires=bluetooth.target

[Service]
ExecStart=/usr/bin/bt-agent -c DisplayYesNo
Restart=always
RestartSec=3

[Install]
WantedBy=bluetooth.target
EOF

# --- 4. Service Enable and Start ---
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Enabling and starting all services..."
sudo systemctl enable bluetooth-ssh-bridge.service
sudo systemctl enable bluetooth-pairing-agent.service

sudo systemctl restart bluetooth-ssh-bridge.service
sudo systemctl restart bluetooth-pairing-agent.service

# --- 5. Bluetooth Controller Config ---
echo "Setting up Bluetooth discoverability and agent..."
# Use an interactive shell to configure bluetoothctl settings (needs sudo)
sudo bluetoothctl << EOF
power on
pairable on
discoverable on
discoverable-timeout 0
EOF

# The 'nohup' command is no longer needed
echo "Bluetooth auto-pairing agent is now managed by systemd."

echo "Setup complete! The RFCOMM bridge is running."
echo ""
echo "======================== CONNECTION INSTRUCTIONS ========================"
echo "Jetson Bluetooth MAC: $BT_ADDR"
echo ""
echo "To check bridge status: sudo systemctl status bluetooth-ssh-bridge.service"
echo "To check agent status: sudo systemctl status bluetooth-pairing-agent.service"
echo "Please pair the devices now."
echo ""
echo "FROM CLIENT DEVICE (Linux/Termux):"
echo "1. Pair and Trust the Jetson ($BT_ADDR) using bluetoothctl/Android settings."
echo "2. Connect: sudo rfcomm connect /dev/rfcomm0 $BT_ADDR 1"
echo "3. SSH: ssh <username>@localhost -o ProxyCommand='socat - /dev/rfcomm0'"
echo "========================================================================="