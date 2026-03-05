#!/bin/bash
# setup-robot-network.sh
# ONE SCRIPT TO RULE THEM ALL: WiFi Hotspot + Bluetooth PAN + Boot Persistence

set -euo pipefail

echo "==========================================================="
echo "   RAIDER ROBOTICS - ALL-IN-ONE NETWORK INSTALLER          "
echo "==========================================================="

# --- 1. CONFIGURATION ---
SOURCE_IF=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
SOURCE_IF=${SOURCE_IF:-"wlP1p1s0"}
HOTSPOT_SSID="$(hostname)"
HOTSPOT_PASS="RAIDER_ROBOTICS"
PAN_IP="192.168.100.1/24"
BRIDGE_IF="br0"

# --- 2. INSTALL DEPENDENCIES ---
echo "[1/6] Installing required packages..."
sudo apt update
sudo apt install -y bluez bluez-tools dnsmasq bridge-utils git dkms build-essential bc network-manager

# --- 3. CREATE THE BACKGROUND SERVICES (BOOT PERSISTENCE) ---
echo "[2/6] Writing system services for boot persistence..."

# A. Bluetooth PAN Service
sudo tee /etc/systemd/system/bt-pan.service > /dev/null <<EOF
[Unit]
Description=Bluetooth PAN NAP Service
After=bluetooth.service
Requires=bluetooth.service
[Service]
Type=simple
ExecStart=/usr/bin/bt-network -s nap $BRIDGE_IF
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# B. Bluetooth Auth Agent (Auto-Pairing)
sudo tee /etc/systemd/system/bt-agent.service > /dev/null <<EOF
[Unit]
Description=Bluetooth Auth Agent
After=bluetooth.service
[Service]
Type=simple
ExecStart=/usr/bin/bt-agent --capability=NoInputNoOutput
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# --- 4. CONFIGURE BLUETOOTH IDENTITY (NAP Mode) ---
echo "[3/6] Configuring Bluetooth Class and Mode..."
sudo mkdir -p /etc/systemd/system/bluetooth.service.d
sudo tee /etc/systemd/system/bluetooth.service.d/override.conf > /dev/null <<EOF
[Service]
ExecStart=
ExecStart=/usr/lib/bluetooth/bluetoothd -C
EOF

sudo tee /etc/bluetooth/main.conf > /dev/null <<EOF
[General]
Name = %h
Class = 0x020300
DiscoverableTimeout = 0
PairableTimeout = 0
[Policy]
AutoEnable = true
DisablePlugins = network
EOF

# --- 5. CREATE THE MASTER RUNTIME SCRIPT (FIXED) ---
echo "[4/6] Creating master runtime script at /usr/local/bin/robot-bridge-up.sh..."
sudo tee /usr/local/bin/robot-bridge-up.sh > /dev/null <<EOF
#!/bin/bash
# A. Enable Forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/90-robot-forwarding.conf

# B. HARDWARE KICKSTART (CRITICAL FIX)
# Wait for hardware to settle
sleep 5
hciconfig hci0 up || true
hciconfig hci0 class 0x020300 || true
sdptool add NAP || true

# Force bluetoothctl settings
bluetoothctl <<BTCTL
power on
discoverable on
pairable on
exit
BTCTL

# C. Find Interfaces
SRC=\$(ip route show default | awk '/default/ {print \$5}' | head -n 1)
SRC=\${SRC:-"wlP1p1s0"}
WIFI_IF=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -E '^wlan|^wlx' | grep -v "\$SRC" | head -n 1)

# D. WiFi Hotspot Cleanup & Start
mapfile -t ALL_CONS < <(nmcli -g NAME connection show)
for con in "\${ALL_CONS[@]}"; do
    IS_AP=\$(nmcli -g 802-11-wireless.mode connection show "\$con" 2>/dev/null || echo "client")
    [ "\$IS_AP" == "ap" ] && nmcli con delete "\$con" > /dev/null 2>&1 || true
done

if [ -n "\$WIFI_IF" ]; then
    nmcli con add type wifi ifname "\$WIFI_IF" con-name "Hotspot" autoconnect yes ssid "$HOTSPOT_SSID"
    nmcli con modify "Hotspot" 802-11-wireless.mode ap 802-11-wireless-security.key-mgmt wpa-psk 802-11-wireless-security.psk "$HOTSPOT_PASS" ipv4.method shared ipv4.addresses "192.168.150.1/24"
    nmcli con up "Hotspot"
fi

# E. Bluetooth Bridge Setup
nmcli con delete $BRIDGE_IF 2>/dev/null || true
nmcli con add type bridge ifname $BRIDGE_IF con-name $BRIDGE_IF >/dev/null
nmcli con modify $BRIDGE_IF ipv4.method manual ipv4.addresses $PAN_IP
nmcli con up $BRIDGE_IF

# F. Routing & DNS Hijack (The Windows Fix)
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -o "\$SRC" -j MASQUERADE
[ -n "\$WIFI_IF" ] && iptables -t nat -A PREROUTING -i "\$WIFI_IF" -p udp --dport 53 -j DNAT --to-destination 8.8.8.8
iptables -t nat -A PREROUTING -i "bnep+" -p udp --dport 53 -j DNAT --to-destination 8.8.8.8
EOF

sudo chmod +x /usr/local/bin/robot-bridge-up.sh

# --- 6. FINAL SERVICE & START ---
echo "[5/6] Registering Master Runtime Service..."
sudo tee /etc/systemd/system/robot-master.service > /dev/null <<EOF
[Unit]
Description=Raider Robotics Master Bridge
After=NetworkManager.service bt-pan.service
[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/bin/robot-bridge-up.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

echo "[6/6] Activating all processes..."
sudo systemctl daemon-reload
sudo systemctl enable bt-pan.service bt-agent.service robot-master.service
sudo systemctl restart bluetooth
sudo systemctl start bt-pan.service bt-agent.service robot-master.service

echo "==========================================================="
echo "   SUCCESS! Robot is now a WiFi + BT Bridge."
echo "   SSID: $HOTSPOT_SSID | PASS: $HOTSPOT_PASS"
echo "   This configuration will survive a reboot."
echo "==========================================================="