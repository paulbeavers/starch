# Working on starch

Install media that produces an Arch + Hyprland desktop and then leaves nothing
of itself behind. `README.md` explains the idea; this file is the things that
are not visible from the code and that cost real time to learn.

## The principle: an install is native Arch

**What starch installs must be the system you would get by installing Arch by
hand, following the install guide, and then running lucent's `install.sh`.**
Same packages, same install reasons, same enabled units, same files in `/etc`.
This is the design principle everything else serves, and it is the test for
any change: if a hand-installed machine would not have it, a starch machine
must not either, and the other way round.

starch adds exactly five things a hand install would not, each on purpose and
each listed here. Anything not on this list is drift:

- the boot splash (plymouth, its theme, the hook, `quiet splash`)
- `SYSTEMD_SULOGIN_FORCE=1` for emergency and rescue mode, because root is locked
- `FONT=` in vconsole.conf on high-density panels
- `broadcom-bt-firmware` from the AUR, on Apple hardware only
- `/var/log/starch-install.log`, the installer's own log

`tools/install-manifest` prints what the principle compares. Run it on a
starch install and on a hand install of the same hardware and diff the two;
everything in the diff should be on this list.

Speed, offline installs and nicer installers are all worth having, and none of
them is worth breaking this. The install drifted from it once, for six weeks:
on 2026-09-06 Calamares replaced pacstrap with a copy of the live medium, for a
graphical installer that needed no network, and every fix after that was
removing one more thing the copy brought along. It should never have diverged;
the principle was the reason starch existed, and nothing checked it. Prove a
change against it rather than arguing it, with `tools/install-manifest`.

## Two repos

`lucent/` is a submodule: the desktop half — `install.sh`, the Hyprland
config, and `lucent-config`. Almost all desktop changes belong there. After
committing in the submodule, bump the pointer here:

    git -C lucent fetch origin
    git submodule update --remote lucent
    git add lucent && git commit

**The submodule is its own checkout.** Editing `~/lucent` does not
change `starch/lucent`; the build reads the latter. Three things can
disagree — the commit recorded in starch's history, the files checked out in
`lucent/`, and what is on origin. `git pull` updates the first and
never the second. build.sh now refuses to start when those two differ and
mentions it when origin has moved on, because a stale checkout is otherwise
silent: the build looks perfect and ships a desktop from weeks ago.

## Build

`./build-all.sh` from a clean clone: it checks out the submodule, builds the
AUR packages and then the ISO, in that order. `./build.sh --assemble` builds the
profile with no root in seconds, which is the cheap way to check what would go
on the medium: diff `work-assemble/profile` against
`/usr/share/archiso/configs/releng`. It skips the offline repository, which
needs root to download.

`extract-packages.sh` reads the `PKGS_*` arrays out of `install.sh`, so a
package added there lands in the medium's offline repository too. Never
maintain a second list. The installer's own pacstrap list is the one exception,
and it appears twice — `install_base` in `installer/starch-install` and
`offline_pkgs` in `build.sh`. Change both, or the installer asks the repository
for a package it does not have.

It reads them *by column*, with sed: only the Arch arrays, which start at
column 0. `install.sh` also carries Fedora and Ubuntu lists, indented inside
an `if`, and those are deliberately out of reach — the ISO is Arch, and an
Ubuntu package name on the medium would be a build failure. So an Arch package
has to go in at column 0 to land here, and a package added to the other two
lists will not. After touching any of them, check the list did not move:

    diff <(./extract-packages.sh) <previous output>

To check the repository resolves without a root build — every package, every
dependency, no conflicts — sync a scratch database under fakeroot and ask for
the plan, as `checkupdates` does:

    fakeroot -- pacman --config C --dbpath D -Sy
    pacman --config C --dbpath D -Sp --print-format '%n' <packages>

**Do not edit `build.sh` while a build is running.** Bash reads a script
incrementally; an edit mid-run makes it resume at a byte offset into different
text and die with a syntax error a hundred lines from anything you touched. If
you must, write the whole file atomically and preserve the mode.

## The installer is pacstrap, on purpose

