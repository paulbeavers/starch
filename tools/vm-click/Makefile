# click — move the pointer and click, in a Wayland session that has no mouse.
#
# The protocol XML is vendored from wlroots/wlr-protocols (MIT) so this builds
# with no network. Regenerate the glue with wayland-scanner, which ships with
# wayland; the only other dependency is wayland-client.
CFLAGS  ?= -O2 -Wall
PKGS    := wayland-client
XML     := wlr-virtual-pointer-unstable-v1.xml

click: click.c vp.c vp-client.h
	$(CC) $(CFLAGS) -o $@ click.c vp.c $(shell pkg-config --cflags --libs $(PKGS))

vp-client.h: $(XML)
	wayland-scanner client-header $< $@

vp.c: $(XML)
	wayland-scanner private-code $< $@

clean:
	rm -f click vp.c vp-client.h

.PHONY: clean
