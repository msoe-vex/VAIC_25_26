#!/bin/bash
# bluetoothpan-setup-full.sh
# Full ISOLATED Bluetooth PAN (NAP) server setup (multi-client capable)
#
# --- FINAL HYBRID STRATEGY ---
# 1. USES 'bt-network' (bt-pan.service) because internal BlueZ bridging is failing.
# 2. DISABLES internal 'network' plugin to prevent conflicts.
# 3. FIXES PAIRING by running a persistent Agent and re-applying controller
#    settings AFTER bt-network starts.
#
set -euo pipefail
SLEEP_SHORT=1

echo
echo "=== ISOLATED Bluetooth PAN (NAP) Setup (HYBRID) ==="
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
address=/msoe-nano/${PAN_IP_ADDR}
address=/msoe-nano1/${PAN_IP_ADDR}
address=/msoe-nano2/${PAN_IP_ADDR}
address=/msoe-nano.local/${PAN_IP_ADDR}
address=/msoe-nano1.local/${PAN_IP_ADDR}
address=/msoe-nano2.local/${PAN_IP_ADDR}
DNSMASQ_EOF

sudo systemctl enable dnsmasq.service
sudo systemctl restart dnsmasq.service
sleep $SLEEP_SHORT

# --- 5. ENABLE COMPATIBILITY MODE (Required for sdptool) ---
echo "Enabling Bluetooth Compatibility Mode (-C)..."
sudo mkdir -p /etc/systemd/system/bluetooth.service.d
sudo tee /etc/systemd/system/bluetooth.service.d/override.conf > /dev/null <<'SVC_EOF'
[Service]
ExecStart=
# -C for Compat, but NO --noplugin so Windows can pair
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
Class = 0x020104
DiscoverableTimeout = 0
PairableTimeout = 0
JustWorksRepairing = always

[Policy]
AutoEnable = true
# Disable internal network plugin so we can use bt-network instead
DisablePlugins = network
MAIN_EOF

# Clear network.conf since we are using bt-network
echo "" | sudo tee /etc/bluetooth/network.conf > /dev/null

echo "Restarting bluetooth.service..."
sudo systemctl restart bluetooth.service
sleep $SLEEP_SHORT

# --- 7. Disable kernel IP forwarding (ISOLATED) ---
echo "Disabling IP forwarding..."
echo "net.ipv4.ip_forward=0" | sudo tee /etc/sysctl.d/98-pan-isolated.conf > /dev/null
sudo sysctl -w net.ipv4.ip_forward=0 >/dev/null || true

# --- 8. *** RESTORED *** bt-pan.service (bt-network) ---
# We use this because internal BlueZ bridging was failing.
echo "Installing bt-pan.service (bt-network)..."
sudo tee /etc/systemd/system/bt-pan.service > /dev/null <<PAN_SERVICE_EOF
[Unit]
Description=Bluetooth PAN (NAP) service via bt-network
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=simple
# We tell it to bridge to br0.
ExecStart=/usr/bin/bt-network -s nap ${BRIDGE_IF}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
PAN_SERVICE_EOF

sudo systemctl daemon-reload
sudo systemctl enable --now bt-pan.service

# --- 9. Persistent Agent Service ---
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
TimeoutStopSec=2

[Install]
WantedBy=multi-user.target
AGENT_EOF

sudo systemctl daemon-reload
sudo systemctl enable --now bt-agent.service

# --- 10. Controller Config & SDP Registration ---
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

# 2. Force Register NAP Service (Legacy)
/usr/bin/sdptool add NAP || true
/usr/bin/sdptool add GN || true

# 3. Set properties (Fixes what bt-network might have broken)
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
# CRITICAL: Run AFTER bt-pan.service to override its bad settings
After=bt-pan.service bt-agent.service
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

# --- 11. UDEV Rule for Bridging ---
# Keeps the connection reliable even if bt-network misses the bridge event
echo "Configuring Udev rule for automatic bridging..."
sudo tee /usr/local/bin/bt-add-bnep-to-br0.sh > /dev/null <<'ADD_EOF'
#!/bin/bash
set -e
BRIDGE="br0"
INTERFACE="$1"
if [ -n "$INTERFACE" ]; then
    sleep 0.5
    ip link set "$INTERFACE" master "$BRIDGE" || true
    ip link set "$INTERFACE" up || true
fi
ADD_EOF
sudo chmod +x /usr/local/bin/bt-add-bnep-to-br0.sh

echo 'ACTION=="add", SUBSYSTEM=="net", KERNEL=="bnep*", RUN+="/usr/local/bin/bt-add-bnep-to-br0.sh %k"' | sudo tee /etc/udev/rules.d/99-pan-bridge.rules > /dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger

# --- 12. Debug helper script ---
sudo tee /usr/local/bin/bt-pan-debug > /dev/null <<'DEBUG_EOF'
#!/bin/bash
echo "=== Bluetooth PAN Diagnostics ==="
echo
echo "--- Services ---"
sudo systemctl status bluetooth.service bt-pan.service dnsmasq.service bt-agent.service bt-controller-config.service --no-pager
echo
echo "--- SDP Services (Check for NAP) ---"
sudo sdptool browse local | grep "Network Access Point" -A 2 -B 2
echo
echo "--- Controller (bluetoothctl show) ---"
bluetoothctl show || true
echo
echo "--- Bridge Members (Should see bnep0) ---"
ip link show master br0
echo
echo "--- DHCP leases ---"
sudo cat /var/lib/dnsmasq/dnsmasq.leases 2>/dev/null || true
DEBUG_EOF
sudo chmod +x /usr/local/bin/bt-pan-debug

echo "======================================="
echo "ISOLATED Bluetooth PAN (NAP) setup complete"
echo " - Run: sudo bt-pan-debug to check status"
echo "======================================="
echo