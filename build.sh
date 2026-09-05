#!/usr/bin/env bash
# Build a bootable ISO of this setup.
#
#     ./build.sh              build (needs root for mkarchiso)
#     ./build.sh --check      verify prerequisites and print the plan, build nothing
#     ./build.sh --assemble    assemble the profile but do not run mkarchiso.
#                              Needs no root, so the overlay can be inspected
#                              and diffed before committing to a 20GB build.
#     ./build.sh --clean      remove the work directory and exit
#     ./build.sh --reuse      keep the existing work directory. Faster, but
#                             mkarchiso skips steps it has already done, so the
#                             packages will be the ones downloaded last time.
#
# The profile is assembled on top of archiso's stock `releng` profile rather
# than vendored into this repo. releng carries the bootloader configs for
# syslinux, GRUB and systemd-boot, and those change between archiso releases —
# a vendored copy goes stale silently and fails at boot, which is the worst
# place to find out. We copy it at build time and layer on top.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
RELENG="${RELENG:-/usr/share/archiso/configs/releng}"
WORK="${WORK:-$HERE/work}"
PROFILE="$WORK/profile"
OUT="${OUT:-$HERE/out}"

# Live session identity.
LIVE_USER="${LIVE_USER:-live}"
ISO_NAME="hyprarch"
ISO_LABEL="HYPRARCH_$(date +%Y%m)"
ISO_PUBLISHER="hyprland-setup <https://github.com/paulbeavers/hyprland-setup>"
ISO_APPLICATION="Hyprland desktop live/install medium"

C_B=$'\e[34m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_0=$'\e[0m'
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$1"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$1"; }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_0" "$1"; }
die()  { printf '\n%sERROR:%s %s\n' "$C_R" "$C_0" "$1" >&2; exit 1; }

CHECK_ONLY=0
ASSEMBLE_ONLY=0
REUSE_WORK=0
for a in "$@"; do
    case "$a" in
        --check)    CHECK_ONLY=1 ;;
        --assemble) ASSEMBLE_ONLY=1 ;;
        --reuse)    REUSE_WORK=1 ;;
        --clean)
            rm -rf "$HERE/work-assemble" 2>/dev/null || true
            rm -rf "$WORK" 2>/dev/null \
                || die "cannot remove $WORK (root-owned from a previous build) — sudo $0 --clean"
            ok "removed the work directories"; exit 0 ;;
        *) die "unknown option: $a" ;;
    esac
done

# A real build runs under sudo and leaves a root-owned work directory behind.
# --assemble runs as your user and must not trip over it, so it gets its own.
if [[ $ASSEMBLE_ONLY -eq 1 && $EUID -ne 0 ]]; then
    WORK="$HERE/work-assemble"
    PROFILE="$WORK/profile"
fi

# ── prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
command -v mkarchiso >/dev/null || die "archiso is not installed:  sudo pacman -S archiso"
[[ -d $RELENG ]] || die "stock releng profile not found at $RELENG"
ok "archiso $(pacman -Q archiso 2>/dev/null | awk '{print $2}')"

avail=$(df -BG --output=avail "$HERE" | tail -1 | tr -dc '0-9')
[[ ${avail:-0} -ge 20 ]] || warn "only ${avail}GB free; a build wants ~20GB"
ok "${avail}GB free at $HERE"

pkgcount=$("$HERE/extract-packages.sh" | wc -l)
ok "$pkgcount packages from install.sh"

if [[ $CHECK_ONLY -eq 1 ]]; then
    step "Plan"
    echo "    base profile : $RELENG"
    echo "    work dir     : $WORK"
    echo "    output       : $OUT/${ISO_NAME}-*.iso"
    echo "    live user    : $LIVE_USER (autologin, straight into Hyprland)"
    echo "    label        : $ISO_LABEL"
    printf '\n    Build with:  sudo %s\n\n' "$0"
    exit 0
fi

