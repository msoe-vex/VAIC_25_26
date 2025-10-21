#!/bin/bash
# Purpose: Installs dependencies and configures the systemd service for Bluetooth SSH.

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

# Get the Bluetooth MAC address for instructions
BT_ADDR=$(bluetoothctl show | grep -i "Controller" | awk '{print $2}' || echo "UNKNOWN_MAC")
echo "Jetson Bluetooth MAC address: $BT_ADDR"

# --- 3. Create RFCOMM-to-SSH Bridge Systemd Service ---
SERVICE_FILE="/etc/systemd/system/bluetooth-ssh-bridge.service"
SSH_PORT=22 # Standard SSH port

echo "Creating systemd service file at $SERVICE_FILE..."
# The service uses 'rfcomm' which will automatically register the SPP service
# when it starts, often more reliably than 'sdptool add' during startup.
# It also ensures the service *waits* for bluetooth.target to be ready.
sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Bluetooth RFCOMM to SSH Bridge
After=bluetooth.target network.target ssh.service
Requires=bluetooth.target

[Service]
# User/Group to run the service as (non-root is safer, but rfcomm may need capabilities)
# Using root here for full device access, as in your original script.
User=root
Group=root

# The main command: Listen on channel 1, and pipe data through socat to local SSH
ExecStart=/usr/bin/rfcomm listen /dev/rfcomm0 1 /usr/bin/socat STDIO TCP:localhost:$SSH_PORT

# Restart policy: Always try to restart if the process exits (e.g., if rfcomm gets disconnected)
Restart=always
RestartSec=5s

# Standard output/error logs to journald
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# --- 4. Service Enable and Start ---
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Enabling and starting bluetooth-ssh-bridge.service..."
# This service will now survive reboots and restart on failure.
sudo systemctl enable bluetooth-ssh-bridge.service
sudo systemctl restart bluetooth-ssh-bridge.service

# --- 5. Bluetooth Agent/Config (separate step for pairing) ---
echo "Setting up Bluetooth discoverability and agent..."
# Use an interactive shell to configure bluetoothctl settings
bluetoothctl << EOF
power on
pairable on
discoverable on
discoverable-timeout 0
EOF

# Use bt-agent for auto-pairing (your original method)
echo "Starting Bluetooth agent in background for auto-accept pairing..."
# We use nohup and 'disown' to let it run *after* the script exits, or you can
# install 'bluetooth-agent.service' which is a better persistent solution.
# For simplicity, let's use your background process, but we'll manage the PID.
# A simpler approach is to set the default agent in /etc/bluetooth/main.conf
# or rely on a system agent/service. Sticking to your method:
sudo pkill -f "bt-agent" || true # Kill any old one
sudo nohup bt-agent -c NoInputNoOutput & disown

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