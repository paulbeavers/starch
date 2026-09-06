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

# Every GPU vendor, because live media cannot know the host.
out+=(mesa vulkan-radeon vulkan-intel vulkan-nouveau vulkan-icd-loader
      libva-mesa-driver intel-media-driver)

printf '%s\n' "${out[@]}" | sed '/^$/d' | LC_ALL=C sort -u
