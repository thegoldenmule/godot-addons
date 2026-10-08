#!/usr/bin/env bash
# Live smoke test of one game's DEVELOPMENT snapend using this repo's snapser_kit.
#
#   tools/snapser/smoke/run_smoke.sh <game repo or project dir | path to snapser_kit.config.json> [--session-file=<path>] [--stat=<declared key>] [--board=<logical>] [--verbose]
#
# The gateway comes ONLY from the game's committed snapser_kit.config.json
# (looked up at <repo>/game/snapser_kit.config.json, then
# <repo>/snapser_kit.config.json). smoke.gd refuses to run if
# SNAPSER_GATEWAY_URL points anywhere else. No API key is read or needed.
# Under an isolated HOME, pass --session-file=<abs path> to reuse the same smoke
# identity (user:// follows HOME, so the default file would be a new user).
#
# Env: GODOT (default /Applications/Godot.app/Contents/MacOS/Godot, else `godot` on PATH),
#      SMOKE_IMPORT_TIMEOUT_S (240), SMOKE_TIMEOUT_S (300). Exit 124 on timeout.
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

# Run a command with a deadline; on expiry kill it and fail fast (no hangs).
# macOS has no `timeout`, so this is a small bash watchdog.
run_with_deadline() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= secs )); then
      kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null || true
      echo "run_smoke: TIMEOUT after ${secs}s: $*" >&2
      return 124
    fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid"
}

# Always (re)build the class cache first: a missing OR stale cache makes the
# smoke script fail to parse, or run against out-of-date class names.
echo "run_smoke: importing $addons_root (class cache)"
if ! run_with_deadline "${SMOKE_IMPORT_TIMEOUT_S:-240}" \
    "$godot" --headless --path "$addons_root" --import >/dev/null 2>&1; then
  echo "run_smoke: --import failed or timed out; aborting" >&2
  exit 2
fi

echo "run_smoke: config=$config"
# The smoke must actually go online: never inherit a forced-offline flag. The
# kit's own test/headless auto-offline rule does not apply: smoke.gd builds its
# config with SnapKitConfig.from_dict(), from the game's file only.
run_with_deadline "${SMOKE_TIMEOUT_S:-300}" env -u SNAPSER_OFFLINE "$godot" --headless --path "$addons_root" \
  --script res://tools/snapser/smoke/smoke.gd -- --config="$config" "$@"
