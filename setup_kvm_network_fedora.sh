#!/usr/bin/env bash
set -euo pipefail

# ====== Config (override via env) ======
NIC="${NIC:-enp7s0}"
BR_LAN="${BR_LAN:-br0}"
BR_VLAN="${BR_VLAN:-br-vlan20}"
VLAN_NAME="${VLAN_NAME:-vlan20}"
VLAN_ID="${VLAN_ID:-20}"

HOST_IP="${HOST_IP:-192.168.20.1}"
CIDR="${CIDR:-24}"                          # /24 mask for 192.168.20.0/24
DHCP_START="${DHCP_START:-192.168.20.50}"
DHCP_END="${DHCP_END:-192.168.20.150}"
DHCP_LEASE_HOURS="${DHCP_LEASE_HOURS:-12h}"

TRIM_WAIT_ONLINE="${TRIM_WAIT_ONLINE:-1}"   # 1 = set wait-online timeout to 5s
DEFINE_LIBVIRT_NETS="${DEFINE_LIBVIRT_NETS:-0}"  # 1 = define libvirt bridge nets

echo "==> NIC=$NIC  BR_LAN=$BR_LAN  BR_VLAN=$BR_VLAN  VLAN=$VLAN_NAME(id=$VLAN_ID)"
echo "==> $BR_VLAN IP ${HOST_IP}/${CIDR}; DHCP ${DHCP_START}-${DHCP_END} (${DHCP_LEASE_HOURS})"

# ====== Helpers ======
nm_has() { nmcli -t -f NAME con show "$1" &>/dev/null; }   # exact name match
enable_up() { nmcli connection modify "$1" connection.autoconnect yes; nmcli connection up "$1" || true; }

require_cmd() { command -v "$1" >/dev/null || { echo "Missing: $1"; exit 1; }; }

# ====== Sanity ======
require_cmd nmcli
systemctl is-active --quiet NetworkManager || { echo "NetworkManager must be active"; exit 1; }
ip link show "$NIC" >/dev/null || { echo "NIC $NIC not found"; exit 1; }

# ====== br0 (LAN bridge) ======
if ! nm_has "$BR_LAN"; then
  nmcli connection add type bridge ifname "$BR_LAN" con-name "$BR_LAN" ipv4.method auto ipv6.method auto
else
  nmcli connection modify "$BR_LAN" ipv4.method auto ipv6.method auto
fi

if ! nm_has "${NIC}-${BR_LAN}"; then
  nmcli connection add type ethernet ifname "$NIC" con-name "${NIC}-${BR_LAN}" master "$BR_LAN"
else
  nmcli connection modify "${NIC}-${BR_LAN}" master "$BR_LAN"
fi

enable_up "$BR_LAN"
enable_up "${NIC}-${BR_LAN}"

# ====== vlan20 + br-vlan20 (isolated) ======
if ! nm_has "$VLAN_NAME"; then
  nmcli connection add type vlan ifname "$VLAN_NAME" con-name "$VLAN_NAME" dev "$NIC" id "$VLAN_ID" ipv4.method disabled ipv6.method disabled
else
  nmcli connection modify "$VLAN_NAME" vlan.parent "$NIC" vlan.id "$VLAN_ID" ipv4.method disabled ipv6.method disabled
fi

if ! nm_has "$BR_VLAN"; then
  nmcli connection add type bridge ifname "$BR_VLAN" con-name "$BR_VLAN" ipv4.method manual ipv4.addresses "${HOST_IP}/${CIDR}" ipv6.method disabled
else
  nmcli connection modify "$BR_VLAN" ipv4.method manual ipv4.addresses "${HOST_IP}/${CIDR}" ipv6.method disabled
fi

nmcli connection modify "$VLAN_NAME" connection.master "$BR_VLAN" connection.slave-type bridge
enable_up "$BR_VLAN"
enable_up "$VLAN_NAME"

# Prefer slaves to autoconnect under both bridges
nmcli connection modify "$BR_LAN" connection.autoconnect-slaves 1 || true
nmcli connection modify "$BR_VLAN" connection.autoconnect-slaves 1 || true

# ====== dnsmasq dedicated instance for br-vlan20 ======
sudo dnf -y install dnsmasq policycoreutils-python-utils >/dev/null 2>&1 || true

# Avoid conflicts with the generic service
systemctl mask dnsmasq || true
systemctl disable dnsmasq || true
systemctl stop dnsmasq || true
pkill -f 'dnsmasq -k --conf-file=/etc/dnsmasq.conf' >/dev/null 2>&1 || true

