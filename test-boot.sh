#!/usr/bin/env bash
# Boot the built ISO in QEMU, so it can be checked without burning a USB.
#
#     ./test-boot.sh              UEFI boot, graphical window
#     ./test-boot.sh --headless   serial console only, for a machine with no display
#     ./test-boot.sh --bios       legacy BIOS instead of UEFI
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ISO="$(ls -t "$HERE"/out/*.iso 2>/dev/null | head -1 || true)"

# The VM's own disk and firmware variables do not go in out/. build.sh runs
# under sudo, so out/ belongs to root, and this script does not — writing there
# fails with a bare "Permission denied" from cp. They are throwaway state
# anyway, and keeping them out of out/ also keeps them away from the ISO.
VMDIR="$HERE/.vm"
mkdir -p "$VMDIR" || { echo "cannot create $VMDIR" >&2; exit 1; }
[[ -n $ISO ]] || { echo "no ISO in $HERE/out — run ./build.sh first" >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null || {
    echo "qemu is not installed:  sudo pacman -S qemu-desktop edk2-ovmf" >&2; exit 1; }

# The video device belongs with the display, not with the machine: virtio-vga-gl
# refuses to start unless the backend has GL turned on explicitly ("-display gtk"
# alone is not enough, it must be "gtk,gl=on"), and in headless mode there is no
# display to attach it to at all.
MODE=uefi; DISPLAY_ARGS=(-device virtio-vga-gl -display gtk,gl=on)
for a in "$@"; do
    case "$a" in
        --headless) DISPLAY_ARGS=(-nographic) ;;
        --bios)     MODE=bios ;;
        *) echo "unknown option: $a" >&2; exit 1 ;;
    esac
done

args=(
    -m 4G -smp 4 -enable-kvm
    -cpu host
    -cdrom "$ISO"
    -boot d
    # A blank disk, so an install can actually be exercised.
    -drive file="$VMDIR/test-disk.qcow2",if=virtio,format=qcow2
    -device virtio-net,netdev=n0 -netdev user,id=n0
)
[[ $MODE == uefi ]] && {
    OVMF=/usr/share/edk2/x64/OVMF_CODE.4m.fd
    VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
    [[ -f $OVMF ]] || { OVMF=/usr/share/OVMF/OVMF_CODE.fd; VARS=/usr/share/OVMF/OVMF_VARS.fd; }
    [[ -f $OVMF ]] || { echo "OVMF firmware not found: sudo pacman -S edk2-ovmf" >&2; exit 1; }

    # OVMF is split in two: read-only code, and a writable variable store. With
    # only the code half the firmware has nowhere to record a boot entry, so an
    # installed system leaves no trace in NVRAM and the VM will not boot it on
    # the next run. Give each test VM its own writable copy of the vars.
    NVRAM="$VMDIR/OVMF_VARS.fd"
    [[ -f $NVRAM ]] || cp "$VARS" "$NVRAM"
    args+=(
        -drive if=pflash,format=raw,readonly=on,file="$OVMF"
        -drive if=pflash,format=raw,file="$NVRAM"
    )
}

[[ -f "$VMDIR/test-disk.qcow2" ]] || qemu-img create -f qcow2 "$VMDIR/test-disk.qcow2" 20G

echo "Booting $(basename "$ISO") in $MODE mode..."
exec qemu-system-x86_64 "${args[@]}" "${DISPLAY_ARGS[@]}"