# ── assemble the profile ──────────────────────────────────────────────────────
step "Assembling profile"
# mkarchiso marks completed steps with files in the work directory and skips
# them on a rerun (see _run_once in /usr/bin/mkarchiso). Reusing a work dir
# therefore repackages the packages downloaded last time and silently produces
# a stale ISO, so start clean unless explicitly told not to.
if [[ -d $WORK && $REUSE_WORK -eq 0 ]]; then
    warn "removing the previous work directory (--reuse to keep it)"
    rm -rf "$WORK" 2>/dev/null || die "cannot remove $WORK (root-owned from a previous build) — sudo $0 --clean"
fi
rm -rf "$PROFILE"; mkdir -p "$PROFILE" "$OUT"
cp -r "$RELENG/." "$PROFILE/"
ok "copied stock releng profile"

"$HERE/extract-packages.sh" >> "$PROFILE/packages.x86_64"
# releng ships its own list; ours is appended, so de-duplicate.
LC_ALL=C sort -u -o "$PROFILE/packages.x86_64" "$PROFILE/packages.x86_64"
ok "package list merged ($(wc -l < "$PROFILE/packages.x86_64") total)"

# ── branding ──────────────────────────────────────────────────────────────────
sed -i \
    -e "s|^iso_name=.*|iso_name=\"$ISO_NAME\"|" \
    -e "s|^iso_label=.*|iso_label=\"$ISO_LABEL\"|" \
    -e "s|^iso_publisher=.*|iso_publisher=\"$ISO_PUBLISHER\"|" \
    -e "s|^iso_application=.*|iso_application=\"$ISO_APPLICATION\"|" \
    "$PROFILE/profiledef.sh"
ok "branded as $ISO_NAME ($ISO_LABEL)"

# ── the repo itself, so the live session can install from it ──────────────────
AIR="$PROFILE/airootfs"
# An allowlist, not an exclude list. `tar -C "$REPO" -cf - .` emits members as
# "./iso/out/...", which --exclude=iso/out does not match — so the 2.5GB ISO
# from the previous build was being copied into the next one. Naming what goes
# in cannot fail that way.
DEST="$AIR/usr/local/share/hyprland-setup"
install -d "$DEST"
for item in install.sh README.md config; do
    cp -r "$REPO/$item" "$DEST/"
done
install -d "$DEST/iso"
for item in build.sh extract-packages.sh test-boot.sh archinstall.json README.md; do
    cp "$HERE/$item" "$DEST/iso/"
done

# The payload is source, so anything near a megabyte means something large got
# swept in — exactly the failure this replaced.
size_kb=$(du -sk "$DEST" | cut -f1)
[[ $size_kb -lt 5120 ]] || die "embedded payload is ${size_kb}KB — something large was included"
ok "embedded the repo at /usr/local/share/hyprland-setup (${size_kb}KB)"

# ── live user with the desktop config already in place ────────────────────────
# archiso's airootfs/etc/{passwd,shadow,group} are plain files; append rather
# than rewrite so releng's own entries survive.
install -d "$AIR/etc"
for f in passwd shadow group; do
    [[ -f "$RELENG/airootfs/etc/$f" ]] && cp "$RELENG/airootfs/etc/$f" "$AIR/etc/$f"
done
grep -q "^${LIVE_USER}:" "$AIR/etc/passwd" 2>/dev/null || \
    echo "${LIVE_USER}:x:1000:1000::/home/${LIVE_USER}:/bin/bash" >> "$AIR/etc/passwd"
grep -q "^${LIVE_USER}:" "$AIR/etc/group" 2>/dev/null || {
    echo "${LIVE_USER}:x:1000:" >> "$AIR/etc/group"
    sed -i "s/^wheel:x:998:.*/wheel:x:998:${LIVE_USER}/" "$AIR/etc/group" 2>/dev/null || true
}
# No password on live media; sudo is passwordless for the same reason.
grep -q "^${LIVE_USER}:" "$AIR/etc/shadow" 2>/dev/null || \
    echo "${LIVE_USER}::14871::::::" >> "$AIR/etc/shadow"
install -d -m 750 "$AIR/etc/sudoers.d"
echo "${LIVE_USER} ALL=(ALL) NOPASSWD: ALL" > "$AIR/etc/sudoers.d/00-live"
chmod 440 "$AIR/etc/sudoers.d/00-live"
ok "live user '${LIVE_USER}' (no password, passwordless sudo)"

