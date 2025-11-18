#!/usr/bin/env bash
# verify_vfio_env.sh — Post-reimage VFIO readiness checker (Fedora-ready)
# Usage:
#   sudo verify_vfio_env.sh --vm win11 \
#     --gpu 0000:08:00.0 --hda 0000:08:00.1 \
#     [--bridge 0000:00:03.1] [--usb 0000:0a:00.3]

set -euo pipefail

# ===== configurable defaults =====
VM="win11"
GPU=""
HDA=""
BRIDGE=""
USB=""
REQUIRED_FLAGS=(amd_iommu=on iommu=pt video=efifb:off)
SUGGESTED_FLAGS=(isolcpus= nohz_full= rcu_nocbs= amd_pstate=active mitigations=off)

# ===== colors =====
G="\e[32m"; R="\e[31m"; Y="\e[33m"; C="\e[36m"; Z="\e[0m"

pass(){ printf "${G}✔ %s${Z}\n" "$*"; }
fail(){ printf "${R}✘ %s${Z}\n" "$*"; }
warn(){ printf "${Y}! %s${Z}\n" "$*"; }
info(){ printf "${C}• %s${Z}\n" "$*"; }

# ===== parse args =====
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm) VM="$2"; shift 2;;
    --gpu) GPU="$2"; shift 2;;
    --hda) HDA="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --usb) USB="$2"; shift 2;;
    -h|--help)
      echo "Usage: sudo $0 --vm <name> --gpu <BB:DD.F> --hda <BB:DD.F> [--bridge <...>] [--usb <...>]"
      exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

echo -e "\n===== VFIO ENV VERIFICATION ====="
info "VM: $VM  GPU:$GPU  HDA:$HDA  BRIDGE:${BRIDGE:-n/a}  USB:${USB:-n/a}"
echo

RC=0

# ===== 1) Kernel cmdline flags =====
CMDLINE="$(cat /proc/cmdline)"
ALL_OK=1
for f in "${REQUIRED_FLAGS[@]}"; do
  if ! grep -qw "${f%%=*}" <<<"$CMDLINE"; then ALL_OK=0; warn "Missing kernel flag: $f"; fi
done
(( ALL_OK )) && pass "Kernel flags (required) present" || RC=1

# Suggest optional flags
for f in "${SUGGESTED_FLAGS[@]}"; do
  if ! grep -q "${f%%=*}" <<<"$CMDLINE"; then warn "Suggested flag not found: $f"; fi
done

# ===== 2) IOMMU enabled + groups exist =====
if dmesg | grep -Ei "IOMMU|AMD-Vi|DMAR" >/dev/null; then pass "IOMMU messages present in dmesg"
else fail "No IOMMU lines in dmesg"; RC=1; fi

if [[ -d /sys/kernel/iommu_groups ]] && [[ $(find /sys/kernel/iommu_groups -maxdepth 1 -type d | wc -l) -gt 1 ]]; then
  pass "IOMMU groups present"
else
  fail "IOMMU groups missing; check BIOS SVM/IOMMU + kernel flags"
  RC=1
fi

# ===== 3) KVM & VFIO modules =====
mods=(kvm kvm_amd vfio vfio_pci vfio_iommu_type1)
for m in "${mods[@]}"; do
  if lsmod | grep -q "^$m"; then pass "Module loaded: $m"; else warn "Module not loaded: $m"; fi
done

# ===== 4) Libvirt & OVMF =====
if systemctl is-active --quiet libvirtd; then pass "libvirtd active"; else fail "libvirtd not active"; RC=1; fi

OVMF_CODE="/usr/share/edk2/ovmf/x64/OVMF_CODE.fd"
OVMF_VARS="/usr/share/edk2/ovmf/x64/OVMF_VARS.fd"
[[ -f "$OVMF_CODE" ]] && pass "OVMF_CODE present" || { fail "Missing $OVMF_CODE"; RC=1; }
[[ -f "$OVMF_VARS" ]] && pass "OVMF_VARS present" || { fail "Missing $OVMF_VARS"; RC=1; }

# ===== 5) HugePages mount =====
if mount | grep -q "hugetlbfs on /dev/hugepages"; then pass "hugetlbfs mounted at /dev/hugepages"
else warn "hugetlbfs not mounted; will be mounted by vfio-perf-start.sh"; fi

# ===== 6) Device existence + grouping =====
check_dev() {
  local id="$1" label="$2"
  [[ -z "$id" ]] && return 0
  local path="/sys/bus/pci/devices/$id"
  if [[ -d "$path" ]]; then
    pass "$label device $id present"
    # group check
    local drv="unbound"; [[ -L "$path/driver" ]] && drv="$(basename "$(readlink "$path/driver")")"
    local grp=$(basename "$(dirname "$(dirname "$(readlink -f "$path/iommu_group" 2>/dev/null || echo /dev/null)")")" 2>/dev/null || echo "?")
    info "$label driver: $drv | IOMMU group: $grp"
  else
    fail "$label device $id not found"; RC=1
  fi
}

check_dev "$GPU"  "GPU"
check_dev "$HDA"  "HDA"
[[ -n "$USB" ]]    && check_dev "$USB" "USB Controller"
[[ -n "$BRIDGE" ]] && check_dev "$BRIDGE" "Upstream Bridge"

# ===== 7) VM XML presence (optional) =====
if virsh dominfo "$VM" >/dev/null 2>&1; then
  pass "VM '$VM' defined in libvirt"
  # quick probes
  if virsh dumpxml "$VM" | grep -q "<memoryBacking>"; then pass "VM has <memoryBacking> (hugepages)"; else warn "VM missing <memoryBacking><hugepages/>"; fi
  if virsh dumpxml "$VM" | grep -q "<cpu mode='host-passthrough'"; then pass "VM CPU passthrough configured"; else warn "VM not set to host-passthrough"; fi
else
  warn "VM '$VM' not defined yet (ok if importing later)"
fi

# ===== 8) Hooks & permissions =====
if [[ -x /etc/libvirt/hooks/qemu ]]; then pass "Hook dispatcher present"
else warn "Missing /etc/libvirt/hooks/qemu (will be installed by vfio-full-install.sh)"; fi

# ===== 9) Quick binding sanity (GPU should be on host when VM not running) =====
if [[ -n "$GPU" && -L "/sys/bus/pci/devices/$GPU/driver" ]]; then
  drv=$(basename "$(readlink "/sys/bus/pci/devices/$GPU/driver")")
  if [[ "$drv" == "vfio-pci" ]]; then
    warn "GPU currently bound to vfio-pci (expected when VM running)."
  else
    pass "GPU currently bound to host driver: $drv"
  fi
fi

echo -e "\n===== SUMMARY ====="
if (( RC == 0 )); then
  echo -e "${G}Environment ready for VFIO passthrough.${Z}"
else
  echo -e "${R}One or more checks failed. Review messages above.${Z}"
fi
exit "$RC"
