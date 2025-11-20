#!/bin/bash
# bluetoothpan-setup-full.sh
# Full ISOLATED Bluetooth PAN (NAP) server setup (multi-client capable)
#
# --- ULTIMATE MERGED VERSION ---
# 1. COMPAT MODE: Enables 'bluetoothd -C' for sdptool support.
# 2. SDP REGISTRATION: Uses 'sdptool add NAP' so Windows sees a Network Access Point.
# 3. CONFIG: Disables Audio/Input plugins so Windows doesn't see a Headset.
# 4. UDEV BRIDGING: Uses Udev rules for instant bridging (Fixes DHCP/169.254 issues).
# 5. AGENT: Uses persistent bt-agent to keep Pairable=Yes.
#
set -euo pipefail
SLEEP_SHORT=1

echo
echo "=== ISOLATED Bluetooth PAN (NAP) Setup (MULTI-CLIENT) ==="
echo

# --- 0. Basic variables ---
PAN_IP="192.168.100.1/24"
PAN_IP_ADDR="192.168.100.1"
DHCP_RANGE_START="192.168.100.50"
DHCP_RANGE_END="192.168.100.150"
DHCP_LEASE="12h"
BRIDGE_IF="br0"

# --- 1. Ensure required packages are installed ---
PACKAGES="bluez bluez-tools dnsmasq openssh-server bridge-utils"
MISSING=()
for p in $PACKAGES; do
  if ! dpkg -l 2>/dev/null | grep -q "^ii[[:space:]]\+$p[[:space:]]"; then
    MISSING+=("$p")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Installing missing packages: ${MISSING[*]}"
  sudo apt-get update
  sudo apt-get install -y "${MISSING[@]}"
fi

# --- 2. Create / configure br0 via NetworkManager ---
echo "Configuring bridge ${BRIDGE_IF} (NetworkManager)..."
sudo nmcli con delete ${BRIDGE_IF} 2>/dev/null || true
sudo ip link delete ${BRIDGE_IF} 2>/dev/null || true || true

# create the bridge and set IP
sudo nmcli con add type bridge ifname ${BRIDGE_IF} con-name ${BRIDGE_IF} >/dev/null
sudo nmcli con modify ${BRIDGE_IF} ipv4.method manual ipv4.addresses ${PAN_IP}
sudo nmcli con modify ${BRIDGE_IF} bridge.stp no
sudo nmcli con modify ${BRIDGE_IF} bridge.forward-delay 0
sudo nmcli con up ${BRIDGE_IF}

sudo ip link set dev ${BRIDGE_IF} type bridge ageing_time 0 2>/dev/null || true

sleep $SLEEP_SHORT

# --- 3. Tell NetworkManager to ignore bnep* ---
echo "Configuring NetworkManager to ignore bnep* devices..."
sudo tee /etc/NetworkManager/conf.d/99-unmanaged-bnep.conf > /dev/null <<'NMEOF'
[keyfile]
unmanaged-devices=interface-name:bnep*
NMEOF

sudo systemctl restart NetworkManager
sleep $SLEEP_SHORT

# --- 4. Configure dnsmasq for br0 ---
echo "Writing dnsmasq config for ${BRIDGE_IF}..."
sudo tee /etc/dnsmasq.d/bt-pan.conf > /dev/null <<DNSMASQ_EOF
interface=${BRIDGE_IF}
bind-interfaces
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_LEASE}
dhcp-option=option:router,${PAN_IP_ADDR}
dhcp-option=option:dns-server,${PAN_IP_ADDR}
listen-address=127.0.0.1,${PAN_IP_ADDR}
DNSMASQ_EOF

sudo systemctl enable dnsmasq.service
sudo systemctl restart dnsmasq.service
sleep $SLEEP_SHORT

# --- 5. ENABLE COMPATIBILITY MODE (Required for Windows Service Discovery) ---
echo "Enabling Bluetooth Compatibility Mode (-C)..."
sudo mkdir -p /etc/systemd/system/bluetooth.service.d
sudo tee /etc/systemd/system/bluetooth.service.d/override.conf > /dev/null <<'SVC_EOF'
[Service]
ExecStart=
ExecStart=/usr/lib/bluetooth/bluetoothd -C
SVC_EOF
sudo systemctl daemon-reload

# --- 6. SANITIZED /etc/bluetooth/main.conf ---
if [[ ! -f /etc/bluetooth/main.conf.bak-setup ]]; then
  sudo cp /etc/bluetooth/main.conf /etc/bluetooth/main.conf.bak-setup || true
fi

echo "Writing a SANITIZED /etc/bluetooth/main.conf..."
sudo tee /etc/bluetooth/main.conf > /dev/null <<MAIN_EOF
[General]
Name = %h
# 0x020104 = Desktop Computer
Class = 0x020104
DiscoverableTimeout = 0
PairableTimeout = 0
JustWorksRepairing = always

[Policy]
AutoEnable = true
MAIN_EOF

# Ensure network.conf points to br0
echo "Writing /etc/bluetooth/network.conf to use ${BRIDGE_IF}..."
sudo tee /etc/bluetooth/network.conf > /dev/null <<NETCONF_EOF
[General]
Interface=${BRIDGE_IF}
NETCONF_EOF

echo "Restarting bluetooth.service..."
sudo systemctl restart bluetooth.service
sleep $SLEEP_SHORT

