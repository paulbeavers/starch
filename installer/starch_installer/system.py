"""What the installer asks the live system: disks, keymaps, timezones.

Every query is here so the screens stay about the screens, and so the whole
front end can run on a development machine with STARCH_FAKE=1 — fake disks,
a fake back end — which is how it is tested without a VM.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from zoneinfo import available_timezones

FAKE = os.environ.get("STARCH_FAKE") == "1"

HERE = Path(__file__).resolve().parent
BACKEND = Path(os.environ.get("STARCH_BACKEND", "/usr/local/lib/starch/starch-backend"))
WORK = Path(os.environ.get("STARCH_WORK", "/run/starch"))
STATE = WORK / "state.json"
KMSCON_CONF = Path("/etc/kmscon/kmscon.conf")
KBD_MODEL_MAP = Path("/usr/share/systemd/kbd-model-map")

GIB = 1024 ** 3
MIN_DISK = 20 * GIB


def run(*cmd: str) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=False).stdout
    except FileNotFoundError:
        return ""


def human(n: int) -> str:
    for unit in ("B", "K", "M", "G", "T"):
        if n < 1024 or unit == "T":
            return f"{n:.0f}{unit}" if unit in ("B", "K") else f"{n:.1f}{unit}".replace(".0", "")
        n /= 1024
    return str(n)


# ── the machine ──────────────────────────────────────────────────────────────

def machine() -> str:
    """One line about the hardware, for the welcome screen."""
    if FAKE:
        return "MacBookPro11,3  ·  16 GB  ·  Intel Core i7-4850HQ"
    dmi = Path("/sys/class/dmi/id")
    name = (dmi / "product_name").read_text().strip() if (dmi / "product_name").exists() else ""
    mem = 0
    for line in Path("/proc/meminfo").read_text().splitlines():
        if line.startswith("MemTotal:"):
            mem = int(line.split()[1]) * 1024
    cpu = ""
    for line in Path("/proc/cpuinfo").read_text().splitlines():
        if line.startswith("model name"):
            cpu = line.split(":", 1)[1].strip()
            for junk in ("(R)", "(TM)", " CPU", "@"):
                cpu = cpu.replace(junk, "")
            cpu = cpu.split("  ")[0].strip()
            break
    parts = [p for p in (name, f"{round(mem / GIB)} GB" if mem else "", cpu) if p]
    return "  ·  ".join(parts)


def is_apple() -> bool:
    if FAKE:
        return True
    p = Path("/sys/class/dmi/id/sys_vendor")
    return p.exists() and p.read_text().strip() == "Apple Inc."


def uefi() -> bool:
    return FAKE or Path("/sys/firmware/efi").exists()


# ── disks ────────────────────────────────────────────────────────────────────

@dataclass
class Disk:
    path: str
    size: int
    model: str
    transport: str
    gpt: bool = False
    free: int = 0
    partitions: list[str] = field(default_factory=list)

    @property
    def label(self) -> str:
        return f"{self.model or 'Disk'}"


def _medium_disk() -> str:
    """The disk the medium was booted from, which is never offered."""
    src = run("findmnt", "-nvo", "SOURCE", "/run/archiso/bootmnt").strip()
    if not src:
        return ""
    parent = run("lsblk", "-npo", "PKNAME", src).strip().splitlines()
    return parent[0] if parent and parent[0] else src


def _largest_free(path: str) -> int:
    """The largest unallocated block, by sgdisk's own reckoning — the same
    block the back end's sgdisk -n 0:0:... will use."""
    try:
        ss = int(run("blockdev", "--getss", path).strip())
        first = int(run("sgdisk", "-F", path).strip().splitlines()[-1])
        last = int(run("sgdisk", "-E", path).strip().splitlines()[-1])
    except (ValueError, IndexError):
        return 0
    return (last - first + 1) * ss if last > first else 0


def disks() -> list[Disk]:
    if FAKE:
        return [
            Disk("/dev/nvme0n1", 500 * GIB, "APPLE SSD SM0512F", "nvme", True, 120 * GIB,
                 ["nvme0n1p1   300M  vfat   EFI", "nvme0n1p2   380G  apfs   Macintosh HD"]),
            Disk("/dev/sda", 64 * GIB, "SanDisk Ultra", "usb", False, 0, []),
        ]
    medium = _medium_disk()
    data = json.loads(run("lsblk", "-J", "-b", "-d", "-o", "PATH,SIZE,RO,TYPE,MODEL,TRAN") or "{}")
    found = []
    for d in data.get("blockdevices", []):
        path = d.get("path", "")
        if d.get("type") != "disk" or d.get("ro") or path == medium:
            continue
        if any(path.startswith(p) for p in ("/dev/loop", "/dev/sr", "/dev/zram", "/dev/ram")):
            continue
        size = int(d.get("size") or 0)
        if size < MIN_DISK:
            continue
        pttype = run("blkid", "-po", "value", "-s", "PTTYPE", path).strip()
        disk = Disk(path, size, (d.get("model") or "").strip(), d.get("tran") or "")
        disk.gpt = pttype == "gpt"
        disk.free = _largest_free(path) if disk.gpt else 0
        # By type, not by skipping the first line: an open LUKS mapping or
        # RAID member adds rows, and the disk itself came through as one.
        rows = json.loads(run("lsblk", "-J", "-lo", "NAME,SIZE,FSTYPE,LABEL,TYPE", path) or "{}")
        disk.partitions = [" ".join(str(r.get(k) or "") for k in ("name", "size", "fstype", "label")).strip()
                           for r in rows.get("blockdevices", []) if r.get("type") == "part"]
        found.append(disk)
    return found


