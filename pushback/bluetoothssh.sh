#!/bin/bash
# filepath: /home/s3nt/Downloads/programming/VAIC_25_26/pushback/bluetoothssh.sh
# This script is designed to allow the Jetson Orin Nano to open an SSH connection over bluetooth

set -euo pipefail

# Function to clean on exit
cleanup() {
    echo "Cleaning up..."
    sudo pkill -f "rfcomm" || true
    sudo pkill -f "socat" || true
    # Use -i hci0 for cleanup as well
    sudo sdptool -i hci0 del SP > /dev/null 2>&1 || true
    bluetoothctl <<EOF >/dev/null 2>&1 || true
discoverable off
pairable off
EOF
}
trap cleanup EXIT

# Package check
for pack in bluez openssh-server socat; do
    if ! dpkg -l | grep -q "^ii  $pack "; then
        echo "Installing $pack..."
        sudo apt-get install -y "$pack"
    fi
done

echo "Performing a full reset of the Bluetooth service..."
sudo systemctl stop bluetooth.service
sleep 2
sudo systemctl start bluetooth.service
sleep 2

echo "Forcing Bluetooth hardware interface (hci0) up..."
sudo hciconfig hci0 up

# STAGE 1: Wait for D-Bus
echo "Waiting for Bluetooth D-Bus interface..."
while ! sudo bluetoothctl show > /dev/null 2>&1; do
    echo "Waiting for D-Bus..."
    sleep 1
done
echo "Bluetooth D-Bus interface is ready."

# STAGE 2: Wait for SDP using the 'search' command
echo "Waiting for Bluetooth SDP server component..."
while ! sudo sdptool -i hci0 search SP > /dev/null 2>&1; do
    echo "Waiting for SDP..."
    sleep 1
done
echo "Bluetooth SDP server is ready."

sudo systemctl enable --now ssh

# Get the bluetooth MAC address first
BT_ADDR=$(bluetoothctl show | grep "Controller" | awk '{print $2}')
echo "Bluetooth MAC address: $BT_ADDR"

# Configure Bluetooth
bluetoothctl << EOF
power on
pairable on
discoverable on
EOF

echo "Starting Bluetooth agent..."
sudo bt-agent -c NoInputNoOutput &
sleep 2
echo "Bluetooth is discoverable and pairable."

PORT=22
echo "Using TCP port $PORT for SSH."

# Register Serial Port Profile service using the -i hci0 flag
sudo sdptool -i hci0 del SP > /dev/null 2>&1 || true
sleep 1 # Give the SDP server a moment to process the deletion
sudo sdptool -i hci0 add --channel=1 SP

echo "Registered services (searching for SP):"
sudo sdptool -i hci0 search SP

# Release any existing rfcomm bindings
for i in {0..9}; do
    sudo rfcomm release $i 2>/dev/null || true
done

echo "Starting RFCOMM listener on channel 1..."
sudo rfcomm listen /dev/rfcomm0 1 socat STDIO TCP:localhost:$PORT &
RFCOMM_PID=$!
sleep 2

if ! kill -0 $RFCOMM_PID 2>/dev/null; then
    echo "ERROR: RFCOMM failed to start!"
    exit 1
fi

echo "Bluetooth SSH bridge active (pid $RFCOMM_PID)"
echo ""
echo "======================== CONNECTION INSTRUCTIONS ========================"
echo "Jetson Bluetooth MAC: $BT_ADDR"
echo ""
echo "On a client, pair with the Jetson, then run:"
echo "sudo rfcomm connect /dev/rfcomm0 $BT_ADDR 1"
echo ""
echo "In another terminal on the client, run:"
echo "ssh <your_username>@localhost -o ProxyCommand='socat - /dev/rfcomm0'"
echo "========================================================================="
echo ""
echo "Monitoring connections... (Ctrl+C to stop)"

# Monitor the connection
while true; do
    if ! kill -0 $RFCOMM_PID 2>/dev/null; then
        echo "[$(date)] Bridge died, restarting..."
        sudo rfcomm release 0 2>/dev/null || true
        sudo rfcomm listen /dev/rfcomm0 1 socat STDIO TCP:localhost:$PORT &
        RFCOMM_PID=$!
    fi
    sleep 5
done