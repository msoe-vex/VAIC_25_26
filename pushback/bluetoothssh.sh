#!/bin/bash
# bluetoothpan-setup-full.sh
# Full ISOLATED Bluetooth PAN (NAP) server setup (multi-client capable)
#
# --- FINAL WORKING VERSION ---
# - Uses 'tee' to safely overwrite /etc/bluetooth/main.conf with a
#   100% correct config, fixing all "Unknown key" errors.
# - REMOVED the conflicting bt-pan.service (bt-network).
# - We now let the main bluetooth.service handle the NAP connection,
#   as defined in /etc/bluetooth/network.conf.
# - FIXED helper script /usr/local/bin/bt-pan-config.sh to:
#   - Use correct /usr/bin/hciconfig path.
#   - Remove agent registration (relies on JustWorksRepairing in main.conf).
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
# bridge-utils is needed for brctl
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

# --- 3. Tell NetworkManager to ignore bnep* (so bluetooth creates bnep devices) ---
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

# --- 5. *** MODIFIED *** /etc/bluetooth/main.conf safe rewrite ---
# Backup original if not already backed up
if [[ ! -f /etc/bluetooth/main.conf.bak-setup ]]; then
  sudo cp /etc/bluetooth/main.conf /etc/bluetooth/main.conf.bak-setup || true
fi

echo "Writing a minimal, BlueZ-compatible /etc/bluetooth/main.conf (safe rewrite)..."
# Overwrite with a minimal, valid main.conf to fix all "Unknown key" errors.
sudo tee /etc/bluetooth/main.conf > /dev/null <<MAIN_EOF
[General]
Name = %h
Class = 0x00020104
DiscoverableTimeout = 0
JustWorksRepairing = always
AutoEnable = true

[Policy]
ClassicBondedOnly = false
PageTimeout = 8192
# We disable the default 'network' plugin so our network.conf can take over.
DisablePlugins = network
MAIN_EOF

# Ensure network.conf points to br0 (BlueZ will use this interface for NAP)
echo "Writing /etc/bluetooth/network.conf to use ${BRIDGE_IF}..."
sudo tee /etc/bluetooth/network.conf > /dev/null <<NETCONF_EOF
[General]
Interface=${BRIDGE_IF}
NETCONF_EOF

# Restart bluetoothd so main.conf / network.conf take effect
echo "Restarting bluetooth.service..."
sudo systemctl restart bluetooth.service
sleep $SLEEP_SHORT

# --- 6. Disable kernel IP forwarding to keep network ISOLATED ---
echo "Disabling IP forwarding (isolated network)..."
echo "net.ipv4.ip_forward=0" | sudo tee /etc/sysctl.d/98-pan-isolated.conf > /dev/null
sudo sysctl -w net.ipv4.ip_forward=0 >/dev/null || true

# --- 7. *** MODIFIED *** Install bt-controller-config helper ---
# This helper script just applies hciconfig settings and sets pairable/discoverable
echo "Installing controller helper (/usr/local/bin/bt-pan-config.sh)..."
sudo tee /usr/local/bin/bt-pan-config.sh > /dev/null <<'BTCONF_EOF'
#!/bin/bash
# Apply controller settings: bring up hci0 and set mode
sleep 1
set -e

# Bring up controller (errors ignored)
# MODIFIED: Fixed path from /sbin/hciconfig to /usr/bin/hciconfig
/usr/bin/hciconfig hci0 up || true
/usr/bin/hciconfig hci0 lm MASTER,ACCEPT || true
/usr/bin/hciconfig hci0 piscan || true
/usr/bin/hciconfig hci0 sspmode 1 || true
/usr/bin/hciconfig hci0 class 0x00020104 || true

# Use bluetoothctl: set pairable/discoverable
# MODIFIED: Removed agent registration. We now rely on 'JustWorksRepairing' in main.conf
timeout 25 /usr/bin/bluetoothctl <<BTCTL_EOF
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
Description=Configure Bluetooth Controller for PAN
After=bluetooth.service
Requires=bluetooth.service

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

