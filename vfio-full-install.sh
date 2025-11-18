#!/usr/bin/env bash
# vfio-full-install.sh — end-to-end installer for a production VFIO setup on Fedora
# Installs:
#   - /bin/vfio-watch.sh (live logs), /bin/vm-quick-health.sh (snapshot), /bin/cpu-governor.sh (toggle)
#   - /bin/vfio-perf-start.sh, /bin/vfio-perf-stop.sh (governor + HugePages)
#   - /bin/vfio (namespace wrapper)
#   - RisingPrism-style libvirt hooks + your tuned startup/teardown with adaptive waits
# Usage example:
#   sudo bash vfio-full-install.sh --vm win11 --gpu 0000:08:00.0 --hda 0000:08:00.1 --bridge 0000:00:03.1 --host nvidia --huge 48

set -euo pipefail

# ---------- defaults (override via flags) ----------
VM_NAME="win11"
GPU="0000:08:00.0"
HDA="0000:08:00.1"
BRIDGE="0000:00:03.1"
HOSTDRV="nvidia"     # or "nouveau"
HUGEPROFILE="48"     # 16 / 32 / 48 GiB

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm) VM_NAME="$2"; shift 2;;
    --gpu) GPU="$2"; shift 2;;
    --hda) HDA="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --host) HOSTDRV="$2"; shift 2;;
    --huge) HUGEPROFILE="$2"; shift 2;;
    -h|--help)
      echo "Usage: sudo bash $0 --vm <name> --gpu <0000:BB:DD.F> --hda <0000:BB:DD.F> --bridge <0000:BB:DD.F> --host <nvidia|nouveau> --huge <16|32|48>"
      exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

echo "═══════════════════════════════════════════════════════"
echo " VFIO FULL INSTALLER — Fedora"
echo " VM=$VM_NAME  GPU=$GPU  HDA=$HDA  BRIDGE=$BRIDGE  HOST=$HOSTDRV  HUGE=${HUGEPROFILE}G"
echo "═══════════════════════════════════════════════════════"

# ---------- deps / dirs ----------
echo "[INFO] Installing dependencies (kernel-tools for cpupower, multitail, util-linux)..."
dnf install -y kernel-tools multitail util-linux >/dev/null 2>&1 || true

mkdir -p /var/log/libvirt
touch /var/log/libvirt/vfio-perf.log /var/log/libvirt/custom_hooks.log /var/log/libvirt/vfio-hotplug.log
chmod 644 /var/log/libvirt/vfio-perf.log /var/log/libvirt/custom_hooks.log /var/log/libvirt/vfio-hotplug.log

# ---------- /bin/vfio-watch.sh ----------
cat >/bin/vfio-watch.sh <<"EOF"
#!/usr/bin/env bash
set -euo pipefail
VM="${1:-win11}"
WITH_JOURNAL=1
[[ "${2:-}" == "--no-journal" ]] && WITH_JOURNAL=0

FILES=(
  "/var/log/libvirt/custom_hooks.log"
  "/var/log/libvirt/vfio-hotplug.log"
  "/var/log/libvirt/vfio-perf.log"
  "/var/log/libvirt/qemu/${VM}.log"
)

tail_one() {
  local tag="$1"; local file="$2"
  stdbuf -oL -eL tail -F "$file" 2>/dev/null | sed -u "s/^/[$tag] /"
}
echo "== VFIO Watcher =="
echo "VM: $VM"
echo "Press Ctrl-C to quit."
echo
if command -v multitail >/dev/null 2>&1; then
  MT_ARGS=()
  for f in "${FILES[@]}"; do
    [[ -f "$f" ]] && MT_ARGS+=( -cs 0,0 -l "tail -F $f" )
  done
  (( WITH_JOURNAL )) && MT_ARGS+=( -cs 0,0 -l "journalctl -f -u libvirtd -u display-manager" )
  exec multitail "${MT_ARGS[@]}"
