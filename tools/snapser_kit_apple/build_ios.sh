#!/usr/bin/env bash
# Builds addons/snapser_kit_apple/ios/snapser_kit_apple.xcframework (release,
# ios-arm64, static) from tools/snapser_kit_apple/src.
#
# Needs: macOS with Xcode (iPhoneOS SDK), git, python3, and scons on PATH (or
# SCONS=/path/to/scons). Keep scons in a venv rather than a global install:
#
#   python3 -m venv .venv-scons && .venv-scons/bin/pip install scons
#   SCONS=.venv-scons/bin/scons tools/snapser_kit_apple/build_ios.sh
#
# godot-cpp is fetched (shallow, pinned) into tools/snapser_kit_apple/.build/,
# which is gitignored. Only the finished .xcframework is committed.
#
# The output is one static library: our objects plus the godot-cpp objects they
# use, pre-linked with `ld -r` so that only the entry symbol stays global. That
# keeps the file small and stops our copy of godot-cpp colliding with any other
# static GDExtension linked into the same app.

set -euo pipefail

# godot-cpp v10 targets several engine versions through api_version (set to
# 4.7 in SConstruct). It has no 4.7 branch; this tag is the pin.
GODOT_CPP_TAG="10.0.0-stable"
GODOT_CPP_SHA="507ed9d840c01a3c5b2a39af8bb4000bfac30bf5"
GODOT_CPP_URL="https://github.com/godotengine/godot-cpp.git"

IOS_MIN="15.0"
ARCH="arm64"
TARGET="template_release"
ENTRY_SYMBOL="snapser_kit_apple_init"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$HERE/.build"
GODOT_CPP="$BUILD/godot-cpp"
OUT_DIR="$REPO_ROOT/addons/snapser_kit_apple/ios"
XCFRAMEWORK="$OUT_DIR/snapser_kit_apple.xcframework"

SCONS="${SCONS:-scons}"
if ! command -v "$SCONS" >/dev/null 2>&1; then
	echo "error: scons not found. Install it in a venv and pass SCONS=<venv>/bin/scons (see the header of this script)." >&2
	exit 1
fi
for tool in git xcrun xcodebuild; do
	command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found (install Xcode)." >&2; exit 1; }
done

# 1. Fetch the pinned godot-cpp.
mkdir -p "$BUILD"
if [ ! -d "$GODOT_CPP/.git" ]; then
	echo "==> fetching godot-cpp $GODOT_CPP_TAG"
	git clone --quiet --depth 1 --branch "$GODOT_CPP_TAG" "$GODOT_CPP_URL" "$GODOT_CPP"
fi
actual_sha="$(git -C "$GODOT_CPP" rev-parse HEAD)"
if [ "$actual_sha" != "$GODOT_CPP_SHA" ]; then
	echo "error: $GODOT_CPP is at $actual_sha, expected $GODOT_CPP_SHA ($GODOT_CPP_TAG). Delete $BUILD and rerun." >&2
	exit 1
fi

# 2. Compile godot-cpp and our sources.
jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
echo "==> scons ($TARGET, ios-$ARCH, iOS $IOS_MIN)"
(cd "$HERE" && GODOT_CPP_DIR="$GODOT_CPP" "$SCONS" -j"$jobs" \
	platform=ios arch="$ARCH" target="$TARGET" ios_min_version="$IOS_MIN" \
	optimize=size debug_symbols=no)

suffix=".ios.$TARGET.$ARCH"
ours="$BUILD/lib/libsnapser_kit_apple_only$suffix.a"
cpp="$GODOT_CPP/bin/libgodot-cpp$suffix.a"
[ -f "$ours" ] || { echo "error: missing $ours" >&2; exit 1; }
[ -f "$cpp" ] || { echo "error: missing $cpp" >&2; exit 1; }

# 3. Pre-link: force-load our objects, pull only the godot-cpp objects they
#    reference, and make every symbol except the entry point local.
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
combined="$BUILD/snapser_kit_apple$suffix.o"
echo "==> ld -r (exporting only _$ENTRY_SYMBOL)"
xcrun --sdk iphoneos ld -r -arch "$ARCH" \
	-platform_version ios "$IOS_MIN" "$sdk_version" \
	-exported_symbol "_$ENTRY_SYMBOL" \
	-force_load "$ours" "$cpp" \
	-o "$combined"
xcrun strip -S "$combined"

lib="$BUILD/libsnapser_kit_apple$suffix.a"
rm -f "$lib"
ZERO_AR_DATE=1 xcrun libtool -static -D -o "$lib" "$combined"

# 4. Package.
echo "==> xcframework"
mkdir -p "$OUT_DIR"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework -library "$lib" -output "$XCFRAMEWORK" >/dev/null

echo "==> done: $XCFRAMEWORK"
du -sh "$XCFRAMEWORK"
find "$XCFRAMEWORK" -name '*.a' -exec ls -l {} \;