# --- 8. *** MODIFIED *** Remove bt-pan.service (bt-network) ---
echo "Stopping and disabling old bt-pan.service (if it exists)..."
sudo systemctl stop bt-pan.service 2>/dev/null || true
sudo systemctl disable bt-pan.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/bt-pan.service

### MULTICLIENT ADDITION: helper to attach new bnep* interfaces to br0
# This script will be called by a systemd service/path to automatically
# add any bnep devices as members of the bridge so multiple clients work.
sudo tee /usr/local/bin/bt-add-bnep-to-br0.sh > /dev/null <<'ADD_EOF'
#!/bin/bash
# bt-add-bnep-to-br0.sh
# Add any bnep* interfaces to br0 if not already a member.
set -e
BRIDGE="br0"

# wait a tiny bit to let the kernel bring interface up
sleep 0.5

for ifpath in /sys/class/net/bnep*; do
  [ -e "$ifpath" ] || continue
  iface=$(basename "$ifpath")
  # check if interface already in bridge
  if ! bridge link show | grep -q " $iface "; then
    # add to bridge
    ip link set "$iface" master "$BRIDGE" || true
    ip link set "$iface" up || true
    echo "Attached $iface to $BRIDGE"
  fi
done
ADD_EOF

sudo chmod +x /usr/local/bin/bt-add-bnep-to-br0.sh

# systemd service the path unit will trigger
sudo tee /etc/systemd/system/bt-add-bnep.service > /dev/null <<'ADD_SVC_EOF'
[Unit]
Description=Attach bnep interfaces to br0
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bt-add-bnep-to-br0.sh
ADD_SVC_EOF

# systemd path unit watches for new bnep interfaces
sudo tee /etc/systemd/system/bt-add-bnep.path > /dev/null <<'ADD_PATH_EOF'
[Unit]
Description=Watch for new bnep interfaces and attach to br0

[Path]
# PathExistsGlob triggers when any bnep* appears under /sys/class/net
PathExistsGlob=/sys/class/net/bnep*

[Install]
WantedBy=multi-user.target
ADD_PATH_EOF

# enable and start path+service so future bnep devices are handled
sudo systemctl daemon-reload
sudo systemctl enable --now bt-add-bnep.path
sudo systemctl start bt-add-bnep.service || true

### END MULTICLIENT ADDITION

# --- 9. Small sanity wait and display status summary ---
sleep 1
echo
echo "=== Setup finished. Quick status summary: ==="
echo "- Bluetooth service:"
sudo systemctl status bluetooth.service --no-pager | sed -n '1,6p' || true
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

# --- 10. Debug helper script (same style as before) ---
sudo tee /usr/local/bin/bt-pan-debug > /dev/null <<'DEBUG_EOF'
#!/bin/bash
echo "=== Bluetooth PAN Diagnostics ==="
echo
echo "--- Services ---"
# MODIFIED: Removed bt-pan.service
sudo systemctl status bluetooth.service dnsmasq.service bt-controller-config.service bt-add-bnep.path --no-pager
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
echo "--- Recent logs (bluetooth, dnsmasq) ---"
# MODIFIED: Removed bt-pan.service
sudo journalctl -u bluetooth.service -u dnsmasq.service -u bt-controller-config.service -n 80 --no-pager
DEBUG_EOF
sudo chmod +x /usr/local/bin/bt-pan-debug

# --- final message ---
echo "======================================="
echo "ISOLATED Bluetooth PAN (NAP) setup complete (multi-client enabled)"
echo " - PAN IP: ${PAN_IP_ADDR}"
echo " - DHCP range: ${DHCP_RANGE_START}..${DHCP_RANGE_END}"
echo " - Pairing mode: Just Works (JustWorksRepairing = always)"
echo " - bnep interfaces will be auto-attached to br0 (systemd.path)"
echo " - Debug: sudo bt-pan-debug"
echo "======================================="
echo