#!/bin/bash
# This script is designed to allow the jetson nano to open an SSH connection over bluetooth

set -euo pipefail

# Function to clean on exit
cleanup() {
    echo "Cleaning up..."
    sudo pkill -f "rfcomm listen /dev/rfcomm0" || true
    sudo pkill -f "socat" || true
    sudo sdptool del SP || true
    sudo rfcomm release 0 || true
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

sudo systemctl restart bluetooth
sleep 2
sudo systemctl enable --now ssh

# Configure Bluetooth
bluetoothctl << EOF
power on
agent NoInputNoOutput
default-agent
discoverable on
pairable on
EOF

echo "Bluetooth is discoverable and pairable"

# Get the bluetooth MAC address
BT_ADDR=$(bluetoothctl show | grep "Controller" | awk '{print $2}')
echo "Bluetooth MAC address: $BT_ADDR"

# Pick a TCP port
if ss -ltn "( sport = :22 )" | grep -q LISTEN; then
    PORT=2222
else
    PORT=22
fi
echo "Using TCP port $PORT for SSH"

# Register Serial Port Profile service
sudo sdptool add --channel=1 SP

# Start rfcomm in background
sudo rfcomm release 0 2>/dev/null || true
sudo rfcomm watch /dev/rfcomm0 1 sh -c "socat STDIO TCP:localhost:$PORT" &
RFCOMM_PID=$!

echo "Bluetooth SSH bridge active (pid $RFCOMM_PID)"
echo ""
echo "======================== CONNECTION INSTRUCTIONS ========================"
echo "Jetson Bluetooth MAC: $BT_ADDR"
echo ""
echo "FROM CLIENT DEVICE:"
echo "1. Pair: bluetoothctl pair $BT_ADDR"
echo "2. Trust: bluetoothctl trust $BT_ADDR"
echo "3. Connect: sudo rfcomm connect /dev/rfcomm0 $BT_ADDR 1"
echo "4. SSH: ssh username@localhost -o ProxyCommand='socat - /dev/rfcomm0'"
echo ""
echo "========================================================================="

# Monitor the connection
while true; do
    if ! kill -0 $RFCOMM_PID 2>/dev/null; then
        echo "Bridge died, restarting..."
        sudo rfcomm watch /dev/rfcomm0 1 sh -c "socat STDIO TCP:localhost:$PORT" &
        RFCOMM_PID=$!
    fi
    sleep 2
done