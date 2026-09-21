#!/usr/bin/env bash
#
# Full clean-slate: menu, theme-set hook, Omarchy-{a,b} icon themes, Hypr/env
# wiring, cache/state, optional SDDM system wiring. Restores stock Adwaita.
# Optional package drop prompts in this TTY (no floater). Cursor reset is inline.
#
set -euo pipefail

assume_yes=0
for arg in "$@"; do
  case $arg in --yes|-y) assume_yes=1 ;; esac
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_id="io.github.alxwolfenstein97.omacursor"
hooks="$HOME/.config/omarchy/hooks/theme-set.d"
state="$HOME/.local/state/omarchy/omacursor"
cache="$HOME/.cache/omarchy/omacursor"
icons="$HOME/.local/share/icons"
menu_lock="$HOME/.local/state/omarchy/style-extenders/menu.lock"

note() { printf 'omacursor: %s\n' "$1"; }
warn() { printf 'omacursor: %s\n' "$1" >&2; }

try_pkg_drop() {
  # Best-effort: drop packages we may have pulled. If something else still
  # needs them, pacman refuses and we leave them — that is fine.
  local pkg
  for pkg in "$@"; do
    pacman -Q "$pkg" &>/dev/null || continue
    if command -v omarchy >/dev/null 2>&1 && omarchy pkg drop "$pkg"; then
      note "dropped $pkg"
    else
      note "kept $pkg (still required elsewhere or drop failed — fine)"
    fi
  done
}

ask_pkg_drop() {
  # Interactive — prompts in this terminal (no floater).
  local -a have=()
  local pkg a req
  for pkg in "$@"; do
    pacman -Q "$pkg" &>/dev/null && have+=("$pkg")
  done
  ((${#have[@]})) || return 0
  note "optional package drops — n / Enter keeps; pacman may refuse if still required"
  for pkg in "${have[@]}"; do
    case $pkg in
      python-pillow)
        note "python-pillow — Style carousel mockups (shared); MangoHud/goverlay/Lutris may need it"
        req=$(pacman -Qi python-pillow 2>/dev/null | awk -F': ' '/^Required By/{print $2}')
        note "  pacman Required By: ${req:-none}"
        ;;
      python-numpy)
        note "python-numpy — OmaCursor Adwaita remaps"
        req=$(pacman -Qi python-numpy 2>/dev/null | awk -F': ' '/^Required By/{print $2}')
        note "  pacman Required By: ${req:-none}"
        ;;
      terminus-font)
        note "terminus-font — OmaTTY console faces"
        ;;
      adw-gtk-theme)
        note "adw-gtk-theme — GTK theme Chroma paints over"
        ;;
      *)
        note "package: $pkg"
        ;;
    esac
    read -r -p "Drop $pkg? [y/N] " a || a=
    case $a in
      [yY]|[yY][eE][sS]) try_pkg_drop "$pkg" ;;
      *) note "kept $pkg" ;;
    esac
  done
}



export OMACURSOR_PLUGIN_DIR="$here"

# Tombstone + disable first so Service --quiet cannot resurrect the Style row.
mkdir -p "$state"
touch "$state/uninstalled"
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin disable "$plugin_id" >/dev/null 2>&1 || true
fi

# Remember SDDM flag before state wipe.
sddm_linked=0
[[ -f $state/sddm-linked ]] && sddm_linked=1

mkdir -p "$(dirname "$menu_lock")"
(
  flock 9
  "$here/bin/omacursor" uninstall-menu || true
) 9>"$menu_lock"
"$here/bin/omacursor" revert --quiet || true
rm -f "$hooks/omacursor"
rm -f "$state/armed-theme-hook" "$state/armed-style-menu"
note "removed theme-set hook"

# Always strip Hypr wiring even if revert failed (avoids require of a deleted
# omacursor-envs.lua leaving Hypr errors).
rm -rf "$icons/Omarchy" "$icons/Omarchy-a" "$icons/Omarchy-b"
rm -f "$HOME/.config/hypr/omacursor-envs.lua"
rm -f "$HOME/.config/environment.d/99-omacursor.conf"
hl="$HOME/.config/hypr/hyprland.lua"
if [[ -f $hl ]] && grep -q -- '-- omacursor:start' "$hl"; then
  python3 - <<'PY'
