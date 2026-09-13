# OmaCursor

**Omarchy themes your desktop. OmaCursor carries the same palette into the
pointer — mockup previews in the Style menu, then a real Adwaita recolor Hyprland
and GTK can load.**

Stock Omarchy paints Hyprland, the terminal, and (with Chroma) your GTK apps.
The mouse cursor stays default Adwaita black/white in every theme. Your desktop
wears Hackerman neon; the pointer still looks like a stock GNOME install.

OmaCursor closes that gap the same way Style → OBS Themes works: a labelled
image picker, one mockup per installed theme, and an apply step that writes
what the compositor understands. Pick once, or let `omarchy theme set` keep
cursors in lockstep forever after.

## Goals (and honest limits)

These Style plugins extend Omarchy’s theme system **without requiring theme
authors — or you — to ship anything extra**. Official themes, your forks, and
third-party installs all work as long as they have a `colors.toml`.

| Goal | What that means here |
|------|----------------------|
| Zero extra assets | No per-theme cursor packs. Colours come from `colors.toml` alone. |
| Extreme compatibility | Stock + user + foreign themes all appear in the picker automatically. |
| Illustrative mockups | Stylized pointer / hand / text / wait on a themed window. **Not** live captures. |
| Carousel-safe | Mockups are 1536×864 with ~8% side inset so the Style tile crop does not shave the subject. |
| Fast pickers | Previews are drawn with Pillow — we do **not** bake a full XCursor theme per tile (that would be slow and pointless for a carousel). |

Recoloring every Adwaita cursor file for every theme just to show a thumbnail
would be wasted work. The applied `Omarchy` cursor theme *is* a real XCursor
recolor of stock Adwaita; only the picker art is drawn.

## What you get

- **Style → Cursors** in the Omarchy menu — same carousel picker as Unlock /
  Theme / OBS / Boot.
- **Live theme discovery** — every Omarchy theme with a `colors.toml`.
- **Mockups** — Adwaita-shaped cursors on a small desktop chrome, coloured from
  that theme’s accent / foreground / backgrounds.
- **Real cursors** — stock Adwaita XCursor files remapped (fill → accent,
  outline → contrasting ink) into alternating
  `~/.local/share/icons/Omarchy-{a,b}/` slots (live reload without reboot).
- **Apply wiring** — `hyprctl setcursor` (bounce via Adwaita), `XCURSOR_THEME`
  via Hyprland env + `environment.d` + user systemd, and
  `org.gnome.desktop.interface cursor-theme`.
- **theme-set hook + service safety net** — `omarchy theme set …` keeps
  cursors in step; the shell service retries if a switch somehow skips the hook.
- **Optional SDDM** — `install.sh --with-sddm` mirrors into
  `/usr/share/icons/Omarchy` + `CursorTheme=Omarchy` so the greeter matches
  (handy next to themed Plymouth on unencrypted installs).
- **Default** tile — restores stock Adwaita.

## Install

```sh
omarchy plugin add https://github.com/AlxWolfenstein97/omacursor.git --enable
```

That clones into `~/.config/omarchy/plugins/io.github.alxwolfenstein97.omacursor`.
Or from a checkout:

```sh
~/.config/omarchy/plugins/io.github.alxwolfenstein97.omacursor/install.sh
omarchy plugin enable io.github.alxwolfenstein97.omacursor
```

**Optional — SDDM login cursor** (unencrypted installs where SDDM shows the
password prompt; encrypted drives stay on Plymouth for that step):

```sh
~/.config/omarchy/plugins/io.github.alxwolfenstein97.omacursor/install.sh --with-sddm
```

