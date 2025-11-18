#!/usr/bin/env bash
# freeze_vfio_core.sh — Lock down Fedora VFIO environment for stability
# Author: hrishikesh9409
# Description:
#   Freezes kernel, NVIDIA, libvirt, and VFIO stack to current versions.
#   Enables security-only auto-updates via dnf-automatic.
#   Ensures user-space packages remain updateable.
# Usage: sudo bash freeze_vfio_core.sh

set -euo pipefail
LOG="/var/log/vfio-freeze.log"

echo "========== VFIO CORE FREEZE SETUP ==========" | tee "$LOG"
echo "Date: $(date)" | tee -a "$LOG"

# --- 1) Install dnf-automatic if missing ---
echo "[INFO] Installing dnf-automatic..." | tee -a "$LOG"
dnf install -y dnf-automatic >>"$LOG" 2>&1

# --- 2) Define critical packages to freeze ---
CRITICAL_PKGS=(
  kernel kernel-core kernel-modules kernel-modules-extra kernel-devel
  qemu qemu-system-x86 qemu-kvm libvirt virt-manager virt-viewer
  akmod-nvidia xorg-x11-drv-nvidia nvidia-settings nvidia-persistenced
  linux-firmware linux-firmware-whence
  pciutils efibootmgr dracut edk2-ovmf
)

echo "[INFO] Applying DNF version locks..." | tee -a "$LOG"
dnf install -y dnf-plugins-core >>"$LOG" 2>&1
dnf versionlock clear >>"$LOG" 2>&1 || true
dnf versionlock add "${CRITICAL_PKGS[@]}" >>"$LOG" 2>&1

# --- 3) Add exclusions to /etc/dnf/dnf.conf ---
DNF_CONF="/etc/dnf/dnf.conf"
echo "[INFO] Updating $DNF_CONF with exclude rules..." | tee -a "$LOG"
if ! grep -q "exclude=" "$DNF_CONF"; then
  cat <<EOF >> "$DNF_CONF"

# === VFIO stability exclusions ===
exclude=kernel* qemu* libvirt* akmod-nvidia* xorg-x11-drv-nvidia* \
nvidia-settings nvidia-persistenced dracut* linux-firmware*
EOF
else
  echo "[WARN] Exclude line already present; please verify manually." | tee -a "$LOG"
fi

# --- 4) Configure dnf-automatic for security-only updates ---
AUTO_CONF="/etc/dnf/automatic.conf"
echo "[INFO] Configuring $AUTO_CONF for security-only updates..." | tee -a "$LOG"
sudo sed -i \
  -e 's/^apply_updates.*/apply_updates = yes/' \
  -e 's/^upgrade_type.*/upgrade_type = security/' \
  -e 's/^emit_via.*/emit_via = motd/' \
  "$AUTO_CONF" || echo "[WARN] Could not auto-edit $AUTO_CONF" | tee -a "$LOG"

systemctl enable --now dnf-automatic.timer >>"$LOG" 2>&1

# --- 5) Verify versionlocks applied ---
echo "[INFO] Current locked packages:" | tee -a "$LOG"
dnf versionlock list | tee -a "$LOG"

# --- 6) Print safety summary ---
echo -e "\n========== VFIO FREEZE SUMMARY ==========" | tee -a "$LOG"
echo "✔ Kernel & driver packages locked"
echo "✔ DNF exclusions applied for kernel/QEMU/libvirt/NVIDIA"
echo "✔ Automatic security-only updates enabled (dnf-automatic.timer)"
echo "✔ User-space packages remain updatable via: sudo dnf upgrade"
echo "✔ Security updates only via: sudo dnf upgrade --security"
echo "✔ Version locks list: sudo dnf versionlock list"
echo "✔ Log: $LOG"
echo "=========================================="
