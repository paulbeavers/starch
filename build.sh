#!/usr/bin/env bash
# Build the starch install ISO.
#
# starch is install media and nothing else. It boots to an installer, lays down
# Arch plus this Hyprland setup, and then has no further existence — the
# installed system is plain Arch, updated with pacman, with no custom repo or
# branding left behind.
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
# The desktop half lives in its own repository, pinned here as a submodule, so
# an ISO is reproducible from this repo's history: the commit recorded here is
# exactly the config that goes on the medium.
REPO="$HERE/hyprland-setup"
RELENG="${RELENG:-/usr/share/archiso/configs/releng}"
WORK="${WORK:-$HERE/work}"
PROFILE="$WORK/profile"
OUT="${OUT:-$HERE/out}"
# Where tools/build-aur.sh leaves the packages that are not in the official
# repositories.
LOCALREPO="${LOCALREPO:-$HERE/localrepo}"
LOCALDB=starch-local

# Live session identity.
LIVE_USER="${LIVE_USER:-live}"
ISO_NAME="starch"
ISO_LABEL="STARCH_$(date +%Y%m)"
ISO_PUBLISHER="starch <https://github.com/paulbeavers/hyprland-setup>"
ISO_APPLICATION="starch — Arch + Hyprland install medium"

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
[[ -f $REPO/install.sh ]] || die "the hyprland-setup submodule is empty — run: git submodule update --init"

# The desktop half is a submodule, and three things can disagree about which
# version that is:
#
#   1. the commit recorded in starch's history
#   2. the files actually checked out in hyprland-setup/
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
    pinned="$(git -C "$HERE" rev-parse HEAD:hyprland-setup 2>/dev/null || true)"
    actual="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"

    if [[ -n $pinned && -n $actual && $pinned != "$actual" ]]; then
        die "hyprland-setup is checked out at ${actual:0:7}, but this commit records ${pinned:0:7}.
    The ISO would be built from files no commit describes. Pick one:
      git submodule update hyprland-setup                 # use the recorded ${pinned:0:7}
      git submodule update --remote hyprland-setup && git add hyprland-setup && git commit
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
            warn "hyprland-setup is $behind commit(s) behind origin — building ${actual:0:7}"
            git -C "$REPO" log --oneline "$actual".."$remote" 2>/dev/null | sed 's/^/      /'
            info "to take them:  git submodule update --remote hyprland-setup && git add hyprland-setup && git commit"
        fi
    fi

    if [[ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]]; then
        warn "hyprland-setup has uncommitted changes — the ISO will contain them"
    fi
    ok "hyprland-setup at ${actual:0:7}$(git -C "$REPO" log -1 --format=' (%s)' 2>/dev/null)"
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
    echo "    live user    : $LIVE_USER (autologin, straight into the installer)"
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

# Calamares installs by copying the live filesystem onto the target, so the ISO
# has to contain the finished system: the desktop packages ship here, not on
# the other side of a download. That is what makes the install fast and lets it
# work with no network at all.
#
# The desktop list comes from install.sh via extract-packages.sh, so the two
# cannot drift — adding a package to install.sh puts it on the ISO too.
desktop_pkgs="$("$HERE/extract-packages.sh")" \
    || die "could not read the desktop package list from install.sh"
printf '%s\n' "$desktop_pkgs" >> "$PROFILE/packages.x86_64"
desktop_n=$(printf '%s\n' "$desktop_pkgs" | wc -l)

# Installer tooling, and the graphical canvas Calamares is drawn on. cage is a
# kiosk compositor: one application, full screen, no desktop around it.
printf '%s\n' \
    calamares \
    cage qt6-wayland \
    networkmanager \
    archinstall arch-install-scripts dialog \
    parted gptfdisk dosfstools e2fsprogs btrfs-progs exfatprogs ntfs-3g \
    git jq \
    >> "$PROFILE/packages.x86_64"
LC_ALL=C sort -u -o "$PROFILE/packages.x86_64" "$PROFILE/packages.x86_64"
ok "package list ($(wc -l < "$PROFILE/packages.x86_64") total, ${desktop_n} from install.sh)"

