
---

# Vfio-Full-Passthrough-Setup-Toolkit for Single GPU Passthrough on Fedora

### What does this toolkit provide?

End-to-end toolkit to set up a stable, production-grade **Single GPU Passthrough (VFIO)** on Fedora — tuned for reliability with **Btrfs snapshots**, **SELinux**, and **NVIDIA**.
Validated on Fedora 43 running custom ACS kernel (6.17.4-300.acs.fc43). Works on GNOME and XFCE.

## Contents

* `pre_vfio_setup_cmds.sh` – **pre-vfio setup command checklist** (run manually, line-by-line) before VFIO install.
* `vfio-full-install.sh` – one-shot installer that deploys hooks/services and host helpers.
* `01-vfio-startup.sh` / `99-vfio-teardown.sh` – your **per-VM** host↔guest handoff scripts.
* `btrfs-snap` – snapshot manager (create/restore/pin/doctor).
* `finalize` – safe promotion of restored `@.new` → canonical `@` (handles nested `@.new`).
* `safe_update` – **safe updater** (DNF + Flatpak + Snap) that excludes VFIO-critical packages and auto-snapshots.

> Philosophy: keep the host kernel/NVIDIA/libvirt/qemu **fixed** for VFIO stability; update **userspace** aggressively; wrap risky changes behind a Btrfs snapshot with 1-command rollback.

[!NOTE] : Ensure that freshly installed Fedora host OS is up to date. Avoid installing new kernel. Install all current kernel headers, drivers, NVIDIA drivers and other basic packages before proceeding further.

---

## Quick start (fresh box)

### 0) Prereqs

```bash
sudo dnf install -y make git util-linux-core btrfs-progs \
  policycoreutils policycoreutils-python-utils
# Optional: RPM Fusion/NVIDIA per Fedora docs
```

### 0.5) Pre-VFIO Setup Checklist (run before VFIO install)

Open **`pre_vfio_setup_cmds.sh`** — it’s a curated list of commands to run **manually, line-by-line**.
It is **not** meant to be executed as a single script.

Typical items covered there include:

* Kernel command-line tuning (iommu, acs override, cpusets, etc.).
* Module autoload (`vfio`, `vfio_iommu_type1`, `vfio_pci`, `vhost_net`, `tun`).
* Binding your GPU/HDA to `vfio-pci` by **PCI IDs**.
* Optional blacklists for `nouveau` / host NVIDIA stack (if you isolate the GPU).
* Sanity checks (IOMMU groups, `lspci -nnk`, etc.).

> **Edit to your hardware first** (PCI IDs, BDFs). Then run each command consciously.

Example: (these are representative examples; rely on pre_vfio_setup_cmds.sh file for exact lines)

```bash
# Load VFIO modules at boot
cat <<'EOF' | sudo tee /etc/modules-load.d/vfio.conf
vfio
vfio_iommu_type1
vfio_pci
vhost_net
tun
EOF

# Bind your GPU/HDA early (replace IDs with your own!)
echo 'options vfio-pci ids=10de:2208,10de:1aef disable_vga=1' | \
  sudo tee /etc/modprobe.d/vfio-pci-ids.conf

# (Optional) blacklist nouveau on hosts that should never claim the GPU
echo -e "blacklist nouveau\noptions nouveau modeset=0" | \
  sudo tee /etc/modprobe.d/blacklist-nouveau.conf
```

> After finishing the pre-vfio setup commands, reboot once to ensure the host comes back clean with the new module/driver state.

### 1) Clone & enter

```bash
git clone https://github.com/hrishikesh9409/vfio-full-passthrough-setup-fedora.git
cd vfio-full-passthrough-setup-fedora
```

### 2) (Recommended) take a golden snapshot

```bash
sudo ./btrfs-snap create "golden-base-$(date +%F_%H%M)"
sudo ./btrfs-snap pin "golden-base-$(date +%F_%H%M)"   # optional
```

