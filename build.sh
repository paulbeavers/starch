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
for item in install.sh README.md config; do
    cp -r "$REPO/$item" "$DEST/"
done

# The payload is source, so anything near a megabyte means something large got
# swept in — exactly the failure this replaced.
size_kb=$(du -sk "$DEST" | cut -f1)
[[ $size_kb -lt 5120 ]] || die "embedded payload is ${size_kb}KB — something large was included"
ok "embedded the repo at /usr/local/share/hyprland-setup (${size_kb}KB)"

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

# ── autologin straight into Hyprland ──────────────────────────────────────────
install -d "$AIR/etc/systemd/system/getty@tty1.service.d"
cat > "$AIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${LIVE_USER} --noclear %I \$TERM
EOF

install -d "$AIR/home/${LIVE_USER}"
cat > "$AIR/home/${LIVE_USER}/.bash_profile" <<'EOF'
# Install media: tty1 brings up the desktop, which starts the installer itself.
# Any other VT is a plain shell, which matters when the desktop is the thing
# that is broken.
#
# Running the real desktop rather than a kiosk is what gives the live session a
# network applet, a terminal and a file manager — none of which a single
# fullscreen Calamares has. Someone can join a wifi network, check their
# hardware works, and then install; on a laptop whose wireless needs a driver
# the kernel does not carry, that is the difference between a usable medium and
# one that can only be used offline.
#
# STARCH_SHELL guards against re-entry: the text menu's Shell option runs a
# login shell, which reads this file.
if [[ $XDG_VTNR == 1 && -z ${STARCH_SHELL:-} ]]; then
    # Not exec: if the desktop will not start — no GPU it can use, a broken
    # config — falling through to the text installer is the difference between
    # a usable medium and a blank screen. It is also where you land after
    # logging out.
    # Pick a scale for whatever display this turned out to be, before the
    # compositor reads its configuration. Hyprland's own "auto" resolves to 1x
    # on the panels that most need scaling, which is how the installer ended up
    # unreadably small on a retina laptop.
    /usr/local/lib/starch/live-scale || true
    uwsm start -- hyprland-uwsm.desktop
    exec starch-install
fi
EOF
ok "tty1 starts the desktop"

# The live user's copy of the desktop configuration. An installed system gets
# this from install.sh; the medium cannot, because install.sh runs against the
# target, so it is laid down here at build time.
install -d "$AIR/home/${LIVE_USER}/.config"
cp -r "$REPO/config/." "$AIR/home/${LIVE_USER}/.config/"

# And the piece that only belongs on the medium: start the installer once the
# desktop is up. hyprland.lua loads this if it exists and ignores it if not.
cat > "$AIR/home/${LIVE_USER}/.config/hypr/live.lua" <<'EOF'
--------------------------------------------------------------------------------
--  Install media only
--
--  Starts the installer once the desktop is running. An installed system has
--  no live.lua, so nothing here follows anyone home.
--------------------------------------------------------------------------------

hl.on("hyprland.start", function()
    -- Calamares partitions disks, so it needs to be root. The live user has
    -- passwordless sudo; -E keeps the Wayland environment, without which a Qt
    -- application started as another user has no display to draw on.
    --
    -- Output goes to a file because there is nowhere else for it to go: this
    -- runs from the compositor, with no terminal attached. If the window never
    -- appears, that log is the only thing that will say why, and the terminal
    -- is one keystroke away.
    hl.exec_cmd("sh -c 'sudo -E calamares >/tmp/calamares.log 2>&1'")
end)
EOF
ok "desktop configuration deployed for '${LIVE_USER}'"

# Render the theme, which the configuration does not carry ready-made.
#
# waybar's style.css imports colors.css, kitty includes colors.conf, and
# theme.lua requires colors.lua — none of which exist until a theme is applied.
# On an installed system install.sh does that. Copying the configuration alone
# is not enough: without it waybar exits at startup with "Failed to import
# colors.css", which takes the tray with it and leaves nm-applet running with
# nowhere to draw. No bar, and no way to join a wifi network.
#
# The defaults come from install.sh so the medium and the installed system
# cannot disagree about what starch looks like.
eval "$(grep -E '^DEFAULT_(THEME|WALLPAPER)=' "$REPO/install.sh")"
live_cfg="$AIR/home/${LIVE_USER}/.config"

if XDG_CONFIG_HOME="$live_cfg" \
   bash "$REPO/config/hypr/scripts/theme.sh" --no-reload --set "$DEFAULT_THEME" >/dev/null 2>&1; then
    ok "theme rendered ($DEFAULT_THEME)"
else
    die "could not render the $DEFAULT_THEME theme; waybar would not start"
fi

# And a wallpaper, for the same reason: hyprpaper.conf names a file that only
# exists once one has been chosen.
if [[ -f $DEFAULT_WALLPAPER ]] && XDG_CONFIG_HOME="$live_cfg" \
   bash "$REPO/config/hypr/scripts/wallpaper.sh" --no-reload --set "$DEFAULT_WALLPAPER" >/dev/null 2>&1; then
    ok "wallpaper set ($(basename "$DEFAULT_WALLPAPER"))"
else
    warn "no wallpaper on the medium; the desktop will come up plain"
fi

# Networking on the medium, to match the desktop rather than archiso.
#
# releng enables iwd and systemd-networkd. The desktop expects NetworkManager —
# waybar's network module and nm-applet both talk to it — and two managers
# fighting over one interface is worse than either alone. So the medium is
# switched over to match what it is running, which also means the wifi someone
# joins in the live session is joined the same way it will be after installing.
rm -f "$AIR/etc/systemd/system/multi-user.target.wants/iwd.service" \
      "$AIR/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" \
      "$AIR/etc/systemd/system/sockets.target.wants/systemd-networkd.socket" \
      "$AIR/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service"
rm -f "$AIR/etc/systemd/network/"*.network
install -d "$AIR/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/NetworkManager.service \
    "$AIR/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
ok "NetworkManager runs the medium's networking"

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
  ["/usr/local/lib/starch/add-microcode"]="0:0:755"
  ["/usr/local/lib/starch/live-scale"]="0:0:755"
  ["/usr/local/lib/starch/broadcom-live"]="0:0:755"
  ["/usr/local/lib/starch/copy-kernel"]="0:0:755"
  ["/usr/local/lib/starch/strip-live"]="0:0:755"
  ["/usr/local/lib/starch/configure-desktop"]="0:0:755"
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