Password once. This does **more** than drop `CursorTheme=` into sddm.conf —
Omarchy’s greeter is Wayland/Hyprland, and SDDM’s `CursorTheme` is ignored
there ([sddm#1996](https://github.com/sddm/sddm/issues/1996)). Hyprland also
falls back to `/usr/share/icons/default` (stock: Adwaita). OmaCursor therefore:

- publishes `/usr/share/icons/Omarchy`
- ships a **self-contained** `/usr/share/icons/default/cursors/` tree (does
  **not** touch stock Adwaita)
- installs `/etc/sddm/omacursor-hyprland.lua` with `hl.env` + `hyprctl setcursor`
- overrides `CompositorCommand=` to `/usr/local/lib/omacursor/sddm-compositor`
- sets passwordless `sudo -n /usr/local/lib/omacursor/sync-sddm` for later switches

Log out once after `--with-sddm`. Greeter cursor theming works with that path —
no Adwaita hijack required. Debug: `/var/log/omacursor-sddm.log`.

**Needs:** `adwaita-cursors`, Omarchy’s image picker, Python 3 with Pillow
(`python-pillow` on Arch). The installer pulls `adwaita-cursors` if missing.

## How it works

1. `bin/omacursor-switcher` renders PNG mockups into
   `~/.cache/omarchy/omacursor/previews/`, then opens `omarchy-menu-images`
   with `--selected` pointing at the *current* PNG (so the carousel remembers).
2. On selection / `theme-set`, `omacursor-set` remaps Adwaita into the
   **inactive** slot (`Omarchy-a` ↔ `Omarchy-b`). Hyprland caches cursors by
   theme *name* — overwriting the same folder never reloads until reboot, which
   is why we flip the name and bounce via Adwaita.
3. Apply points Hyprland / GNOME / `environment.d` / the session env at the
   new slot. A stable `Omarchy` symlink always points at the active slot.
4. `~/.config/omarchy/hooks/theme-set.d/omacursor` runs `omacursor sync` after
   every desktop theme change; the shell service is a Chroma-style safety net.

CLI:

```sh
omacursor list
omacursor preview              # warm all mockups
omacursor switcher             # picker → prints slug
omacursor set tokyo-night      # generate + apply (live)
omacursor sync                 # apply current desktop theme
omacursor current
omacursor revert               # back to stock Adwaita
```

## Why live apply used to need a reboot

Hyprland (and libxcursor) key the in-memory cursor cache on the theme name.
v1.0 wrote into a single `Omarchy` directory and called `setcursor Omarchy`
again — the compositor kept serving the old pixels until a cold start. v1.1
alternates `Omarchy-a` / `Omarchy-b` so every apply is a *new* theme name.

## Remove

```sh
~/.config/omarchy/plugins/io.github.alxwolfenstein97.omacursor/uninstall.sh
omarchy plugin disable io.github.alxwolfenstein97.omacursor
omarchy plugin remove io.github.alxwolfenstein97.omacursor
```

Uninstall removes the menu row, theme-set hook, Hyprland env snippet, managed
`Omarchy` cursor theme, and state/cache — then restores Adwaita. With
`--with-sddm`, it also restores `/usr/share/icons/default` and the greeter
compositor override.

## Limits, honestly

- **Steam** — locks the cursor theme it saw at launch. After a Style → Cursors
  (or desktop theme) switch, tray-quit Steam fully and reopen; otherwise you
  get a mix of old and new. Not much to fix on our side.
- **Root / elevated apps** — `sudo` / `pkexec` GUIs keep whatever cursor was
  current at boot (or when that process tree started). Session `hyprctl` /
  `gsettings` do not reach them. Same class of problem as Steam.
- **Plymouth / encrypted installs** — the LUKS passphrase screen has no mouse
  cursor. OmaCursor cannot theme that; use Style → Unlock / Plymouth for the
  chrome. SDDM wiring is for **unencrypted** installs where you type the
  password on the greeter.
- **SDDM Wayland** — `[Theme] CursorTheme=` alone does nothing for Omarchy’s
  Hyprland greeter. `--with-sddm` overrides `CompositorCommand`, sets
  `hyprctl setcursor`, and ships self-contained default cursors. **Never
  hijacks Adwaita** — that was tried once, broke GTK/Qt with an inherit loop,
  and is gone.
- **First greeter start** — log out once after `--with-sddm`.

If you barely switch themes: pick something you like, reboot once, and stop
worrying about live reload edge cases.

## Why not pure Chroma-style background sync?

Chroma (GTK/Qt) only needs to rewrite a few CSS files — perfect for silent
sync. Cursors need a Style picker so you can *see* the recolor before living
with it, and mockups are cheap. The theme-set hook still mirrors Chroma’s
“set it and forget it” sync after you pick (or on first install).

## Check

```sh
bash ~/.config/omarchy/plugins/io.github.alxwolfenstein97.omacursor/check.sh
```

## Credits

- Sibling Style plugins: [OmaOBS](https://github.com/AlxWolfenstein97/omaobs),
  [OmaBoot](https://github.com/AlxWolfenstein97/omaboot),
  [OmaVT](https://github.com/AlxWolfenstein97/omavt),
  [OmaTTY](https://github.com/AlxWolfenstein97/omatty),
  [Chroma](https://github.com/AlxWolfenstein97/chroma).
- [Omarchy](https://omarchy.org/) — theme pipeline, Style menu image picker, and
  `theme-set` hooks this plugin hooks into.
- Stock shapes from GNOME’s Adwaita cursors (`adwaita-cursors`).

## License

MIT — see [LICENSE](LICENSE).
