#!/usr/bin/env bash
# Build the starch install ISO.
#
# starch is install media and nothing else. It boots to a text installer that
# runs pacstrap and then lucent's install.sh, exactly as someone installing Arch
# by hand would, and then has no further existence — the installed system is
# plain Arch, updated with pacman, with no custom repo left behind.
#
# Offline: the medium carries every package the install can ask for, as pacman
# repositories under /usr/share/starch. See "the offline repository" below.
#
#     ./build.sh              build (needs root for mkarchiso)
#     ./build.sh --check      verify prerequisites and print the plan, build nothing
#     ./build.sh --assemble    assemble the profile but do not run mkarchiso.
#                              Needs no root, so the overlay can be inspected
#                              and diffed before committing to a 20GB build.
#                              Skips the offline repository, which needs root
#                              to download.
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
# The desktop half lives in its own repository, pinned here as a submodule, so
# an ISO is reproducible from this repo's history: the commit recorded here is
# exactly the config that goes on the medium.
REPO="$HERE/lucent"
RELENG="${RELENG:-/usr/share/archiso/configs/releng}"
WORK="${WORK:-$HERE/work}"
PROFILE="$WORK/profile"
OUT="${OUT:-$HERE/out}"
# Where tools/build-aur.sh leaves the packages that are not in the official
# repositories.
LOCALREPO="${LOCALREPO:-$HERE/localrepo}"
LOCALDB=starch-local

ISO_NAME="starch"
ISO_LABEL="STARCH_$(date +%Y%m)"
ISO_PUBLISHER="starch <https://github.com/paulbeavers/lucent>"
ISO_APPLICATION="starch — Arch + Hyprland install medium"

C_B=$'\e[34m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_0=$'\e[0m'
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$1"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$1"; }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_0" "$1"; }
info() { printf '      %s\n' "$1"; }
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
[[ -f $REPO/install.sh ]] || die "the lucent submodule is empty — run: git submodule update --init"

# The desktop half is a submodule, and three things can disagree about which
# version that is:
#
#   1. the commit recorded in starch's history
#   2. the files actually checked out in lucent/
#   3. what is on the branch at origin
#
# `git pull` updates 1 and never 2, and knows nothing about a second clone of
# the same repo somewhere else. This build reads 2 — the files on disk. So a
# pull can leave everything looking current while the ISO is built from a
# checkout that is weeks old, which has happened, silently, and cost a build.
#
# Refuse when 2 disagrees with 1: that combination is never deliberate, and the
# result would be an ISO that no commit describes. Only mention it when origin
# has moved on, because building an older pin on purpose is a reasonable thing
# to do.
if [[ -d $REPO/.git || -f $REPO/.git ]] && command -v git >/dev/null; then
    pinned="$(git -C "$HERE" rev-parse HEAD:lucent 2>/dev/null || true)"
    actual="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"

    if [[ -n $pinned && -n $actual && $pinned != "$actual" ]]; then
        die "lucent is checked out at ${actual:0:7}, but this commit records ${pinned:0:7}.
    The ISO would be built from files no commit describes. Pick one:
      git submodule update lucent                 # use the recorded ${pinned:0:7}
      git submodule update --remote lucent && git add lucent && git commit
                                                           # take the newest and record it"
    fi

    if [[ -n ${STARCH_SKIP_REMOTE_CHECK:-} ]]; then
        :
    elif timeout 20 git -C "$REPO" fetch -q origin 2>/dev/null; then
        remote="$(git -C "$REPO" rev-parse origin/HEAD 2>/dev/null \
                  || git -C "$REPO" rev-parse origin/main 2>/dev/null || true)"
        if [[ -n $remote && -n $actual && $remote != "$actual" ]] \
           && git -C "$REPO" merge-base --is-ancestor "$actual" "$remote" 2>/dev/null; then
            behind="$(git -C "$REPO" rev-list --count "$actual".."$remote" 2>/dev/null || echo '?')"
            warn "lucent is $behind commit(s) behind origin — building ${actual:0:7}"
            git -C "$REPO" log --oneline "$actual".."$remote" 2>/dev/null | sed 's/^/      /'
            info "to take them:  git submodule update --remote lucent && git add lucent && git commit"
        fi
    fi

    if [[ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]]; then
        warn "lucent has uncommitted changes — the ISO will contain them"
    fi
    ok "lucent at ${actual:0:7}$(git -C "$REPO" log -1 --format=' (%s)' 2>/dev/null)"
