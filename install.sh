#!/usr/bin/env bash
#
# OmaCursor installer. Safe to re-run: rewrites what it owns, leaves the rest alone.
#
# Flags:
#   --quiet      less chatter (used by the shell service on startup)
#   --with-sddm  one-time: install Omarchy cursors system-wide for SDDM (pkexec)
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
quiet=0
with_sddm=0
for arg in "$@"; do
  case $arg in
    --quiet) quiet=1 ;;
    --with-sddm) with_sddm=1 ;;
  esac
done

note() { (( quiet )) || printf 'omacursor: %s\n' "$1"; }
warn() { printf 'omacursor: %s\n' "$1" >&2; }

plugin_id="io.github.alxwolfenstein97.omacursor"
hooks="$HOME/.config/omarchy/hooks/theme-set.d"
state="$HOME/.local/state/omarchy/omacursor"

mkdir -p "$hooks" "$state" "$HOME/.local/share/icons" "$HOME/.config/environment.d"

chmod 755 "$here"/bin/* "$here/omarchy/theme-set-hook" "$here/check.sh" \
  "$here/install.sh" "$here/uninstall.sh" 2>/dev/null || true

export OMACURSOR_PLUGIN_DIR="$here"

ensure_pkg() {
  local pkg=$1
  local why=$2
  if pacman -Q "$pkg" &>/dev/null; then
    return 0
  fi
  note "installing $pkg — $why"
  if command -v omarchy >/dev/null 2>&1; then
    omarchy pkg add "$pkg" || warn "could not install $pkg"
  else
    warn "install $pkg manually — $why"
  fi
}

# Pillow draws Style carousel mockups — install before warming previews.
# Adwaita cursors come with Omarchy already; we recolour those in place (no pkg pull).
ensure_pkg python-pillow "draws Style → Cursors mockups (Pillow)"
if [[ ! -d /usr/share/icons/Adwaita/cursors ]]; then
  warn "Adwaita cursors missing (Omarchy normally ships them) — OmaCursor cannot recolour until they are present"
fi

# ------------------------------------------------------------------- theme hook
install -m 755 "$here/omarchy/theme-set-hook" "$hooks/omacursor"
note "hook: $hooks/omacursor"

# ------------------------------------------------------------------------ menu
"$here/bin/omacursor" install-menu
omarchy-shell -q omarchy.menu refresh >/dev/null 2>&1 || true
omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true

# ----------------------------------------------------------- initial apply/sync
if command -v omarchy >/dev/null 2>&1; then
  "$here/bin/omacursor-sync" --quiet >/dev/null 2>&1 \
    && note "synced cursors to current Omarchy palette" \
    || warn "initial sync skipped (no current theme yet?)"
else
  warn "omarchy not on PATH; run 'omacursor sync' after your next theme set"
fi

# ------------------------------------------------------------------- SDDM (opt)
if (( with_sddm )); then
  if [[ -f $state/sddm-linked ]]; then
    note "SDDM already linked ($state/sddm-linked)"
    # Refresh system copy in case the palette moved
    sudo -n "$here/bin/omacursor-sync-sddm" >/dev/null 2>&1 \
      || warn "SDDM sync refresh failed — re-run with --with-sddm after fixing sudoers"
  else
    note "wiring SDDM cursor theme (password once)"
    if command -v pkexec >/dev/null 2>&1; then
      pkexec "$here/bin/omacursor-link-sddm" && note "SDDM linked" \
        || warn "SDDM link failed — login greeter will keep stock Adwaita until this succeeds"
    else
      sudo "$here/bin/omacursor-link-sddm" && note "SDDM linked" || warn "SDDM link failed"
    fi
  fi
else
  if [[ ! -f $state/sddm-linked ]]; then
    note "SDDM cursors: run '$here/install.sh --with-sddm' once (unencrypted installs)"
  fi
fi

# Warm mockups in the background so Style > Cursors opens quickly.
(
  "$here/bin/omacursor" preview >/dev/null 2>&1 || true
) &

if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin enable "$plugin_id" >/dev/null 2>&1 || true
fi

note "done — Style > Cursors, or '$here/bin/omacursor switcher'"
exit 0
