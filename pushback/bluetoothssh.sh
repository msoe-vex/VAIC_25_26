#!/bin/bash
# bluetoothpan-setup.sh
# Setup an ISOLATED Bluetooth PAN (NAP) server on br0 for Jetson (Ubuntu 22.04)
# - Uses NetworkManager to create br0
# - Uses dnsmasq for DHCP on br0
# - Uses bt-network (bluez-tools) to start NAP server
# - Registers a NoInputNoOutput agent (Just Works)
# - Creates systemd services for controller setup and NAP server
#
# Run as root (sudo)

set -euo pipefail
SLEEP_SHORT=1

echo
echo "=== ISOLATED Bluetooth PAN (NAP) Setup ==="
echo

# --- 0. Basic variables ---
PAN_IP="192.168.100.1/24"
PAN_IP_ADDR="192.168.100.1"
DHCP_RANGE_START="192.168.100.50"
DHCP_RANGE_END="192.168.100.150"
DHCP_LEASE="12h"
BRIDGE_IF="br0"

# --- 1. Ensure required packages are installed ---
PACKAGES="bluez bluez-tools dnsmasq openssh-server"
MISSING=()
for p in $PACKAGES; do
  if ! dpkg -l 2>/dev/null | grep -q "^ii[[:space:]]\+$p[[:space:]]"; then
    MISSING+=("$p")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Installing missing packages: ${MISSING[*]}"
  apt-get update
  apt-get install -y "${MISSING[@]}"
fi

# --- 2. Create / configure br0 via NetworkManager ---
echo "Configuring bridge ${BRIDGE_IF} (NetworkManager)..."
nmcli con delete ${BRIDGE_IF} 2>/dev/null || true
ip link delete ${BRIDGE_IF} 2>/dev/null || true || true

nmcli con add type bridge ifname ${BRIDGE_IF} con-name ${BRIDGE_IF}
nmcli con modify ${BRIDGE_IF} ipv4.method manual ipv4.addresses ${PAN_IP}
nmcli con modify ${BRIDGE_IF} bridge.stp no
nmcli con modify ${BRIDGE_IF} bridge.forward-delay 0
nmcli con up ${BRIDGE_IF}

sleep $SLEEP_SHORT

# --- 3. Tell NetworkManager to ignore bnep* (so bluetooth creates bnep devices) ---
echo "Configuring NetworkManager to ignore bnep* devices..."
cat > /etc/NetworkManager/conf.d/99-unmanaged-bnep.conf <<'NMEOF'
[keyfile]
unmanaged-devices=interface-name:bnep*
NMEOF

systemctl restart NetworkManager
sleep $SLEEP_SHORT

# --- 4. Configure dnsmasq for br0 ---
echo "Writing dnsmasq config for ${BRIDGE_IF}..."
cat > /etc/dnsmasq.d/bt-pan.conf <<DNSMASQ_EOF
interface=${BRIDGE_IF}
bind-interfaces
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_LEASE}
dhcp-option=option:router,${PAN_IP_ADDR}
dhcp-option=option:dns-server,${PAN_IP_ADDR}
listen-address=127.0.0.1,${PAN_IP_ADDR}
DNSMASQ_EOF

systemctl enable dnsmasq.service
systemctl restart dnsmasq.service
sleep $SLEEP_SHORT

# --- 5. Minimal, safe /etc/bluetooth/main.conf changes ---
# Backup original if not already backed up
if [[ ! -f /etc/bluetooth/main.conf.bak-setup ]]; then
  cp /etc/bluetooth/main.conf /etc/bluetooth/main.conf.bak-setup || true
fi

echo "Writing a minimal, BlueZ-compatible /etc/bluetooth/main.conf (preserving other content)..."
# Remove existing [General] and [Policy] sections (to avoid duplicates / unknown keys)
sed -i '/^\[General\]/,/^\[/d' /etc/bluetooth/main.conf || true
sed -i '/^\[Policy\]/,/^\[/d' /etc/bluetooth/main.conf || true

cat >> /etc/bluetooth/main.conf <<MAIN_EOF
[General]
# Minimal recommended settings for PAN + Just-Works
JustWorksRepairing = always
DiscoverableTimeout = 0
PairableTimeout = 0
Class = 0x00020104

[Policy]
# Keep Policy minimal. Do NOT insert DisablePlugins or AutoEnable here.
MAIN_EOF

# Ensure network.conf points to br0 (BlueZ will use this interface for NAP)
cat > /etc/bluetooth/network.conf <<NETCONF_EOF
[General]
Interface=${BRIDGE_IF}
NETCONF_EOF

# Restart bluetoothd so main.conf / network.conf take effect
echo "Restarting bluetooth.service..."
systemctl restart bluetooth.service
sleep $SLEEP_SHORT

