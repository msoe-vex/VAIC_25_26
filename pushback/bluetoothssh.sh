#!/bin/bash
set -e

echo "=== Bluetooth PAN (NAP) Setup Script ==="

#
# 1. Install required packages
#
sudo apt-get update
sudo apt-get install -y \
    bluez bluez-tools pulseaudio-module-bluetooth \
    bridge-utils dnsmasq python3-dbus python3-gi

#
# 2. Create bridge br0
#
echo "[+] Creating bridge br0..."
sudo ip link add name br0 type bridge || true
sudo ip addr flush dev br0 || true
sudo ip addr add 10.42.0.1/24 dev br0
sudo ip link set br0 up

#
# 3. Configure dnsmasq for br0
#
echo "[+] Writing /etc/dnsmasq.d/bt-pan.conf..."
sudo bash -c 'cat >/etc/dnsmasq.d/bt-pan.conf' <<'EOF'
interface=br0
bind-interfaces
dhcp-range=10.42.0.10,10.42.0.200,12h
dhcp-option=3
EOF

sudo systemctl restart dnsmasq

#
# 4. Create BlueZ pairing agent
#
echo "[+] Writing /usr/local/bin/bt-agent.py..."
sudo bash -c 'cat >/usr/local/bin/bt-agent.py' <<'EOF'
#!/usr/bin/env python3
import dbus, dbus.mainloop.glib
from gi.repository import GLib

AGENT_PATH = "/com/bt/agent"

class NoInputNoOutputAgent(dbus.service.Object):
    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Release(self):
        pass

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        return

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
    def AuthorizeService(self, device, uuid):
        return

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
    def RequestConfirmation(self, device, passkey):
        return

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        raise NotImplementedError("No input/no output")

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
    def RequestPinCode(self, device):
        raise NotImplementedError("No input/no output")

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SystemBus()
manager = dbus.Interface(bus.get_object("org.bluez", "/org/bluez"), "org.bluez.AgentManager1")

agent = NoInputNoOutputAgent(bus, AGENT_PATH)
manager.RegisterAgent(AGENT_PATH, "NoInputNoOutput")
manager.RequestDefaultAgent(AGENT_PATH)

GLib.MainLoop().run()
EOF

sudo chmod +x /usr/local/bin/bt-agent.py

#
# 5. Write systemd service for pairing agent
#
echo "[+] Writing /etc/systemd/system/bluetooth-agent.service..."
sudo bash -c 'cat >/etc/systemd/system/bluetooth-agent.service' <<'EOF'
[Unit]
Description=Bluetooth Auto-Pairing Agent (NoInputNoOutput)
After=bluetooth.service
Requires=bluetooth.service

[Service]
ExecStart=/usr/local/bin/bt-agent.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

#
# 6. Write systemd service for NAP
#
echo "[+] Writing /etc/systemd/system/bluetooth-nap.service..."
sudo bash -c 'cat >/etc/systemd/system/bluetooth-nap.service' <<'EOF'
[Unit]
Description=Bluetooth NAP Server
After=bluetooth.service network-online.target
Requires=bluetooth.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/bt-network -s nap br0
ExecStop=/usr/bin/bt-network -r nap
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

#
# 7. Enable everything
#
echo "[+] Enabling services..."
sudo systemctl daemon-reload
sudo systemctl enable bluetooth-agent.service
sudo systemctl enable bluetooth-nap.service
sudo systemctl restart bluetooth-agent.service
sudo systemctl restart bluetooth-nap.service

#
# 8. Final instructions
#
echo "=============================================="
echo " PAN server ready!"
echo " Connect from client using: NAP (Network Access Point) "
echo " Bridge IP: 10.42.0.1"
echo ""
echo "To check live status:"
echo "  sudo systemctl status bluetooth-nap"
echo "  sudo systemctl status bluetooth-agent"
echo "  sudo bt-network -l"
echo "=============================================="
