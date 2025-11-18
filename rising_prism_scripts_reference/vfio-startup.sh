#!/bin/bash

#############################################################################
##     ______  _                _  _______         _                 _     ##
##    (_____ \(_)              | |(_______)       | |               | |    ##
##     _____) )_  _   _  _____ | | _    _   _   _ | |__   _____   __| |    ##
##    |  ____/| |( \ / )| ___ || || |  | | | | | ||  _ \ | ___ | / _  |    ##
##    | |     | | ) X ( | ____|| || |__| | | |_| || |_) )| ____|( (_| |    ##
##    |_|     |_|(_/ \_)|_____) \_)\______)|____/ |____/ |_____) \____|    ##
##                                                                         ##
#############################################################################
###################### Credits ###################### ### Update PCI ID'S ###
## Lily (PixelQubed) for editing the scripts       ## ##                   ##
## RisingPrisum for providing the original scripts ## ##   update-pciids   ##
## Void for testing and helping out in general     ## ##                   ##
## .Chris. for testing and helping out in general  ## ## Run this command  ##
## WORMS for helping out with testing              ## ## if you dont have  ##
##################################################### ## names in you're   ##
## The VFIO community for using the scripts and    ## ## lspci feedback    ##
## testing them for us!                            ## ## in your terminal  ##
##################################################### #######################

################################# Variables #################################

## Adds current time to var for use in echo for a cleaner log and script ##
DATE=$(date +"%m/%d/%Y %R:%S :")

## Sets dispmgr var as null ##
DISPMGR="null"

################################## Script ###################################

echo "$DATE Beginning of Startup!"


function stop_display_manager_if_running {
    ## Get display manager on systemd based distros ##
    if [[ -x /run/systemd/system ]] && echo "$DATE Distro is using Systemd"; then
        DISPMGR="$(grep 'ExecStart=' /etc/systemd/system/display-manager.service | awk -F'/' '{print $(NF-0)}')"
        echo "$DATE Display Manager = $DISPMGR"

        ## Stop display manager using systemd ##
        if systemctl is-active --quiet "$DISPMGR.service"; then
            grep -qsF "$DISPMGR" "/tmp/vfio-store-display-manager" || echo "$DISPMGR" >/tmp/vfio-store-display-manager
            systemctl stop "$DISPMGR.service"
            systemctl isolate multi-user.target
        fi

        while systemctl is-active --quiet "$DISPMGR.service"; do
            sleep "1"
        done

        return

    fi

}

function kde-clause {

    echo "$DATE Display Manager = display-manager"

    ## Stop display manager using systemd ##
    if systemctl is-active --quiet "display-manager.service"; then
    
        grep -qsF "display-manager" "/tmp/vfio-store-display-manager"  || echo "display-manager" >/tmp/vfio-store-display-manager
        systemctl stop "display-manager.service"
    fi

        while systemctl is-active --quiet "display-manager.service"; do
                sleep 2
        done

    return

}

####################################################################################################################
## Checks to see if your running KDE. If not it will run the function to collect your display manager.            ##
## Have to specify the display manager because kde is weird and uses display-manager even though it returns sddm. ##
####################################################################################################################

if pgrep -l "plasma" | grep "plasmashell"; then
    echo "$DATE Display Manager is KDE, running KDE clause!"
    kde-clause
    else
        echo "$DATE Display Manager is not KDE!"
        stop_display_manager_if_running
fi

## Unbind EFI-Framebuffer ##
if test -e "/tmp/vfio-is-nvidia"; then
    rm -f /tmp/vfio-is-nvidia
    else
        test -e "/tmp/vfio-is-amd"
        rm -f /tmp/vfio-is-amd
fi

sleep "1"

##############################################################################################################################
## Unbind VTconsoles if currently bound (adapted and modernised from https://www.kernel.org/doc/Documentation/fb/fbcon.txt) ##
##############################################################################################################################
if test -e "/tmp/vfio-bound-consoles"; then
    rm -f /tmp/vfio-bound-consoles
fi
for (( i = 0; i < 16; i++))
do
  if test -x /sys/class/vtconsole/vtcon"${i}"; then
      if [ "$(grep -c "frame buffer" /sys/class/vtconsole/vtcon"${i}"/name)" = 1 ]; then
	       echo 0 > /sys/class/vtconsole/vtcon"${i}"/bind
           echo "$DATE Unbinding Console ${i}"
           echo "$i" >> /tmp/vfio-bound-consoles
      fi
  fi
done

sleep "1"

if lspci -nn | grep -e VGA | grep -s NVIDIA ; then
    echo "$DATE System has an NVIDIA GPU"
    grep -qsF "true" "/tmp/vfio-is-nvidia" || echo "true" >/tmp/vfio-is-nvidia
    echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/unbind

    ## Unload NVIDIA GPU drivers ##
    modprobe -r nvidia_uvm
    modprobe -r nvidia_drm
    modprobe -r nvidia_modeset
    modprobe -r nvidia
    modprobe -r i2c_nvidia_gpu
    modprobe -r drm_kms_helper
    modprobe -r drm

    echo "$DATE NVIDIA GPU Drivers Unloaded"
fi

if lspci -nn | grep -e VGA | grep -s AMD ; then
    echo "$DATE System has an AMD GPU"
    grep -qsF "true" "/tmp/vfio-is-amd" || echo "true" >/tmp/vfio-is-amd
    echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/unbind

    ## Unload AMD GPU drivers ##
    modprobe -r drm_kms_helper
    modprobe -r amdgpu
    modprobe -r radeon
    modprobe -r drm

    echo "$DATE AMD GPU Drivers Unloaded"
fi

## Load VFIO-PCI driver ##
modprobe vfio
modprobe vfio_pci
modprobe vfio_iommu_type1


## === Begin: explicit hand-off to VFIO ===
# IDs for safety (not strictly required here, but fine to have)
GPU="0000:08:00.0"
HDA="0000:08:00.1"

# Make sure vfio-pci is ready
modprobe vfio-pci || true

# Unbind from current driver (likely none after rmmod, but do it explicitly)
for dev in "$GPU" "$HDA"; do
  if [ -e "/sys/bus/pci/devices/$dev/driver/unbind" ]; then
    echo "$dev" > "/sys/bus/pci/devices/$dev/driver/unbind"
    echo "$DATE Unbound $dev from previous driver"
  fi
done

# Bind to vfio-pci
for dev in "$GPU" "$HDA"; do
  if [ -e "/sys/bus/pci/drivers/vfio-pci/bind" ]; then
    echo "$dev" > "/sys/bus/pci/drivers/vfio-pci/bind"
    echo "$DATE Bound $dev to vfio-pci"
  fi
done

# On some systems simpledrm can hold the console; try to release it (best-effort)
if [ -e /sys/bus/platform/drivers/simple-framebuffer ] && [ -e /sys/bus/platform/drivers/simple-framebuffer/efi-framebuffer.0/unbind ]; then
  echo efi-framebuffer.0 > /sys/bus/platform/drivers/simple-framebuffer/unbind 2>/dev/null || true
fi

## === End: explicit hand-off to VFIO ===


echo "$DATE End of Startup!"
