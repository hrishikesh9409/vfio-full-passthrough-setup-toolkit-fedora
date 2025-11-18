#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# --- Settings you can tweak ---
IMAGES_DIR="${IMAGES_DIR:-/var/lib/libvirt/images}"
HOOKS_DIR="${HOOKS_DIR:-/etc/libvirt/hooks}"
# ------------------------------

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1"; exit 1; }; }
need sudo

echo "[+] Installing SELinux tooling (if needed)…"
sudo dnf -y install policycoreutils-python-utils setools-console policycoreutils selinux-policy-targeted >/dev/null 2>&1 || true

echo "[+] Setting SELinux booleans (persistent)…"
# Allow QEMU to use executable memory (common need with various firmware/ROM/BIOS blobs)
sudo setsebool -P virt_use_execmem 1
# Allow general mmap of files in confined domains (was suggested by prior AVC)
sudo setsebool -P domain_can_mmap_files 1
# If you use NFS or Samba storage for VMs, uncomment:
# sudo setsebool -P virt_use_nfs 1
# sudo setsebool -P virt_use_samba 1

echo "[+] Declaring persistent file contexts for VM assets…"
sudo semanage fcontext -a -t virt_image_t "${IMAGES_DIR}(/.*)?"
# If you keep ISO/cache elsewhere, add more lines (examples):
# sudo semanage fcontext -a -t virt_image_t "/vm-storage(/.*)?"
# sudo semanage fcontext -a -t virt_content_t "/var/lib/libvirt/boot(/.*)?"

# Libvirt hooks dir (if you use qemu hooks, label as etc_t or lib_t is fine; they run confined under virtqemud_t)
sudo semanage fcontext -a -t etc_t "${HOOKS_DIR}(/.*)?"

echo "[+] Restoring contexts now…"
sudo restorecon -RFv "${IMAGES_DIR}" "${HOOKS_DIR}" 2>/dev/null || true
# Device nodes (nvidia, vfio) are dynamic; we’ll restore them at boot via a service too:
sudo restorecon -RFv /dev 2>/dev/null || true

echo "[+] Creating boot-time relabel service…"
sudo tee /etc/systemd/system/libvirt-selinux-prepare.service >/dev/null <<'EOF'
[Unit]
Description=Prepare SELinux labels for libvirt/VFIO devices
DefaultDependencies=no
After=local-fs.target
Before=libvirtd.service virtqemud.service

[Service]
Type=oneshot
ExecStart=/sbin/restorecon -RF /dev
ExecStart=/sbin/restorecon -RF /var/lib/libvirt/images
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

echo "[+] Enabling service…"
sudo systemctl daemon-reload
sudo systemctl enable libvirt-selinux-prepare.service
sudo systemctl start  libvirt-selinux-prepare.service

echo "[✓] Baseline SELinux setup done."
echo "    Reboot once, then try starting the VM."
echo "    If you still see AVC denials, use the capture flow below to auto-generate a tiny allow module."

