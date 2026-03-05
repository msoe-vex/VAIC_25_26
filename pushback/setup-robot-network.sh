#!/bin/bash
# master-network-setup.sh
#
# Full system networking stack:
# - Bluetooth PAN (NAP) server
# - WiFi hotspot with internet sharing
# - DHCP via dnsmasq
# - Boot-persistent services
#
# Combines:
#   bluetoothssh.sh
#   wifi-hotspot.sh

set -euo pipefail
SLEEP_SHORT=1

echo
echo "======================================"
echo " Bluetooth PAN + WiFi Hotspot Setup"
echo "======================================"
echo

# ------------------------------------------------------------
# GLOBAL VARIABLES
# ------------------------------------------------------------

PAN_IP="192.168.100.1/24"
PAN_IP_ADDR="192.168.100.1"
DHCP_RANGE_START="192.168.100.50"
DHCP_RANGE_END="192.168.100.150"
DHCP_LEASE="12h"

BRIDGE_IF="br0"

HOTSPOT_PASS="RAIDER_ROBOTICS"
HOTSPOT_SSID="$(hostname)"

DRIVER_REPO="https://github.com/aircrack-ng/rtl8812au.git"
VER="5.6.4.2"
MODULE_NAME="88XXau"
DKMS_NAME="8812au"

SOURCE_IF=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
SOURCE_IF=${SOURCE_IF:-"wlP1p1s0"}

echo "Internet Source Interface: $SOURCE_IF"

# ------------------------------------------------------------
# INSTALL REQUIRED PACKAGES
# ------------------------------------------------------------

PACKAGES="bluez bluez-tools dnsmasq openssh-server bridge-utils git dkms build-essential bc"

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

# ------------------------------------------------------------
# NETWORKMANAGER CONFIG
# ------------------------------------------------------------

echo "Configuring NetworkManager to ignore bnep*..."

sudo tee /etc/NetworkManager/conf.d/99-unmanaged-bnep.conf > /dev/null <<'NMEOF'
[keyfile]
unmanaged-devices=interface-name:bnep*
NMEOF

sudo systemctl restart NetworkManager
sleep $SLEEP_SHORT

# ------------------------------------------------------------
# CREATE BRIDGE
# ------------------------------------------------------------

echo "Configuring bridge ${BRIDGE_IF}"

sudo nmcli con delete ${BRIDGE_IF} 2>/dev/null || true
sudo ip link delete ${BRIDGE_IF} 2>/dev/null || true

sudo nmcli con add type bridge ifname ${BRIDGE_IF} con-name ${BRIDGE_IF} >/dev/null
sudo nmcli con modify ${BRIDGE_IF} ipv4.method manual ipv4.addresses ${PAN_IP}
sudo nmcli con modify ${BRIDGE_IF} bridge.stp no
sudo nmcli con modify ${BRIDGE_IF} bridge.forward-delay 0
sudo nmcli con modify ${BRIDGE_IF} connection.autoconnect yes

sudo nmcli con up ${BRIDGE_IF}

sudo ip link set dev ${BRIDGE_IF} type bridge ageing_time 0 2>/dev/null || true
sleep $SLEEP_SHORT

# ------------------------------------------------------------
# DNSMASQ FOR BLUETOOTH PAN
# ------------------------------------------------------------

echo "Configuring dnsmasq..."

sudo tee /etc/dnsmasq.d/bt-pan.conf > /dev/null <<DNSMASQ_EOF
interface=${BRIDGE_IF}
bind-dynamic
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_LEASE}
dhcp-option=option:router,${PAN_IP_ADDR}
dhcp-option=option:dns-server,${PAN_IP_ADDR}
listen-address=127.0.0.1,${PAN_IP_ADDR}
address=/msoe-nano/${PAN_IP_ADDR}
address=/msoe-nano.local/${PAN_IP_ADDR}
DNSMASQ_EOF

sudo mkdir -p /etc/systemd/system/dnsmasq.service.d

sudo tee /etc/systemd/system/dnsmasq.service.d/override.conf > /dev/null <<'SYS_EOF'
[Unit]
After=network-online.target
Wants=network-online.target
SYS_EOF

sudo systemctl daemon-reload
sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq

sleep $SLEEP_SHORT

# ------------------------------------------------------------
# BLUETOOTH CONFIG
# ------------------------------------------------------------

echo "Configuring Bluetooth"

sudo mkdir -p /etc/systemd/system/bluetooth.service.d

sudo tee /etc/systemd/system/bluetooth.service.d/override.conf > /dev/null <<'SVC_EOF'
[Service]
ExecStart=
ExecStart=/usr/lib/bluetooth/bluetoothd -C
SVC_EOF

sudo systemctl daemon-reload

sudo tee /etc/bluetooth/main.conf > /dev/null <<MAIN_EOF
[General]
Name = %h
Class = 0x020300
DiscoverableTimeout = 0
PairableTimeout = 0
JustWorksRepairing = always

[Policy]
AutoEnable = true
DisablePlugins = network
MAIN_EOF

echo "" | sudo tee /etc/bluetooth/network.conf > /dev/null

sudo systemctl restart bluetooth
sleep $SLEEP_SHORT

# ------------------------------------------------------------
# ENABLE IP FORWARDING
# ------------------------------------------------------------

echo "Enabling IP forwarding"

echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/90-forwarding.conf > /dev/null
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null || true

