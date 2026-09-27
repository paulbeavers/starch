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
change `starch/hyprland-setup`; the build reads the latter. Three things can
disagree — the commit recorded in starch's history, the files checked out in
`hyprland-setup/`, and what is on origin. `git pull` updates the first and
never the second. build.sh now refuses to start when those two differ and
mentions it when origin has moved on, because a stale checkout is otherwise
silent: the build looks perfect and ships a desktop from weeks ago.

## Build

`./build-all.sh` from a clean clone: it checks out the submodule, builds the
AUR packages and then the ISO, in that order. `sudo ./build.sh` alone is about
5 minutes with a warm pacman cache. `./build.sh --assemble` builds the profile
with no root in seconds, which is the cheap way to check what would go on the
medium: diff `work-assemble/profile` against `/usr/share/archiso/configs/releng`.

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

## The pin is automated now, and it is branch-aware

`~/hyprland-setup` has a `post-commit` hook that pushes the commit, moves the
submodule here to it, commits the bump and pushes that too. It exists because
forgetting the pin shipped two ISOs missing the fixes they were built for.

It acts **only when both repos are on `main`**. A commit on a release branch
such as `2026-09` is a fix for something already shipped, and pinning `main` to
it would drag the next release backwards. Release branches are cut in both
repos at the same point; `2026-09` records the September ISO exactly, submodule
pin included.

## The medium launches Hyprland directly, on purpose

Not `start-hyprland`, the watchdog wrapper the hyprland package ships.
Hyprland warns on every boot when you call the binary, and silencing that
warning by using the wrapper cost a working desktop: on a 2013 13" MacBook Pro
it exited immediately, `.bash_profile` fell through to `exec starch-install`,
and the machine came up with the text installer and no desktop. It was fine on
a 15" and in a VM, which is how it shipped. `live.lua` sets
`misc:disable_watchdog_warning` instead, and the fallback now prints why it
fired.

## Calamares

**Its Wayland app_id is `io.calamares.calamares`**, reverse-DNS. A window rule
matching `calamares` silently does not apply, which is how the installer came
up tiled across the whole screen with a correct-looking rule sitting right
there.

**`hl.window_rule` sizes are logical pixels.** `live-prepare` sized from the
raw panel and multiplied the floor by the scale as well, so a 2880x1800 retina
panel at scale 2 asked for an 1800x1240 window on a 1440x900 logical screen —
centred to a negative origin, with the fields off the top. Every scaled panel
was affected and only unscaled ones, which is what a VM is, ever worked.

**Qt must not scale on top of the compositor.** `QT_SCALE_FACTOR` carried the
whole job under cage; Hyprland scales the output itself, so setting both drew
the installer at scale squared. `live-prepare` records what it actually gave
Hyprland and `start-installer` scales Qt only when Hyprland is not.

**The sidebar logo's margin belongs in the asset.** `make-logos.sh` trims it
tight, so its artwork starts at pixel zero and sits flush against the window
edge. QSS cannot fix that: margins on `#logoApp` clip the wordmark and expose
the unpainted parent as pale bars, and padding on `#sidebarApp` does nothing at
all, because Calamares scales the pixmap into the box it gives the label.
`logo.png` carries 12% transparent margin, vertical only.

**A generated Lua rule is a Lua string before it is a regex.** Lua 5.4 rejects
`\.` as an invalid escape and fails the whole config, not just the rule, so
`live-prepare` writes `[.]` for a literal dot.

## Editing a script while a build is running

bash reads a script incrementally, so a running build picks up edits mid-file
and dies on a half-written line. `rename()` is atomic and a running process
keeps its descriptor on the old inode — so write the new version to a temp file
in the same directory and `mv` it over. Verified by inode number before and
after. The same applies to anything `build.sh` reads while it runs.

## Publishing

`./tools/deploy-web.sh` publishes `web/` and the newest ISO to S3, versioned by
month (`starch-2026.09-x86_64.iso`) with a `latest` alias made by server-side
copy. It skips the upload when the local sha256 matches the one published
beside the last release, and invalidates CloudFront — uploading to S3 is not
publishing.

`./tools/deploy-cdn.sh` owns bucket access: certificate, distribution, Origin
Access Control, the policy naming that one distribution, and the Route 53
alias. Only it writes the bucket policy; a publish script that also wrote one
would undo the lockdown every time someone fixed a typo. Both take
`--dry-run`.

## Do not run sudo from a tool call

There is no TTY, so sudo cannot prompt, and PAM counts each failure. With
`deny=3` three calls in one chain lock the user out of sudo for ten minutes.
Hand them the command instead. Prove a root-owned layout by installing into a
scratch prefix under `/tmp` first — that costs nothing when it is wrong.
