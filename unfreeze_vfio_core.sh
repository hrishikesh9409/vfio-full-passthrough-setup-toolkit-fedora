#!/usr/bin/env bash
# unfreeze_vfio_core.sh — Safely unfreeze Fedora VFIO environment before upgrade
# Author: hrishikesh9409
# Description:
#   Removes versionlocks, disables kernel exclusions, and preps system for staged upgrade (e.g. to Fedora 43).
# Usage: sudo bash unfreeze_vfio_core.sh

set -euo pipefail
LOG="/var/log/vfio-unfreeze.log"

echo "========== VFIO CORE UNFREEZE ==========" | tee "$LOG"
echo "Date: $(date)" | tee -a "$LOG"

# --- 1) Confirm user intention ---
read -p "⚠️  This will unfreeze kernel, NVIDIA, and VFIO stack. Continue? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

# --- 2) Backup critical configuration ---
BACKUP_DIR="/root/vfio_pre_upgrade_backup_$(date +%F_%H-%M-%S)"
mkdir -p "$BACKUP_DIR"

echo "[INFO] Backing up critical configs to $BACKUP_DIR..." | tee -a "$LOG"
cp -a /etc/dnf/dnf.conf "$BACKUP_DIR"/ || true
cp -a /etc/dnf/versionlock.list "$BACKUP_DIR"/ || true
cp -a /etc/libvirt "$BACKUP_DIR"/libvirt/ || true
cp -a /usr/local/sbin/vfio-switch.sh "$BACKUP_DIR"/ 2>/dev/null || true
cp -a /etc/libvirt/hooks "$BACKUP_DIR"/hooks/ 2>/dev/null || true
cp -a /boot/grub2/grub.cfg "$BACKUP_DIR"/ 2>/dev/null || true
echo "[INFO] Backup complete." | tee -a "$LOG"

# --- 3) Clear versionlocks ---
echo "[INFO] Removing all DNF version locks..." | tee -a "$LOG"
dnf install -y dnf-plugins-core >>"$LOG" 2>&1
dnf versionlock clear >>"$LOG" 2>&1

# --- 4) Disable exclusions in /etc/dnf/dnf.conf ---
DNF_CONF="/etc/dnf/dnf.conf"
if grep -q '^exclude=' "$DNF_CONF"; then
  echo "[INFO] Commenting out exclude= line in $DNF_CONF..." | tee -a "$LOG"
  sed -i 's/^exclude=/#exclude=/' "$DNF_CONF"
else
  echo "[INFO] No exclude line found, skipping." | tee -a "$LOG"
fi

# --- 5) Stop automatic updates temporarily ---
if systemctl is-enabled --quiet dnf-automatic.timer; then
  echo "[INFO] Disabling dnf-automatic.timer temporarily..." | tee -a "$LOG"
  systemctl disable --now dnf-automatic.timer >>"$LOG" 2>&1
fi

# --- 6) Provide user upgrade instructions ---
cat <<EOF | tee -a "$LOG"

========== NEXT STEPS ==========
✔ Review backup: $BACKUP_DIR
✔ Verify free space and snapshot if using Btrfs.
✔ Proceed with *staged* upgrades:
    sudo dnf upgrade libvirt\* qemu\*
    sudo dnf upgrade kernel\*
    sudo dnf upgrade akmod-nvidia\* xorg-x11-drv-nvidia\*
✔ Test with your verify_vfio_env.sh script after each layer.
✔ When satisfied, you can run:
    sudo dnf system-upgrade download --releasever=43
    sudo dnf system-upgrade reboot
✔ Once stable, re-run: sudo bash /bin/freeze_vfio_core.sh
===============================
EOF

echo "✅ VFIO environment unfrozen. Safe to proceed with updates." | tee -a "$LOG"
