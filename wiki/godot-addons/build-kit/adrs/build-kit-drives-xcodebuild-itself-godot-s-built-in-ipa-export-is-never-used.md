# Build Kit drives xcodebuild itself; Godot's built-in .ipa export is never used

**Status:** accepted

## Metadata
- **Number:** ADR-17
- **Date:** 2026-08-28
- **Scope:** build_kit
- **Deciders:** Benjamin Jordan

## Context
Godot 4.2+ can produce an iOS `.ipa` on its own by invoking `xcodebuild` from inside the export. Reusing that would have meant no `xcodebuild` code in the addon at all. Three things rule it out: the path is **broken under Xcode 26** ([godot#111213](https://github.com/godotengine/godot/issues/111213)); it can only ride the Xcode GUI login session, so **App Store Connect API-key auth is impossible** and nothing runs headless; and it **stops at an `.ipa`** — getting that file to TestFlight then needs the classic uploader `altool`, which is deprecated and rotting. Godot's own signing fields would also have to hold a team and identity, putting build configuration into `export_presets.cfg`.

## Decision
The iOS export preset sets application/export_project_only = true, so Godot's job ends at generating an Xcode project. Build Kit owns every step after that: the Info.plist patch, xcodebuild archive, and xcodebuild -exportArchive with its own generated export-options plist.

The preset's signing fields stay EMPTY. The team id is read from the preset, but no certificate, profile or credential is ever written into export_presets.cfg.

start_build() refuses to run when export_project_only is off or the Team ID is blank, and points at the preflight Fix button rather than silently falling back to Godot's path.

## Consequences
The pipeline works under Xcode 26, can authenticate with an API key, and ends with the build in TestFlight rather than with a file on disk.

No secret lands in a committed file: export_presets.cfg carries a bundle id and a team id, and nothing else.

The cost is owning four xcodebuild-shaped stages and their failure modes — which is what classify.gd exists to absorb — and tracking Apple's tooling changes ourselves.

The addon is macOS-only in practice, since every stage after the export is an Apple tool.

## Relations
_None._