else
  pids=()
  for f in "${FILES[@]}"; do
    [[ -f "$f" ]] && tail_one "$(basename "$f")" "$f" &
    pids+=("$!")
  done
  if (( WITH_JOURNAL )); then
    stdbuf -oL -eL journalctl -f -u libvirtd -u display-manager | sed -u "s/^/[journal] /" &
    pids+=("$!")
  fi
  trap 'kill "${pids[@]}" 2>/dev/null || true; wait; exit 0' INT TERM
  wait
fi
EOF
chmod +x /bin/vfio-watch.sh

# ---------- /bin/vm-quick-health.sh ----------
cat >/bin/vm-quick-health.sh <<"EOF"
#!/usr/bin/env bash
GPU_ID="${1:-0000:08:00.0}"
LOG_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════"
echo " VFIO QUICK HEALTH CHECK — $LOG_DATE"
echo "═══════════════════════════════════════════════════════"
if command -v cpupower >/dev/null 2>&1; then
  GOV="$(cpupower frequency-info -p 2>/dev/null | awk -F: '/governor/{print $2}' | xargs)"
else
  GOV="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
fi
echo "🧠 CPU governor:  ${GOV:-unknown}"
HP_TOTAL=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
HP_FREE=$(awk '/HugePages_Free/ {print $2}' /proc/meminfo)
HP_SIZE_KB=$(awk '/Hugepagesize/ {print $2}' /proc/meminfo)
HP_TOTAL_MB=$((HP_TOTAL * HP_SIZE_KB / 1024))
echo "📦 HugePages:     $HP_FREE free / $HP_TOTAL total  (${HP_TOTAL_MB} MB reserved)"
DRV_PATH="/sys/bus/pci/devices/$GPU_ID/driver"
DRV_NAME="unbound"; [[ -L "$DRV_PATH" ]] && DRV_NAME=$(basename "$(readlink "$DRV_PATH")")
echo "🎮 GPU $GPU_ID bound to:  $DRV_NAME"
AUDIO_ID="${GPU_ID%.*}.1"
if [[ -d "/sys/bus/pci/devices/$AUDIO_ID" ]]; then
  ADRV_PATH="/sys/bus/pci/devices/$AUDIO_ID/driver"
  ADRV_NAME="unbound"; [[ -L "$ADRV_PATH" ]] && ADRV_NAME=$(basename "$(readlink "$ADRV_PATH")")
  echo "🔊 Audio $AUDIO_ID bound to: $ADRV_NAME"
fi
[ -e /dev/dri/card0 ] && echo "🖥️  DRM node: present (/dev/dri/card0)" || echo "🖥️  DRM node: missing"
if lsmod | grep -q '^nvidia_drm'; then
  if [ -e /dev/nvidiactl ] && [ -e /dev/nvidia0 ]; then
    echo "🧩 NVIDIA device nodes: present (/dev/nvidiactl, /dev/nvidia0)"
  else
    echo "🧩 NVIDIA device nodes: missing"
  fi
fi
grep -q 'kvm' /proc/modules && echo "⚙️  KVM modules loaded: yes" || echo "⚙️  KVM modules loaded: no"
echo "═══════════════════════════════════════════════════════"
EOF
chmod +x /bin/vm-quick-health.sh

# ---------- /bin/cpu-governor.sh ----------
cat >/bin/cpu-governor.sh <<"EOF"
#!/usr/bin/env bash
set -euo pipefail
want="${1:-status}"
drv_file="/sys/devices/system/cpu/cpu0/cpufreq/scaling_driver"
driver="$(cat "$drv_file" 2>/dev/null || echo unknown)"
pick_normal() {
  local avail="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "")"
  for g in schedutil ondemand powersave; do
    if echo "$avail" | grep -qw "$g"; then
      echo "$g"; return
    fi
  done
  echo "powersave"
}
set_gov_all() {
  local gov="$1"
  if command -v cpupower >/dev/null 2>&1; then
    cpupower frequency-set -g "$gov" >/dev/null
  else
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      [[ -w "$g" ]] && echo "$gov" > "$g" || true
    done
  fi
}
show_status() {
  echo "Driver: $driver"
  echo "Governors per CPU:"
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    cpu="$(basename "$(dirname "$g")")"
    val="$(cat "$g" 2>/dev/null || echo n/a)"
    printf "  %-6s  %s\n" "$cpu" "$val"
  done
}
case "$want" in
  perf|performance) set_gov_all performance; show_status;;
  normal) norm="$(pick_normal)"; set_gov_all "$norm"; show_status;;
  status|*) show_status;;