# ── keyboard ─────────────────────────────────────────────────────────────────
# The common layouts by name. localectl lists every console keymap kbd ships,
# some 250 names with no description, which is the list behind "Other". An
# Intel MacBook with a US keyboard wants plain "us": the mac-* keymaps are for
# old Apple keyboards and get keys wrong on these. Every name here is in
# systemd's kbd-model-map, which is how the back end finds the desktop layout.
COMMON_KEYMAPS = [
    ("English (US)", "us"),
    ("English (UK)", "uk"),
    ("German", "de-latin1"),
    ("French", "fr-latin1"),
    ("Spanish", "es"),
    ("Italian", "it"),
    ("Portuguese", "pt-latin1"),
    ("Portuguese (Brazil)", "br-abnt2"),
    ("Latin American", "la-latin1"),
    ("French (Canada)", "cf"),
    ("Swiss German", "sg"),
    ("Swiss French", "fr_CH-latin1"),
    ("Belgian", "be-latin1"),
    ("Dutch", "nl"),
    ("Swedish", "sv-latin1"),
    ("Norwegian", "no"),
    ("Danish", "dk-latin1"),
    ("Finnish", "fi"),
    ("Polish", "pl2"),
    ("Russian", "ru"),
    ("Japanese", "jp106"),
]


def all_keymaps() -> list[str]:
    if FAKE:
        return sorted({k for _, k in COMMON_KEYMAPS} | {"dvorak", "colemak", "mac-us", "trq"})
    return [k for k in run("localectl", "list-keymaps").split() if k]


def xkb_for(keymap: str) -> tuple[str, str, str]:
    """(layout, variant, options) for a console keymap, from systemd's table."""
    if KBD_MODEL_MAP.exists():
        for line in KBD_MODEL_MAP.read_text().splitlines():
            f = line.split()
            if len(f) >= 5 and f[0] == keymap:
                dash = lambda s: "" if s == "-" else s  # noqa: E731
                opts = ",".join(o for o in dash(f[4]).split(",") if o and not o.startswith("terminate:"))
                return f[1], dash(f[3]), opts
    return "us", "", ""


def on_kmscon() -> bool:
    return os.environ.get("STARCH_KMSCON") == "1"


def current_kmscon_layout() -> str:
    if KMSCON_CONF.exists():
        for line in KMSCON_CONF.read_text().splitlines():
            if line.startswith("xkb-layout="):
                return line.split("=", 1)[1].strip()
    return "us"


def apply_keymap(keymap: str) -> bool:
    """Make the keys typed into the installer match the layout chosen.

    On the plain console that is loadkeys. kmscon reads the keyboard through
    xkb and only at start, so its config is rewritten and it is restarted;
    the front end saves its answers first and resumes after. Returns True when
    a restart is coming and the front end should exit.
    """
    if FAKE:
        return False
    if not on_kmscon():
        run("loadkeys", keymap)
        return False
    layout, variant, options = xkb_for(keymap)
    if layout == current_kmscon_layout():
        return False
    lines = [l for l in KMSCON_CONF.read_text().splitlines()
             if not l.startswith(("xkb-layout=", "xkb-variant=", "xkb-options="))]
    lines += [f"xkb-layout={layout}", f"xkb-variant={variant}", f"xkb-options={options}"]
    KMSCON_CONF.write_text("\n".join(lines) + "\n")
    # Detached, so the restart outlives the session it is about to end. A
    # transient timer is accurate to a minute unless told otherwise, which
    # left ten seconds of a blank console.
    run("systemd-run", "--no-block", "--on-active=1", "--timer-property=AccuracySec=100ms",
        "--unit=starch-kmscon-restart", "systemctl", "restart", "kmsconvt@tty1.service")
    return True


# ── timezone ─────────────────────────────────────────────────────────────────

def timezones() -> list[str]:
    zones = sorted(z for z in available_timezones()
                   if "/" in z and not z.startswith(("Etc/", "SystemV/", "posix/", "right/")))
    return ["UTC"] + zones


# ── accounts ─────────────────────────────────────────────────────────────────
# The installed system gets the same system accounts the medium has — both come
# from the filesystem and systemd packages — so the medium's passwd is a fair
# list of names a new user cannot take. The login manager's account is the
# exception: sddm is installed later, by install.sh, so the medium has none.

def reserved_user(name: str) -> bool:
    if FAKE:
        return name in ("root", "bin", "daemon", "nobody", "sddm")
    try:
        import pwd
        pwd.getpwnam(name)
        return True
    except KeyError:
        return name == "sddm"


# ── handing over ─────────────────────────────────────────────────────────────

def save_state(answers: dict) -> None:
    WORK.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(answers))
    STATE.chmod(0o600)


def load_state() -> dict:
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def write_answers(answers: dict) -> Path:
    """The answers as shell assignments, for the back end to source."""
    WORK.mkdir(parents=True, exist_ok=True)
    path = WORK / "answers.sh"
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        for k, v in answers.items():
            f.write(f"ANS[{k}]={shlex.quote(str(v))}\n")
    return path


def backend_command(answers_path: Path) -> list[str]:
    if FAKE:
        return ["bash", str(HERE / "fake-backend.sh"), str(answers_path)]
    return [str(BACKEND), str(answers_path)]
