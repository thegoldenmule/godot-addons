#!/usr/bin/env bash
# One-command iOS TestFlight release for a Godot project that vendors build_kit.
#
#   addons/build_kit/cli/release_ios.sh [--project <dir>] [--no-upload] [--no-commit] [--no-push] [--timeout <minutes>]
#
# Picks the build number (build_kit.config.json vs App Store Connect), exports,
# archives, signs, verifies entitlements, uploads, waits for processing, then
# commits + pushes the next build_number. The work happens in the headless
# GDScript runner next to this file (release_ios.gd), driving build_kit's own
# BuildKitService. Godot: $GODOT, else /Applications/Godot.app.
#
# This path is stable on purpose: a Claude Code permission rule
# `Bash(*addons/build_kit/cli/release_ios.sh*)` allows exactly this script.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/../../.." && pwd)"
runner="res://addons/build_kit/cli/release_ios.gd"

usage() { sed -n '4p' "${BASH_SOURCE[0]}" | sed 's/^#   /usage: /'; }

args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
	case "${args[$i]}" in
		--project)
			if [ $((i + 1)) -ge ${#args[@]} ]; then
				echo "release_ios: --project needs a value" >&2; usage >&2; exit 2
			fi
			project_dir="${args[$((i + 1))]}"
			i=$((i + 1))
			;;
		--project=*) project_dir="${args[$i]#--project=}" ;;
	esac
	i=$((i + 1))
done

if [ ! -f "$project_dir/project.godot" ]; then
	echo "release_ios: no project.godot in $project_dir (pass --project <dir>)" >&2
	exit 2
fi
project_dir="$(cd "$project_dir" && pwd)"
if [ ! -f "$project_dir/addons/build_kit/cli/release_ios.gd" ]; then
	echo "release_ios: $project_dir doesn't vendor addons/build_kit/cli (update build_kit to 0.3.0+)" >&2
	exit 2
fi

godot="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
if [ ! -x "$godot" ]; then
	echo "release_ios: Godot not found at $godot (set GODOT to the binary)" >&2
	exit 2
fi

exec "$godot" --headless --path "$project_dir" --script "$runner" -- "$@"
