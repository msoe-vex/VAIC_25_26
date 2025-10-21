#!/bin/bash
# Purpose: Installs dependencies and configures systemd services for Bluetooth SSH
#          using the modern "Just Works" (NoInputNoOutput) pairing method.
#          Includes a cache clear to force config reload.

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
echo "Ensuring SSH service is enabled and running..."
sudo systemctl enable --now ssh
BT_ADDR=$(sudo bluetoothctl show | grep -i "Controller" | awk '{print $2}' || echo "UNKNOWN_MAC")
echo "Jetson Bluetooth MAC address: $BT_ADDR"

# --- 3. Create RFCOMM-to-SSH Bridge Service ---
SERVICE_FILE="/etc/systemd/system/bluetooth-ssh-bridge.service"
SSH_PORT=22
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

# --- 4. Remove Old/Buggy Agent Service ---
echo "Removing old bluetooth-pairing-agent.service..."
sudo systemctl stop bluetooth-pairing-agent.service || true
sudo systemctl disable bluetooth-pairing-agent.service || true
sudo rm -f /etc/systemd/system/bluetooth-pairing-agent.service
sudo rm -f /etc/bluetooth/pincodes.conf

# --- 5. Configure "Just Works" Pairing in main.conf ---
echo "Configuring 'JustWorksRepairing' in /etc/bluetooth/main.conf..."
if grep -q "JustWorksRepairing" /etc/bluetooth/main.conf; then
    sudo sed -i 's/^JustWorksRepairing.*/JustWorksRepairing = always/' /etc/bluetooth/main.conf
else
    sudo sed -i '/\[General\]/a JustWorksRepairing = always' /etc/bluetooth/main.conf
fi
sudo sed -i '/^SecureSimplePairing = false/d' /etc/bluetooth/main.conf

# --- 6. Service Enable, Cache Clear, and Start ---
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Enabling bluetooth-ssh-bridge.service..."
sudo systemctl enable bluetooth-ssh-bridge.service

echo "Stopping Bluetooth service to clear cache..."
sudo systemctl stop bluetooth.service

echo "Clearing Bluetooth adapter cache..."
# This forces bluetoothd to re-read all settings and forget old devices
sudo rm -rf /var/lib/bluetooth/*

echo "Restarting Bluetooth service..."
sudo systemctl start bluetooth.service
sudo systemctl restart bluetooth-ssh-bridge.service

# --- 7. Bluetooth Controller Config ---
echo "Setting up Bluetooth discoverability..."
# Give the service a second to come up before we talk to it
sleep 1
sudo bluetoothctl << EOF
power on
pairable on
discoverable on
discoverable-timeout 0
EOF

echo "Setup complete! The RFCOMM bridge is running."
echo ""
echo "======================== CONNECTION INSTRUCTIONS ========================"
echo "Jetson Bluetooth MAC: $BT_ADDR"
echo "PAIRING: 'Just Works' (No PIN or agent required)"
echo ""
echo "To check bridge status: sudo systemctl status bluetooth-ssh-bridge.service"
echo "You can now pair from your client device. It should connect automatically."
echo "CRITICAL: On Windows, you MUST 'Remove device' one last time before trying."
echo "========================================================================="