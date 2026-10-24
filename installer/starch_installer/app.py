"""The starch installer's front end.

Welcome, four steps (keyboard, disk, account, review), then the install itself
with a step list, a progress bar and the back end's output streaming beside
them. The questions are all asked before anything touches a disk; the answers
go to starch-backend as a file, and its line protocol drives the last screen.
"""

from __future__ import annotations

import asyncio
import re
import sys

from rich.text import Text
from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Center, Horizontal, Middle, Vertical, VerticalScroll
from textual.screen import ModalScreen, Screen
from textual.theme import Theme
from textual.widgets import (
    Button, ContentSwitcher, DataTable, Input, Label, OptionList, ProgressBar,
    RadioButton, RadioSet, RichLog, Static, Switch,
)
from textual.widgets.option_list import Option

from . import system

LOGO = r"""
███████╗████████╗ █████╗ ██████╗  ██████╗██╗  ██╗
██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██╔════╝██║  ██║
███████╗   ██║   ███████║██████╔╝██║     ███████║
╚════██║   ██║   ██╔══██║██╔══██╗██║     ██╔══██║
███████║   ██║   ██║  ██║██║  ██║╚██████╗██║  ██║
╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝
""".strip("\n")

# starch's colours, as on the website and the boot splash: the sapphire-to-
# blue gradient with lavender at the top of the mark, on Catppuccin's darkest
# base. Text is brighter than Catppuccin's and muted text much brighter than
# Textual's dimmed default: on a console across the room, contrast is what
# makes it readable.
SAPPHIRE, BLUE, LAVENDER = "#74c7ec", "#89b4fa", "#b4befe"
GREEN, YELLOW, RED = "#a6e3a1", "#f9e2af", "#f7768e"

STARCH_THEME = Theme(
    name="starch",
    primary=SAPPHIRE,
    secondary=BLUE,
    accent=LAVENDER,
    success=GREEN,
    warning=YELLOW,
    error=RED,
    foreground="#e6e9f8",
    background="#11111b",
    surface="#1a1a28",
    panel="#232336",
    dark=True,
    text_alpha=1.0,
    variables={
        "text-muted": "#b6bcd2",
        "input-selection-background": f"{SAPPHIRE} 40%",
        "footer-key-foreground": SAPPHIRE,
    },
)


def logo() -> Text:
    """The block letters in the splash's gradient, lavender down to sapphire."""
    rgb = lambda c: [int(c[i:i + 2], 16) for i in (1, 3, 5)]  # noqa: E731
    top, bottom = rgb(LAVENDER), rgb(SAPPHIRE)
    rows = LOGO.splitlines()
    t = Text()
    for n, row in enumerate(rows):
        f = n / (len(rows) - 1)
        colour = "".join(f"{round(a + (b - a) * f):02x}" for a, b in zip(top, bottom))
        t.append(row, style=f"bold #{colour}")
        if n < len(rows) - 1:
            t.append("\n")
    return t

STEPS = ["Keyboard", "Disk", "Account", "Review"]

HOSTNAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$")
USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")


# ── dialogs ──────────────────────────────────────────────────────────────────