### 3) Install VFIO toolkit

**Option A — one-shot installer**

```bash
sudo bash ./vfio-full-install.sh \
  --vm win11 \
  --gpu-bdf 0000:08:00.0 \
  --audio-bdf 0000:08:00.1 \
  --bridge-bdf 0000:00:03.1 \
  --assets /var/lib/libvirt/images
```

**Option B — manual hook placement (use your known-good flow)**

```bash
sudo install -Dm0755 01-vfio-startup.sh \
  /etc/libvirt/hooks/qemu.d/win11/prepare/begin/01-vfio-startup.sh
sudo install -Dm0755 99-vfio-teardown.sh \
  /etc/libvirt/hooks/qemu.d/win11/release/end/99-vfio-teardown.sh
sudo install -Dm0755 hooks/qemu /etc/libvirt/hooks/qemu  # if you use dispatcher
sudo restorecon -RF /etc/libvirt/hooks || true
```

### 4) SELinux baseline (persistent, safe)

```bash
# Helpful booleans
sudo setsebool -P virt_use_execmem 1
sudo setsebool -P domain_can_mmap_files 1

# Label VM assets
sudo semanage fcontext -a -t virt_image_t "/var/lib/libvirt/images(/.*)?"
sudo restorecon -RF /var/lib/libvirt/images

# Boot-time relabel for device nodes & images
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
sudo systemctl enable --now libvirt-selinux-prepare.service
```

> If virt-manager’s first start after a cold reboot is flaky, `sudo virsh start win11` starts cleanly on the first go. You can also add a tiny autostart unit with a one-retry helper if you want zero clicks.

### 5) Safe updates (userspace + Flatpak + Snap; VFIO-critical stuff excluded)

```bash
sudo install -m0755 ./safe_update /usr/local/sbin/safe_update
sudo safe_update
# logs: /var/log/vfio-maintenance/safe_update_<timestamp>.log
```

By default, `safe_update` excludes:

```
kernel* kernel-core* kernel-modules* kernel-modules-extra* kernel-devel* kernel-headers*
kernel-tools* perf* python3-perf* libperf* rtla* rv*
akmod-nvidia* kmod-nvidia* nvidia-* xorg-x11-drv-nvidia*
qemu* libvirt* virt-* edk2-ovmf* ovmf* uki-* uki-direct* systemd-boot* shim-* grub2-*
```

so you keep your **VFIO/NVIDIA/libvirt/qemu** stable while updating everything else.

---

## Btrfs restore/finalize workflow

Restore to a snapshot per your usual flow. After you boot into `@.new`, run:

```bash
sudo ./finalize
```

This tool:

* Mounts the Btrfs **top-level by FS-UUID** (never picks the wrong disk).
* Handles **nested `@.new`**: deletes children deepest-first, then deletes nested `@.new`.
* Switches **default subvol** during the swap; deletes old `@`; promotes `@.new → @`.
* Normalizes **/etc/fstab + BLS + grubby** to `subvol=@`.


### Start VM:

  * `sudo virsh start win11` → works on first try after host reboot.
  * virt-manager as normal user may occasionally need a second click after a cold reboot (SELinux timing quirk).
* Update safely:

  ```bash
  sudo safe_update
  sudo safe_update log
  sudo safe_update follow
  ```

---

## Troubleshooting Commands 

### In case of issues with BTRFS Snap management - restore/finalize

* **EFI got UKI/initrd copies or ran out of space**: we keep initramfs under `/boot` and can disable loader entry:

  ```bash
  sudo mkdir -p /etc/kernel/install.d
  sudo ln -sf /dev/null /etc/kernel/install.d/90-loaderentry.install
  ```
* **GRUB shows stale rescue or wrong subvol**: `finalize` already normalizes. If needed:

  ```bash
  sudo grub2-mkconfig -o /boot/grub2/grub.cfg
  ```

---

## License

MIT

---
