#!/usr/bin/env bash
# Emit the flat package list the ISO profile installs, derived from install.sh
# so the two can never drift. GPU packages are deliberately excluded: the live
# environment needs every vendor's driver, not the one this machine happens to
# have, and install.sh picks per-host at install time.
#
#     ./extract-packages.sh            print the list
#     ./extract-packages.sh --write    write ../iso/packages.extra
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$HERE/hyprland-setup/install.sh"
[[ -f $INSTALL ]] || {
    echo "hyprland-setup/install.sh not found — run: git submodule update --init" >&2
    exit 1
}

# Source only the package arrays. install.sh guards its body behind a main
# function and option parsing, so this pulls the declarations out instead of
# executing it — running the installer as a side effect would be a bad day.
eval "$(sed -n '/^PKGS_[A-Z0-9]*=(/,/^)/p' "$INSTALL")"

groups=(PKGS_BASE PKGS_AUDIO PKGS_HYPRLAND PKGS_DESKTOP PKGS_FONTS
        PKGS_THEME PKGS_APPS PKGS_SHELL PKGS_GREETD PKGS_BLUETOOTH)

out=()
for g in "${groups[@]}"; do
    declare -n arr="$g" 2>/dev/null || continue
    out+=("${arr[@]}")
done

# Packages the live ISO needs that an installed system does not.
out+=(archinstall arch-install-scripts gparted parted dosfstools e2fsprogs
      btrfs-progs exfatprogs mtools nfs-utils ntfs-3g
      linux linux-firmware mkinitcpio mkinitcpio-archiso syslinux
      memtest86+-efi edk2-shell)

# Graphics, for every vendor, because the medium cannot know the host — and
# because since the install became a copy of this image, whatever is missing
# here cannot be fetched later. install.sh picks per-host at install time from
# exactly this set; anything it wants that is absent turns an offline install
# into one that stops and asks for a network.
#
# PKGS_GPU above is the vendor-neutral base, sourced from install.sh so the two
# cannot drift. The per-vendor additions are spelled out because install.sh
# builds them in a loop over the hardware it finds, which cannot be sourced.
out+=("${PKGS_GPU[@]}")
out+=(vulkan-radeon)                        # amd
out+=(vulkan-intel intel-media-driver)      # intel
out+=(vulkan-virtio vulkan-swrast)          # virtual machines, and the fallback
out+=(nvidia-open-dkms nvidia-utils nvidia-settings egl-wayland
      libva-nvidia-driver dkms linux-headers)   # nvidia
# NVIDIA costs 1.3GB, most of it nvidia-utils, and it is carried so that an
# NVIDIA machine installs without a network like every other machine.
# install.sh removes the drivers this host has no use for once it knows what
# the hardware is, so an AMD laptop does not keep 900MB of NVIDIA userspace.

# Wireless the kernel cannot handle on its own. broadcom-wl-dkms drives the
# BCM4360 in a 2013 MacBook Pro, which brcmfmac does not support at all, and
# the BCM4331 in the older ones. install.sh decides whether this machine wants
# it and blacklists the in-kernel drivers that would fight it for the card.
# broadcom-bt-firmware is the bluetooth half of the same machines.
out+=(broadcom-wl-dkms broadcom-bt-firmware dkms linux-headers)

printf '%s\n' "${out[@]}" | sed '/^$/d' | LC_ALL=C sort -u