Until October 2026 the install was Calamares cloning the live squashfs and
then removing the live parts. Every removal it missed shipped: the kernel
lived where pacman never updated it, so the first `pacman -Syu` with a kernel
left machines unbootable; logind ignored the lid; the journal lived in RAM;
`sshd_config.d` allowed root password login; ~110 rescue-disk packages stayed
installed as explicit. Nothing about a clone is native by construction, so it
was replaced. **Do not reintroduce copying the medium** to save install time.

`installer/starch-install` runs what the Arch install guide runs, then
`install.sh --for-user` in a chroot. Things that are not visible from it:

- **Offline, through file:// servers.** `build.sh` resolves every package the
  install can ask for against a fresh database and downloads the closure into
  `/usr/share/starch/repo`, beside copies of the `core.db` and `extra.db` it
  resolved against. Signatures are checked against those databases, as from a
  mirror. The AUR packages are a second repository, `starch-local`.
- **During `install.sh` only the target's mirrorlist is swapped**, not
  pacman.conf. `install.sh` edits pacman.conf (ParallelDownloads, multilib),
  and those edits have to survive into the installed system. The real
  mirrorlist is written last.
- **The splash is starch's, so the installer adds it.** lucent's CLAUDE.md
  says `install.sh` does not touch the boot. pacstrap's mkinitcpio.conf uses
  the `systemd` hook, not `udev`; a sed that only knows `udev` drops the splash
  silently. `plymouth` has to come before `sd-encrypt` for a graphical
  passphrase prompt.
- **Boot entries name `/vmlinuz-linux`**, which mkinitcpio's pacman hooks keep
  current. Anything that runs `kernel-install` (Calamares did) writes a copy
  under `/boot/<machine-id>/` that no upgrade touches.
- **Root is locked, so emergency mode needs `SYSTEMD_SULOGIN_FORCE=1`** on
  `emergency.service` and `rescue.service`, or it answers every failed boot
  with "the root account is locked".
- **gum on the Linux console:** colours by ANSI number (sixteen exist), border
  `normal` (rounded arcs are missing from console fonts), and the spinner is
  ASCII for the same reason.

## MacBooks: where the support lives now

Intel MacBooks — the 2013 13" and 15" retina Pros above all — are the hardware
this was made on. Each piece below cost real time, and the move off Calamares
moved several of them. Before removing any, read why it is there.

| What | Where | Why |
|---|---|---|
| wl driver choice and blacklist | lucent `install.sh` (`detect_broadcom_wifi`, `WL_IDS`) | BCM4360 in the 13" needs `wl`. BCM43602 in the 15" is brcmfmac's; listing it left the 15" with no wireless |
| Kernel headers with `broadcom-wl-dkms` | lucent `install.sh` | dkms lists headers as optional; without them no module builds. The clone carried headers and hid it |
| Bluetooth firmware | `starch-install` pacstraps `broadcom-bt-firmware` from `starch-local` when DMI says Apple | AUR-only; reached installs only through the clone before |
| Live wireless | `installer/broadcom-live`, plus `broadcom-wl-dkms dkms linux-headers` in the live package list | the medium has to pick the driver at boot, before NetworkManager |
| Retina console font | `starch-install` (`pick_console_font`), and `FONT=` in the target's vconsole.conf | 8x16 on 2560/2880-wide panels is unreadable — including the LUKS prompt |
| Mac keyboard, notch, Parallels | lucent | see lucent's CLAUDE.md |

Two lessons from the live desktop, kept because they are about the hardware,
not about Calamares:

- **`start-hyprland` exited immediately on a 2013 13" MacBook Pro** and was
  fine on a 15" and in a VM, which is how it shipped. If anything starts
  Hyprland through the watchdog wrapper on those machines, test it on the 13".
- **Scaled panels are the case VMs never exercise.** Every retina bug in the
  live session (window sizes in physical rather than logical pixels, Qt scaling
  on top of the compositor) passed in a VM, because a VM is unscaled. Judge
  anything display-related on the hardware.

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

`~/lucent` has a `post-commit` hook that pushes the commit, moves the
submodule here to it, commits the bump and pushes that too. It exists because
forgetting the pin shipped two ISOs missing the fixes they were built for.

It acts **only when both repos are on `main`**. A commit on a release branch
such as `2026-09` is a fix for something already shipped, and pinning `main` to
it would drag the next release backwards. Release branches are cut in both
repos at the same point; `2026-09` records the September ISO exactly, submodule
pin included.

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