# ------------------------------------------------------------
# BT PAN SERVICE
# ------------------------------------------------------------

echo "Installing bt-pan.service"

sudo tee /etc/systemd/system/bt-pan.service > /dev/null <<PAN_SERVICE_EOF
[Unit]
Description=Bluetooth PAN NAP service
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=simple
ExecStart=/usr/bin/bt-network -s nap ${BRIDGE_IF}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
PAN_SERVICE_EOF

sudo systemctl daemon-reload
sudo systemctl enable --now bt-pan.service

# ------------------------------------------------------------
# BLUETOOTH AGENT
# ------------------------------------------------------------

echo "Creating bt-agent.service"

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

# ------------------------------------------------------------
# WIFI HOTSPOT SETUP
# ------------------------------------------------------------

echo "Detecting WiFi hotspot interface..."

GET_IF() {
ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlan|^wlx' | grep -v "$SOURCE_IF" | head -n 1
}

HOTSPOT_IF=$(GET_IF)

if [ -z "$HOTSPOT_IF" ]; then
echo "Attempting driver install..."

if ! lsmod | grep -q "$MODULE_NAME"; then

if ! dkms status | grep -q "$DKMS_NAME"; then

sudo apt install -y git dkms build-essential bc

[ ! -d "rtl8812au" ] && git clone "$DRIVER_REPO"

cd rtl8812au

sudo mkdir -p /usr/src/${DKMS_NAME}-${VER}
sudo cp -r . /usr/src/${DKMS_NAME}-${VER}

sudo dkms add -m $DKMS_NAME -v ${VER} || true
sudo dkms build -m $DKMS_NAME -v ${VER}
sudo dkms install -m $DKMS_NAME -v ${VER}

cd ..

fi

sudo depmod -a
sudo modprobe "$MODULE_NAME"
sleep 2

fi

HOTSPOT_IF=$(GET_IF)

fi

if [ -z "$HOTSPOT_IF" ]; then
echo "ERROR: No hotspot interface found"
exit 1
fi

echo "Hotspot Interface: $HOTSPOT_IF"

# ------------------------------------------------------------
# CREATE HOTSPOT CONNECTION
# ------------------------------------------------------------

sudo nmcli con add type wifi ifname "$HOTSPOT_IF" con-name "Hotspot" autoconnect yes ssid "$HOTSPOT_SSID"

sudo nmcli con modify "Hotspot" 802-11-wireless.mode ap
sudo nmcli con modify "Hotspot" 802-11-wireless.band bg

sudo nmcli con modify "Hotspot" 802-11-wireless-security.key-mgmt wpa-psk
sudo nmcli con modify "Hotspot" 802-11-wireless-security.psk "$HOTSPOT_PASS"

sudo nmcli con modify "Hotspot" ipv4.method shared
sudo nmcli con modify "Hotspot" ipv4.addresses "192.168.150.1/24"

sudo nmcli con up "Hotspot"

# ------------------------------------------------------------
# IPTABLES
# ------------------------------------------------------------

sudo iptables -t nat -A PREROUTING -i "$HOTSPOT_IF" -p udp --dport 53 -j DNAT --to-destination 8.8.8.8
sudo iptables -t nat -A PREROUTING -i "$HOTSPOT_IF" -p tcp --dport 53 -j DNAT --to-destination 8.8.8.8

sudo iptables -t nat -F POSTROUTING
sudo iptables -t nat -A POSTROUTING -o "$SOURCE_IF" -j MASQUERADE

sudo iptables -A FORWARD -i "$SOURCE_IF" -o "$HOTSPOT_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i "$HOTSPOT_IF" -o "$SOURCE_IF" -j ACCEPT

# ------------------------------------------------------------
# PERSISTENT WIFI HOTSPOT SERVICE
# ------------------------------------------------------------

echo "Installing persistent WiFi hotspot service..."

sudo tee /usr/local/bin/start-wifi-hotspot.sh > /dev/null <<'HOTSPOT_EOF'
#!/bin/bash
set -euo pipefail

SOURCE_IF=$(ip route show default | awk '/default/ {print $5}' | head -n 1)

GET_IF() {
ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlan|^wlx' | grep -v "$SOURCE_IF" | head -n 1
}

HOTSPOT_IF=$(GET_IF)

sudo nmcli device set "$HOTSPOT_IF" managed yes || true
sudo nmcli con up "Hotspot" || true
HOTSPOT_EOF

sudo chmod +x /usr/local/bin/start-wifi-hotspot.sh

sudo tee /etc/systemd/system/wifi-hotspot.service > /dev/null <<'SERVICE_EOF'
[Unit]
Description=WiFi Hotspot Service
After=NetworkManager.service network-online.target
Wants=network-online.target
Requires=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/start-wifi-hotspot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE_EOF

sudo systemctl daemon-reload
sudo systemctl enable wifi-hotspot.service

# ------------------------------------------------------------
# COMPLETE
# ------------------------------------------------------------

echo
echo "======================================"
echo " SETUP COMPLETE"
echo "======================================"
echo "Bluetooth PAN Network: 192.168.100.x"
echo "WiFi Hotspot Network: 192.168.150.x"
echo
echo "WiFi SSID: $HOTSPOT_SSID"
echo "WiFi Password: $HOTSPOT_PASS"
echo
echo "Reboot recommended."
echo