# The desktop config, exactly as install.sh would deploy it.
install -d "$AIR/home/${LIVE_USER}/.config"
cp -r "$REPO/config/." "$AIR/home/${LIVE_USER}/.config/"
install -d "$AIR/etc/skel/.config"
cp -r "$REPO/config/." "$AIR/etc/skel/.config/"
ok "desktop config placed in the live home and /etc/skel"

# install.sh normally generates monitors.lua from the detected displays, but
# live media has no idea what it will boot on. An explicit catch-all is clearer
# than leaning on Hyprland's implicit default, and hyprland.lua treats the file
# as optional either way.
cat > "$AIR/home/${LIVE_USER}/.config/hypr/monitors.lua" <<'EOF'
-- Live media: accept whatever displays are attached.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
EOF
cp "$AIR/home/${LIVE_USER}/.config/hypr/monitors.lua" "$AIR/etc/skel/.config/hypr/monitors.lua"
ok "live monitors.lua (auto-detect)"

# ── autologin straight into Hyprland ──────────────────────────────────────────
install -d "$AIR/etc/systemd/system/getty@tty1.service.d"
cat > "$AIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${LIVE_USER} --noclear %I \$TERM
EOF

cat > "$AIR/home/${LIVE_USER}/.bash_profile" <<'EOF'
# Live media: land in the desktop rather than a shell. uwsm matches how the
# installed system starts Hyprland, so the live session is not a special case.
if [[ -z ${WAYLAND_DISPLAY:-} && $XDG_VTNR == 1 ]]; then
    exec uwsm start -- hyprland.desktop
fi
EOF
ok "tty1 autologin into Hyprland"

# ── a visible way to install ──────────────────────────────────────────────────
install -d "$AIR/usr/local/bin"
cat > "$AIR/usr/local/bin/install-hyprarch" <<'EOF'
#!/usr/bin/env bash
# Installs Arch, then this desktop on top of it.
set -euo pipefail
echo "This installs Arch Linux and the Hyprland desktop onto a disk."
echo "Everything on the target disk will be erased."
echo
read -rp "Continue? [y/N] " a; [[ ${a,,} == y ]] || exit 0
sudo archinstall --config /usr/local/share/hyprland-setup/iso/archinstall.json
echo
echo "Base install done. Applying the desktop config..."
sudo arch-chroot /mnt /usr/local/share/hyprland-setup/install.sh --configs-only
EOF
chmod 755 "$AIR/usr/local/bin/install-hyprarch"
ok "install-hyprarch helper"

# archiso needs every airootfs file's mode declared in profiledef.sh.
#
# The trailing slash on the home directory is load-bearing: mkarchiso only
# recurses when the path ends in "/" (see the chown -fhR branch in
# /usr/bin/mkarchiso). Without it just the directory is chowned and the whole
# desktop config underneath stays root-owned, so the live session cannot write
# to its own ~/.config and Hyprland comes up broken.
python3 - "$PROFILE" "$LIVE_USER" <<'PY'
import re, sys, pathlib
prof, user = pathlib.Path(sys.argv[1]), sys.argv[2]
pd = prof / "profiledef.sh"
s = pd.read_text()
extra = f'''  ["/usr/local/bin/install-hyprarch"]="0:0:755"
  ["/home/{user}/"]="1000:1000:755"
  ["/etc/sudoers.d/00-live"]="0:0:440"
'''
s = re.sub(r'(file_permissions=\(\n)', r'\1' + extra, s, count=1)
pd.write_text(s)
print("    ✓ file permissions declared")
PY

if [[ $ASSEMBLE_ONLY -eq 1 ]]; then
    step "Assembled (not built)"
    echo "    profile: $PROFILE"
    echo "    packages: $(wc -l < "$PROFILE/packages.x86_64")"
    printf '\n    Build it with:  sudo %s\n\n' "$0"
    exit 0
fi

[[ $EUID -eq 0 ]] || die "mkarchiso needs root:  sudo $0"

step "Building"
echo "    This downloads ~2GB and takes 10-30 minutes."
mkarchiso -v -w "$WORK" -o "$OUT" "$PROFILE"

step "Done"
ls -lh "$OUT"/*.iso
