#!/bin/bash
# bluetoothpan-setup-full.sh
# Full ISOLATED Bluetooth PAN (NAP) server setup (multi-client capable)
#
# --- FINAL VERSION WITH COMPATIBILITY MODE ---
# 1. Enables 'bluetoothd -C' (Compat mode) to allow legacy tools like sdptool.
# 2. Uses 'sdptool add NAP' to FORCE advertise the Network Access Point service.
#    (This fixes the Windows "Headset vs Router" issue).
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

# --- 5. *** NEW *** ENABLE COMPATIBILITY MODE (Critical for sdptool) ---
echo "Enabling Bluetooth Compatibility Mode (-C)..."
# Create a drop-in override to add the -C flag to bluetoothd
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
# 0x020104 = Computer (Networking capable)
Class = 0x020104
DiscoverableTimeout = 0
PairableTimeout = 0
JustWorksRepairing = always
DisablePlugins = audio,input,avrcp,a2dp,hog

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

# --- 9. *** UPDATED *** Controller Config & SDP Registration ---
echo "Installing controller helper (/usr/local/bin/bt-pan-config.sh)..."
sudo tee /usr/local/bin/bt-pan-config.sh > /dev/null <<'BTCONF_EOF'
#!/bin/bash
sleep 2

# 1. Force Controller Settings
/usr/bin/hciconfig hci0 up || true
/usr/bin/hciconfig hci0 lm MASTER,ACCEPT || true
/usr/bin/hciconfig hci0 piscan || true
/usr/bin/hciconfig hci0 sspmode 1 || true
# Force Class to "Desktop Computer + Networking"
/usr/bin/hciconfig hci0 class 0x020104 || true

# 2. *** CRITICAL *** Force Register NAP Service
# This tells Windows: "I am a Network Access Point"
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
echo "Stopping and disabling old bt-pan.service (if it exists)..."
sudo systemctl stop bt-pan.service 2>/dev/null || true
sudo systemctl disable bt-pan.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/bt-pan.service

### MULTICLIENT ADDITION: helper to attach new bnep* interfaces to br0
sudo tee /usr/local/bin/bt-add-bnep-to-br0.sh > /dev/null <<'ADD_EOF'
#!/bin/bash
set -e
BRIDGE="br0"
sleep 0.5
for ifpath in /sys/class/net/bnep*; do
  [ -e "$ifpath" ] || continue
  iface=$(basename "$ifpath")
  if ! bridge link show | grep -q " $iface "; then
    ip link set "$iface" master "$BRIDGE" || true
    ip link set "$iface" up || true
    echo "Attached $iface to $BRIDGE"
  fi
done
ADD_EOF

sudo chmod +x /usr/local/bin/bt-add-bnep-to-br0.sh

sudo tee /etc/systemd/system/bt-add-bnep.service > /dev/null <<'ADD_SVC_EOF'
[Unit]
Description=Attach bnep interfaces to br0
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bt-add-bnep-to-br0.sh
ADD_SVC_EOF

sudo tee /etc/systemd/system/bt-add-bnep.path > /dev/null <<'ADD_PATH_EOF'
[Unit]
Description=Watch for new bnep interfaces and attach to br0

[Path]
PathExistsGlob=/sys/class/net/bnep*

[Install]
WantedBy=multi-user.target
ADD_PATH_EOF

sudo systemctl daemon-reload
sudo systemctl enable --now bt-add-bnep.path
sudo systemctl start bt-add-bnep.service || true

# --- 11. Status summary ---
sleep 2
echo
echo "=== Setup finished. Quick status summary: ==="
echo "- Bluetooth service:"
sudo systemctl status bluetooth.service --no-pager | sed -n '1,6p' || true
echo
echo "- bt-agent.service:"
sudo systemctl status bt-agent.service --no-pager | sed -n '1,6p' || true
echo
echo "- bt-controller-config.service:"
sudo systemctl status bt-controller-config.service --no-pager | sed -n '1,6p' || true
echo
echo "- dnsmasq:"
sudo systemctl status dnsmasq.service --no-pager | sed -n '1,6p' || true
echo
echo "- Network bridge:"
ip a show ${BRIDGE_IF} || true
nmcli con show ${BRIDGE_IF} || true
echo

# --- 12. Debug helper script ---
sudo tee /usr/local/bin/bt-pan-debug > /dev/null <<'DEBUG_EOF'
#!/bin/bash
echo "=== Bluetooth PAN Diagnostics ==="
echo
echo "--- Services ---"
sudo systemctl status bluetooth.service dnsmasq.service bt-agent.service bt-controller-config.service bt-add-bnep.path --no-pager
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
echo "--- Bridge ---"
ip a show br0 || true
brctl show br0 || true
nmcli con show br0 || true
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
echo " - Compat mode (-C) enabled"
echo " - NAP service registered via sdptool"
echo " - Debug: sudo bt-pan-debug"
echo "======================================="
echo