from pathlib import Path
import re

path = Path.home() / ".config/hypr/hyprland.lua"
text = path.read_text(encoding="utf-8")
start, end = "-- omacursor:start", "-- omacursor:end"
pat = re.compile(re.escape(start) + r".*?" + re.escape(end) + r"\n?", re.S)
new = pat.sub("", text)
if new != text:
    path.write_text(new, encoding="utf-8")
    print("stripped omacursor block from hyprland.lua")
PY
fi

# Best-effort stock Adwaita restore (revert may have failed earlier).
if command -v hyprctl >/dev/null 2>&1; then
  size=$(hyprctl getoption cursor:size -j 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("int", 24))' 2>/dev/null || echo 24)
  hyprctl setcursor Adwaita "$size" >/dev/null 2>&1 || true
fi
gsettings set org.gnome.desktop.interface cursor-theme Adwaita >/dev/null 2>&1 || true
systemctl --user unset-environment XCURSOR_THEME >/dev/null 2>&1 || true

# Optional SDDM teardown (password if sudoers already gone)
if (( sddm_linked )) || [[ -f /etc/sddm.conf.d/99-omacursor.conf ]] \
  || [[ -d /usr/share/icons/Omarchy ]] || [[ -d /usr/local/lib/omacursor ]]; then
  note "removing SDDM cursor wiring (may prompt for password)"
  sddm_cleanup='
      rm -rf /usr/share/icons/Omarchy
      rm -rf /usr/share/icons/default/cursors
      if [[ -L /usr/share/icons/Adwaita/cursors ]]; then
        rm -f /usr/share/icons/Adwaita/cursors
      fi
      if [[ -d /usr/share/icons/Adwaita/cursors.omacursor-stock ]]; then
        mv /usr/share/icons/Adwaita/cursors.omacursor-stock /usr/share/icons/Adwaita/cursors
      fi
      if [[ -f /usr/share/icons/default/index.theme.omacursor-bak ]]; then
        cp -f /usr/share/icons/default/index.theme.omacursor-bak /usr/share/icons/default/index.theme
        rm -f /usr/share/icons/default/index.theme.omacursor-bak
      else
        printf "[Icon Theme]\nInherits=Adwaita\n" > /usr/share/icons/default/index.theme
      fi
      rm -rf /var/lib/sddm/.icons
      rm -f /etc/sddm.conf.d/99-omacursor.conf
      rm -f /etc/sddm/omacursor-hyprland.lua
      rm -f /etc/sudoers.d/omacursor_sddm /etc/sudoers.d/omacursor-sddm
      rm -f /var/log/omacursor-sddm.log
      rm -rf /usr/local/lib/omacursor
  '
  if command -v pkexec >/dev/null 2>&1; then
    pkexec bash -c "$sddm_cleanup" || warn "could not fully remove SDDM wiring"
  else
    sudo bash -c "$sddm_cleanup" || warn "could not fully remove SDDM wiring"
  fi
fi

rm -rf "$cache"
find "$state" -mindepth 1 ! -name uninstalled -delete 2>/dev/null || true
touch "$state/uninstalled"
note "cleared state/cache (tombstone left so quiet install cannot resurrect)"

omarchy-shell -q omarchy.menu refresh >/dev/null 2>&1 || true
omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true

if (( ! assume_yes )); then
  ask_pkg_drop python-pillow python-numpy
else
  note "full wipe (--yes): trying package drops (kept if still required elsewhere)"
  try_pkg_drop python-pillow python-numpy
fi

note "done — stock Adwaita cursors; no omacursor menu/hook/slots left"
if (( assume_yes )); then
  note "full wipe (--yes): removing plugin $plugin_id"
  if command -v omarchy >/dev/null 2>&1; then
    # Leave the tree before Omarchy deletes it out from under us.
    cd "${HOME:-/}" || cd /
    omarchy plugin remove "$plugin_id" --yes \
      || note "plugin remove failed — try: omarchy plugin remove $plugin_id --yes"
  else
    note "omarchy CLI missing — delete by hand: $here"
  fi
else
  note "plugin files remain at $here until you omit/remove the plugin"
  note "  omarchy plugin remove $plugin_id"
fi

exit 0
