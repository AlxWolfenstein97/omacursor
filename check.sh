#!/usr/bin/env bash
# Lightweight self-check for OmaCursor.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
pass() { printf 'ok  %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

[[ -x $here/bin/omacursor ]] || bad "omacursor not executable"
[[ -x $here/bin/omacursor-switcher ]] || bad "omacursor-switcher not executable"
[[ -x $here/bin/omacursor-sync-sddm ]] || bad "omacursor-sync-sddm not executable"
[[ -x $here/bin/omacursor-link-sddm ]] || bad "omacursor-link-sddm not executable"
[[ -f $here/manifest.json ]] || bad "manifest.json missing"
[[ -f $here/lib/omacursor.py ]] || bad "lib/omacursor.py missing"
[[ -d /usr/share/icons/Adwaita/cursors ]] && pass "adwaita-cursors present" || bad "adwaita-cursors present"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/themes/fixture" "$tmp/icons" "$tmp/state" "$tmp/cache" \
  "$tmp/.config/omarchy/themes" "$tmp/.config/omarchy/extensions" \
  "$tmp/.config/hypr" "$tmp/.config/environment.d" \
  "$tmp/.local/state/omarchy/current"

mkdir -p "$tmp/adwaita/cursors"
for name in default pointer text progress; do
  src="/usr/share/icons/Adwaita/cursors/$name"
  if [[ -L $src ]]; then
    ln -s "$(readlink "$src")" "$tmp/adwaita/cursors/$name"
  elif [[ -f $src ]]; then
    cp -a "$src" "$tmp/adwaita/cursors/$name"
  fi
done
for name in left_ptr arrow; do
  src="/usr/share/icons/Adwaita/cursors/$name"
  [[ -e $src ]] || continue
  if [[ -L $src ]]; then
    ln -sf "$(readlink "$src")" "$tmp/adwaita/cursors/$name"
  else
    cp -a "$src" "$tmp/adwaita/cursors/$name" 2>/dev/null || true
  fi
done

cat >"$tmp/themes/fixture/colors.toml" <<'EOF'
mode = "dark"
accent = "#FF3D9A"
background = "#0B0618"
foreground = "#F2E8FF"
dark_background = "#070412"
darker_background = "#04020C"
lighter_background = "#1A1030"
muted = "#5A4A78"
selection = "#2A1848"
bright_foreground = "#FFFFFF"
red = "#FF3355"
green = "#3DFF9A"
yellow = "#FFD400"
blue = "#5B7CFF"
magenta = "#FF3D9A"
cyan = "#00E8FF"
EOF

ln -s "$tmp/themes/fixture" "$tmp/.config/omarchy/themes/fixture"
printf 'fixture\n' >"$tmp/.local/state/omarchy/current/theme.name"
printf -- '-- Learn how to configure Hyprland\nrequire("hypr.autostart")\n' >"$tmp/.config/hypr/hyprland.lua"
printf '{}\n' >"$tmp/.config/omarchy/extensions/omarchy-menu.jsonc"

export OMACURSOR_HOME="$tmp"
export OMACURSOR_PLUGIN_DIR="$here"
export OMARCHY_PATH="$tmp"
export OMACURSOR_ICONS_DIR="$tmp/icons"
export OMACURSOR_STATE_DIR="$tmp/state"
export OMACURSOR_CACHE_DIR="$tmp/cache"
export OMACURSOR_ADWAITA="$tmp/adwaita/cursors"

if "$here/bin/omacursor" set fixture --quiet; then
  pass "set fixture"
else
  bad "set fixture"
fi

slot1=$(cat "$tmp/state/slot" 2>/dev/null || true)
[[ -n $slot1 ]] && pass "slot written ($slot1)" || bad "slot written"
[[ -d $tmp/icons/$slot1/cursors ]] && pass "wrote slot cursors" || bad "wrote slot cursors"
[[ -L $tmp/icons/Omarchy ]] && pass "stable Omarchy symlink" || bad "stable Omarchy symlink"
[[ "$(cat "$tmp/state/current")" == "fixture" ]] && pass "state current" || bad "state current"
grep -q 'omacursor-envs' "$tmp/.config/hypr/hyprland.lua" && pass "hypr require" || bad "hypr require"
grep -q "$slot1" "$tmp/.config/hypr/omacursor-envs.lua" && pass "hypr envs slot" || bad "hypr envs slot"
grep -q "$slot1" "$tmp/.config/environment.d/99-omacursor.conf" && pass "environment.d" || bad "environment.d"

if [[ -f $tmp/icons/$slot1/cursors/default ]]; then
  python3 - <<PY && pass "xcursor magic" || bad "xcursor magic"
from pathlib import Path
import os
slot = Path(os.environ["OMACURSOR_STATE_DIR"], "slot").read_text().strip()
p = Path(os.environ["OMACURSOR_ICONS_DIR"]) / slot / "cursors/default"
assert p.read_bytes()[:4] == b"Xcur"
PY
else
  bad "xcursor magic"
fi

# Second set must flip the slot name (live-reload contract)
if "$here/bin/omacursor" set fixture --quiet; then
  slot2=$(cat "$tmp/state/slot")
  [[ $slot1 != "$slot2" ]] && pass "slot flipped ($slot1 → $slot2)" || bad "slot flipped ($slot1 → $slot2)"
else
  bad "second set"
fi

if "$here/bin/omacursor" preview fixture >/dev/null; then
  [[ -f $tmp/cache/previews/fixture.png ]] && pass "preview png" || bad "preview png"
else
  bad "preview fixture"
fi

if "$here/bin/omacursor" install-menu >/dev/null; then
  grep -q 'style.cursors' "$tmp/.config/omarchy/extensions/omarchy-menu.jsonc" \
    && pass "menu entry" || bad "menu entry"
else
  bad "menu entry"
fi

if command -v omarchy >/dev/null 2>&1; then
  if omarchy plugin validate "$here" >/dev/null 2>&1; then
    pass "omarchy plugin validate"
  else
    bad "omarchy plugin validate"
  fi
fi

if (( fail )); then
  echo "omacursor check: FAILED"
  exit 1
fi
echo "omacursor check: all good"
exit 0
