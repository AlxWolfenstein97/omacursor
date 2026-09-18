#!/usr/bin/env bash
#
# Full clean-slate: menu, theme-set hook, Omarchy-{a,b} icon themes, Hypr/env
# wiring, cache/state, optional SDDM system wiring. Restores stock Adwaita.
# Optional floating terminal for shared package drop (not cursor reset).
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_id="io.github.alxwolfenstein97.omacursor"
hooks="$HOME/.config/omarchy/hooks/theme-set.d"
state="$HOME/.local/state/omarchy/omacursor"
cache="$HOME/.cache/omarchy/omacursor"
icons="$HOME/.local/share/icons"
menu_lock="$HOME/.local/state/omarchy/style-extenders/menu.lock"

note() { printf 'omacursor: %s\n' "$1"; }
warn() { printf 'omacursor: %s\n' "$1" >&2; }

offer_pkg_drop() {
  local -a have=()
  local pkg
  for pkg in "$@"; do
    pacman -Q "$pkg" &>/dev/null && have+=("$pkg")
  done
  ((${#have[@]})) || return 0
  local list="${have[*]}"
  local script="$state/uninstall-floater.sh"
  mkdir -p "$state"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail'
    printf '%s\n' "printf '%s\n' 'OmaCursor — uninstall'"
    printf '%s\n' "printf '%s\n' '────────────────────────────────'"
    printf '%s\n' "printf '%s\n' 'Optional — drop shared packages only if nothing else needs them:'"
    for pkg in "${have[@]}"; do
      case $pkg in
        python-pillow) printf '%s\n' "printf '  • %s — %s\n' 'python-pillow' 'Style carousel mockups'" ;;
        python-numpy) printf '%s\n' "printf '  • %s — %s\n' 'python-numpy' 'Adwaita cursor remaps'" ;;
        adw-gtk-theme) printf '%s\n' "printf '  • %s — %s\n' 'adw-gtk-theme' 'GTK theme Chroma paints'" ;;
        *) printf '%s\n' "printf '  • %s\n' $(printf %q "$pkg")" ;;
      esac
    done
    printf '%s\n' "printf '%s\n' '────────────────────────────────'"
    printf '%s\n' "printf '%s\n' ''"
    printf '%s\n' "read -r -p 'Drop ${list}? [y/N] ' a"
    printf '%s\n' 'case $a in'
    printf '%s\n' "  [yY]|[yY][eE][sS]) omarchy pkg drop ${list} ;;"
    printf '%s\n' "  *) printf 'skipped package drop\n' ;;"
    printf '%s\n' 'esac'
  } >"$script"
  chmod 755 "$script"
  if command -v omarchy-launch-floating-terminal-with-presentation >/dev/null 2>&1; then
    note "optional package drop — opening floating terminal"
    omarchy-launch-floating-terminal-with-presentation "bash $(printf %q "$script")" >/dev/null 2>&1 &
  else
    note "optional: omarchy pkg drop $list"
  fi
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

offer_pkg_drop python-pillow python-numpy

note "done — stock Adwaita cursors; no omacursor menu/hook/slots left"
note "plugin files remain at $here until you omit/remove the plugin"
exit 0