# ── the local repo that carries Calamares ─────────────────────────────────────
# A few packages are not in the official repositories — the installer itself,
# and firmware for Broadcom wireless. tools/build-aur.sh builds them into
# localrepo/ and the profile installs them from there.
# Check for each one by name. "the directory is not empty" was enough when
# there was a single package in it; with more than one, a half-built repo would
# otherwise get past this and fail much later, inside pacstrap, as an
# unresolvable target.
aur_missing=()
for _p in $(sed -n '/^AUR_PACKAGES=(/,/^)/p' "$HERE/tools/build-aur.sh" \
            | sed '1d;$d' | awk '{print $1}'); do
    compgen -G "$LOCALREPO/$_p-*.pkg.tar.*" >/dev/null || aur_missing+=("$_p")
done

if [[ -d $LOCALREPO && ${#aur_missing[@]} -eq 0 ]]; then
    cat >> "$PROFILE/pacman.conf" <<EOF

[$LOCALDB]
SigLevel = Optional TrustAll
Server = file://$LOCALREPO
EOF
    ok "local repo wired in ($(ls -1 "$LOCALREPO"/*.pkg.tar.* 2>/dev/null | wc -l) package(s))"

elif [[ $ASSEMBLE_ONLY -eq 1 ]]; then
    # Assembling is for inspecting the profile; not having built Calamares yet
    # is worth saying, but it is not a reason to refuse to lay the profile out.
    warn "not built: ${aur_missing[*]} — run ./tools/build-aur.sh before the real build"
else
    die "not built: ${aur_missing[*]:-<none>}. Run:  ./tools/build-aur.sh"
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

# ── the repo itself, so the live session can install from it ──────────────────
AIR="$PROFILE/airootfs"
# An allowlist, not an exclude list. An earlier version excluded build output by
# name and the pattern silently did not match, so a 2.5GB ISO from the previous
# build was copied into the next one. Naming what goes in cannot fail that way.
#
# Only the desktop repo ships. starch's own build tooling has no use on the
# installed machine, and the point of starch is that nothing of it remains.
DEST="$AIR/usr/local/share/hyprland-setup"
install -d "$DEST"
for item in install.sh README.md config starch-config; do
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
ok "embedded the repo at /usr/local/share/hyprland-setup (${size_kb}KB)"

# ── boot splash ───────────────────────────────────────────────────────────────
# The splash is starch's, not the desktop's: hyprland-setup also runs on
# machines starch never installed, and has no business rebuilding their boot.
# It goes into the airootfs directly, because the *live* boot has to splash
# too. That also means the clone inherits it: the installed system is a copy of
# this filesystem, so the theme and the choice of theme come across as they are.
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
# Networking still comes up; nothing waits for it. The install is a copy of
# this filesystem and never needed it.
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

# ── live user with the desktop config already in place ────────────────────────
# The live user is declared to systemd-sysusers rather than written straight
# into /etc/{passwd,group,shadow}.
#
# Those three are backup files of the "filesystem" package. The profile's
# airootfs is copied into place *before* pacstrap runs, so anything written
# here is what the package hooks find when they run. Releng ships a one-line
# passwd (it only changes root's shell) and no group file at all. Writing a
# group file containing just the live user replaced the real group database
# while /etc/gshadow stayed as the package shipped it, and the two then
# disagreed: the pacstrap sysusers hook died on "/etc/gshadow: Group root
# already exists" and stopped before creating any system user.
#
# The cost of that was not obvious. With no "systemd-network" user,
# systemd-networkd fails at 217/USER and never brings up a link, so the live
# ISO has no network — and archinstall answers a failed connectivity check by
# opening its wifi prompt, finding no wifi device, and returning 0 without
# installing anything. A silent, successful-looking install of nothing.
#
# A sysusers drop-in cooperates with the package files instead of replacing
# them. zz- so it sorts last: wheel has to exist (basic.conf, GID 998) before
# anyone can be added to it.
install -d "$AIR/etc/sysusers.d"
# 1500, not 1000. The live user exists only on the medium, but it takes a UID
# there, and the account the installer creates gets the next one free — the
# first Calamares install made its user 1001, which is not what someone setting
# up their own machine expects to see. Out of the way, and 1000 is left for
# them.
cat > "$AIR/etc/sysusers.d/zz-live.conf" <<EOF
g ${LIVE_USER} 1500
u ${LIVE_USER} 1500:${LIVE_USER} "starch live user" /home/${LIVE_USER} /bin/bash
m ${LIVE_USER} wheel
EOF
# sysusers locks the account, which autologin does not care about: agetty
# --autologin does not authenticate. Everything that needs privilege goes
# through sudo, which is passwordless here for the same reason.
install -d -m 750 "$AIR/etc/sudoers.d"
echo "${LIVE_USER} ALL=(ALL) NOPASSWD: ALL" > "$AIR/etc/sudoers.d/00-live"
chmod 440 "$AIR/etc/sudoers.d/00-live"
ok "live user '${LIVE_USER}' declared to sysusers (passwordless sudo)"

# The overlay must not carry a user or group database of its own. Replacing one
# of these disables every system user on the ISO and says nothing about it, so
# fail the build here rather than ship it.
for f in passwd group shadow gshadow; do
    [[ -e "$AIR/etc/$f" ]] || continue
    cmp -s "$AIR/etc/$f" "$RELENG/airootfs/etc/$f" && continue
    die "the profile ships its own /etc/$f — that breaks the pacstrap sysusers hook"
done
ok "user and group databases left to the packages"

# ── the live session is the finished desktop ──────────────────────────────────
# The medium boots into the same desktop it installs, with the installer
# opening on top of it — the way Ubuntu and most others do it. Two reasons
# beyond looking better than a full-screen installer on a 5K monitor: you can
# see what you are about to install before committing a disk to it, and the
# installer becomes a window on a compositor that honours geometry, which is
# the thing cage could never do.
#
# The config is copied rather than installed. install.sh --for-user would also
# detect monitors and a GPU, and it would be detecting this build machine's,
# which is exactly wrong for a medium that boots on someone else's hardware.
# monitors.lua and gpu.lua are deliberately absent: hyprland.lua treats both as
# optional and Hyprland's own detection is right when there is nothing to say.
LIVE_HOME="$AIR/home/$LIVE_USER"
install -d "$LIVE_HOME/.config"
cp -r "$REPO/config/." "$LIVE_HOME/.config/"
find "$LIVE_HOME/.config" -name '*.sh' -exec chmod 755 {} +

# The wallpapers live outside config/ because they are not configuration and do
# not belong in ~/.config. install.sh puts them here on a real machine; the
# medium needs the same, both so the live desktop has one and so SUPER+W has
# something to offer.
install -d "$LIVE_HOME/Pictures/wallpapers"
if compgen -G "$REPO/wallpapers/*.png" >/dev/null; then
    cp "$REPO"/wallpapers/*.png "$LIVE_HOME/Pictures/wallpapers/"
    ok "live session gets $(ls "$REPO"/wallpapers/*.png | wc -l) wallpapers"
else
    warn "hyprland-setup ships no wallpapers/ — the live desktop will have none"
fi
rm -f "$LIVE_HOME/.config/hypr/monitors.lua" "$LIVE_HOME/.config/hypr/gpu.lua"

# starch-config opens on its welcome page at first login. On the medium the
# installer is the thing that should have your attention, so the switch that
# page offers is pre-set for the live user only.
install -d "$LIVE_HOME/.config/starch"
cat > "$LIVE_HOME/.config/starch/settings.json" <<'STATE'
{
  "show_at_login": false
}
STATE

# hyprland.lua ends with optional("live"), which exists for exactly this: a
# module that is only ever present on install media. It is what makes the
# session an installer session rather than a desktop that happens to be
# running from a stick.
cat > "$LIVE_HOME/.config/hypr/live.lua" <<'LIVE'
--------------------------------------------------------------------------------
--  Install media only
--
--  Loaded last by hyprland.lua, and present only here — an installed system
--  has no such file. Everything in it is about the medium.
--------------------------------------------------------------------------------

-- The installer is a window, not the screen. live-prepare sizes it from the
-- monitor it finds, since half of a 5K panel and half of a 1280x800 one want
-- different answers, and writes live-window.lua just before Hyprland starts.
--
-- pcall rather than hyprland.lua's optional(), which is a local in that file
-- and not visible from a module it requires. Missing means live-prepare did
-- not run: the installer still opens, tiled, which is what it did before any
-- of this.
pcall(require, "live-window")

hl.on("hyprland.start", function()
    -- The installer, elevated. Calamares partitions disks; nothing else here
    -- is root. The variables are named rather than passed with sudo -E, which
    -- depends on the sudoers policy and can drop one without saying so.
    hl.exec_cmd("/usr/local/lib/starch/start-installer")
end)
LIVE

ok "live session gets the desktop config, with the installer on top"

# ── autologin straight into the desktop ───────────────────────────────────────
install -d "$AIR/etc/systemd/system/getty@tty1.service.d"
cat > "$AIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${LIVE_USER} --noclear %I \$TERM
EOF

cat > "$AIR/home/${LIVE_USER}/.bash_profile" <<'EOF'
# Install media: tty1 brings up the desktop, with the installer on top of it.
# Any other VT is a plain shell, which matters when the desktop is the thing
# that is broken.
#
# start-hyprland, not uwsm and not a display manager. Nothing here waits on
# graphical.target, and nothing waits on the network — an earlier attempt at a
# live desktop put a ninety second countdown on the screen and the cause was
# cloud-init and networkd-wait-online pulling in network-online.target, not the
# compositor. Those are off on this medium.
#
# start-hyprland is the watchdog the hyprland package ships, and is not a
# session manager, so none of the above changes. Calling the Hyprland binary
# straight puts "Hyprland was started without start-hyprland" on the screen of
# every boot of the medium. An installed system never sees it: the stock
# hyprland.desktop is Exec=/usr/bin/start-hyprland, and the uwsm entry resolves
# through that same file, so the medium was the only thing doing it by hand.
#
# If the session cannot start, the text installer still can. That is the whole
# reason the fallback is here: a graphical failure should cost you the pretty
# installer, not the ability to install.
#
# STARCH_SHELL guards against re-entry. The text menu's Shell option runs a
# login shell, which reads this file — without the guard it execs straight back
# into the installer and the menu appears to ignore the choice.
if [[ $XDG_VTNR == 1 && -z ${STARCH_SHELL:-} ]]; then
    # Decide the display scale and the installer's window size from the panel
    # in front of us, and write both where hyprland.lua will read them.
    /usr/local/lib/starch/live-prepare

    start-hyprland 2>>/tmp/hyprland-session.log

    # Hyprland exited: either the installer finished and quit the session, or
    # it never started. Either way the text menu is what is left.
    exec starch-install
fi
EOF
ok "tty1 opens the desktop with the installer on it, text menu behind"

# ── Calamares ─────────────────────────────────────────────────────────────────
install -d "$AIR/etc/calamares/modules" "$AIR/etc/calamares/branding/starch"
install -m 644 "$HERE/calamares/settings.conf" "$AIR/etc/calamares/settings.conf"
install -m 644 "$HERE/calamares/modules/"*.conf "$AIR/etc/calamares/modules/"
install -m 644 "$HERE/calamares/branding/starch/"* "$AIR/etc/calamares/branding/starch/"
ok "Calamares configuration ($(ls -1 "$HERE/calamares/modules" | wc -l) modules)"

# The two scripts Calamares runs inside the target. They live outside
# /usr/local/bin because they are not commands anyone should run by hand.
install -d "$AIR/usr/local/lib/starch"
install -m 755 "$HERE/installer/add-microcode"     "$AIR/usr/local/lib/starch/add-microcode"
install -m 755 "$HERE/installer/live-scale"        "$AIR/usr/local/lib/starch/live-scale"
install -m 755 "$HERE/installer/broadcom-live"     "$AIR/usr/local/lib/starch/broadcom-live"
install -m 755 "$HERE/installer/copy-kernel"       "$AIR/usr/local/lib/starch/copy-kernel"
install -m 755 "$HERE/installer/strip-live"        "$AIR/usr/local/lib/starch/strip-live"
install -m 755 "$HERE/installer/configure-desktop" "$AIR/usr/local/lib/starch/configure-desktop"
install -m 755 "$HERE/installer/live-prepare"      "$AIR/usr/local/lib/starch/live-prepare"
install -m 755 "$HERE/installer/start-installer"   "$AIR/usr/local/lib/starch/start-installer"
install -m 755 "$HERE/installer/add-plymouth"      "$AIR/usr/local/lib/starch/add-plymouth"
install -m 755 "$HERE/installer/splash-cmdline"    "$AIR/usr/local/lib/starch/splash-cmdline"
ok "post-install scripts staged"

# Wireless in the live session. The installed system gets its driver choice
# from install.sh; the medium has to work it out at boot, on hardware it has
# not seen before, before anything tries to bring a network up.
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
# squashfs takes upwards of forty seconds. It is most of the wait between the
# splash and the installer, and it shows up on the details screen as
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
# The theme the live desktop wears is the one a fresh install gets, read from
# install.sh so the medium and the machine it makes cannot drift apart.
LIVE_THEME="$(sed -n 's/^DEFAULT_THEME=//p' "$REPO/install.sh" | head -1)"
# DEFAULT_WALLPAPER names a design in hyprland-setup's wallpapers/, not a path:
# each design ships a 16:9 and an ultrawide render and which one fits is a
# property of the panel, not of the repo. The medium bakes the 16:9 one, and
# live-prepare swaps to the wide render at boot if the screen turns out to want
# it. Read as a path, this used to be /usr/share/hypr/wall2.png.
LIVE_WALL_DESIGN="$(sed -n 's/^DEFAULT_WALLPAPER=//p' "$REPO/install.sh" | head -1)"
LIVE_WALL="/home/${LIVE_USER}/Pictures/wallpapers/${LIVE_WALL_DESIGN}-3840x2160.png"
[[ -n $LIVE_THEME ]] || die "could not read DEFAULT_THEME from install.sh"

cat > "$AIR/root/customize_airootfs.sh" <<CUSTOMIZE
#!/usr/bin/env bash
# Run by mkarchiso inside the airootfs, then deleted. See build.sh.

# The live desktop's palette. theme.sh renders the active theme into the six
# formats the desktop reads — waybar imports a colors.css that does not exist
# until this runs, and an unstyled bar is the first thing anyone would see.
# --no-reload because there is nothing running in a chroot to signal.
if [ -x /home/${LIVE_USER}/.config/hypr/scripts/theme.sh ]; then
    HOME=/home/${LIVE_USER} XDG_CONFIG_HOME=/home/${LIVE_USER}/.config \
        /home/${LIVE_USER}/.config/hypr/scripts/theme.sh --set ${LIVE_THEME} --no-reload \
        || echo "  theme.sh failed; the live bar will be unstyled"
fi

# And its wallpaper, by the same argument: hyprpaper.conf and the lock screen
# are both rendered from the recorded choice.
if [ -x /home/${LIVE_USER}/.config/hypr/scripts/wallpaper.sh ] && [ -f "${LIVE_WALL}" ]; then
    HOME=/home/${LIVE_USER} XDG_CONFIG_HOME=/home/${LIVE_USER}/.config \
        /home/${LIVE_USER}/.config/hypr/scripts/wallpaper.sh --set "${LIVE_WALL}" --no-reload \
        || echo "  wallpaper.sh failed; the live desktop will have no wallpaper"
fi
#
# Deliberately cannot fail the build. Neither of these is worth losing a
# twenty-minute build over: the worst case without them is the boot taking the
# time back, which is where it was already.
set -u

# theme.sh and wallpaper.sh just ran as root with HOME pointed at the live
# user, and whatever they cached landed in /home/${LIVE_USER} owned by root.
# archiso applies profiledef's file_permissions *before* this script runs, so
# nothing puts it back: /home/${LIVE_USER}/.cache shipped as root:root 700, and
# every app that wants a cache directory died on startup. kitty was the visible
# one — SUPER+Return did nothing and the medium had no way to reach a shell.
#
# Numeric ids, to match profiledef and because name lookup in a chroot is one
# more thing that can quietly not work.
chown -R 1500:1500 /home/${LIVE_USER}

# ── networking, matched to what an installed system gets ─────────────────────
# archiso ships iwd + systemd-networkd. Everything on this desktop that shows
# or controls a network is NetworkManager's — waybar's network module, the
# nm-applet tray icon, nmtui — so the medium had a wireless stack that nothing
# on screen could drive. strip-live already flips the installed system this way
# round; doing it here makes the medium agree with what it installs.
#
# systemctl rather than hand-made .wants symlinks: NetworkManager carries
# Alias= and Also= units for D-Bus activation, and symlinks miss them. That is
# the same lesson strip-live records for the disable direction.
systemctl enable  --no-reload NetworkManager.service \
    || echo "  could not enable NetworkManager; the live session will have no network UI"
systemctl disable --no-reload iwd.service systemd-networkd.service \
                              systemd-networkd.socket >/dev/null 2>&1 || true

# Not optional, and not redundant: `systemctl enable NetworkManager.service`
# carries Also=NetworkManager-wait-online.service, so the line above *creates*
# network-online.target.wants/NetworkManager-wait-online.service as a side
# effect. That is the family of unit that put a ninety second countdown on the
# screen. It has to be taken back off, and it has to happen after the enable.
systemctl disable --no-reload NetworkManager-wait-online.service >/dev/null 2>&1 || true

ldconfig || echo "  ldconfig failed; the first boot will rebuild the cache"
if [ -x /usr/lib/systemd/systemd-update-done ]; then
    /usr/lib/systemd/systemd-update-done || echo "  could not write the .updated stamps"
else
    echo "  systemd-update-done is missing; ldconfig.service will run at boot"
fi
exit 0
CUSTOMIZE
chmod 755 "$AIR/root/customize_airootfs.sh"
ok "linker cache stamped at build time, not rebuilt at every boot"

# ── the installer ─────────────────────────────────────────────────────────────
install -d "$AIR/usr/local/bin"
install -m 755 "$HERE/installer/starch-install" "$AIR/usr/local/bin/starch-install"
install -m 755 "$HERE/installer/starch-setup"   "$AIR/usr/local/bin/starch-setup"
ok "installer at /usr/local/bin/{starch-install,starch-setup}"

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
extra = f'''  ["/usr/local/bin/starch-install"]="0:0:755"
  ["/usr/local/bin/starch-setup"]="0:0:755"
  ["/usr/local/share/hyprland-setup/install.sh"]="0:0:755"
  ["/usr/local/share/hyprland-setup/starch-config/starch-config"]="0:0:755"
  ["/usr/local/lib/starch/add-microcode"]="0:0:755"
  ["/usr/local/lib/starch/live-scale"]="0:0:755"
  ["/usr/local/lib/starch/broadcom-live"]="0:0:755"
  ["/usr/local/lib/starch/copy-kernel"]="0:0:755"
  ["/usr/local/lib/starch/strip-live"]="0:0:755"
  ["/usr/local/lib/starch/configure-desktop"]="0:0:755"
  ["/usr/local/lib/starch/live-prepare"]="0:0:755"
  ["/usr/local/lib/starch/start-installer"]="0:0:755"
  ["/usr/local/lib/starch/add-plymouth"]="0:0:755"
  ["/usr/local/lib/starch/splash-cmdline"]="0:0:755"
  ["/usr/local/share/hyprland-setup/config/hypr/scripts/"]="0:0:755"
  ["/home/{user}/"]="1500:1500:755"
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
