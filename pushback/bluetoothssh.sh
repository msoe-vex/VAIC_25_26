#!/bin/bash
# filepath: /home/s3nt/Downloads/programming/VAIC_25_26/pushback/bluetoothssh.sh
# This script is designed to allow the jetson nano to open an SSH connection over bluetooth

set -euo pipefail

# Function to clean on exit
cleanup() {
    echo "Cleaning up..."
    # Kill the rfcomm listener and the socat process started under sudo
    sudo pkill -f "rfcomm listen" || true
    # Attempt to delete SDP service. This can fail if the SDP server is already stopped.
    sudo sdptool del SP 2>/dev/null || true
    # Turn off discoverable/pairable
    bluetoothctl <<EOF >/dev/null 2>&1 || true
discoverable off
pairable off
EOF
    # Kill the bluetooth agent if it was started
    if [ -n "${BT_AGENT_PID:-}" ]; then
        sudo kill $BT_AGENT_PID 2>/dev/null || true
        # Wait for agent to exit completely before cleaning agent pids
        sleep 1
        sudo pkill -f "bt-agent" || true
    fi
}
trap cleanup EXIT

# Package check
# ADDED bluez-tools, which contains bt-agent on many systems
for pack in bluez openssh-server socat bluez-tools; do
    if ! dpkg -l | grep -q "^ii  $pack "; then
        echo "Installing $pack..."
        sudo apt-get update && sudo apt-get install -y "$pack"
    fi
done

echo "Restarting and enabling Bluetooth service..."
sudo systemctl restart bluetooth
sudo systemctl enable --now bluetooth

# Wait longer for the Bluetooth service/SDP server to fully initialize
sleep 8 

sudo systemctl enable --now ssh

# Get the bluetooth MAC address first
BT_ADDR=$(bluetoothctl show | grep "Controller" | awk '{print $2}')
if [ -z "$BT_ADDR" ]; then
    echo "ERROR: Could not find Bluetooth MAC address. Is the adapter present?"
    exit 1
fi
echo "Bluetooth MAC address: $BT_ADDR"

# Configure Bluetooth with proper agent
bluetoothctl << EOF
power on
pairable on
discoverable on
EOF

# Start bluetooth-agent in background to auto-accept pairing
echo "Starting Bluetooth agent..."
# Ensure the agent is started with 'sudo' if necessary, and use the full path if 'bt-agent' isn't in sudo's path
# We check if bt-agent exists, otherwise the script will fail here
if ! command -v bt-agent >/dev/null; then
    echo "ERROR: bt-agent not found. Please verify bluez-tools installation."
    exit 1
fi
sudo bt-agent -c NoInputNoOutput &
BT_AGENT_PID=$!
sleep 2

echo "Bluetooth is discoverable and pairable (auto-accept enabled)"

# Pick a TCP port
PORT=22
echo "Using TCP port $PORT for SSH"

# Register Serial Port Profile service with a stability check
echo "Attempting to register Serial Port Profile (SPP) service..."
sudo sdptool del SP 2>/dev/null || true # Clean old service
if sudo sdptool add --channel=1 SP; then
    echo "SUCCESS: SPP service registered on channel 1."
else
    echo "FATAL ERROR: Failed to register SDP service. The 'bluetooth' daemon may be unstable."
    exit 1
fi

# Verify SPP registration
echo "Registered services:"
sudo sdptool browse local | grep -A 2 'Service Name: Serial Port' || true

# Release any existing rfcomm bindings
for i in {0..9}; do
    sudo rfcomm release $i 2>/dev/null || true
done

# Start rfcomm listener with socat for the SSH bridge
echo "Starting RFCOMM listener on channel 1..."
# Note: rfcomm listen will block, so we use the '&' operator to run it in the background
# The socat command is passed as the listener handler.
sudo rfcomm listen /dev/rfcomm0 1 socat STDIO TCP:localhost:$PORT 2>&1 &
RFCOMM_PID=$!

# Give it time to start
sleep 2

# Verify it's running
if ! kill -0 $RFCOMM_PID 2>/dev/null; then
    echo "ERROR: RFCOMM failed to start! Check logs."
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

# Monitor the connection with a robust check for the RFCOMM bridge
while true; do
    # Check if the RFCOMM bridge process is still alive
    if ! kill -0 $RFCOMM_PID 2>/dev/null; then
        echo "[$(date)] Bridge died, restarting..."
        # Clean up old binding and restart the listener
        sudo rfcomm release 0 2>/dev/null || true
        sudo rfcomm listen /dev/rfcomm0 1 socat STDIO TCP:localhost:$PORT 2>&1 &
        RFCOMM_PID=$!
        
        # Check if the restart failed
        sleep 2
        if ! kill -0 $RFCOMM_PID 2>/dev/null; then
            echo "[$(date)] ERROR: Failed to restart RFCOMM bridge. Exiting monitor."
            break
        fi
    fi
    
    # Simple check for connected devices (might not be reliable for SPP, but keeps the original spirit)
    CONNECTED=$(bluetoothctl info 2>/dev/null | grep "Connected: yes" || true)
    if [ -n "$CONNECTED" ]; then
        # This message indicates the main adapter is connected to *something*, not necessarily the rfcomm connection
        : # Do nothing to avoid spamming "Device connected!"
    fi
    
    sleep 5
done

# Cleanup will be called automatically when the script exits