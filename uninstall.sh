#!/usr/bin/env bash
#
# Remove OmaCursor wiring and restore stock Adwaita cursors.
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_id="io.github.alxwolfenstein97.omacursor"
hooks="$HOME/.config/omarchy/hooks/theme-set.d"
state="$HOME/.local/state/omarchy/omacursor"
cache="$HOME/.cache/omarchy/omacursor"

note() { printf 'omacursor: %s\n' "$1"; }
warn() { printf 'omacursor: %s\n' "$1" >&2; }

export OMACURSOR_PLUGIN_DIR="$here"
"$here/bin/omacursor" uninstall-menu || true
"$here/bin/omacursor" revert --quiet || true
rm -f "$hooks/omacursor"
note "removed theme-set hook"

# Optional SDDM teardown (password if sudoers already gone)
if [[ -f $state/sddm-linked ]] || [[ -f /etc/sddm.conf.d/99-omacursor.conf ]]; then
  note "removing SDDM cursor wiring (may prompt for password)"
  if command -v pkexec >/dev/null 2>&1; then
    pkexec bash -c '
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
    ' || warn "could not fully remove SDDM wiring"
  else
    sudo bash -c '
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
    ' || warn "could not fully remove SDDM wiring"
  fi
fi

rm -rf "$state" "$cache"
rm -f "$HOME/.config/environment.d/99-omacursor.conf"
note "cleared state/cache"

omarchy-shell -q omarchy.menu refresh >/dev/null 2>&1 || true

if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin disable "$plugin_id" >/dev/null 2>&1 || true
fi

note "done — plugin files left at $here; remove the folder yourself if you want it gone"
exit 0
