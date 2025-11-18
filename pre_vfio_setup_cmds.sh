#Only needed for dual gpu vfio passthrough -->
# sudo tee /etc/modprobe.d/vfio-pci.conf <<EOF
# options vfio-pci ids=10de:2208,10de:1aef
# EOF

#-------------------------------------------------------------------------------------------------------------------------------------------------------------------
ACS Kernel patching for Fedora linux :
https://github.com/mateussouzaweb/kvm-qemu-virtualization-guide/blob/master/Docs/02%20-%20PCI-e%20Passthrough.md

Go to https://github.com/some-natalie/fedora-acs-override/actions and download the latest kernel version available (you must log in on GitHub first to download files). After completing the download, if necessary, transfer the file to the host and run the following commands to install the patched kernel with alternative ACS implementation. You already added the boot flag pcie_acs_override so now just need to install the patched kernel:

Commands on installing the acs kernel patch :

# Install the new kernel
unzip kernel-*-acs-override-rpms.zip -d kernel-acs-override
dnf install --allowerasing kernel-acs-override/*.rpm

# Clean artifacts
rm -fr kernel-acs-override/ kernel-*-acs-override-rpms.zip

# Reboot
reboot
#-------------------------------------------------------------------------------------------------------------------------------------------------------------------

#Need for both single and dual gpu vfio passthrough -->
sudo tee /etc/modules-load.d/vfio.conf <<EOF
vfio
vfio_iommu_type1
vfio_pci
EOF


#For dual gpu passthrough -->
# sudo tee /etc/modprobe.d/blacklist-nvidia.conf <<EOF
# blacklist nouveau
# blacklist nvidia
# blacklist nvidia_drm
# blacklist nvidia_modeset
# blacklist nvidia_uvm
# EOF



#create snapshot before initramfs generation, can prevent nvidia modules from loading properly
sudo dracut --force

#Build initramfs for custom kernel
sudo dracut -f /boot/initramfs-6.17.4-300.fc43.x86_64.img 6.17.4-300.fc43.x86_64 || true



sudo dnf install @virtualization
sudo dnf install qemu libvirt edk2-ovmf
sudo usermod -a -G libvirt hrishi

#-------------------------------------------------------------------------------------------------------------------------------------------------------------------
#Make sure to add grub commandline additions :
#Basic Working -->
#GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 amd_iommu=on iommu=pt kvm.ignore_msrs=1 amd_pstate=active mitigations=off video=efifb:off" 

#Fully Optimized for high performance --> 
#GRUB_CMDLINE_LINUX="resume=UUID=fc6600fa-d85c-4962-bc58-dd98a4ed0b8e rhgb rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core loglevel=3 amd_iommu=on iommu=pt pcie_acs_override=downstream,multifunction kvm.ignore_msrs=1 amd_pstate=active mitigations=off video=efifb:off isolcpus=1-16,managed_nohz nohz_full=1-16 rcu_nocbs=1-16"

#-------------------------------------------------------------------------------------------------------------------------------------------------------------------
#Rebuild Grub
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

#-------------------------------------------------------------------------------------------------------------------------------------------------------------------