class Confirm(ModalScreen[bool]):
    """A yes/no question over the current screen."""

    BINDINGS = [Binding("escape", "dismiss(False)", "Cancel")]

    def __init__(self, title: str, body: str, yes: str, no: str = "Cancel",
                 danger: bool = False) -> None:
        super().__init__()
        self.title_text, self.body, self.yes, self.no, self.danger = title, body, yes, no, danger

    def compose(self) -> ComposeResult:
        with Vertical(id="dialog", classes="danger" if self.danger else ""):
            yield Label(self.title_text, id="dialog-title")
            yield Static(self.body, id="dialog-body")
            with Horizontal(id="dialog-buttons"):
                yield Button(self.no, id="no")
                yield Button(self.yes, id="yes", variant="error" if self.danger else "primary")

    def on_mount(self) -> None:
        self.query_one("#no", Button).focus()

    @on(Button.Pressed)
    def answer(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")


# ── welcome ──────────────────────────────────────────────────────────────────

class Welcome(Screen):
    BINDINGS = [Binding("enter", "begin", "Begin", show=False)]

    def compose(self) -> ComposeResult:
        with Middle():
            with Center():
                yield Static(logo(), id="logo")
            with Center():
                yield Label("Arch Linux  +  Hyprland", id="tagline")
            with Center():
                yield Label(system.machine(), id="machine")
            with Center():
                yield Static(
                    "Installs Arch exactly as the install guide does, then the desktop.\n"
                    "Needs no network. Nothing is written to a disk until you say so.",
                    id="intro")
            with Center():
                with Horizontal(id="welcome-buttons"):
                    yield Button("Begin", id="begin", variant="primary")
                    yield Button("Shell", id="shell")

    def on_mount(self) -> None:
        self.query_one("#begin", Button).focus()
        if not system.uefi():
            self.app.push_screen(Confirm(
                "This machine booted in BIOS mode",
                "starch installs for UEFI only. Reboot and choose the UEFI entry for "
                "this USB stick in the firmware's boot menu.", "Shell", "Back"))

    def action_begin(self) -> None:
        self.app.switch_screen(Wizard())

    @on(Button.Pressed, "#begin")
    def begin(self) -> None:
        self.action_begin()

    @on(Button.Pressed, "#shell")
    def shell(self) -> None:
        self.app.exit(None)


# ── the wizard ───────────────────────────────────────────────────────────────

class Sidebar(Static):
    """The step list down the left: done, current, still to come."""

    def show(self, current: int) -> None:
        t = Text()
        t.append("starch\n\n", style=f"bold {SAPPHIRE}")
        for i, name in enumerate(STEPS):
            if i < current:
                t.append("  ✓  ", style=f"bold {GREEN}")
                t.append(f"{name}\n\n", style="")
            elif i == current:
                t.append("  ●  ", style=f"bold {SAPPHIRE}")
                t.append(f"{name}\n\n", style="bold")
            else:
                t.append("  ○  ", style="#7f849c")
                t.append(f"{name}\n\n", style="#b6bcd2")
        self.update(t)


class Wizard(Screen):
    BINDINGS = [
        Binding("ctrl+q", "quit_installer", "Quit"),
        Binding("escape", "back", "Back"),
    ]

    def __init__(self, start: int = 0) -> None:
        super().__init__()
        self.step = start
        self.disks: list[system.Disk] = []

    # ── layout ──
    def compose(self) -> ComposeResult:
        with Center(id="frame-wrap"):
            with Horizontal(id="frame"):
                yield Sidebar(id="sidebar")
                with Vertical(id="main"):
                    yield Label("", id="heading")
                    yield Label("", id="subheading")
                    with ContentSwitcher(id="pages", initial="page-0"):
                        yield from self.page_keyboard()
                        yield from self.page_disk()
                        yield from self.page_account()
                        yield from self.page_review()
                    yield Label("", id="problem")
                    with Horizontal(id="nav"):
                        yield Button("Back", id="back")
                        yield Button("Next", id="next", variant="primary")

    def page_keyboard(self) -> ComposeResult:
        with Vertical(id="page-0", classes="page"):
            opts = [Option(f"{name:<24}{km}", id=km) for name, km in system.COMMON_KEYMAPS]
            opts.append(Option("Other…  (search every console keymap)", id="__other__"))
            yield OptionList(*opts, id="keymaps")
            yield Input(placeholder="Search keymaps", id="keymap-search", classes="hidden")
            yield OptionList(id="keymap-all", classes="hidden")
            yield Input(placeholder="Type here to try the layout", id="keytest")

    def page_disk(self) -> ComposeResult:
        with Vertical(id="page-1", classes="page"):
            yield DataTable(id="disks", cursor_type="row", zebra_stripes=True)
            yield Static("", id="disk-contents")
            yield Label("Use", classes="optlabel")
            with RadioSet(id="mode"):
                yield RadioButton("Erase the whole disk", id="erase", value=True)
                yield RadioButton("Free space only", id="alongside")
            with Horizontal(id="disk-options"):
                with Vertical(classes="optgroup"):
                    yield Label("Filesystem", classes="optlabel")
                    with RadioSet(id="fstype"):
                        yield RadioButton("ext4", id="ext4", value=True)
                        yield RadioButton("btrfs  (@, @home, zstd)", id="btrfs")
                with Vertical(classes="optgroup"):
                    yield Label("Encrypt (LUKS2)", classes="optlabel")
                    yield Switch(id="encrypt")

    def page_account(self) -> ComposeResult:
        with VerticalScroll(id="page-2", classes="page"):
            with Horizontal(classes="row"):
                with Vertical(classes="field"):
                    yield Label("Your name for logging in", classes="flabel")
                    yield Input(placeholder="lowercase, e.g. alex", id="username")
                with Vertical(classes="field"):
                    yield Label("This machine's name", classes="flabel")
                    yield Input(value="starch", id="hostname")
            with Horizontal(classes="row"):
                with Vertical(classes="field"):
                    yield Label("Password", classes="flabel")
                    yield Input(password=True, id="password")
                with Vertical(classes="field"):
                    yield Label("Password again", classes="flabel")
                    yield Input(password=True, id="password2")
            with Horizontal(classes="row", id="luks-row"):
                yield Label("Unlock the disk with the same password", classes="flabel inline")
                yield Switch(value=True, id="same-pass")
            with Horizontal(classes="row hidden", id="luks-pass-row"):
                with Vertical(classes="field"):
                    yield Label("Disk passphrase", classes="flabel")
                    yield Input(password=True, id="passphrase")
                with Vertical(classes="field"):
                    yield Label("Passphrase again", classes="flabel")
                    yield Input(password=True, id="passphrase2")
            yield Label("Timezone", classes="flabel")
            yield Input(placeholder="Type to search, e.g. Chicago", id="tz-search")
            yield OptionList(*[Option(z, id=z) for z in system.timezones()], id="timezones")

    def page_review(self) -> ComposeResult:
        with Vertical(id="page-3", classes="page"):
            yield DataTable(id="review", show_cursor=False, show_header=False)
            yield Static("", id="warning")

    # ── state ──
    def on_mount(self) -> None:
        self.query_one(Sidebar).show(self.step)
        table = self.query_one("#disks", DataTable)
        table.add_columns("Disk", "Size", "Model", "Free")
        self.disks = system.disks()
        for d in self.disks:
            table.add_row(d.path, system.human(d.size), d.label,
                          system.human(d.free) if d.free else "—", key=d.path)
        self.query_one("#review", DataTable).add_columns("", "")
        saved = system.load_state()
        if saved.get("keymap"):
            self.select_keymap(saved["keymap"])
        else:
            self.query_one("#keymaps", OptionList).highlighted = 0
        self.query_one("#timezones", OptionList).highlighted = 0
        self.show_step()

    def show_step(self) -> None:
        heads = [
            ("Keyboard", "The layout of the keys in front of you. Try it in the box below."),
            ("Disk", "Where Arch goes. The disk this USB stick is on is not listed."),
            ("Account", "You, this machine, and where it is."),
            ("Review", "Everything, one last time. Nothing has been written yet."),
        ]
        h, s = heads[self.step]
        self.query_one("#heading", Label).update(h)
        self.query_one("#subheading", Label).update(s)
        self.query_one("#pages", ContentSwitcher).current = f"page-{self.step}"
        self.query_one(Sidebar).show(self.step)
        self.query_one("#back", Button).disabled = self.step == 0
        nxt = self.query_one("#next", Button)
        if self.step == 3:
            erase = self.mode() == "erase"
            nxt.label = "Erase and install" if erase else "Install"
            nxt.variant = "error" if erase else "success"
            self.fill_review()
        else:
            nxt.label, nxt.variant = "Next", "primary"
        self.problem("")
        focus = {0: "#keymaps", 1: "#disks", 2: "#username", 3: "#next"}[self.step]
        self.query_one(focus).focus()
        if self.step == 1:
            self.update_disk()
        if self.step == 2:
            self.query_one("#luks-row").display = self.encrypt()

    def problem(self, text: str) -> None:
        self.query_one("#problem", Label).update(text)

    @on(Input.Changed)
    @on(Switch.Changed)
    @on(RadioSet.Changed)
    def clear_problem(self) -> None:
        # Whatever was wrong may not be any more; say so again on Next if it is.
        self.problem("")

    # ── keyboard ──
    def select_keymap(self, km: str) -> None:
        ol = self.query_one("#keymaps", OptionList)
        try:
            ol.highlighted = ol.get_option_index(km)
        except Exception:
            self.show_all_keymaps()
            allk = self.query_one("#keymap-all", OptionList)
            try:
                allk.highlighted = allk.get_option_index(km)
            except Exception:
                pass

    def keymap(self) -> str:
        allk = self.query_one("#keymap-all", OptionList)
        if allk.display and allk.highlighted is not None:
            return allk.get_option_at_index(allk.highlighted).id or "us"
        ol = self.query_one("#keymaps", OptionList)
        if ol.highlighted is None:
            return "us"
        km = ol.get_option_at_index(ol.highlighted).id
        return "us" if km == "__other__" else km

    def show_all_keymaps(self, query: str = "") -> None:
        allk = self.query_one("#keymap-all", OptionList)
        search = self.query_one("#keymap-search", Input)
        self.query_one("#keymaps").display = False
        allk.display = search.display = True
        allk.clear_options()
        allk.add_options([Option(k, id=k) for k in system.all_keymaps() if query.lower() in k.lower()])
        if allk.option_count:
            allk.highlighted = 0

    @on(OptionList.OptionSelected, "#keymaps")
    def keymap_chosen(self, event: OptionList.OptionSelected) -> None:
        if event.option.id == "__other__":
            self.show_all_keymaps()
            self.query_one("#keymap-search", Input).focus()
        else:
            self.query_one("#keytest", Input).focus()

    @on(Input.Changed, "#keymap-search")
    def keymap_search(self, event: Input.Changed) -> None:
        self.show_all_keymaps(event.value)

    @on(OptionList.OptionHighlighted, "#keymaps")
    @on(OptionList.OptionHighlighted, "#keymap-all")
    def keymap_preview(self) -> None:
        if not system.on_kmscon():
            km = self.keymap()
            if km != "__other__":
                system.apply_keymap(km)

    # ── disk ──
    def disk(self) -> system.Disk | None:
        table = self.query_one("#disks", DataTable)
        if not self.disks or table.cursor_row is None:
            return None
        return self.disks[table.cursor_row]

    def mode(self) -> str:
        btn = self.query_one("#mode", RadioSet).pressed_button
        return btn.id if btn else "erase"

    def fstype(self) -> str:
        btn = self.query_one("#fstype", RadioSet).pressed_button
        return btn.id if btn else "ext4"

    def encrypt(self) -> bool:
        return self.query_one("#encrypt", Switch).value

    @on(DataTable.RowHighlighted, "#disks")
    def update_disk(self) -> None:
        d = self.disk()
        contents = self.query_one("#disk-contents", Static)
        alongside = self.query_one("#alongside", RadioButton)
        if d is None:
            contents.update("No disk of 20 GB or more was found to install onto.")
            return
        lines = d.partitions or ["(empty — no partitions)"]
        contents.update(Text("\n".join(lines), style="dim"))
        can = d.gpt and d.free >= system.MIN_DISK
        alongside.disabled = not can
        alongside.label = (f"Free space only  ({system.human(d.free)}, keep the rest)" if can
                           else "Free space only  (needs 20 GB unallocated on GPT)")
        if not can and alongside.value:
            self.query_one("#erase", RadioButton).value = True

    # ── account ──
    @on(Switch.Changed, "#same-pass")
    def same_pass(self, event: Switch.Changed) -> None:
        self.query_one("#luks-pass-row").set_class(event.value, "hidden")

    @on(Input.Changed, "#tz-search")
    def tz_search(self, event: Input.Changed) -> None:
        ol = self.query_one("#timezones", OptionList)
        q = event.value.lower().replace(" ", "_")
        ol.clear_options()
        ol.add_options([Option(z, id=z) for z in system.timezones() if q in z.lower()])
        if ol.option_count:
            ol.highlighted = 0

    def timezone(self) -> str:
        ol = self.query_one("#timezones", OptionList)
        if ol.highlighted is None:
            return ""
        return ol.get_option_at_index(ol.highlighted).id or ""

    def check_account(self) -> str:
        v = lambda i: self.query_one(i, Input).value  # noqa: E731
        u, h = v("#username"), v("#hostname")
        if not USERNAME_RE.match(u):
            return "Username: start with a lowercase letter; then lowercase letters, digits, - and _."
        if system.reserved_user(u):
            return f"Username: {u} is a system account. Choose another."
        if not HOSTNAME_RE.match(h):
            return "Machine name: letters, digits and hyphens, not starting with a hyphen."
        if not v("#password"):
            return "Password: it cannot be empty."
        if v("#password") != v("#password2"):
            return "Password: the two do not match."
        if self.encrypt() and not self.query_one("#same-pass", Switch).value:
            if not v("#passphrase"):
                return "Disk passphrase: it cannot be empty."
            if v("#passphrase") != v("#passphrase2"):
                return "Disk passphrase: the two do not match."
        if not self.timezone():
            return "Timezone: nothing matches that search."
        return ""

    # ── review ──
    def answers(self) -> dict:
        d = self.disk()
        v = lambda i: self.query_one(i, Input).value  # noqa: E731
        enc = self.encrypt()
        same = self.query_one("#same-pass", Switch).value
        return {
            "keymap": self.keymap(),
            "disk": d.path if d else "",
            "mode": self.mode(),
            "free": d.free if d else 0,
            "fstype": self.fstype(),
            "encrypt": "yes" if enc else "no",
            "hostname": v("#hostname"),
            "username": v("#username"),
            "password": v("#password"),
            "passphrase": (v("#password") if same else v("#passphrase")) if enc else "",
            "timezone": self.timezone(),
        }

    def fill_review(self) -> None:
        a = self.answers()
        d = self.disk()
        t = self.query_one("#review", DataTable)
        t.clear()
        where = (f"{a['disk']}  {d.label}  — everything on it is erased" if a["mode"] == "erase"
                 else f"{a['disk']}  — {system.human(a['free'])} of free space, nothing else touched")
        rows = [
            ("Disk", where),
            ("Filesystem", a["fstype"] + (", encrypted with LUKS2" if a["encrypt"] == "yes" else "")),
            ("Keyboard", a["keymap"]),
            ("User", a["username"]),
            ("Password", "•" * len(a["password"])),
            ("Machine name", a["hostname"]),
            ("Timezone", a["timezone"]),
        ]
        if system.is_apple():
            rows.append(("Mac support", "Broadcom bluetooth firmware, and the wl driver if the card needs it"))
        for k, val in rows:
            t.add_row(Text(k, style="bold"), val)
        warn = self.query_one("#warning", Static)
        if a["mode"] == "erase":
            warn.update(Text(f"Everything on {a['disk']} will be erased:\n" + "\n".join(d.partitions or ["(empty)"]),
                             style=f"bold {RED}"))
        else:
            warn.update("")

    # ── navigation ──
    def action_back(self) -> None:
        if self.step > 0:
            self.step -= 1
            self.show_step()

    @on(Button.Pressed, "#back")
    def back(self) -> None:
        self.action_back()

    @on(Button.Pressed, "#next")
    def next(self) -> None:
        if self.step == 0:
            km = self.keymap()
            system.save_state({"keymap": km})
            if system.apply_keymap(km):
                # kmscon is being restarted with the new layout; the session
                # ends here and the installer resumes at the disk step.
                self.app.exit("restart")
                return
        elif self.step == 1:
            if self.disk() is None:
                self.problem("There is no disk to install onto.")
                return
        elif self.step == 2:
            msg = self.check_account()
            if msg:
                self.problem(msg)
                return
        elif self.step == 3:
            self.confirm_install()
            return
        self.step += 1
        self.show_step()

    @work
    async def confirm_install(self) -> None:
        a = self.answers()
        if a["mode"] == "erase":
            ok = await self.app.push_screen_wait(Confirm(
                f"Erase {a['disk']}?",
                f"Everything on {a['disk']} is destroyed, and Arch is installed in its place.\n"
                "This cannot be undone.", "Erase and install", danger=True))
        else:
            ok = await self.app.push_screen_wait(Confirm(
                "Install into the free space?",
                f"New partitions are made in the {system.human(a['free'])} of free space on "
                f"{a['disk']}. Existing partitions are not touched.", "Install"))
        if ok:
            self.app.switch_screen(Installing(a))

    @work
    async def action_quit_installer(self) -> None:
        if await self.app.push_screen_wait(Confirm(
                "Leave the installer?", "Nothing has been written to any disk.", "Quit", "Keep going")):
            self.app.exit(None)


# ── installing ───────────────────────────────────────────────────────────────

class Steps(Static):
    def __init__(self, **kw) -> None:
        super().__init__(**kw)
        self.items: list[tuple[str, str]] = []   # (state, title)
        self.frame = 0

    def render_steps(self) -> None:
        spin = "▖▘▝▗"[self.frame % 4]
        t = Text()
        for state, title in self.items:
            icon, style = {"run": (spin, f"bold {SAPPHIRE}"), "ok": ("✓", f"bold {GREEN}"),
                           "fail": ("✗", f"bold {RED}")}[state]
            t.append(f" {icon}  ", style=style)
            t.append(f"{title}\n", style="bold" if state == "run" else "")
        self.update(t)

    def tick(self) -> None:
        self.frame += 1
        if any(s == "run" for s, _ in self.items):
            self.render_steps()


class Installing(Screen):
    BINDINGS = [Binding("ctrl+l", "toggle_log", "Log")]

    def __init__(self, answers: dict) -> None:
        super().__init__()
        self.answers = answers
        self.planned = 8
        self.done_steps = 0
        self.finished = False

    def compose(self) -> ComposeResult:
        with Center(id="frame-wrap"):
            with Vertical(id="install-frame"):
                yield Label("Installing", id="heading")
                yield Label(f"onto {self.answers['disk']}. This takes a while; the long step is the desktop.",
                            id="subheading")
                yield ProgressBar(total=100, show_eta=False, id="progress")
                with Horizontal(id="install-body"):
                    yield Steps(id="steps")
                    yield RichLog(id="log", wrap=True, markup=False, max_lines=4000)
                yield Label("", id="status")
                with Horizontal(id="done-buttons", classes="hidden"):
                    yield Button("Reboot", id="reboot", variant="success")
                    yield Button("Power off", id="poweroff")
                    yield Button("Shell", id="shell")

    def on_mount(self) -> None:
        self.set_interval(0.15, self.query_one(Steps).tick)
        self.run_backend()

    def event(self, kind: str, text: str) -> None:
        steps = self.query_one(Steps)
        log = self.query_one("#log", RichLog)
        status = self.query_one("#status", Label)
        if kind == "plan":
            self.planned = int(text or 8)
        elif kind == "step":
            steps.items = [("ok", t) if s == "run" else (s, t) for s, t in steps.items]
            steps.items.append(("run", text))
            self.done_steps = len(steps.items) - 1
            self.query_one(ProgressBar).update(progress=100 * self.done_steps / self.planned)
            log.write(Text(f"\n── {text}", style=f"bold {SAPPHIRE}"))
            status.update(text)
        elif kind == "ok":
            log.write(Text(f"✓ {text}", style=GREEN))
        elif kind == "warn":
            log.write(Text(f"! {text}", style=f"bold {YELLOW}"))
        elif kind == "fail":
            steps.items = [("fail", t) if s == "run" else (s, t) for s, t in steps.items]
            log.write(Text(f"✗ {text}", style=f"bold {RED}"))
            status.update(Text(f"The install stopped: {text}", style=f"bold {RED}"))
            self.end(ok=False)
        elif kind == "done":
            steps.items = [("ok", t) for _, t in steps.items]
            self.query_one(ProgressBar).update(progress=100)
            status.update(Text(f"starch is installed. Remove the USB stick, reboot, and log in as "
                               f"{self.answers['username']}.", style=f"bold {GREEN}"))
            self.end(ok=True)
        steps.render_steps()

    def end(self, ok: bool) -> None:
        self.finished = True
        self.query_one("#heading", Label).update("Installed" if ok else "Install failed")
        self.query_one("#subheading", Label).update(
            "" if ok else "The log is at /var/log/starch-install.log, and on the target if it got that far.")
        buttons = self.query_one("#done-buttons")
        buttons.remove_class("hidden")
        self.query_one("#reboot", Button).display = ok
        self.query_one("#poweroff", Button).display = ok
        self.query_one("#reboot" if ok else "#shell", Button).focus()

    @work(exclusive=True)
    async def run_backend(self) -> None:
        path = system.write_answers(self.answers)
        proc = await asyncio.create_subprocess_exec(
            *system.backend_command(path),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            stdin=asyncio.subprocess.DEVNULL)
        log = self.query_one("#log", RichLog)
        assert proc.stdout
        while True:
            raw = await proc.stdout.readline()
            if not raw:
                break
            line = raw.decode(errors="replace").rstrip("\n")
            # pacman and friends redraw progress with carriage returns; keep
            # the last state of each line rather than every frame of it.
            line = line.split("\r")[-1]
            if line.startswith("::"):
                kind, _, text = line[2:].partition(" ")
                self.event(kind, text)
            else:
                log.write(line)
        rc = await proc.wait()
        if not self.finished:
            self.event("fail", f"the installer exited ({rc}) without saying why")

    def action_toggle_log(self) -> None:
        log = self.query_one("#log")
        log.display = not log.display

    @on(Button.Pressed, "#reboot")
    def reboot(self) -> None:
        self.app.exit("reboot")

    @on(Button.Pressed, "#poweroff")
    def poweroff(self) -> None:
        self.app.exit("poweroff")

    @on(Button.Pressed, "#shell")
    def shell(self) -> None:
        self.app.exit(None)


# ── the app ──────────────────────────────────────────────────────────────────

class StarchInstaller(App):
    CSS_PATH = "app.tcss"
    TITLE = "starch"
    ENABLE_COMMAND_PALETTE = False

    def on_mount(self) -> None:
        self.register_theme(STARCH_THEME)
        self.theme = "starch"
        # Back from a kmscon restart for the keyboard layout: carry on where
        # the person was, not at the welcome screen.
        if system.load_state().get("keymap") and "--resume" in sys.argv:
            self.push_screen(Wizard(start=1))
        else:
            self.push_screen(Welcome())


def main() -> None:
    result = StarchInstaller().run()
    # The launcher reads this: reboot, poweroff, restart (kmscon is coming
    # back with a new keyboard layout), or nothing for a shell.
    sys.exit({"reboot": 10, "poweroff": 11, "restart": 12}.get(result or "", 0))
