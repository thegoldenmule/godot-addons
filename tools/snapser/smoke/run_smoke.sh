#!/usr/bin/env bash
# Live smoke test of one game's DEVELOPMENT snapend using this repo's snapser_kit.
#
#   tools/snapser/smoke/run_smoke.sh <game repo or project dir | path to snapser_kit.config.json> [--stat=<declared key>] [--board=<logical>] [--verbose]
#
# The gateway comes ONLY from the game's committed snapser_kit.config.json
# (looked up at <repo>/game/snapser_kit.config.json, then
# <repo>/snapser_kit.config.json). smoke.gd refuses to run if
# SNAPSER_GATEWAY_URL points anywhere else. No API key is read or needed.
#
# Env: GODOT (default /Applications/Godot.app/Contents/MacOS/Godot, else `godot` on PATH).
set -euo pipefail

if [[ $# -lt 1 ]]; then
  sed -n '2,12p' "$0"
  exit 2
fi

target="$1"; shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
addons_root="$(cd "$here/../../.." && pwd)"

if [[ -f "$target" ]]; then
  config="$target"
elif [[ -f "$target/game/snapser_kit.config.json" ]]; then
  config="$target/game/snapser_kit.config.json"
elif [[ -f "$target/snapser_kit.config.json" ]]; then
  config="$target/snapser_kit.config.json"
else
  echo "run_smoke: no snapser_kit.config.json under '$target' (looked in game/ and the root)" >&2
  exit 2
fi
config="$(cd "$(dirname "$config")" && pwd)/$(basename "$config")"

godot="${GODOT:-}"
if [[ -z "$godot" ]]; then
  if [[ -x /Applications/Godot.app/Contents/MacOS/Godot ]]; then
    godot=/Applications/Godot.app/Contents/MacOS/Godot
  else
    godot="$(command -v godot || true)"
  fi
fi
[[ -n "$godot" ]] || { echo "run_smoke: Godot not found; set GODOT" >&2; exit 2; }

# Make sure the class cache exists (fresh clones / worktrees).
if [[ ! -f "$addons_root/.godot/global_script_class_cache.cfg" ]]; then
  "$godot" --headless --editor --quit --path "$addons_root" >/dev/null 2>&1 || true
fi

echo "run_smoke: config=$config"
# The smoke must actually go online: never inherit a forced-offline flag.
exec env -u SNAPSER_OFFLINE "$godot" --headless --path "$addons_root" \
  --script res://tools/snapser/smoke/smoke.gd -- --config="$config" "$@"
