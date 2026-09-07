# Testing the ISO without a human

Booting the ISO and watching it is slow, and most questions about a build are
questions about text. These three turn a boot into something you can drive and
read from a script.

`../test-boot.sh --monitor` boots the newest ISO with QEMU's monitor on a unix
socket at `.vm/monitor.sock`, which is what the first two talk to.

## `vm-keys` — type at it, and see it

```
./tools/vm-keys .vm/monitor.sock type 'hyprctl monitors'
./tools/vm-keys .vm/monitor.sock key ret
./tools/vm-keys .vm/monitor.sock screendump /tmp/shot.ppm
```

Enough to get through a boot menu, log in, and read the result off the screen.
The socket path has to be under about 108 bytes — a unix socket address is a
fixed-size field — so keep it in the repo or `/tmp`, not somewhere deep.

**The monitor cannot click.** `mouse_move` only emits *relative* events, and
the pointer QEMU gives a modern guest is absolute (usb-tablet, or the vmmouse
that takes over the PS/2 port), so the events are discarded. The cursor does
not move and nothing reports an error. That is what `vm-click` is for.

## `vm-shell` — a real shell in the guest

Screen-scraping a terminal is slow and lossy. User-mode networking puts the
host at 10.0.2.2, so the guest can reach a server here with no port forwarding.

```
./tools/vm-shell serve &                       # on the host
# then, once, in the guest (vm-keys can type it):
#   curl -s http://10.0.2.2:8099/agent.sh | bash &
./tools/vm-shell run 'hyprctl monitors -j | jq .[0].scale'
```

Unauthenticated, and meant for a VM you booted yourself.

## `vm-click` — click things

A small client speaking `wlr-virtual-pointer-unstable-v1`, so the compositor
sees an ordinary pointer. `make` in `vm-click/`; the protocol XML is vendored,
so it builds with no network. Build it on the host and copy the binary into the
guest — same Arch, same libraries.

```
./click <x> <y> <screen_w> <screen_h>              # move and left-click
./click <x> <y> <screen_w> <screen_h> --move-only
./click <x> <y> <screen_w> <screen_h> --scroll-down
```

Two things that cost an afternoon:

- **Coordinates are logical, not framebuffer pixels.** On a scaled output
  `hyprctl monitors` reports a 1280x800 mode at scale 1.333, and the pointer
  lives in 960x600. A screendump is in the other one.
- **Scroll needs `axis_source`, `axis_discrete` *and* `axis` before `frame`.**
  Without the plain `axis` value GTK clients ignore it entirely, while
  Hyprland's own keybinds still fire — so it looks like the toolkit is broken
  rather than the injection. Sending both also makes waybar count two ticks,
  so expect a scroll to move two workspaces.
