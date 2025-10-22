#!/bin/bash
# Purpose: Installs dependencies and configures systemd services for Bluetooth SSH
#          using a robust, forking "Just Works" (NoInputNoOutput) agent.

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

# --- 4. Create Correct "Just Works" Agent Service ---
AGENT_SERVICE_FILE="/etc/systemd/system/bluetooth-pairing-agent.service"

echo "Creating systemd service file at $AGENT_SERVICE_FILE..."
sudo tee "$AGENT_SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Bluetooth Auto-Pairing Agent (Just Works)
After=bluetooth.target
Requires=bluetooth.target

[Service]
# Correct for auto-pairing: NoInputNoOutput allows devices to connect without prompts
Type=forking
ExecStart=/usr/bin/bt-agent -d -c NoInputNoOutput
Restart=always
RestartSec=3
# Add logging to debug pairing issues (e.g., why connections drop)
StandardOutput=journal
StandardError=journal
# Optional: Add a short delay to ensure Bluetooth is ready
ExecStartPre=/bin/sleep 2

[Install]
WantedBy=bluetooth.target
EOF

# --- 5. Clean Up Old Configs ---
echo "Cleaning up old config files..."
# Remove the static PIN file (not needed)
sudo rm -f /etc/bluetooth/pincodes.conf
# Remove the JustWorksRepairing line from main.conf (not needed, agent handles it)
sudo sed -i '/^JustWorksRepairing/d' /etc/bluetooth/main.conf
# Ensure SSP is not disabled
sudo sed -i '/^SecureSimplePairing = false/d' /etc/bluetooth/main.conf

# --- 6. Service Enable and Start ---
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Enabling and starting all services..."
sudo systemctl enable bluetooth-ssh-bridge.service
sudo systemctl enable bluetooth-pairing-agent.service

# Restart the main bluetooth service to apply all new settings
sudo systemctl restart bluetooth.service
sudo systemctl restart bluetooth-ssh-bridge.service
sudo systemctl restart bluetooth-pairing-agent.service

# --- 7. Bluetooth Controller Config ---
echo "Setting up Bluetooth discoverability..."
sleep 1 # Give services a second to start
sudo bluetoothctl << EOF
power on
pairable on
discoverable on
discoverable-timeout 0
EOF

echo "Setup complete! The RFCOMM bridge and a stable agent are running."
echo ""
echo "======================== CONNECTION INSTRUCTIONS ========================"
echo "Jetson Bluetooth MAC: $BT_ADDR"
echo "PAIRING: 'Just Works' (No PIN required)"
echo ""
echo "To check bridge status: sudo systemctl status bluetooth-ssh-bridge.service"
echo "To check agent status: sudo systemctl status bluetooth-pairing-agent.service"
echo "CRITICAL: On Windows, you MUST 'Remove device' one last time before trying."
echo "========================================================================="