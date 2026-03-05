#!/bin/bash
echo "=== Cleaning up legacy Raider Robotics network configs ==="

# 1. Stop and disable old services
# We use a wildcard to catch variations like bt-pan-config, bt-controller-config, etc.
sudo systemctl stop bt-pan bt-agent bt-controller-config bt-pan-config wifi-hotspot 2>/dev/null || true
sudo systemctl disable bt-pan bt-agent bt-controller-config bt-pan-config wifi-hotspot 2>/dev/null || true

# 2. Remove old service files
sudo rm -f /etc/systemd/system/bt-pan.service
sudo rm -f /etc/systemd/system/bt-agent.service
sudo rm -f /etc/systemd/system/bt-controller-config.service
sudo rm -f /etc/systemd/system/wifi-hotspot.service
sudo rm -f /etc/systemd/system/bt-controller-fix.service

# 3. Remove conflicting sysctl forwarding rules
# We only want the one we just created to exist
sudo rm -f /etc/sysctl.d/98-pan-isolated.conf
sudo rm -f /etc/sysctl.d/98-pan.conf
sudo rm -f /etc/sysctl.d/90-hotspot-forwarding.conf

# 4. Remove local bin scripts
sudo rm -f /usr/local/bin/bt-pan-config.sh
sudo rm -f /usr/local/bin/bt-add-bnep-to-br0.sh
sudo rm -f /usr/local/bin/bt-pan-debug
sudo rm -f /usr/local/bin/wifi-hotspot.sh

# 5. Flush old IPTables (to ensure DNS hijack and NAT are clean)
sudo iptables -F
sudo iptables -t nat -F

# 6. Reset NetworkManager bridge and hotspot
sudo nmcli con delete br0 2>/dev/null || true
sudo nmcli con delete Hotspot 2>/dev/null || true

sudo systemctl daemon-reload
echo "=== Cleanup Complete. You are ready for the Master Script! ==="