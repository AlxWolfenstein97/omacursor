#!/usr/bin/env python3
"""OmaCursor — Adwaita cursors recolored from any Omarchy palette.

Discovers every theme with a colors.toml (no extra theme assets). Style-menu
mockups are a Catppuccin-style grid of real Adwaita frames recolored with the
same fill/outline map as apply — not live desktop captures. Apply writes an
alternating XCursor slot under ~/.local/share/icons/Omarchy-{a,b} (Hyprland
caches by theme *name*, so same-name overwrites never reload until reboot),
points the session at the new slot, and optionally mirrors to SDDM.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from functools import lru_cache
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont

PLUGIN_ID = "io.github.alxwolfenstein97.omacursor"
# Stable public name (symlink → active slot). SDDM always gets this name under
# /usr/share/icons/Omarchy when --with-sddm is enabled.
CURSOR_THEME_NAME = "Omarchy"
SLOT_A = "Omarchy-a"
SLOT_B = "Omarchy-b"
SLOTS = (SLOT_A, SLOT_B)
ADWAITA_CURSORS = Path("/usr/share/icons/Adwaita/cursors")
XCURSOR_IMAGE_TYPE = 0xFFFD0002
HEX_RE = re.compile(r"^#?[0-9A-Fa-f]{6}$")

MENU_START = "  // omacursor:start"
MENU_END = "  // omacursor:end"
HYPR_START = "-- omacursor:start"
HYPR_END = "-- omacursor:end"


def home() -> Path:
    return Path(os.environ.get("OMACURSOR_HOME", Path.home())).expanduser()


def omarchy_path() -> Path:
    return Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"))


def plugin_dir() -> Path:
    override = os.environ.get("OMACURSOR_PLUGIN_DIR")
    if override:
        return Path(override).expanduser()
    return Path(__file__).resolve().parent.parent


def paths() -> dict[str, Path]:
    h = home()
    icons = Path(
        os.environ.get(
            "OMACURSOR_ICONS_DIR",
            h / ".local/share/icons",
        )
    )
    state = Path(
        os.environ.get("OMACURSOR_STATE_DIR", h / ".local/state/omarchy/omacursor")
    )
    return {
        "user_themes": h / ".config/omarchy/themes",
        "stock_themes": omarchy_path() / "themes",
        "cursor_theme": icons / CURSOR_THEME_NAME,
        "icons": icons,
        "state": state,
        "slot_file": state / "slot",
        "sddm_marker": state / "sddm-linked",
        "cache": Path(
            os.environ.get("OMACURSOR_CACHE_DIR", h / ".cache/omarchy/omacursor")
        ),
        "menu": h / ".config/omarchy/extensions/omarchy-menu.jsonc",
        "hooks": h / ".config/omarchy/hooks/theme-set.d",
        "current_theme_name": h / ".local/state/omarchy/current/theme.name",
        "hyprland": h / ".config/hypr/hyprland.lua",
        "hypr_envs": h / ".config/hypr/omacursor-envs.lua",
        "env_d": h / ".config/environment.d/99-omacursor.conf",
    }


def note(msg: str) -> None:
    print(f"omacursor: {msg}", file=sys.stderr)


def slugify(name: str) -> str:
    cleaned = re.sub(r"<[^>]+>", "", name or "")
    return cleaned.strip().lower().replace(" ", "-")


def pretty_name(slug: str) -> str:
    return re.sub(
        r"(^|-)([a-z])",
        lambda m: (" " if m.group(1) == "-" else "") + m.group(2).upper(),
        slugify(slug),
    )


def parse_hex(value: str, fallback: str) -> str:
    raw = (value or fallback).strip().strip('"').strip("'")
    if not HEX_RE.match(raw):
        raw = fallback
    if not raw.startswith("#"):
        raw = "#" + raw
    return raw.lower()


def hex_to_rgb(value: str) -> tuple[int, int, int]:
    h = parse_hex(value, "#000000").lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def rgb_to_hex(rgb: tuple[int, int, int]) -> str:
    return "#{:02x}{:02x}{:02x}".format(*(max(0, min(255, int(c))) for c in rgb))


def mix(a: str, b: str, t: float) -> str:
    ar, ag, ab = hex_to_rgb(a)
    br, bg, bb = hex_to_rgb(b)
    return rgb_to_hex(
        (
            round(ar + (br - ar) * t),
            round(ag + (bg - ag) * t),
            round(ab + (bb - ab) * t),
        )
    )


def lighten(color: str, amount: float) -> str:
    return mix(color, "#ffffff", amount)


def darken(color: str, amount: float) -> str:
    return mix(color, "#000000", amount)


def luma(color: str) -> float:
    r, g, b = hex_to_rgb(color)
    return 0.299 * r + 0.587 * g + 0.114 * b


def on_color(base: str, candidates: list[str]) -> str:
    base_l = luma(base)
    return max(candidates, key=lambda c: abs(luma(c) - base_l))


def atomic_write(path: Path, text: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_colors_toml(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    text = path.read_text(encoding="utf-8")
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key:
            data[key] = value
    return data


def theme_dir(slug: str) -> Path | None:
    slug = slugify(slug)
    for root in (paths()["user_themes"], paths()["stock_themes"]):
        candidate = root / slug
        if (candidate / "colors.toml").is_file():
            return candidate
    return None


def list_theme_slugs() -> list[str]:
    found: set[str] = set()
    for root in (paths()["user_themes"], paths()["stock_themes"]):
        if not root.is_dir():
            continue
        for entry in root.iterdir():
            if entry.name.startswith("."):
                continue
            if entry.is_dir() or entry.is_symlink():
                if (entry / "colors.toml").is_file():
                    found.add(entry.name)
    return sorted(found)


def current_omarchy_slug() -> str | None:
    name_path = paths()["current_theme_name"]
    if name_path.is_file():
        return slugify(name_path.read_text(encoding="utf-8").strip())
    return None


def current_omacursor_slug() -> str | None:
    current = paths()["state"] / "current"
    if current.is_file():
        return slugify(current.read_text(encoding="utf-8").strip())
    return None


def palette_from_theme(slug: str) -> dict[str, Any]:
    directory = theme_dir(slug)
    if directory is None:
        raise FileNotFoundError(f"theme not found or missing colors.toml: {slug}")

    raw = read_colors_toml(directory / "colors.toml")
    mode = (raw.get("mode") or "dark").strip().lower()
    dark = mode != "light"

    background = parse_hex(raw.get("background", ""), "#1e1e2e")
    dark_background = parse_hex(raw.get("dark_background", ""), darken(background, 0.15))
    darker_background = parse_hex(raw.get("darker_background", ""), darken(background, 0.35))
    lighter_background = parse_hex(raw.get("lighter_background", ""), lighten(background, 0.12))
    foreground = parse_hex(raw.get("foreground", ""), "#cdd6f4")
    dark_foreground = parse_hex(raw.get("dark_foreground", ""), "#6c7086")
    light_foreground = parse_hex(raw.get("light_foreground", ""), foreground)
    bright_foreground = parse_hex(raw.get("bright_foreground", ""), light_foreground)
    muted = parse_hex(raw.get("muted", ""), dark_foreground)
    selection = parse_hex(raw.get("selection", ""), lighter_background)
    accent = parse_hex(raw.get("accent", raw.get("blue", "")), "#89b4fa")
    red = parse_hex(raw.get("red", ""), "#f38ba8")
    green = parse_hex(raw.get("green", ""), "#a6e3a1")
    yellow = parse_hex(raw.get("yellow", ""), "#f9e2af")

    # Adwaita is black fill + white outline. Map fill → accent (identity),
    # outline → high-contrast ink so the tip stays readable on any wallpaper.
    fill = accent
    outline = on_color(fill, [bright_foreground, foreground, background, "#ffffff", "#111111"])
    # Soft midtone for spinner/anti-alias mid-greys
    mid = mix(fill, outline, 0.45)

    return {
        "slug": slugify(slug),
        "name": pretty_name(slug),
        "mode": "dark" if dark else "light",
        "background": background,
        "dark_background": dark_background,
        "darker_background": darker_background,
        "lighter_background": lighter_background,
        "foreground": foreground,
        "dark_foreground": dark_foreground,
        "bright_foreground": bright_foreground,
        "muted": muted,
        "selection": selection,
        "accent": accent,
        "red": red,
        "green": green,
        "yellow": yellow,
        "fill": fill,
        "outline": outline,
        "mid": mid,
        "desktop": darker_background if dark else lighten(background, 0.08),
        "panel": dark_background if dark else background,
        "window": background,
        "window_border": mix(accent, muted, 0.35),
    }


# --------------------------------------------------------------------------- Xcursor


def _remap_pixel(
    r: int, g: int, b: int, a: int, fill: tuple[int, int, int], outline: tuple[int, int, int]
) -> tuple[int, int, int, int]:
    if a == 0:
        return r, g, b, a
    # Luma-lerp keeps Adwaita's anti-aliased edges intact.
    t = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
    nr = round(fill[0] + (outline[0] - fill[0]) * t)
    ng = round(fill[1] + (outline[1] - fill[1]) * t)
    nb = round(fill[2] + (outline[2] - fill[2]) * t)
    return nr, ng, nb, a


def recolor_xcursor(data: bytes, fill: tuple[int, int, int], outline: tuple[int, int, int]) -> bytes:
    if data[:4] != b"Xcur":
        return data
    out = bytearray(data)
    _magic, header, _version, ntoc = struct.unpack_from("<IIII", data, 0)
    for i in range(ntoc):
        typ, _subtype, pos = struct.unpack_from("<III", data, header + i * 12)
        if typ != XCURSOR_IMAGE_TYPE:
            continue
        chunk_header, _ct, _cs, _cv, width, height, _xhot, _yhot, _delay = struct.unpack_from(
            "<IIIIIIIII", data, pos
        )
        pix = pos + chunk_header
        for j in range(width * height):
            o = pix + j * 4
            b, g, r, a = out[o], out[o + 1], out[o + 2], out[o + 3]
            nr, ng, nb, na = _remap_pixel(r, g, b, a, fill, outline)
            out[o] = nb
            out[o + 1] = ng
            out[o + 2] = nr
            out[o + 3] = na
    return bytes(out)


def adwaita_source() -> Path:
    override = os.environ.get("OMACURSOR_ADWAITA")
    if override:
        return Path(override)
    if not ADWAITA_CURSORS.is_dir():
        raise FileNotFoundError(
            "Adwaita cursors missing — install adwaita-cursors (pacman -S adwaita-cursors)"
        )
    return ADWAITA_CURSORS


def write_index_theme(dest: Path, display: str, theme_name: str) -> None:
    atomic_write(
        dest / "index.theme",
        (
            "[Icon Theme]\n"
            f"Name={theme_name}\n"
            f"Comment=OmaCursor recolor of Adwaita — {display}\n"
            "Example=left_ptr\n"
            "Inherits=hicolor\n"
        ),
    )


def current_slot() -> str:
    path = paths()["slot_file"]
    if path.is_file():
        value = path.read_text(encoding="utf-8").strip()
        if value in SLOTS:
            return value
    return SLOT_A


def next_slot(current: str | None = None) -> str:
    active = current or current_slot()
    return SLOT_B if active == SLOT_A else SLOT_A


def slot_dir(name: str) -> Path:
    return paths()["icons"] / name


def point_stable_symlink(slot: str) -> None:
    """Keep ~/.local/share/icons/Omarchy → active slot for SDDM sync / docs."""
    stable = paths()["cursor_theme"]
    target = slot_dir(slot)
    if stable.is_symlink() or stable.exists():
        if stable.is_dir() and not stable.is_symlink():
            shutil.rmtree(stable)
        else:
            stable.unlink()
    stable.symlink_to(target.name)


def generate_cursor_theme(slug: str, dest_name: str | None = None) -> Path:
    """Recolor stock Adwaita into a slot directory (does not touch the live slot)."""
    palette = palette_from_theme(slug)
    src = adwaita_source()
    name = dest_name or next_slot()
    dest = slot_dir(name)
    cursors = dest / "cursors"

    # Stage into a temp dir then swap — never mutate the live slot in place.
    staging = dest.parent / f".{name}.staging"
    if staging.exists():
        shutil.rmtree(staging)
    (staging / "cursors").mkdir(parents=True)

    fill = hex_to_rgb(palette["fill"])
    outline = hex_to_rgb(palette["outline"])

    entries = sorted(src.iterdir(), key=lambda p: (p.is_symlink(), p.name))
    for entry in entries:
        target = staging / "cursors" / entry.name
        if entry.is_symlink():
            target.symlink_to(os.readlink(entry))
            continue
        if not entry.is_file():
            continue
        data = entry.read_bytes()
        if data[:4] == b"Xcur":
            data = recolor_xcursor(data, fill, outline)
        target.write_bytes(data)

    write_index_theme(staging, palette["name"], name)

    if dest.exists():
        shutil.rmtree(dest)
    staging.rename(dest)
    return dest


def cursor_size() -> int:
    env = os.environ.get("XCURSOR_SIZE") or os.environ.get("HYPRCURSOR_SIZE")
    if env and env.isdigit():
        return int(env)
    try:
        result = subprocess.run(
            ["gsettings", "get", "org.gnome.desktop.interface", "cursor-size"],
            check=False,
            capture_output=True,
            text=True,
        )
        value = (result.stdout or "").strip().strip("'")
        if value.isdigit():
            return int(value)
    except FileNotFoundError:
        pass
    return 24


def _run(cmd: list[str]) -> None:
    try:
        subprocess.run(cmd, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        pass


def ensure_hypr_envs(theme_name: str) -> None:
    """Persist XCURSOR_THEME across Hyprland reloads / logins."""
    p = paths()
    atomic_write(
        p["hypr_envs"],
        (
            f"-- Generated by OmaCursor ({PLUGIN_ID}); do not edit by hand.\n"
            f'hl.env("XCURSOR_THEME", "{theme_name}")\n'
        ),
    )
    # Login shells / uwsm also read environment.d
    atomic_write(
        p["env_d"],
        (
            f"# Generated by OmaCursor ({PLUGIN_ID}); do not edit by hand.\n"
            f"XCURSOR_THEME={theme_name}\n"
        ),
    )
    hl = p["hyprland"]
    if not hl.is_file():
        return
    content = hl.read_text(encoding="utf-8")
    content = remove_marked(content, HYPR_START, HYPR_END)
    block = f"\n{HYPR_START}\nrequire(\"hypr.omacursor-envs\")\n{HYPR_END}\n"
    if "require(\"hypr.autostart\")" in content:
        content = content.replace(
            'require("hypr.autostart")',
            'require("hypr.autostart")' + block,
            1,
        )
    else:
        content = content.rstrip() + "\n" + block
    atomic_write(hl, content)


def remove_hypr_envs() -> None:
    p = paths()
    if p["hypr_envs"].is_file():
        p["hypr_envs"].unlink()
    if p["env_d"].is_file():
        p["env_d"].unlink()
    hl = p["hyprland"]
    if hl.is_file():
        content = hl.read_text(encoding="utf-8")
        if HYPR_START in content:
            atomic_write(hl, remove_marked(content, HYPR_START, HYPR_END))


def force_reload_cursor(theme_name: str, size: int) -> None:
    """Hyprland caches cursors by theme name — bounce via Adwaita then the new slot."""
    _run(["hyprctl", "setcursor", "Adwaita", str(size)])
    time.sleep(0.05)
    _run(["hyprctl", "setcursor", theme_name, str(size)])
    # Nudge shape cache: size ±0 then restore (no-op visually on most setups)
    _run(["hyprctl", "setcursor", theme_name, str(size)])


def maybe_sync_sddm(quiet: bool = False) -> None:
    """If optional SDDM wiring is installed, push the stable Omarchy theme system-wide."""
    marker = paths()["sddm_marker"]
    if not marker.is_file():
        return
    # Prefer the stable root-owned helper (sudoers points here after --with-sddm).
    candidates = [
        Path("/usr/local/lib/omacursor/sync-sddm"),
        plugin_dir() / "bin" / "omacursor-sync-sddm",
    ]
    sync = next((p for p in candidates if p.is_file()), None)
    if sync is None:
        return
    try:
        result = subprocess.run(
            ["sudo", "-n", str(sync)],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        return
    if result.returncode == 0:
        if not quiet:
            note("synced SDDM cursor theme")
        return
    if not quiet:
        note("SDDM sync skipped (sudo -n unavailable; re-run install.sh --with-sddm)")


def apply_cursor_theme(theme_name: str, quiet: bool = False) -> None:
    size = cursor_size()
    ensure_hypr_envs(theme_name)
    force_reload_cursor(theme_name, size)

    _run(["systemctl", "--user", "set-environment", f"XCURSOR_THEME={theme_name}"])
    _run(["systemctl", "--user", "set-environment", f"XCURSOR_SIZE={size}"])
    _run(
        [
            "dbus-update-activation-environment",
            "--systemd",
            f"XCURSOR_THEME={theme_name}",
            f"XCURSOR_SIZE={size}",
        ]
    )
    _run(["gsettings", "set", "org.gnome.desktop.interface", "cursor-theme", theme_name])
    _run(["gsettings", "set", "org.gnome.desktop.interface", "cursor-size", str(size)])

    maybe_sync_sddm(quiet=quiet)

    if not quiet:
        note(f"applied {theme_name} (size {size})")


def revert_cursor_theme(quiet: bool = False) -> None:
    remove_hypr_envs()
    icons = paths()["icons"]
    for name in (*SLOTS, CURSOR_THEME_NAME):
        path = icons / name
        if path.is_symlink():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)

    size = cursor_size()
    force_reload_cursor("Adwaita", size)
    _run(["systemctl", "--user", "unset-environment", "XCURSOR_THEME"])
    _run(["gsettings", "set", "org.gnome.desktop.interface", "cursor-theme", "Adwaita"])

    # Best-effort: clear SDDM cursor override if we installed one
    if paths()["sddm_marker"].is_file():
        sync = plugin_dir() / "bin" / "omacursor-sync-sddm"
        _run(["sudo", "-n", str(sync), "--revert"])

    slot_file = paths()["slot_file"]
    if slot_file.is_file():
        slot_file.unlink()
    current = paths()["state"] / "current"
    if current.is_file():
        current.unlink()
    if not quiet:
        note("reverted to Adwaita")


# --------------------------------------------------------------------------- mockups


def try_font(size: int) -> ImageFont.ImageFont | ImageFont.FreeTypeFont:
    candidates = [
        "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
        "/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
    ]
    for path in candidates:
        if Path(path).is_file():
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


MOCKUP_SIZE = (1536, 864)
SAFE_X = 120
# Catppuccin-style dense grid: every unique Adwaita state (symlinks collapsed).
MOCKUP_CURSOR_ORDER = (
    "default",
    "pointer",
    "context-menu",
    "help",
    "progress",
    "wait",
    "copy",
    "alias",
    "no-drop",
    "not-allowed",
    "grab",
    "grabbing",
    "text",
    "vertical-text",
    "cell",
    "crosshair",
    "all-scroll",
    "all-resize",
    "n-resize",
    "s-resize",
    "e-resize",
    "w-resize",
    "ne-resize",
    "nw-resize",
    "se-resize",
    "sw-resize",
    "ns-resize",
    "ew-resize",
    "nesw-resize",
    "nwse-resize",
    "col-resize",
    "row-resize",
    "zoom-in",
    "zoom-out",
    "X_cursor",
)
MOCKUP_FRAME_SIZE = 48
MOCKUP_ICON_SCALE = 2
MOCKUP_GRID_COLS = 7


def _xcursor_frame(data: bytes, preferred_size: int = MOCKUP_FRAME_SIZE) -> Image.Image | None:
    """First frame of the size closest to preferred_size (skips animation tails)."""
    if data[:4] != b"Xcur":
        return None
    _magic, header, _version, ntoc = struct.unpack_from("<IIII", data, 0)
    best: Image.Image | None = None
    best_dist = 10**9
    seen_sizes: set[int] = set()
    for i in range(ntoc):
        typ, subtype, pos = struct.unpack_from("<III", data, header + i * 12)
        if typ != XCURSOR_IMAGE_TYPE or subtype in seen_sizes:
            continue
        seen_sizes.add(subtype)
        chunk_header, _ct, _cs, _cv, width, height, _xhot, _yhot, _delay = struct.unpack_from(
            "<IIIIIIIII", data, pos
        )
        pix = data[pos + chunk_header : pos + chunk_header + width * height * 4]
        im = Image.frombytes("RGBA", (width, height), pix, "raw", "BGRA")
        dist = abs(subtype - preferred_size)
        if dist < best_dist:
            best_dist = dist
            best = im
    return best


@lru_cache(maxsize=1)
def _adwaita_mockup_bases() -> tuple[tuple[str, Image.Image], ...]:
    """Stock Adwaita frames once — mockups only remap colours."""
    src = adwaita_source()
    frames: list[tuple[str, Image.Image]] = []
    for name in MOCKUP_CURSOR_ORDER:
        path = src / name
        if not path.exists():
            continue
        try:
            data = path.resolve().read_bytes()
        except OSError:
            continue
        frame = _xcursor_frame(data)
        if frame is not None:
            frames.append((name, frame))
    return tuple(frames)


def _recolor_rgba(
    im: Image.Image, fill: tuple[int, int, int], outline: tuple[int, int, int]
) -> Image.Image:
    src = im.load()
    out = Image.new("RGBA", im.size)
    dst = out.load()
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = src[x, y]
            dst[x, y] = _remap_pixel(r, g, b, a, fill, outline)
    return out


def render_mockup(palette: dict[str, Any], dest: Path, size: tuple[int, int] = MOCKUP_SIZE) -> Path:
    """Catppuccin-style grid of recolored Adwaita states (same map as apply)."""
    w, h = size
    img = Image.new("RGB", size, hex_to_rgb(palette["desktop"]))
    draw = ImageDraw.Draw(img)
    font_sm = try_font(22)
    font_md = try_font(28)

    margin_x, margin_y = SAFE_X, 56
    draw.rectangle((margin_x, margin_y, w - margin_x, margin_y + 52), fill=hex_to_rgb(palette["panel"]))
    draw.text(
        (margin_x + 24, margin_y + 12),
        f"Cursors · {palette['name']}",
        font=font_md,
        fill=hex_to_rgb(palette["foreground"]),
    )
    chip = (w - margin_x - 160, margin_y + 12, w - margin_x - 24, margin_y + 40)
    draw.rounded_rectangle(chip, radius=8, fill=hex_to_rgb(palette["accent"]))
    draw.text(
        (chip[0] + 18, chip[1] + 4),
        "Adwaita",
        font=font_sm,
        fill=hex_to_rgb(on_color(palette["accent"], [palette["background"], palette["bright_foreground"]])),
    )

    win = (margin_x + 40, margin_y + 80, w - margin_x - 40, h - margin_y - 40)
    draw.rounded_rectangle(
        win,
        radius=16,
        fill=hex_to_rgb(palette["window"]),
        outline=hex_to_rgb(palette["window_border"]),
        width=3,
    )
    draw.rectangle(
        (win[0] + 2, win[1] + 2, win[2] - 2, win[1] + 48),
        fill=hex_to_rgb(palette["panel"]),
    )
    draw.text(
        (win[0] + 24, win[1] + 12),
        "All states",
        font=font_md,
        fill=hex_to_rgb(palette["foreground"]),
    )

    content = (win[0] + 20, win[1] + 64, win[2] - 20, win[3] - 20)
    draw.rounded_rectangle(content, radius=12, fill=hex_to_rgb(palette["lighter_background"]))

    fill = hex_to_rgb(palette["fill"])
    outline = hex_to_rgb(palette["outline"])
    bases = _adwaita_mockup_bases()
    cols = MOCKUP_GRID_COLS
    rows = max(1, (len(bases) + cols - 1) // cols)
    inner = (content[0] + 12, content[1] + 12, content[2] - 12, content[3] - 12)
    cell_w = (inner[2] - inner[0]) / cols
    cell_h = (inner[3] - inner[1]) / rows
    scale = MOCKUP_ICON_SCALE

    for i, (_name, base) in enumerate(bases):
        r, c = divmod(i, cols)
        tinted = _recolor_rgba(base, fill, outline)
        if scale != 1:
            tinted = tinted.resize(
                (base.width * scale, base.height * scale),
                Image.Resampling.NEAREST,
            )
        cx = int(inner[0] + (c + 0.5) * cell_w)
        cy = int(inner[1] + (r + 0.5) * cell_h)
        img.paste(tinted, (cx - tinted.width // 2, cy - tinted.height // 2), tinted)

    dest.parent.mkdir(parents=True, exist_ok=True)
    img.save(dest, format="PNG", optimize=True)
    return dest


def preview_path(slug: str) -> Path:
    return paths()["cache"] / "previews" / f"{slugify(slug)}.png"


def generate_preview(slug: str) -> Path:
    palette = palette_from_theme(slug)
    return render_mockup(palette, preview_path(slug))


def bust_image_picker_cache(preview_root: Path) -> None:
    try:
        os.utime(preview_root, None)
    except OSError:
        pass
    cache_dir = Path(
        os.environ.get(
            "OMACURSOR_IMAGE_SELECTOR_CACHE",
            home() / ".cache/omarchy/image-selector",
        )
    )
    if not cache_dir.is_dir():
        return
    needle = str(preview_root.resolve())
    for path in cache_dir.iterdir():
        name = path.name
        if not (
            name.endswith(".rows")
            or name.endswith(".signature")
            or name.endswith(".fast-signature")
            or name.endswith(".rows.lock")
        ):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if needle in text:
            try:
                path.unlink()
            except OSError:
                pass


def default_palette() -> dict[str, Any]:
    """Stock Adwaita black/white — the picker tile for reverting to default."""
    return {
        "slug": "default",
        "name": "Default",
        "mode": "dark",
        "background": "#2e2e2e",
        "dark_background": "#242424",
        "darker_background": "#1a1a1a",
        "lighter_background": "#3a3a3a",
        "foreground": "#eeeeee",
        "dark_foreground": "#888888",
        "bright_foreground": "#ffffff",
        "muted": "#777777",
        "selection": "#404040",
        "accent": "#000000",
        "red": "#c01c28",
        "green": "#2ec27e",
        "yellow": "#f5c211",
        "fill": "#000000",
        "outline": "#ffffff",
        "mid": "#808080",
        "desktop": "#1a1a1a",
        "panel": "#242424",
        "window": "#2e2e2e",
        "window_border": "#555555",
    }


def generate_default_preview() -> Path:
    return render_mockup(default_palette(), preview_path("default"))


def warm_previews(slugs: list[str] | None = None) -> int:
    targets = slugs or list_theme_slugs()
    preview_root = paths()["cache"] / "previews"
    preview_root.mkdir(parents=True, exist_ok=True)
    try:
        generate_default_preview()
    except Exception as error:  # noqa: BLE001
        note(f"preview default: {error}")
    for slug in targets:
        try:
            generate_preview(slug)
        except Exception as error:  # noqa: BLE001
            note(f"preview {slug}: {error}")
    bust_image_picker_cache(preview_root)
    return 0


# --------------------------------------------------------------------------- menu helpers


def remove_marked(content: str, start: str, end: str) -> str:
    pattern = re.compile(re.escape(start) + r".*?" + re.escape(end) + r"\n?", re.S)
    return pattern.sub("", content)


def menu_action() -> str:
    switcher = plugin_dir() / "bin" / "omacursor-switcher"
    setter = plugin_dir() / "bin" / "omacursor-set"
    return (
        f'theme="$({switcher})"; '
        f'if [[ $theme == default ]]; then {setter} default; '
        f'elif [[ -n $theme ]]; then {setter} "$theme"; fi'
    )


def install_menu_entry() -> None:
    path = paths()["menu"]
    content = path.read_text(encoding="utf-8") if path.is_file() else "{\n}\n"
    content = remove_marked(content, MENU_START, MENU_END)
    entries = [
        (
            "style.cursors",
            {
                "icon": "󰇀",
                "label": "Cursors",
                "aliases": ["cursor", "pointer", "adwaita-cursor"],
                "description": "Preview Adwaita cursors recolored to any Omarchy palette and apply them",
                "action": menu_action(),
            },
        )
    ]
    brace = content.find("{")
    if brace < 0:
        raise RuntimeError(f"menu config has no root object: {path}")
    body = [MENU_START]
    for key, value in entries:
        body.append(f"  {json.dumps(key)}: {json.dumps(value, ensure_ascii=False)},")
    body.append(MENU_END)
    insertion = "\n".join(body) + "\n"
    atomic_write(path, content[: brace + 1] + "\n" + insertion + content[brace + 1 :])


def uninstall_menu_entry() -> None:
    path = paths()["menu"]
    if not path.is_file():
        return
    content = path.read_text(encoding="utf-8")
    if MENU_START in content:
        atomic_write(path, remove_marked(content, MENU_START, MENU_END))


# --------------------------------------------------------------------------- commands


def cmd_list(_: argparse.Namespace) -> int:
    for slug in list_theme_slugs():
        print(slug)
    return 0


def cmd_current(_: argparse.Namespace) -> int:
    slug = current_omacursor_slug()
    if slug:
        print(slug)
        return 0
    return 1


def cmd_preview(args: argparse.Namespace) -> int:
    if args.theme:
        path = generate_preview(args.theme)
        print(path)
        return 0
    return warm_previews()


def cmd_generate(args: argparse.Namespace) -> int:
    if not args.theme:
        return warm_previews()
    dest = generate_cursor_theme(args.theme)
    print(dest)
    return 0


def cmd_set(args: argparse.Namespace) -> int:
    slug = slugify(args.theme)
    quiet = bool(args.quiet)
    if slug in {"default", "adwaita", "stock"}:
        revert_cursor_theme(quiet=quiet)
        return 0

    # Write into the *inactive* slot so Hyprland keeps serving the live one,
    # then flip the name — same-name overwrites are cached until reboot.
    slot = next_slot()
    generate_cursor_theme(slug, dest_name=slot)
    point_stable_symlink(slot)
    apply_cursor_theme(slot, quiet=quiet)

    state = paths()["state"]
    state.mkdir(parents=True, exist_ok=True)
    atomic_write(state / "current", slug + "\n")
    atomic_write(paths()["slot_file"], slot + "\n")
    try:
        generate_preview(slug)
    except Exception:  # noqa: BLE001
        pass
    if not quiet:
        note(f"set {slug} → {slot}")
    return 0


def cmd_sync(args: argparse.Namespace) -> int:
    slug = current_omarchy_slug()
    if not slug:
        if not args.quiet:
            note("no current Omarchy theme")
        return 1
    args.theme = slug
    return cmd_set(args)


def cmd_switcher(_: argparse.Namespace) -> int:
    warm_previews()
    preview_dir = paths()["cache"] / "previews"
    # omarchy-menu-images --selected needs a path under the preview dir (PNG),
    # not a bare slug — same pattern as OmaOBS / Plymouth.
    current = current_omacursor_slug() or current_omarchy_slug() or ""
    selected = ""
    if current and (preview_dir / f"{current}.png").is_file():
        selected = str(preview_dir / f"{current}.png")

    try:
        generate_default_preview()
    except Exception as error:  # noqa: BLE001
        note(f"preview default: {error}")

    bust_image_picker_cache(preview_dir)
    cmd = [
        "omarchy-menu-images",
        "--print-name",
        "--show-labels",
        "--filterable",
    ]
    if selected:
        cmd.extend(["--selected", selected])
    cmd.append(str(preview_dir))

    try:
        result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        note("omarchy-menu-images not found")
        return 1

    choice = (result.stdout or "").strip()
    if result.returncode != 0 and not choice:
        return result.returncode or 1
    if choice:
        print(choice)
    return 0


def cmd_install_menu(_: argparse.Namespace) -> int:
    install_menu_entry()
    note(f"menu entry → {paths()['menu']}")
    return 0


def cmd_uninstall_menu(_: argparse.Namespace) -> int:
    uninstall_menu_entry()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="omacursor", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list", help="List Omarchy theme slugs with colors.toml").set_defaults(func=cmd_list)
    sub.add_parser("current", help="Print the last applied OmaCursor theme slug").set_defaults(
        func=cmd_current
    )

    generate = sub.add_parser("generate", help="Write Omarchy cursor theme, or warm all previews")
    generate.add_argument("theme", nargs="?", help="Theme slug or display name")
    generate.set_defaults(func=cmd_generate)

    preview = sub.add_parser("preview", help="Render mockup PNG(s)")
    preview.add_argument("theme", nargs="?", help="Theme slug; omit for all")
    preview.set_defaults(func=cmd_preview)

    set_cmd = sub.add_parser("set", help="Generate and apply recolored Adwaita cursors")
    set_cmd.add_argument("theme", help="Theme slug, display name, or 'default'")
    set_cmd.add_argument("--quiet", action="store_true")
    set_cmd.set_defaults(func=cmd_set)

    sync = sub.add_parser("sync", help="Apply the current Omarchy desktop theme to cursors")
    sync.add_argument("--quiet", action="store_true")
    sync.set_defaults(func=cmd_sync)

    sub.add_parser("switcher", help="Open the mockup picker and print the selected slug").set_defaults(
        func=cmd_switcher
    )
    sub.add_parser("install-menu", help="Add Style → Cursors to the Omarchy menu").set_defaults(
        func=cmd_install_menu
    )
    sub.add_parser("uninstall-menu", help="Remove the Style → Cursors menu entry").set_defaults(
        func=cmd_uninstall_menu
    )

    revert = sub.add_parser("revert", help="Restore stock Adwaita cursors")
    revert.add_argument("--quiet", action="store_true")
    revert.set_defaults(func=lambda a: (revert_cursor_theme(quiet=a.quiet), 0)[1])
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except BrokenPipeError:
        return 0
    except Exception as error:  # noqa: BLE001 — CLI boundary
        note(str(error))
        return 1


if __name__ == "__main__":
    sys.exit(main())