fi
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
    echo "    tty1         : root autologin, straight into the installer"
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


# ── what the medium itself runs ───────────────────────────────────────────────
# The live system is releng plus the installer's tools. The desktop does not
# run here and its packages are not installed here; they travel as package
# files in the offline repository and are installed onto the target by
# pacstrap and install.sh, the way they would be from a mirror.
#
#   python-textual         the installer's front end
#   kmscon, ttf-jetbrains-mono
#                          the console it draws on: real fonts, full colour,
#                          sized to the panel. Not the Nerd Font build, which
#                          is 230MB; the UI uses only glyphs the plain one has.
#   arch-install-scripts   pacstrap, genfstab, arch-chroot
#   cryptsetup, btrfs-progs, gptfdisk, dosfstools, e2fsprogs
#                          the disk work
#   plymouth               the live boot's splash, and the theme the installer
#                          copies onto the target
#   terminus-font          a console font a retina panel can be read at
#   networkmanager         so the live console can join a network with nmtui
#                          when someone wants one; the install never needs it
#   broadcom-wl-dkms, dkms, linux-headers
#                          the wl driver for the live session, which
#                          broadcom-live picks at boot. Without it a 2013
#                          retina MacBook Pro has no wireless on the medium.
printf '%s\n' \
    python-textual \
    kmscon ttf-jetbrains-mono \
    arch-install-scripts \
    cryptsetup btrfs-progs gptfdisk dosfstools e2fsprogs parted \
    plymouth terminus-font \
    networkmanager \
    broadcom-wl-dkms dkms linux-headers \
    >> "$PROFILE/packages.x86_64"
LC_ALL=C sort -u -o "$PROFILE/packages.x86_64" "$PROFILE/packages.x86_64"
ok "live package list ($(wc -l < "$PROFILE/packages.x86_64") packages)"

# ── the local repo, for what the AUR has and Arch does not ────────────────────
# One package: the Broadcom bluetooth firmware for Intel MacBooks.
# tools/build-aur.sh builds it into localrepo/. The medium does not install it;
# it rides along as a repository the installer offers to pacstrap on Apple
# hardware.
#
# Check for each one by name. "the directory is not empty" was enough when
# there was a single package in it; with more than one, a half-built repo would
# otherwise get past this and fail much later as an unresolvable target.
aur_missing=()
for _p in $(sed -n '/^AUR_PACKAGES=(/,/^)/p' "$HERE/tools/build-aur.sh" \
            | sed '1d;$d' | awk '{print $1}'); do
    compgen -G "$LOCALREPO/$_p-*.pkg.tar.*" >/dev/null || aur_missing+=("$_p")