# --- 6. Disable kernel IP forwarding to keep network ISOLATED ---
echo "Disabling IP forwarding (isolated network)..."
echo "net.ipv4.ip_forward=0" > /etc/sysctl.d/98-pan-isolated.conf
sysctl -w net.ipv4.ip_forward=0 >/dev/null || true

# --- 7. Install bt-controller-config helper (registers NoInputNoOutput agent) ---
echo "Installing controller helper (/usr/local/bin/bt-pan-config.sh)..."
cat > /usr/local/bin/bt-pan-config.sh <<'BTCONF_EOF'
#!/bin/bash
# Apply controller settings: bring up hci0 and register a Just-Works agent
sleep 1
set -e

# Bring up controller
/usr/sbin/hciconfig hci0 up || true
/usr/sbin/hciconfig hci0 lm MASTER,ACCEPT || true
/usr/sbin/hciconfig hci0 piscan || true
/usr/sbin/hciconfig hci0 sspmode 1 || true
/usr/sbin/hciconfig hci0 class 0x00020104 || true

# Use bluetoothctl: register a NoInputNoOutput agent and set pairable/discoverable
# We use a slightly longer timeout to avoid races during early boot.
timeout 25 /usr/bin/bluetoothctl <<BTCTL_EOF
agent NoInputNoOutput
default-agent
power on
pairable on
discoverable on
discoverable-timeout 0
exit
BTCTL_EOF
BTCONF_EOF

chmod +x /usr/local/bin/bt-pan-config.sh

cat > /etc/systemd/system/bt-controller-config.service <<BT_SERVICE_EOF
[Unit]
Description=Configure Bluetooth Controller for PAN (register Just-Works agent)
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bt-pan-config.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
BT_SERVICE_EOF

systemctl daemon-reload
systemctl enable --now bt-controller-config.service
sleep $SLEEP_SHORT

# --- 8. Install a small bt-pan.service to run NAP using bt-network (bluez-tools) ---
# bt-network -s nap br0  will register a network server (NAP) on br0.
echo "Installing systemd service to run NAP via bt-network (bt-pan.service)..."
cat > /etc/systemd/system/bt-pan.service <<PAN_SERVICE_EOF
[Unit]
Description=Bluetooth PAN (NAP) service via bt-network
After=bluetooth.service network-online.target
Requires=bluetooth.service

[Service]
Type=simple
# Use bt-network from bluez-tools to run NAP on br0
ExecStart=/usr/bin/bt-network -s nap ${BRIDGE_IF}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
PAN_SERVICE_EOF

systemctl daemon-reload
systemctl enable --now bt-pan.service
sleep $SLEEP_SHORT

# --- 9. Small sanity wait and display status summary ---
sleep 1
echo
echo "=== Setup finished. Quick status summary: ==="
echo "- Bluetooth service:"
systemctl status bluetooth.service --no-pager | sed -n '1,6p'
echo
echo "- bt-pan.service (NAP):"
systemctl status bt-pan.service --no-pager | sed -n '1,6p'
echo
echo "- bt-controller-config.service:"
systemctl status bt-controller-config.service --no-pager | sed -n '1,6p'
echo
echo "- dnsmasq:"
systemctl status dnsmasq.service --no-pager | sed -n '1,6p'
echo
echo "- Network bridge:"
ip a show ${BRIDGE_IF} || true
nmcli con show ${BRIDGE_IF} || true
echo

# --- 10. Debug helper script (same style as before) ---
cat > /usr/local/bin/bt-pan-debug <<'DEBUG_EOF'
#!/bin/bash
echo "=== Bluetooth PAN Diagnostics ==="
echo
echo "--- Services ---"
systemctl status bluetooth.service bt-pan.service dnsmasq.service bt-controller-config.service --no-pager
echo
echo "--- Controller (bluetoothctl show) ---"
bluetoothctl show || true
echo
echo "--- hciconfig ---"
hciconfig -a || true
echo
echo "--- Bridge ---"
ip a show br0 || true
nmcli con show br0 || true
echo
echo "--- DHCP leases ---"
cat /var/lib/dnsmasq/dnsmasq.leases 2>/dev/null || true
echo
echo "--- Recent logs (bluetooth, bt-pan, dnsmasq) ---"
journalctl -u bluetooth.service -u bt-pan.service -u dnsmasq.service -n 80 --no-pager
DEBUG_EOF
chmod +x /usr/local/bin/bt-pan-debug

# --- final message ---
echo "======================================="
echo "ISOLATED Bluetooth PAN (NAP) setup complete"
echo " - PAN IP: ${PAN_IP_ADDR}"
echo " - DHCP range: ${DHCP_RANGE_START}..${DHCP_RANGE_END}"
echo " - Pairing mode: Just Works (NoInputNoOutput agent registered)"
echo " - To view status: sudo bt-pan-debug"
echo " - To stop NAP: sudo systemctl stop bt-pan.service"
echo "======================================="
echo