esac
EOF
chmod +x /bin/cpu-governor.sh

# ---------- /bin/vfio-perf-start.sh ----------
cat >/bin/vfio-perf-start.sh <<"EOF"
#!/usr/bin/env bash
# Enable performance governor and allocate HugePages
set -euo pipefail
LOG="/var/log/libvirt/vfio-perf.log"
echo "$(date) [INFO] Enabling performance mode..." | tee -a "$LOG"
if command -v cpupower &>/dev/null; then
  cpupower frequency-set -g performance 2>&1 | tee -a "$LOG"
else
  echo "$(date) [WARN] cpupower not found" | tee -a "$LOG"
fi
PROFILE=${1:-16}
case $PROFILE in
  16) PAGES=8192 ;;
  32) PAGES=16384 ;;
  48) PAGES=24576 ;;
  *)  echo "$(date) [WARN] Invalid profile '$PROFILE', defaulting to 16 GB" | tee -a "$LOG"; PAGES=8192 ;;
esac
HUGEPATH="/dev/hugepages"
if ! mountpoint -q "$HUGEPATH"; then
  echo "$(date) [INFO] Mounting hugetlbfs at $HUGEPATH..." | tee -a "$LOG"
  mkdir -p "$HUGEPATH"
  mount -t hugetlbfs none "$HUGEPATH" || { echo "$(date) [ERROR] mount hugetlbfs failed" | tee -a "$LOG"; exit 1; }
fi
want_pages=$PAGES
have_pages=$(awk '/HugePages_Free:/ {print $2}' /proc/meminfo)
if (( have_pages < want_pages )); then
  echo "$(date) [INFO] Setting HugePages to $want_pages" | tee -a "$LOG"
  echo $want_pages > /proc/sys/vm/nr_hugepages
  sleep 1
fi
current_pages=$(awk '/HugePages_Total:/ {print $2}' /proc/meminfo)
if (( current_pages < want_pages )); then
  echo "$(date) [ERROR] HugePages allocation failed: total=$current_pages wanted=$want_pages" | tee -a "$LOG"
  exit 1
else
  echo "$(date) [OK] HugePages allocated: $current_pages pages" | tee -a "$LOG"
fi
grep Huge /proc/meminfo | tee -a "$LOG"
EOF
chmod +x /bin/vfio-perf-start.sh

# ---------- /bin/vfio-perf-stop.sh ----------
cat >/bin/vfio-perf-stop.sh <<"EOF"
#!/usr/bin/env bash
# Release HugePages and restore governor
set -euo pipefail
LOG="/var/log/libvirt/vfio-perf.log"
echo "$(date) [INFO] Releasing HugePages and restoring governor..." | tee -a "$LOG"
echo 0 > /proc/sys/vm/nr_hugepages
grep Huge /proc/meminfo | tee -a "$LOG"
if command -v cpupower &>/dev/null; then
  # choose a sane normal governor if available
  avail=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "")
  if echo "$avail" | grep -qw schedutil; then GOV=schedutil
  elif echo "$avail" | grep -qw ondemand; then GOV=ondemand
  else GOV=powersave
  fi
  cpupower frequency-set -g "$GOV" 2>&1 | tee -a "$LOG"
fi
EOF
chmod +x /bin/vfio-perf-stop.sh

# ---------- /bin/vfio (namespace wrapper) ----------
cat >/bin/vfio <<"EOF"
#!/usr/bin/env bash
subcmd="${1:-help}"; shift || true
case "$subcmd" in
  watch)  exec /bin/vfio-watch.sh "$@";;
  health) exec /bin/vm-quick-health.sh "$@";;
  gov)    exec /bin/cpu-governor.sh "$@";;
  *) echo "VFIO Toolkit:"
     echo "  vfio watch [vm] [--no-journal]   # live logs"
     echo "  vfio health [gpu_id]             # system snapshot"
     echo "  vfio gov [perf|normal|status]    # governor toggle"
     ;;
