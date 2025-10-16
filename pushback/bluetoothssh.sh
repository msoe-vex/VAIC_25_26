#!/bin/bash
# This script is designed to allow the jetson nano to open an SSH connection over bluetooth

set -euo pipefail

# Function to clean on exit
cleanup() {
    echo "Cleaning up my oil spill..."
    sudo pkill -f "rfcomm listen /dev/rfcomm0" || true
    sudo pkill -f "socat TCP-LISTEN" || true
    sudo hciconfig hci0 down || true
    bluetoothctl <<EOF >/dev/null 2>&1 || true
discoverable off
pairable off
EOF
}
trap cleanup EXIT

# Package check
for pack in bluez openssh-server socat; do
    if ! dpkg -l | grep -q "^li $pack "; then
        echo "Installing $pack..."
        sudo apt-get install -y "$pack"
    fi
done

sudo systemctl restart bluetooth
sleep 2
sudo systemctl enable --now ssh

# Discoverability logic
bluetoothctl << EOF
power on
agent on
default-agent
discoverable on
pairable on
EOF

echo "Bluetooth is discoverable and pairable, awaiting SSH connection..."

# Get the bluetooth MAC address
BT_ADDR=$(bluetoothctl show | grep "Controller" | awk '{print $2}')
echo "Bluetooth MAC address: $BT_ADDR"

# pick a TCP port if 22 is in use
if ss -ltn "( sport = :22 )" | grep -q LISTEN; then
    PORT=2222
else
    PORT=22
fi
echo "Using TCP port $PORT for SSH"

sudo hciconfig hci0 up
sudo rfcomm release 0 || true

cat > /tmp/bt_ssh_handler.sh << HANDLER_EOF
#!/bin/bash
# This script handles each Bluetooth connection
exec socat STDIO TCP:localhost:$PORT
HANDLER_EOF
chmod +x /tmp/bt_ssh_handler.sh

echo "Starting Bluetooth SSH bridge..."
sudo rfcomm listen /dev/rfcomm0 1 /tmp/bt_ssh_handler.sh &
RFCOMM_PID=$!

echo "Bluetooth SSH bridge active (pid $RFCOMM_PID)"
echo ""
echo "========================" CONNECTION INSTRUCTIONS ========================"
"Jetson Nano Bluetooth MAC: $BT_ADDR"
""
"FROM CLIENT DEVICE:"
"1. Pair: bluetoothctl pair $BT_ADDR"
"2. Trust: bluetoothctl trust $BT_ADDR"
"3. Connect: sudo rfcomm connect /dev/rfcomm0 $BT_ADDR 1"
"4. SSH: ssh username@localhost -o ProxyCommand='cat /dev/rfcomm0'"
""
"SIMPLE TEST:"
"   sudo rfcomm connect /dev/rfcomm0 $BT_ADDR 1"
"   # You should see SSH banner appear automatically"
echo "========================================================================="

while true; do
    if ! kill -0 $RFCOMM_PID 2>/dev/null; then
        echo "Restarting bridge..."
        sudo rfcomm listen /dev/rfcomm0 1 /tmp/bt_ssh_handler.sh &
        RFCOMM_PID=$!
    fi
    sleep 0.5
done