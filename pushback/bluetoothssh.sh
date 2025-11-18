#!/bin/bash
# Simplified ISOLATED Bluetooth PAN Server Setup for Jetson
# - Creates br0 bridge (NetworkManager)
# - Configures dnsmasq for DHCP on br0
# - Configures bluetoothd for NAP (PAN)
# - Enables Just Works pairing
# - Adds bt-controller-config systemd service
# - Adds bt-pan-debug diagnostic script

set -euo pipefail

echo "=== Setting up ISOLATED Bluetooth PAN Server ==="

# -------------------------------
# 1. Install Required Packages
# -------------------------------
PKGS="bluez bluez-tools dnsmasq openssh-server"
MISSING=()

for p in $PKGS; do
    dpkg -l | grep -q "^ii\s\+$p" || MISSING+=("$p")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "Installing missing packages: ${MISSING[*]}"
    sudo apt-get update
    sudo apt-get install -y "${MISSING[@]}"
fi

# -------------------------------
# 2. Create Bridge (br0)
# -------------------------------
echo "Configuring br0..."

sudo nmcli con delete br0 2>/dev/null || true
sudo ip link delete br0 2>/dev/null || true

sudo nmcli con add type bridge ifname br0 con-name br0
sudo nmcli con modify br0 ipv4.method manual ipv4.addresses 192.168.100.1/24
sudo nmcli con modify br0 bridge.stp no bridge.forward-delay 0
sudo nmcli con up br0

# -------------------------------
# 3. Tell NetworkManager to ignore bnep*
# -------------------------------
echo "Configuring unmanaged bnep devices..."

sudo tee /etc/NetworkManager/conf.d/99-unmanaged-bnep.conf >/dev/null <<'EOF'
[keyfile]
unmanaged-devices=interface-name:bnep*
EOF

sudo systemctl restart NetworkManager
sleep 1

# -------------------------------
# 4. dnsmasq for DHCP on br0
# -------------------------------
echo "Configuring dnsmasq..."

sudo tee /etc/dnsmasq.d/bt-pan.conf >/dev/null <<EOF
interface=br0
bind-interfaces
dhcp-range=192.168.100.50,192.168.100.150,12h
dhcp-option=option:router,192.168.100.1
dhcp-option=option:dns-server,192.168.100.1
listen-address=127.0.0.1,192.168.100.1
EOF

sudo systemctl enable dnsmasq.service

# -------------------------------
# 5. bluetoothd config
# -------------------------------
echo "Configuring bluetoothd..."

sudo tee /etc/bluetooth/network.conf >/dev/null <<'EOF'
[General]
Interface=br0
EOF

sudo cp /etc/bluetooth/main.conf /etc/bluetooth/main.conf.bak 2>/dev/null || true

sudo sed -i '/^\[General\]/,/^\[/d' /etc/bluetooth/main.conf
sudo sed -i '/^\[Policy\]/,/^\[/d' /etc/bluetooth/main.conf

sudo tee -a /etc/bluetooth/main.conf >/dev/null <<'EOF'
[General]
JustWorksRepairing = always
DiscoverableTimeout = 0
Class = 0x00020104
AutoEnable = true

[Policy]
DisablePlugins = network
ClassicBondedOnly = false
EOF

sudo systemctl restart bluetooth.service
sleep 1

# -------------------------------
# 6. Disable IP Forwarding
# -------------------------------
echo "Disabling IP forwarding..."
echo "net.ipv4.ip_forward=0" | sudo tee /etc/sysctl.d/98-pan.conf >/dev/null
sudo sysctl -w net.ipv4.ip_forward=0 >/dev/null

# -------------------------------
# 7. Controller Startup Service
# -------------------------------
echo "Installing bt-controller-config service..."

sudo tee /usr/local/bin/bt-pan-config.sh >/dev/null <<'EOF'
#!/bin/bash
sleep 1
hciconfig hci0 up
hciconfig hci0 lm MASTER,ACCEPT
hciconfig hci0 piscan
hciconfig hci0 sspmode 1
hciconfig hci0 class 0x00020104

timeout 8 bluetoothctl <<BT
power on
pairable on
discoverable on
discoverable-timeout 0
advertise on
exit
BT
EOF
sudo chmod +x /usr/local/bin/bt-pan-config.sh

sudo tee /etc/systemd/system/bt-controller-config.service >/dev/null <<'EOF'
[Unit]
Description=Configure Bluetooth Controller for PAN
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bt-pan-config.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable bt-controller-config.service
sudo systemctl restart bt-controller-config.service

# -------------------------------
# 8. Debug Tool
# -------------------------------
echo "Installing bt-pan-debug..."

sudo tee /usr/local/bin/bt-pan-debug >/dev/null <<'EOF'
#!/bin/bash
echo "=== Bluetooth PAN Diagnostics ==="
systemctl status bluetooth.service dnsmasq.service bt-controller-config.service --no-pager
echo
echo "--- Controller ---"
bluetoothctl show
hciconfig -a
echo
echo "--- Bridge ---"
ip a show br0
nmcli con show br0
echo
echo "--- DHCP leases ---"
cat /var/lib/dnsmasq/dnsmasq.leases 2>/dev/null
echo
echo "--- Logs ---"
journalctl -u bluetooth.service -u dnsmasq.service -u bt-controller-config.service -n 20 --no-pager
EOF
sudo chmod +x /usr/local/bin/bt-pan-debug

# -------------------------------
# DONE
# -------------------------------
echo
echo "=============================================="
echo "    ISOLATED Bluetooth PAN Server READY"
echo "=============================================="
echo " PAN IP: 192.168.100.1"
echo " Pairing: Just Works"
echo " Debug: sudo bt-pan-debug"
