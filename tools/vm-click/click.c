/* click X Y [button] — move the pointer to an absolute position and click.
 *
 * Uses wlr-virtual-pointer, the same protocol wlrctl and ydotool's wayland
 * backend use, so the compositor sees an ordinary pointer device. X and Y are
 * in logical (compositor) coordinates.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>
#include "vp-client.h"

static struct wl_seat *seat;
static struct zwlr_virtual_pointer_manager_v1 *mgr;
static int w = 0, h = 0;

static void handle_global(void *d, struct wl_registry *r, uint32_t name,
                          const char *iface, uint32_t ver) {
  if (!strcmp(iface, wl_seat_interface.name))
    seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
  else if (!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name))
    mgr = wl_registry_bind(r, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void handle_global_remove(void *d, struct wl_registry *r, uint32_t n) {}
static const struct wl_registry_listener reg_listener = {handle_global, handle_global_remove};

static uint32_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int main(int argc, char **argv) {
  if (argc < 5) {
    fprintf(stderr, "usage: click <x> <y> <screen_w> <screen_h> [button] [--move-only]\n");
    return 2;
  }
  int x = atoi(argv[1]), y = atoi(argv[2]);
  w = atoi(argv[3]); h = atoi(argv[4]);
  uint32_t btn = 0x110; /* BTN_LEFT */
  if (argc > 5 && strcmp(argv[5], "--move-only")) btn = strtoul(argv[5], NULL, 0);
  int move_only = 0, scroll = 0;
  for (int i = 5; i < argc; i++) {
    if (!strcmp(argv[i], "--move-only")) move_only = 1;
    if (!strcmp(argv[i], "--scroll-up")) scroll = -1;
    if (!strcmp(argv[i], "--scroll-down")) scroll = 1;
  }

  struct wl_display *dpy = wl_display_connect(NULL);
  if (!dpy) { fprintf(stderr, "no wayland display\n"); return 1; }
  struct wl_registry *reg = wl_display_get_registry(dpy);
  wl_registry_add_listener(reg, &reg_listener, NULL);
  wl_display_roundtrip(dpy);
  if (!mgr) { fprintf(stderr, "compositor has no wlr-virtual-pointer\n"); return 1; }

  struct zwlr_virtual_pointer_v1 *p =
      zwlr_virtual_pointer_manager_v1_create_virtual_pointer(mgr, seat);

  zwlr_virtual_pointer_v1_motion_absolute(p, now_ms(), x, y, w, h);
  zwlr_virtual_pointer_v1_frame(p);
  wl_display_roundtrip(dpy);

  if (scroll) {
    uint32_t t = now_ms();
    zwlr_virtual_pointer_v1_axis_source(p, WL_POINTER_AXIS_SOURCE_WHEEL);
    zwlr_virtual_pointer_v1_axis_discrete(p, t, WL_POINTER_AXIS_VERTICAL_SCROLL,
                                          wl_fixed_from_int(scroll * 15), scroll);
    zwlr_virtual_pointer_v1_axis(p, t, WL_POINTER_AXIS_VERTICAL_SCROLL,
                                 wl_fixed_from_int(scroll * 15));
    zwlr_virtual_pointer_v1_frame(p);
    wl_display_roundtrip(dpy);
    zwlr_virtual_pointer_v1_axis_source(p, WL_POINTER_AXIS_SOURCE_WHEEL);
    zwlr_virtual_pointer_v1_axis_stop(p, t + 10, WL_POINTER_AXIS_VERTICAL_SCROLL);
    zwlr_virtual_pointer_v1_frame(p);
    wl_display_roundtrip(dpy);
  } else if (!move_only) {
    zwlr_virtual_pointer_v1_button(p, now_ms(), btn, WL_POINTER_BUTTON_STATE_PRESSED);
    zwlr_virtual_pointer_v1_frame(p);
    wl_display_roundtrip(dpy);
    struct timespec t = {0, 80 * 1000 * 1000};
    nanosleep(&t, NULL);
    zwlr_virtual_pointer_v1_button(p, now_ms(), btn, WL_POINTER_BUTTON_STATE_RELEASED);
    zwlr_virtual_pointer_v1_frame(p);
    wl_display_roundtrip(dpy);
  }
  zwlr_virtual_pointer_v1_destroy(p);
  wl_display_roundtrip(dpy);
  wl_display_disconnect(dpy);
  return 0;
}
