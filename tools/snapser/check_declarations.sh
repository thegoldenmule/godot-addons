#!/usr/bin/env bash
# Check a game's snapser_kit.config.json declarations against its snapend manifest.
#
#   tools/snapser/check_declarations.sh <game repo>
#   tools/snapser/check_declarations.sh <snapser_kit.config.json> <snapend-manifest.json>
#
# Looks for <repo>/game/snapser_kit.config.json (or <repo>/snapser_kit.config.json)
# and <repo>/snapser/snapend-manifest.json. Offline; exit 0 = consistent.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
addons_root="$(cd "$here/../.." && pwd)"
if [[ $# -eq 2 ]]; then
  config="$1"; manifest="$2"
elif [[ $# -eq 1 ]]; then
  repo="$1"
  config="$repo/game/snapser_kit.config.json"
  [[ -f "$config" ]] || config="$repo/snapser_kit.config.json"
  manifest="$repo/snapser/snapend-manifest.json"
else
  sed -n '2,8p' "$0"; exit 2
fi
for f in "$config" "$manifest"; do
  [[ -f "$f" ]] || { echo "check_declarations: missing $f" >&2; exit 2; }
done
abs() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
godot="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
[[ -x "$godot" ]] || godot="$(command -v godot)"
if [[ ! -f "$addons_root/.godot/global_script_class_cache.cfg" ]]; then
  "$godot" --headless --editor --quit --path "$addons_root" >/dev/null 2>&1 || true
fi
exec "$godot" --headless --path "$addons_root" --script res://tools/snapser/check_declarations.gd \
  -- --config="$(abs "$config")" --manifest="$(abs "$manifest")"