# --- 7. Disable kernel IP forwarding (ISOLATED) ---
echo "Disabling IP forwarding..."
echo "net.ipv4.ip_forward=0" | sudo tee /etc/sysctl.d/98-pan-isolated.conf > /dev/null
sudo sysctl -w net.ipv4.ip_forward=0 >/dev/null || true

# --- 8. Persistent Agent Service ---
echo "Creating persistent bt-agent.service..."
sudo tee /etc/systemd/system/bt-agent.service > /dev/null <<AGENT_EOF
[Unit]
Description=Bluetooth Persistent Agent
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=simple
ExecStart=/usr/bin/bt-agent --capability=NoInputNoOutput
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
AGENT_EOF

sudo systemctl daemon-reload
sudo systemctl enable --now bt-agent.service

# --- 9. Controller Config & SDP Registration ---
echo "Installing controller helper (/usr/local/bin/bt-pan-config.sh)..."
sudo tee /usr/local/bin/bt-pan-config.sh > /dev/null <<'BTCONF_EOF'
#!/bin/bash
sleep 2

# 1. Force Controller Settings
/usr/bin/hciconfig hci0 up || true
/usr/bin/hciconfig hci0 lm MASTER,ACCEPT || true
/usr/bin/hciconfig hci0 piscan || true
/usr/bin/hciconfig hci0 sspmode 1 || true
/usr/bin/hciconfig hci0 class 0x020104 || true

# 2. Force Register NAP Service (The Digital Business Card)
/usr/bin/sdptool add NAP || true
/usr/bin/sdptool add GN || true

# 3. Set properties (Agent service keeps pairing open)
timeout 10 /usr/bin/bluetoothctl <<BTCTL_EOF
power on
pairable on
discoverable on
discoverable-timeout 0
exit
BTCTL_EOF
BTCONF_EOF

sudo chmod +x /usr/local/bin/bt-pan-config.sh

sudo tee /etc/systemd/system/bt-controller-config.service > /dev/null <<BT_SERVICE_EOF
[Unit]
Description=Configure Bluetooth Controller & SDP
After=bt-agent.service
Requires=bt-agent.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bt-pan-config.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
BT_SERVICE_EOF

sudo systemctl daemon-reload
sudo systemctl enable --now bt-controller-config.service
sleep $SLEEP_SHORT

# --- 10. Ensure conflicting services are gone ---
echo "Cleaning up old services..."
sudo systemctl stop bt-pan.service bt-add-bnep.service bt-add-bnep.path 2>/dev/null || true
sudo systemctl disable bt-pan.service bt-add-bnep.service bt-add-bnep.path 2>/dev/null || true
sudo rm -f /etc/systemd/system/bt-pan.service /etc/systemd/system/bt-add-bnep.service /etc/systemd/system/bt-add-bnep.path

# --- 11. UDEV Rule for Bridging (Fast) ---
# Replaces the slow systemd.path method
echo "Configuring Udev rule for automatic bridging..."

# Create Helper Script
sudo tee /usr/local/bin/bt-add-bnep-to-br0.sh > /dev/null <<'ADD_EOF'
#!/bin/bash
# Triggered by Udev when a bnep interface is added
set -e
BRIDGE="br0"
INTERFACE="$1"

if [ -z "$INTERFACE" ]; then
    # Fallback loop if no argument passed
    for ifpath in /sys/class/net/bnep*; do
        [ -e "$ifpath" ] || continue
        INTERFACE=$(basename "$ifpath")
        ip link set "$INTERFACE" master "$BRIDGE" || true
        ip link set "$INTERFACE" up || true
    done
else
    # Direct add
    sleep 0.5
    ip link set "$INTERFACE" master "$BRIDGE" || true
    ip link set "$INTERFACE" up || true
fi
ADD_EOF
sudo chmod +x /usr/local/bin/bt-add-bnep-to-br0.sh

# Create Udev Rule
echo 'ACTION=="add", SUBSYSTEM=="net", KERNEL=="bnep*", RUN+="/usr/local/bin/bt-add-bnep-to-br0.sh %k"' | sudo tee /etc/udev/rules.d/99-pan-bridge.rules > /dev/null

# Reload Udev
sudo udevadm control --reload-rules
sudo udevadm trigger

# --- 12. Debug helper script ---
sudo tee /usr/local/bin/bt-pan-debug > /dev/null <<'DEBUG_EOF'
#!/bin/bash
echo "=== Bluetooth PAN Diagnostics ==="
echo
echo "--- Services ---"
sudo systemctl status bluetooth.service dnsmasq.service bt-agent.service bt-controller-config.service --no-pager
echo
echo "--- SDP Services (Check for NAP) ---"
sudo sdptool browse local | grep "Network Access Point" -A 2 -B 2 || echo "NAP Service NOT FOUND in SDP!"
echo
echo "--- Controller (bluetoothctl show) ---"
bluetoothctl show || true
echo
echo "--- hciconfig ---"
hciconfig -a || true
echo
echo "--- Bridge Members (Should see bnep0) ---"
ip link show master br0
echo
echo "--- DHCP leases ---"
sudo cat /var/lib/dnsmasq/dnsmasq.leases 2>/dev/null || true
echo
echo "--- Recent logs ---"
sudo journalctl -u bluetooth.service -u bt-agent.service -u dnsmasq.service -n 50 --no-pager
DEBUG_EOF
sudo chmod +x /usr/local/bin/bt-pan-debug

# --- final message ---
echo "======================================="
echo "ISOLATED Bluetooth PAN (NAP) setup complete"
echo " - Run: sudo bt-pan-debug to check status"
echo "======================================="
echo