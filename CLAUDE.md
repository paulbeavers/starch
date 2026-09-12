# Working on starch

Install media that produces an Arch + Hyprland desktop and then leaves nothing
of itself behind. `README.md` explains the idea; this file is the things that
are not visible from the code and that cost real time to learn.

## Two repos

`hyprland-setup/` is a submodule: the desktop half — `install.sh`, the Hyprland
config, and `starch-config`. Almost all desktop changes belong there. After
committing in the submodule, bump the pointer here:

    git -C hyprland-setup fetch origin
    git submodule update --remote hyprland-setup
    git add hyprland-setup && git commit

**The submodule is its own checkout.** Editing `~/hyprland-setup` does not
change `starch/hyprland-setup`; the build reads the latter.

## Build

`./build-all.sh` from a clean clone: it checks out the submodule, builds the
AUR packages and then the ISO, in that order. `sudo ./build.sh` alone is about
5 minutes with a warm pacman cache. `./build.sh --assemble` builds the profile
with no root in seconds, which is the cheap way to check what would go on the
medium: diff `work-assemble/profile` against `/usr/share/archiso/configs/releng`.

**Calamares is patched.** `tools/build-aur.sh` removes `packagechooser` from
the AUR recipe's `SKIP_MODULES`, because `settings.conf` uses it for the
"Enable SSHD" checkbox. An ISO built against a Calamares from before that patch
ships an installer that refuses to start; `build.sh` looks inside the package
and dies rather than let that through. If you change anything about the
installer's module set, `./tools/build-aur.sh --force` first.

`extract-packages.sh` reads the `PKGS_*` arrays out of `install.sh`, so a
package added there lands on the ISO too. Never maintain a second list.

**Do not edit `build.sh` while a build is running.** Bash reads a script
incrementally; an edit mid-run makes it resume at a byte offset into different
text and die with a syntax error a hundred lines from anything you touched. If
you must, write the whole file atomically and preserve the mode.

## The install is a copy of the live filesystem

Calamares clones the squashfs rather than running pacstrap, which is what makes
an offline install possible — and means **anything missing from the medium
cannot be fetched later**. It also means several things live outside the
filesystem being cloned, and every one of them has broken an install:

- **mkarchiso copies the profile airootfs with `--no-preserve=mode`**, so every
  executable arrives as 644 and every script silently does nothing. Declare each
  one in `profiledef.sh`'s `file_permissions` — build.sh does this in one place.
- **`_cleanup_pacstrap_dir` empties `/boot`.** The kernel has to be taken from
  `$ROOT/usr/lib/modules/*/vmlinuz`, not from the medium. `installer/copy-kernel
  --check` runs *before* partitioning, because discovering it afterwards leaves
  the machine unbootable.
- **The pacman keyring is a tmpfs on the medium**, so the clone has an empty
  one and every package fails with "unknown trust". `installer/strip-live` runs
  `pacman-key --init && --populate`.
- **The live user holds uid 1500**, so the account Calamares creates gets 1000.
  Do not assume 1000 anywhere; `configure-desktop` takes the first ordinary
  account instead.
- **`systemctl disable`, not `rm` of the `.wants` symlink** — an `Alias=` or
  `Also=` leaves a second link behind and the unit stays enabled.

`installer/strip-live` turns the clone into a real system; `configure-desktop`
then runs `install.sh --for-user` and removes the installer. Order matters:
strip-live runs first and cannot delete configure-desktop, which is why the
cleanup lives at the end of the latter.

## Testing

`tools/README.md` — a keyboard and screendump driver, a real shell in the guest
over user-mode networking, and a virtual-pointer client for clicking. Between
them a question about a build costs seconds rather than a boot cycle.

`./test-boot.sh --monitor` boots the newest ISO with the QEMU monitor on a
socket.

**The ISO filename carries the date.** More than one debugging session has gone
into a bug that was fixed the day before, on a stick that was burned from
yesterday's file. Check the name against `ls -t out/`.

## Do not run sudo from a tool call

There is no TTY, so sudo cannot prompt, and PAM counts each failure. With
`deny=3` three calls in one chain lock the user out of sudo for ten minutes.
Hand them the command instead. Prove a root-owned layout by installing into a
scratch prefix under `/tmp` first — that costs nothing when it is wrong.
