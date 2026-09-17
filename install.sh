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

# Tombstone from uninstall: Service --quiet must not resurrect wiring.
if [[ -f $state/uninstalled ]]; then
  if (( quiet )); then
    exit 0
  fi
  rm -f "$state/uninstalled"
fi

mkdir -p "$hooks" "$state" "$HOME/.local/share/icons" "$HOME/.config/environment.d"

chmod 755 "$here"/bin/* "$here/omarchy/theme-set-hook" "$here/check.sh" \
  "$here/install.sh" "$here/uninstall.sh" 2>/dev/null || true

export OMACURSOR_PLUGIN_DIR="$here"

# Packages need sudo. Interactive install asks in this TTY; Service --quiet
# opens one floating terminal once (pkgs-prompted) — not again every boot.
pull_pkgs() {
  local -a missing=()
  local pkg
  for pkg in "$@"; do
    pacman -Q "$pkg" &>/dev/null || missing+=("$pkg")
  done
  if ((${#missing[@]} == 0)); then
    rm -f "$state/pkgs-prompted"
    return 0
  fi

  if ! command -v omarchy >/dev/null 2>&1; then
    warn "install manually: pacman -S ${missing[*]}"
    return 1
  fi

  note "installing ${missing[*]}"
  if (( ! quiet )) && [[ -t 0 || -t 1 ]]; then
    if omarchy pkg add "${missing[@]}"; then
      rm -f "$state/pkgs-prompted"
      return 0
    fi
    warn "could not install: ${missing[*]}"
    return 1
  fi

  if [[ -f $state/pkgs-prompted ]]; then
    warn "still missing ${missing[*]} — run: omarchy pkg add ${missing[*]}"
    return 1
  fi
  mkdir -p "$state"
  touch "$state/pkgs-prompted"
  local cmd="omarchy pkg add ${missing[*]}"
  [[ -n ${PULL_PKGS_AFTER:-} ]] && cmd+=" && ${PULL_PKGS_AFTER}"
  if command -v omarchy-launch-floating-terminal-with-presentation >/dev/null 2>&1; then
    warn "sudo needed for ${missing[*]} — opening a floating terminal"
    omarchy-launch-floating-terminal-with-presentation "$cmd" >/dev/null 2>&1 &
  else
    warn "run: $cmd"
  fi
  return 1
}

# Pillow draws Style carousel mockups; numpy vectorizes Adwaita fill→outline
# remaps (mockups + apply). Install both before warming / first sync.
# Adwaita cursors come with Omarchy already; we recolour those (no cursor pkg).
# Interactive: ask in this TTY. Quiet/Service: one floating terminal once
# (pkgs-prompted), never again on later boots if dismissed.
pull_pkgs python-pillow python-numpy || true
if [[ ! -d /usr/share/icons/Adwaita/cursors ]]; then
  warn "Adwaita cursors missing (Omarchy normally ships them) — OmaCursor cannot recolour until they are present"
fi

# ------------------------------------------------------------------- theme hook
install -m 755 "$here/omarchy/theme-set-hook" "$hooks/omacursor"
note "hook: $hooks/omacursor"

# ------------------------------------------------------------------------ menu
# Style extenders all rewrite the same extensions file. Shell-service --quiet
# starts them in parallel — flock so we don't clobber each other's rows.
# Quiet path debounces menu refresh (one within 3s across parallel Services);
# interactive also rescans plugins so mid-session enable shows the new row.
menu_lock="$HOME/.local/state/omarchy/style-extenders/menu.lock"
menu_sha="$HOME/.local/state/omarchy/style-extenders/menu.sha"
menu_file="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
mkdir -p "$(dirname "$menu_lock")"
(
  flock 9
  "$here/bin/omacursor" install-menu
  if [[ -f $menu_file ]]; then
    new_sha=$(sha256sum "$menu_file" 2>/dev/null | awk '{print $1}')
    old_sha=$(cat "$menu_sha" 2>/dev/null || true)
    if [[ -n $new_sha && $new_sha != "$old_sha" ]]; then
      printf '%s\n' "$new_sha" >"$menu_sha"
      if command -v omarchy-shell >/dev/null 2>&1; then
        # Debounce: parallel quiet Services all rewrite the menu; one refresh
        # within 3s is enough (avoids stacked Hypr strokes). Interactive always
        # refreshes + rescan so mid-session enable shows the new row.
        stamp="$HOME/.local/state/omarchy/style-extenders/menu.refresh"
        do_refresh=1
        if (( quiet )) && [[ -f $stamp ]]; then
          now=$(date +%s)
          then=$(stat -c %Y "$stamp" 2>/dev/null || echo 0)
          if (( now - then < 3 )); then
            do_refresh=0
          fi
        fi
        if (( do_refresh )); then
          touch "$stamp"
          omarchy-shell -q omarchy.menu refresh >/dev/null 2>&1 || true
          if (( ! quiet )); then
            omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true
          fi
        fi
      fi
    fi
  fi
) 9>"$menu_lock"
if (( ! quiet )); then
  note "Style → Cursors is live; if the row is missing, run: omarchy-shell shell rescanPlugins"
fi

# ----------------------------------------------------------- initial apply/sync
# Interactive always syncs. Quiet: one-shot if we have never synced on this
# machine (fresh plugin add), then the theme-set hook keeps cursors in step.
if command -v omarchy >/dev/null 2>&1; then
  if (( ! quiet )) || [[ ! -f $state/synced ]]; then
    if "$here/bin/omacursor-sync" --quiet >/dev/null 2>&1; then
      touch "$state/synced"
      note "synced cursors to current Omarchy palette"
    else
      warn "initial sync skipped (no current theme yet?)"
    fi
  fi
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

# Warm mockups once on interactive install — not on every shell-start --quiet.
if (( ! quiet )); then
  (
    "$here/bin/omacursor" preview >/dev/null 2>&1 || true
  ) &
fi
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin enable "$plugin_id" >/dev/null 2>&1 || true
fi

note "done — Style > Cursors, or '$here/bin/omacursor switcher'"
exit 0