done
if [[ ${#aur_missing[@]} -gt 0 ]]; then
    if [[ $ASSEMBLE_ONLY -eq 1 ]]; then
        warn "not built: ${aur_missing[*]} — run ./tools/build-aur.sh before the real build"
    else
        die "not built: ${aur_missing[*]}. Run:  ./tools/build-aur.sh"
    fi
fi

# ── branding ──────────────────────────────────────────────────────────────────
sed -i \
    -e "s|^iso_name=.*|iso_name=\"$ISO_NAME\"|" \
    -e "s|^iso_label=.*|iso_label=\"$ISO_LABEL\"|" \
    -e "s|^iso_publisher=.*|iso_publisher=\"$ISO_PUBLISHER\"|" \
    -e "s|^iso_application=.*|iso_application=\"$ISO_APPLICATION\"|" \
    "$PROFILE/profiledef.sh"
ok "branded as $ISO_NAME ($ISO_LABEL)"

# The boot menu. Left alone it says "Arch Linux install medium" for fifteen
# seconds before anything of ours appears — which is the first thing anyone
# sees, and not what they booted. The entries are renamed and the wait cut to
# three seconds; holding a key still stops it, and the speech entry is still
# there for anyone who needs it.
sed -i -E 's|^title(\s+)Arch Linux install medium|title\1starch install medium|' \
    "$PROFILE"/efiboot/loader/entries/*.conf
sed -i -E 's|^MENU LABEL Arch Linux install medium|MENU LABEL starch install medium|' \
    "$PROFILE"/syslinux/*.cfg
sed -i -E 's|^timeout[[:space:]]+[0-9]+|timeout 3|' "$PROFILE/efiboot/loader/loader.conf"
sed -i -E 's|^TIMEOUT[[:space:]]+[0-9]+|TIMEOUT 30|' "$PROFILE"/syslinux/archiso_head.cfg
ok "boot menu says starch, and waits 3 seconds instead of 15"

# ── the desktop setup, which the installer runs in the target ─────────────────
AIR="$PROFILE/airootfs"
# An allowlist, not an exclude list. An earlier version excluded build output by
# name and the pattern silently did not match, so a 2.5GB ISO from the previous
# build was copied into the next one. Naming what goes in cannot fail that way.
#
# Only the desktop repo ships. starch's own build tooling has no use on the
# installed machine, and the point of starch is that nothing of it remains.
DEST="$AIR/usr/local/share/lucent"
install -d "$DEST"
#
# Adding a top-level directory to lucent means adding it here too.
# wallpapers/ was missed on its first outing: install.sh copies the images out
# of its own directory, the guard around that is a compgen test, so a missing
# wallpapers/ failed silently and every installed machine came up with no
# wallpaper at all.
for item in install.sh README.md config lucent-config wallpapers; do
    [[ -e $REPO/$item ]] || die "lucent has no $item — the embedded payload would be incomplete"
    cp -r "$REPO/$item" "$DEST/"
done

# Python bytecode from running the settings app out of a checkout. It is
# regenerated on first run and it names paths that will not exist here, so it
# is dead weight in the squashfs at best.
find "$DEST" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true

# The payload is source, so anything near a megabyte means something large got
# swept in — exactly the failure this replaced.
size_kb=$(du -sk "$DEST" | cut -f1)
[[ $size_kb -lt 5120 ]] || die "embedded payload is ${size_kb}KB — something large was included"
ok "embedded the repo at /usr/local/share/lucent (${size_kb}KB)"

# ── boot splash ───────────────────────────────────────────────────────────────
# The splash is starch's, not the desktop's: lucent also runs on
# machines starch never installed, and has no business rebuilding their boot.
# It goes into the airootfs for the live boot, and the installer copies the
# theme from here onto the target, so both boots wear the same one.
PLY="$AIR/usr/share/plymouth/themes/starch"
install -d "$PLY"
cp "$HERE/splash/theme/"* "$PLY/"
install -d "$AIR/etc/plymouth"
cat > "$AIR/etc/plymouth/plymouthd.conf" <<'PLYCONF'
# Generated by build.sh.
[Daemon]
Theme=starch
ShowDelay=0
PLYCONF

# The hook has to load before anything draws, so it goes straight after udev.
# Without it plymouthd never starts and the boot is `quiet` with no splash —
# the worst of both, and silent about why.
ARCHISO_MKINITCPIO="$PROFILE/airootfs/etc/mkinitcpio.conf.d/archiso.conf"
if grep -qE '^HOOKS=.*\bplymouth\b' "$ARCHISO_MKINITCPIO"; then
    :
else
    sed -i -E 's/^(HOOKS=\([^)]*\budev\b)/\1 plymouth/' "$ARCHISO_MKINITCPIO"
fi
grep -qE '^HOOKS=.*\bplymouth\b' "$ARCHISO_MKINITCPIO" \
    || die "could not add the plymouth hook to archiso.conf"

# And the kernel has to be told to be quiet and to splash. Both boot paths get
# it: systemd-boot for UEFI, syslinux for BIOS. Escape still shows the text, so
# nothing is actually hidden from anyone who wants it.
#
# loglevel=3 silences the kernel; rd.udev.log_level=3 silences udev inside the
# initramfs, which otherwise prints over the splash before it has faded in.
SPLASH_ARGS="quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0"
#
# Not the accessibility entry. Someone booting that has chosen a screen reader
# over a screen, and `quiet splash` would take away the console output it is
# there to read aloud — a splash is worth nothing to them and the output is
# worth everything. Matching on the line rather than the filename, since the
# BIOS entries share one file.
splash_n=0
for entry in "$PROFILE"/efiboot/loader/entries/*.conf; do
    [[ -f $entry ]] || continue
    grep -q ' splash' "$entry" && continue
    grep -q 'accessibility=on' "$entry" && continue
    sed -i -E "s|^(options .*archisosearchuuid=%ARCHISO_UUID%)|\1 $SPLASH_ARGS|" "$entry"
    splash_n=$((splash_n + 1))
done
for cfg in "$PROFILE"/syslinux/archiso_sys*.cfg "$PROFILE"/syslinux/archiso_pxe*.cfg; do
    [[ -f $cfg ]] || continue
    # Per line, because one file holds both the ordinary and the speech entry.
    before=$(grep -c ' splash' "$cfg" || true)
    sed -i -E "/accessibility=on/!s|^(APPEND .*archisosearchuuid=%ARCHISO_UUID%)|\1 $SPLASH_ARGS|" "$cfg"
    after=$(grep -c ' splash' "$cfg" || true)
    splash_n=$((splash_n + after - before))
done
[[ $splash_n -gt 0 ]] || die "no boot entries picked up the splash arguments"
ok "boot splash: theme, initramfs hook and $splash_n boot entries"

# ── a boot with nothing to wait for ───────────────────────────────────────────
# The releng profile is a general-purpose Arch medium and enables things an
# installer for a laptop has no use for. Two of them can stop the boot dead
# while a progress line counts down, which is precisely the "A start job is
# running for..." screen that made an earlier build look broken:
#
#   cloud-init          five services that exist to configure a cloud instance
#                       from metadata, and which pull in network-online.target
#                       to go looking for it. There is no metadata server.
#   networkd-wait-online  blocks network-online.target until a link is up, for
#                       up to two minutes, on a medium that installs offline.
#   time-wait-sync      blocks until the clock is synchronised with NTP, which
#                       needs the network that is not there.
#
# Networking still comes up; nothing waits for it. The install reads its
# packages from the medium and never needs it.
for unit in \
    cloud-init.target.wants/cloud-config.service \
    cloud-init.target.wants/cloud-final.service \
    cloud-init.target.wants/cloud-init-local.service \
    cloud-init.target.wants/cloud-init-main.service \
    cloud-init.target.wants/cloud-init-network.service \
    network-online.target.wants/systemd-networkd-wait-online.service \
    sysinit.target.wants/systemd-time-wait-sync.service
do
    rm -f "$AIR/etc/systemd/system/$unit"
done
ok "cloud-init and the wait-for-network units are off"

# Plymouth hands over rather than blinking out. Without --retain-splash the
# splash is torn down at multi-user.target and the screen is bare until the
# installer paints, which on a slow machine is a second of black. With it the
# last frame stays in the framebuffer until something draws over it.
install -d "$AIR/etc/systemd/system/plymouth-quit.service.d"
cat > "$AIR/etc/systemd/system/plymouth-quit.service.d/10-retain-splash.conf" <<'DROPIN'
# Generated by build.sh.
[Service]
ExecStart=
ExecStart=-/usr/bin/plymouth quit --retain-splash
DROPIN
ok "the splash stays up until something draws over it"

# ── tty1 is the installer, on kmscon ──────────────────────────────────────────
# kmscon replaces the Linux console on tty1: TrueType fonts at a size worked
# out from the panel, full colour, and the mouse. The raw console has a bitmap
# font, sixteen CGA colours and no scaling, which is what made the first text
# installer unreadable on a retina MacBook. starch-session runs in place of a
# login prompt: the installer, then a root shell.
#
# kmsconvt@.service has OnFailure=getty@%i.service. If kmscon cannot start on
# some machine, tty1 falls back to releng's root autologin, and .zlogin below
# starts the installer on the plain console, where starch-install sets a
# readable font and palette itself. Only tty1: the other VTs stay ordinary
# root consoles, because enabling kmsconvt@ as autovt@ would take them all.
install -d "$AIR/etc/kmscon"
cat > "$AIR/etc/kmscon/kmscon.conf" <<'KMSCON'
# Written by starch's build.sh.
font-name=JetBrains Mono
term=xterm-256color
no-issue
mouse
# Catppuccin Mocha, as everywhere else in starch.
palette=custom
palette-black=30,30,46
palette-red=243,139,168
palette-green=166,227,161
palette-yellow=249,226,175
palette-blue=137,180,250
palette-magenta=245,194,231
palette-cyan=148,226,213
palette-light-grey=186,194,222
palette-dark-grey=88,91,112
palette-light-red=243,139,168
palette-light-green=166,227,161
palette-light-yellow=249,226,175
palette-light-blue=137,180,250
palette-light-magenta=245,194,231
palette-light-cyan=148,226,213
palette-white=205,214,244
palette-foreground=205,214,244
palette-background=30,30,46
# The installer rewrites these when a layout other than US is chosen, and
# restarts kmscon so the keys typed into it match the keyboard.
xkb-layout=us
KMSCON
install -d "$AIR/etc/systemd/system/kmsconvt@tty1.service.d" \
           "$AIR/etc/systemd/system/getty.target.wants"
cat > "$AIR/etc/systemd/system/kmsconvt@tty1.service.d/starch.conf" <<'DROPIN'
# Generated by build.sh: the installer instead of a login prompt.
[Service]
ExecStart=
ExecStart=/usr/bin/kmscon --vt=%I --no-switchvt --login -- /usr/local/bin/starch-session
DROPIN
ln -sf /usr/lib/systemd/system/kmsconvt@.service \
    "$AIR/etc/systemd/system/getty.target.wants/kmsconvt@tty1.service"

# The fallback: releng's root autologin on the plain console. Not exec, so
# quitting the installer leaves the shell. STARCH_SHELL guards against
# re-entry from a nested login shell, and from starch-session's own shell.
cat >> "$AIR/root/.zlogin" <<'ZLOGIN'

# starch: tty1 opens the installer when kmscon could not. Quitting leaves this shell.
if [[ $(tty) == /dev/tty1 && -z ${STARCH_SHELL:-} ]]; then
    export STARCH_SHELL=1
    starch-install
    print "\n  starch-install  runs the installer again.\n"
fi
ZLOGIN
ok "tty1 runs the installer on kmscon, the plain console behind it"

# ── live wireless ─────────────────────────────────────────────────────────────
# The install needs no network, but the live console is still a working Arch
# medium, and a MacBook whose card wants wl has no wireless on it unless the
# driver is chosen before the network comes up. broadcom-live does that from
# the same list install.sh uses for the installed system.
install -d "$AIR/usr/local/lib/starch"
install -m 755 "$HERE/installer/broadcom-live" "$AIR/usr/local/lib/starch/broadcom-live"
install -d "$AIR/etc/systemd/system/multi-user.target.wants"
cat > "$AIR/etc/systemd/system/starch-broadcom.service" <<'EOF'
[Unit]
Description=Select the Broadcom wireless driver for this machine
DefaultDependencies=no
After=systemd-udevd.service
Before=iwd.service systemd-networkd.service NetworkManager.service network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/starch/broadcom-live

[Install]
WantedBy=multi-user.target
EOF
ln -sf ../starch-broadcom.service \
    "$AIR/etc/systemd/system/multi-user.target.wants/starch-broadcom.service"
ok "live session picks its own wireless driver"

# ── stop the image rebuilding the linker cache on every boot ──────────────────
# ldconfig.service is "Rebuild Dynamic Linker Cache", and it is conditioned on
#
#   ConditionNeedsUpdate=|/etc
#
# which is true whenever /usr is newer than the .updated stamp in /etc. A fresh
# airootfs has no such stamp, so the condition holds on every boot of every
# copy of the medium — and ldconfig walking every library through a compressed
# squashfs takes upwards of forty seconds, shown on the details screen as
#
#   [ * ] A start job is running for Rebuild Dynamic Linker Cache (40s / no limit)
#
# systemd-update-done writes the stamps with /usr's own timestamp, which is
# exactly what the condition compares against. ldconfig runs first so the cache
# being stamped as current is also correct.
#
# customize_airootfs.sh is the only hook that runs inside the chroot, after
# everything else has finished touching /etc. mkarchiso warns that it is
# deprecated and deletes it after running, so nothing of it reaches the image.
install -d "$AIR/root"
cat > "$AIR/root/customize_airootfs.sh" <<'CUSTOMIZE'
#!/usr/bin/env bash
# Run by mkarchiso inside the airootfs, then deleted. See build.sh.
#
# Deliberately cannot fail the build. The worst case without any of this is a
# slower boot or a console that has to start NetworkManager by hand.
set -u

# ── networking: NetworkManager, so nmtui works ───────────────────────────────
# archiso ships iwd + systemd-networkd. nmtui is the friendliest way onto a
# network from a console, and it is NetworkManager's.
#
# systemctl rather than hand-made .wants symlinks: NetworkManager carries
# Alias= and Also= units for D-Bus activation, and symlinks miss them.
systemctl enable  --no-reload NetworkManager.service \
    || echo "  could not enable NetworkManager"
systemctl disable --no-reload iwd.service systemd-networkd.service \
                              systemd-networkd.socket >/dev/null 2>&1 || true

# Not optional, and not redundant: `systemctl enable NetworkManager.service`
# carries Also=NetworkManager-wait-online.service, so the line above *creates*
# network-online.target.wants/NetworkManager-wait-online.service as a side
# effect. That is the family of unit that put a ninety second countdown on the
# screen. It has to be taken back off, and it has to happen after the enable.
systemctl disable --no-reload NetworkManager-wait-online.service >/dev/null 2>&1 || true

# getty@tty1 is enabled by systemd's preset, and kmsconvt@tty1 conflicts with
# it. Both wanted by getty.target is a transaction that can go either way, so
# getty@tty1 goes; kmscon's OnFailure= still starts it when kmscon cannot run.
rm -f /etc/systemd/system/getty.target.wants/getty@tty1.service

# /etc/resolv.conf is a symlink to resolved's stub. NetworkManager's default
# backend wants to write that file itself, will not overwrite a symlink, and
# the result is an address and a route and no name resolution at all — which
# is exactly what the first medium to ship with NetworkManager did.
install -d /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/dns-systemd-resolved.conf <<'NMDNS'
# Written by the starch build. resolv.conf is resolved's stub, so DNS has to
# go to resolved over D-Bus rather than into a file NetworkManager cannot
# write.
[main]
dns=systemd-resolved
NMDNS

ldconfig || echo "  ldconfig failed; the first boot will rebuild the cache"
if [ -x /usr/lib/systemd/systemd-update-done ]; then
    /usr/lib/systemd/systemd-update-done || echo "  could not write the .updated stamps"
else
    echo "  systemd-update-done is missing; ldconfig.service will run at boot"
fi
exit 0
CUSTOMIZE
chmod 755 "$AIR/root/customize_airootfs.sh"
ok "linker cache stamped at build time, NetworkManager for the console"

# ── the installer ─────────────────────────────────────────────────────────────
# The launcher on PATH; the front end, back end and kmscon session beside
# broadcom-live, where nobody runs them by hand.
install -d "$AIR/usr/local/bin" "$AIR/usr/local/lib/starch/starch_installer"
install -m 755 "$HERE/installer/starch-install" "$AIR/usr/local/bin/starch-install"
install -m 755 "$HERE/installer/starch-session" "$AIR/usr/local/bin/starch-session"
install -m 755 "$HERE/installer/starch-backend" "$AIR/usr/local/lib/starch/starch-backend"
for f in __init__.py __main__.py app.py system.py app.tcss; do
    install -m 644 "$HERE/installer/starch_installer/$f" "$AIR/usr/local/lib/starch/starch_installer/$f"
done
ok "installer: Textual front end, back end, kmscon session"

# archiso needs every airootfs file's mode declared in profiledef.sh: it copies
# the airootfs with --no-preserve=mode, so anything undeclared arrives as 644
# and a script silently does nothing.
python3 - "$PROFILE" <<'PY'
import re, sys, pathlib
pd = pathlib.Path(sys.argv[1]) / "profiledef.sh"
s = pd.read_text()
extra = '''  ["/usr/local/bin/starch-install"]="0:0:755"
  ["/usr/local/bin/starch-session"]="0:0:755"
  ["/usr/local/lib/starch/starch-backend"]="0:0:755"
  ["/usr/local/lib/starch/broadcom-live"]="0:0:755"
  ["/usr/local/share/lucent/install.sh"]="0:0:755"
  ["/usr/local/share/lucent/lucent-config/lucent-config"]="0:0:755"
  ["/usr/local/share/lucent/config/hypr/scripts/"]="0:0:755"
'''
s = re.sub(r'(file_permissions=\(\n)', r'\1' + extra, s, count=1)
pd.write_text(s)
print("    ✓ file permissions declared")
PY

if [[ $ASSEMBLE_ONLY -eq 1 ]]; then
    step "Assembled (not built)"
    echo "    profile: $PROFILE"
    echo "    packages: $(wc -l < "$PROFILE/packages.x86_64") on the live system"
    echo "    offline repository: not assembled (needs root to download)"
    printf '\n    Build it with:  sudo %s\n\n' "$0"
    exit 0
fi

[[ $EUID -eq 0 ]] || die "mkarchiso needs root:  sudo $0"

# ── the offline repository ────────────────────────────────────────────────────
# Every package the installer can ask for, with everything they depend on,
# downloaded into the airootfs beside the official databases they were resolved
# against. On the medium, pacstrap and install.sh read them through file://
# servers and check every signature against those databases, exactly as they
# would from a mirror: the packages are the same files, frozen at build time.
#
# What can be asked for:
#   - what the installer pacstraps, for every machine it might meet: both
#     microcode packages, btrfs-progs, the splash and the console font
#   - everything install.sh can install, read out of it by
#     extract-packages.sh — every GPU vendor's drivers, the Broadcom driver
#     and its headers, because which of them a machine needs is install.sh's
#     decision on that machine, not this build's
#
# A fresh database directory, so pacman sees nothing as installed and
# downloads the whole dependency tree. The packages from localrepo/ resolve
# too, and are kept in their own repository on the medium rather than mixed
# into the official one.
step "Downloading the offline repository"
REPO_DIR="$AIR/usr/share/starch/repo"
LOCAL_DIR="$AIR/usr/share/starch/local"
DBPATH="$WORK/offline-db"
CONF="$WORK/offline-pacman.conf"
rm -rf "$REPO_DIR" "$LOCAL_DIR" "$DBPATH"
install -d "$REPO_DIR" "$LOCAL_DIR" "$DBPATH"
{
    # Not the build host's [options]: an IgnorePkg or CacheDir there would
    # quietly change what lands on the medium.
    printf '[options]\nArchitecture = auto\nSigLevel = Required DatabaseOptional\n'
    printf 'ParallelDownloads = 5\n'
    printf '\n[core]\nInclude = /etc/pacman.d/mirrorlist\n'
    printf '\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n'
    printf '\n[%s]\nSigLevel = Optional TrustAll\nServer = file://%s\n' "$LOCALDB" "$LOCALREPO"
} > "$CONF"

offline_pkgs=(base linux linux-firmware sudo networkmanager dosfstools
              intel-ucode amd-ucode btrfs-progs plymouth terminus-font)
mapfile -t -O "${#offline_pkgs[@]}" offline_pkgs < <("$HERE/extract-packages.sh")

pacman --config "$CONF" --dbpath "$DBPATH" -Sy >/dev/null \
    || die "could not sync package databases for the offline repository"
pacman --config "$CONF" --dbpath "$DBPATH" --cachedir "$REPO_DIR" \
       -Sw --noconfirm "${offline_pkgs[@]}" \
    || die "could not download the offline repository"
cp "$DBPATH/sync/core.db" "$DBPATH/sync/extra.db" "$REPO_DIR/"

# The AUR packages go to their own repository, with their own database.
for f in "$LOCALREPO"/*.pkg.tar.*; do
    [[ $f == *.sig ]] && continue
    rm -f "$REPO_DIR/$(basename "$f")"
done
cp "$LOCALREPO"/*.pkg.tar.* "$LOCAL_DIR/"
# repo-add writes starch-local.db as a symlink to the .db.tar.zst; cp follows
# it, so the medium gets a plain file under the name pacman asks for.
cp "$LOCALREPO/$LOCALDB".db "$LOCALREPO/$LOCALDB".files "$LOCAL_DIR/" \
    || die "localrepo/ has no $LOCALDB database — run ./tools/build-aur.sh"
rm -f "$REPO_DIR"/*.part

n=$(ls "$REPO_DIR"/*.pkg.tar.* 2>/dev/null | grep -vc '\.sig$')
size=$(du -sh "$REPO_DIR" | cut -f1)
ok "offline repository: $n packages, $size"
ok "starch-local: $(ls "$LOCAL_DIR"/*.pkg.tar.* | grep -vc '\.sig$') package(s)"

step "Building"
echo "    This downloads ~2GB and takes 10-30 minutes."
mkarchiso -v -w "$WORK" -o "$OUT" "$PROFILE"

step "Done"
ls -lh "$OUT"/*.iso