# Main config includes conf-dir
install -o root -g root -m 0644 /dev/null /etc/dnsmasq.conf
cat >/etc/dnsmasq.conf <<'CONF'
conf-dir=/etc/dnsmasq.d,*.conf
CONF

mkdir -p /etc/dnsmasq.d
cat >/etc/dnsmasq.d/br-vlan20.conf <<CONF
# DHCP only on ${BR_VLAN}
interface=${BR_VLAN}
bind-interfaces
port=0

# Authoritative DHCP for the isolated mini-LAN
dhcp-authoritative
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,${DHCP_LEASE_HOURS}
CONF
chmod 0644 /etc/dnsmasq.d/br-vlan20.conf

# Lease storage (Fedora defaults); make sure perms/labels are good
mkdir -p /var/lib/dnsmasq
install -o dnsmasq -g dnsmasq -m 0644 /dev/null /var/lib/dnsmasq/dnsmasq.leases || true
restorecon -Rv /etc/dnsmasq.conf /etc/dnsmasq.d /var/lib/dnsmasq >/dev/null || true
chown -R dnsmasq:dnsmasq /var/lib/dnsmasq
chmod 0755 /var/lib/dnsmasq
chmod 0644 /var/lib/dnsmasq/dnsmasq.leases

# Build a bash-free, SELinux-friendly unit that waits for the bridge device
escaped_bridge_unit="sys-subsystem-net-devices-$(echo "$BR_VLAN" | sed 's/-/\\x2d/g').device"

cat >/etc/systemd/system/dnsmasq-br-vlan20.service <<UNIT
[Unit]
Description=dnsmasq for ${BR_VLAN}
Requires=${escaped_bridge_unit}
After=${escaped_bridge_unit}
After=NetworkManager.service
Wants=NetworkManager.service
Conflicts=dnsmasq.service

[Service]
Type=simple
User=dnsmasq
Group=dnsmasq
ExecStart=/usr/bin/dnsmasq -k --conf-file=/etc/dnsmasq.conf

# Caps to bind DHCP and manage sockets
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=yes

Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now dnsmasq-br-vlan20.service

# ====== Optional: trim NetworkManager wait-online ======
if [[ "${TRIM_WAIT_ONLINE}" == "1" ]]; then
  mkdir -p /etc/systemd/system/NetworkManager-wait-online.service.d
  cat >/etc/systemd/system/NetworkManager-wait-online.service.d/override.conf <<'OVR'
[Service]
ExecStart=
ExecStart=/usr/lib/NetworkManager-wait-online --timeout=5
OVR
  systemctl daemon-reload
  systemctl restart NetworkManager-wait-online.service || true
fi

# ====== Optional: libvirt bridge networks ======
if [[ "${DEFINE_LIBVIRT_NETS}" == "1" && -x "$(command -v virsh)" ]]; then
  tmp1="$(mktemp)"; tmp2="$(mktemp)"
  cat >"$tmp1" <<XML
<network><name>${BR_LAN}</name><forward mode="bridge"/><bridge name="${BR_LAN}"/></network>
XML
  cat >"$tmp2" <<XML
<network><name>${BR_VLAN}</name><forward mode="bridge"/><bridge name="${BR_VLAN}"/></network>
XML
  virsh net-info "${BR_LAN}" >/dev/null 2>&1 || { virsh net-define "$tmp1"; virsh net-autostart "${BR_LAN}"; virsh net-start "${BR_LAN}" || true; }
  virsh net-info "${BR_VLAN}" >/dev/null 2>&1 || { virsh net-define "$tmp2"; virsh net-autostart "${BR_VLAN}"; virsh net-start "${BR_VLAN}" || true; }
  rm -f "$tmp1" "$tmp2"
fi

# ====== Final status ======
echo
echo "==> Current devices:"
nmcli device status || true
echo
echo "==> DHCP listeners (UDP 67):"
ss -lupn | grep ':67' || echo "  (none)"
echo
systemctl --no-pager --full status dnsmasq-br-vlan20.service || true

cat <<'TIP'

Tip:
- Attach a VM to 'br-vlan20' for the isolated LAN (DHCP on 192.168.20.0/24).
- Attach a VM to 'br0' to join your real LAN (192.168.68.0/24).
- If you see an SELinux denial for dnsmasq writing leases, run:
    sudo ausearch -m avc -c dnsmasq --raw | sudo audit2allow -M my-dnsmasq
    sudo semodule -i my-dnsmasq.pp
TIP