esac
EOF
chmod +x /bin/vfio

# ---------- libvirt hook dispatcher /etc/libvirt/hooks/qemu ----------
HOOK_DIR="/etc/libvirt/hooks"
DISPATCH="$HOOK_DIR/qemu"
mkdir -p "$HOOK_DIR"
cat >"$DISPATCH"<<'EOF'
#!/usr/bin/env bash
# Libvirt QEMU hook dispatcher
VM_NAME="$1"; HOOK_EVENT="$2"; PHASE="$3"
BASE="/etc/libvirt/hooks/qemu.d/${VM_NAME}/${HOOK_EVENT}/${PHASE}"
if [ -d "$BASE" ]; then
  for s in "$BASE"/*.sh; do
    [ -x "$s" ] && "$s" "$@"
  done
fi
EOF
chmod +x "$DISPATCH"

# ---------- RisingPrism-style per-VM hooks ----------
VM_BASE="$HOOK_DIR/qemu.d/${VM_NAME}"
PREP_BEGIN="${VM_BASE}/prepare/begin"
REL_END="${VM_BASE}/release/end"
mkdir -p "$PREP_BEGIN" "$REL_END"

# STARTUP: stop DM, unbind consoles/fb, unload GPU driver, bind to vfio
cat >"${PREP_BEGIN}/01-vfio-startup.sh"<<EOF
#!/usr/bin/env bash
set -euo pipefail
DATE=\$(date +"%m/%d/%Y %R:%S :")
echo "\$DATE Beginning of Startup!" | tee -a /var/log/libvirt/custom_hooks.log

# Optional: baseline status to perf log
/bin/vm-quick-health.sh "$GPU" >> /var/log/libvirt/vfio-perf.log 2>&1 || true

# Detect KDE special-case, otherwise use display-manager service capture
if pgrep -l "plasma" | grep -q "plasmashell"; then
  echo "\$DATE Display Manager is KDE, stopping display-manager" | tee -a /var/log/libvirt/custom_hooks.log
  echo "display-manager" >/tmp/vfio-store-display-manager
  systemctl stop display-manager.service || true
else
  DISPMGR=\$(grep 'ExecStart=' /etc/systemd/system/display-manager.service | awk -F'/' '{print \$NF}')
  DISPMGR=\${DISPMGR:-display-manager}
  echo "\$DATE Display Manager = \$DISPMGR" | tee -a /var/log/libvirt/custom_hooks.log
  echo "\$DISPMGR" >/tmp/vfio-store-display-manager
  systemctl stop "\$DISPMGR.service" || true
  systemctl isolate multi-user.target || true
fi
while systemctl is-active --quiet "\$(cat /tmp/vfio-store-display-manager).service"; do sleep 1; done

# Unbind VT consoles
rm -f /tmp/vfio-bound-consoles
for i in \$(seq 0 15); do
  if [ -e /sys/class/vtconsole/vtcon"\$i"/bind ] && grep -q "frame buffer" /sys/class/vtconsole/vtcon"\$i"/name; then
    echo 0 > /sys/class/vtconsole/vtcon"\$i"/bind
    echo "\$i" >> /tmp/vfio-bound-consoles
    echo "\$DATE Unbinding Console \$i" | tee -a /var/log/libvirt/custom_hooks.log
  fi
done

# Unbind EFI/simple framebuffers (best-effort)
echo efi-framebuffer.0       > /sys/bus/platform/drivers/efi-framebuffer/unbind 2>/dev/null || true
echo simple-framebuffer.0    > /sys/bus/platform/drivers/simple-framebuffer/unbind 2>/dev/null || true

# Unload host GPU drivers
if lspci -nn | grep -e VGA | grep -q NVIDIA; then
  echo "true" > /tmp/vfio-is-nvidia
  modprobe -r nvidia_uvm 2>/dev/null || true
  modprobe -r nvidia_drm 2>/dev/null || true
  modprobe -r nvidia_modeset 2>/dev/null || true
  modprobe -r nvidia 2>/dev/null || true
  modprobe -r i2c_nvidia_gpu 2>/dev/null || true
  modprobe -r drm_kms_helper 2>/dev/null || true
  modprobe -r drm 2>/dev/null || true
elif lspci -nn | grep -e VGA | grep -q AMD; then
  echo "true" > /tmp/vfio-is-amd
  modprobe -r drm_kms_helper 2>/dev/null || true
  modprobe -r amdgpu 2>/dev/null || true
  modprobe -r radeon 2>/dev/null || true
  modprobe -r drm 2>/dev/null || true
fi

# Bind GPU + HDA to vfio-pci
modprobe vfio vfio_pci vfio_iommu_type1 2>/dev/null || true

# Safety: unbind from any current driver then bind to vfio-pci
for dev in "$GPU" "$HDA"; do
  [ -e "/sys/bus/pci/devices/\$dev/driver/unbind" ] && echo "\$dev" > "/sys/bus/pci/devices/\$dev/driver/unbind"
  echo "\$dev" > /sys/bus/pci/drivers/vfio-pci/bind
done

echo "\$DATE GPU bound to vfio" | tee -a /var/log/libvirt/custom_hooks.log
EOF
chmod +x "${PREP_BEGIN}/01-vfio-startup.sh"

# TEARDOWN: unbind vfio, (optional) reset upstream bridge, rebind host driver, adaptive wait, restart DM
cat >"${REL_END}/99-vfio-teardown.sh"<<EOF
#!/usr/bin/env bash
set -euo pipefail
DATE=\$(date +"%m/%d/%Y %R:%S :")
echo "\$DATE Beginning of Teardown!" | tee -a /var/log/libvirt/custom_hooks.log

# Unbind from vfio-pci
for dev in "$GPU" "$HDA"; do
  if [ -e "/sys/bus/pci/devices/\$dev/driver/unbind" ]; then
    echo "\$dev" > "/sys/bus/pci/devices/\$dev/driver/unbind"
    echo "\$DATE Unbound \$dev from vfio-pci" | tee -a /var/log/libvirt/custom_hooks.log
  fi
done

# Optional: reset upstream bridge for GA102 family if available
if [ -e "/sys/bus/pci/devices/$BRIDGE/reset" ]; then
  echo 1 > "/sys/bus/pci/devices/$BRIDGE/reset"
  echo "\$DATE Bridge $BRIDGE reset triggered." | tee -a /var/log/libvirt/custom_hooks.log
fi

# Rebind to host driver
if grep -q "true" "/tmp/vfio-is-nvidia" ; then
  modprobe drm 2>/dev/null || true
  modprobe drm_kms_helper 2>/dev/null || true
  modprobe i2c_nvidia_gpu 2>/dev/null || true
  modprobe nvidia 2>/dev/null || true
  modprobe nvidia_modeset 2>/dev/null || true
  modprobe nvidia_drm 2>/dev/null || true
  modprobe nvidia_uvm 2>/dev/null || true
  echo "$GPU" > /sys/bus/pci/drivers/nvidia/bind 2>/dev/null || true
  echo "$HDA" > /sys/bus/pci/drivers/snd_hda_intel/bind 2>/dev/null || true
  echo "\$DATE NVIDIA GPU Drivers Loaded" | tee -a /var/log/libvirt/custom_hooks.log
elif grep -q "true" "/tmp/vfio-is-amd" ; then
  modprobe drm 2>/dev/null || true
  modprobe amdgpu 2>/dev/null || true
  modprobe radeon 2>/dev/null || true
  modprobe drm_kms_helper 2>/dev/null || true
  echo "\$DATE AMD GPU Drivers Loaded" | tee -a /var/log/libvirt/custom_hooks.log
fi

# Unload VFIO modules
modprobe -r vfio_pci vfio_iommu_type1 vfio 2>/dev/null || true

# Rebind VT consoles
if [ -f /tmp/vfio-bound-consoles ]; then
  while read -r consoleNumber; do
    if [ -e /sys/class/vtconsole/vtcon"\$consoleNumber"/bind ] && grep -q "frame buffer" /sys/class/vtconsole/vtcon"\$consoleNumber"/name; then
      echo "\$DATE Rebinding console \$consoleNumber" | tee -a /var/log/libvirt/custom_hooks.log
      echo 1 > /sys/class/vtconsole/vtcon"\$consoleNumber"/bind
    fi
  done < /tmp/vfio-bound-consoles
fi

# Adaptive wait for DRM/NVIDIA nodes
wait_gpu_ready() {
  local tries=20; local i=1
  command -v udevadm >/dev/null 2>&1 && udevadm settle -t 5
  while [ \$i -le \$tries ]; do
    if [ -e /dev/dri/card0 ]; then
      if lsmod | grep -q '^nvidia_drm'; then
        if [ -e /dev/nvidiactl ] && [ -e /dev/nvidia0 ]; then
          echo "\$DATE DRM and NVIDIA nodes present" | tee -a /var/log/libvirt/custom_hooks.log
          return 0
        fi
      else
        echo "\$DATE DRM node present" | tee -a /var/log/libvirt/custom_hooks.log
        return 0
      fi
    fi
    echo "\$DATE Waiting for GPU/DRM to settle (\$i/ \$tries)..." | tee -a /var/log/libvirt/custom_hooks.log
    sleep 0.5; i=\$((i+1))
  done
  echo "\$DATE WARNING: GPU/DRM nodes did not appear in time; continuing anyway" | tee -a /var/log/libvirt/custom_hooks.log
  return 1
}
wait_gpu_ready

# Restart Display Manager
DM=\$(cat /tmp/vfio-store-display-manager 2>/dev/null || echo display-manager)
sleep 0.5
echo "\$DATE Starting display manager: \$DM" | tee -a /var/log/libvirt/custom_hooks.log
systemctl start "\$DM.service" 2>/dev/null || true

echo "\$DATE End of Teardown!" | tee -a /var/log/libvirt/custom_hooks.log
EOF
chmod +x "${REL_END}/99-vfio-teardown.sh"

# ---------- top-level qemu hook tying it all together ----------
cat > /etc/libvirt/hooks/qemu <<EOF
#!/usr/bin/env bash
OBJECT="\$1"; OPERATION="\$2"
if [[ "\$OBJECT" == "$VM_NAME" ]]; then
  case "\$OPERATION" in
    "prepare")
      # snapshot before toggles
      /bin/vm-quick-health.sh "$GPU" | tee -a /var/log/libvirt/vfio-perf.log
      # perf toggles (HugePages + governor)
      /bin/vfio-perf-start.sh $HUGEPROFILE | tee -a /var/log/libvirt/vfio-perf.log
      # no-sleep helper if present
      systemctl start libvirt-nosleep@"$VM_NAME" 2>/dev/null || true
      # VFIO startup (bind GPU to vfio, stop DM, etc.)
      "${PREP_BEGIN}/01-vfio-startup.sh" 2>&1 | tee -a /var/log/libvirt/custom_hooks.log
      # post status
      /bin/vm-quick-health.sh "$GPU" | tee -a /var/log/libvirt/vfio-perf.log
      ;;
    "release")
      # VFIO teardown (return GPU to host)
      "${REL_END}/99-vfio-teardown.sh" 2>&1 | tee -a /var/log/libvirt/custom_hooks.log
      # perf revert (free HugePages + normal governor)
      /bin/vfio-perf-stop.sh | tee -a /var/log/libvirt/vfio-perf.log
      systemctl stop libvirt-nosleep@"$VM_NAME" 2>/dev/null || true
      # final status
      /bin/vm-quick-health.sh "$GPU" | tee -a /var/log/libvirt/vfio-perf.log
      ;;
  esac
fi
EOF
chmod +x /etc/libvirt/hooks/qemu

# ---------- SELinux contexts (best-effort) ----------
if command -v restorecon >/dev/null 2>&1; then
  restorecon -RF /etc/libvirt/hooks || true
fi

echo "═══════════════════════════════════════════════════════"
echo "[DONE] All tools and hooks installed."
echo "Try:"
echo "  sudo vfio watch $VM_NAME"
echo "  sudo vfio health"
echo "  sudo vfio gov perf   # or: sudo vfio gov normal"
echo
echo "Start your VM via virt-manager or:  sudo virsh start $VM_NAME"
echo "═══════════════════════════════════════════════════════"
