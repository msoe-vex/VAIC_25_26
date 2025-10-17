#!/bin/bash
# filepath: /home/s3nt/Downloads/programming/VAIC_25_26/pushback/bluetoothssh.sh
#!/bin/bash
# This script is designed to allow the jetson nano to open an SSH connection over bluetooth

set -euo pipefail

# Function to clean on exit
cleanup() {
    echo "Cleaning up..."
    sudo pkill -f "rfcomm" || true
    sudo pkill -f "socat" || true
    # Attempt to delete SDP service, will error if SDP server is gone, but that's okay.
    # The || true handles the "no local SDP server" if it's already stopped.
    sudo sdptool del SP || true
    # Remove the problematic 'rfcomm release 0' since 'pkill' handles the listener.
    bluetoothctl <<EOF >/dev/null 2>&1 || true
discoverable off
pairable off
EOF
}
trap cleanup EXIT

# Package check
for pack in bluez openssh-server socat bluez-tools; do
    if ! dpkg -l | grep -q "^ii  $pack "; then
        echo "Installing $pack..."
        sudo apt-get install -y "$pack"
    fi
done

sudo systemctl restart bluetooth
sleep 5
sudo systemctl enable --now ssh

# Get the bluetooth MAC address first
BT_ADDR=$(bluetoothctl show | grep "Controller" | awk '{print $2}')
echo "Bluetooth MAC address: $BT_ADDR"

# Configure Bluetooth with proper agent
bluetoothctl << EOF
power on
pairable on
discoverable on
EOF

# Start bluetooth-agent in background to auto-accept pairing
echo "Starting Bluetooth agent..."
sudo bt-agent -c NoInputNoOutput &
BT_AGENT_PID=$!
sleep 2

echo "Bluetooth is discoverable and pairable (auto-accept enabled)"

# Pick a TCP port
if ss -ltn "( sport = :22 )" | grep -q LISTEN; then
    PORT=22
else
    PORT=22
fi
echo "Using TCP port $PORT for SSH"

# Register Serial Port Profile service with better parameters
sudo sdptool del SP 2>/dev/null || true
sudo sdptool add --channel=1 SP

# Verify SPP registration
echo "Registered services:"
sudo sdptool browse local

# Release any existing rfcomm bindings
for i in {0..9}; do
    sudo rfcomm release $i 2>/dev/null || true
done

# Start rfcomm listener with explicit logging
echo "Starting RFCOMM listener on channel 1..."
sudo rfcomm listen /dev/rfcomm0 1 socat STDIO TCP:localhost:$PORT 2>&1 &
RFCOMM_PID=$!

# Give it time to start
sleep 2

# Verify it's running
if ! kill -0 $RFCOMM_PID 2>/dev/null; then
    echo "ERROR: RFCOMM failed to start!"
    exit 1
fi

echo "Bluetooth SSH bridge active (pid $RFCOMM_PID)"
echo ""
echo "======================== CONNECTION INSTRUCTIONS ========================"
echo "Jetson Bluetooth MAC: $BT_ADDR"
echo ""
echo "FROM CLIENT DEVICE (Linux):"
echo "1. Scan: bluetoothctl scan on (wait to see device)"
echo "2. Pair: bluetoothctl pair $BT_ADDR"
echo "3. Trust: bluetoothctl trust $BT_ADDR"
echo "4. Connect: sudo rfcomm connect /dev/rfcomm0 $BT_ADDR 1"
echo "5. In another terminal: ssh <username>@localhost -p 22 -o ProxyCommand='socat - /dev/rfcomm0'"
echo ""
echo "FROM CLIENT DEVICE (Android with Termux):"
echo "1. Pair device normally through Android Bluetooth settings"
echo "2. In Termux: pkg install socat openssh"
echo "3. rfcomm connect /dev/rfcomm0 $BT_ADDR 1"
echo "4. ssh <username>@localhost -o ProxyCommand='socat - /dev/rfcomm0'"
echo ""
echo "========================================================================="
echo ""
echo "Monitoring connections... (Ctrl+C to stop)"

# Monitor the connection with detailed logging
while true; do
    if ! kill -0 $RFCOMM_PID 2>/dev/null; then
        echo "[$(date)] Bridge died, restarting..."
        sudo rfcomm release 0 2>/dev/null || true
        sudo rfcomm listen /dev/rfcomm0 1 socat STDIO TCP:localhost:$PORT 2>&1 &
        RFCOMM_PID=$!
    fi
    
    # Check for connected devices
    CONNECTED=$(bluetoothctl info 2>/dev/null | grep "Connected: yes" || true)
    if [ -n "$CONNECTED" ]; then
        echo "[$(date)] Device connected!"
    fi
    
    sleep 5
done