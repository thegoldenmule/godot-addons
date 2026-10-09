# Build Kit

**Status:** current

## Kind
package

## Summary
**Build Kit** (`addons/build_kit/`) — an **editor-only** device-build pipeline, currently iOS → TestFlight. Two halves: a **preflight checklist** that diagnoses the whole chain (Xcode, iOS export templates, ETC2/ASTC imports, the iOS export preset, signed-in Xcode teams, a distribution certificate, an App Store Connect API key, the ASC app record, paired devices) and tells you exactly how to repair each broken link — repairing several itself via a per-row **Fix** button — and a **staged build pipeline** (Godot headless export → `Info.plist` patch → `xcodebuild archive` → `xcodebuild -exportArchive`) that ends with the build sitting in TestFlight. Every external command runs **detached**, its log streamed into the dock, so the editor never blocks and any stage is cancellable. Built on `editor_tool_kit` as a *service + a view* and managed by etk's self-update dock. **Vendored** into a consuming project (committed under `addons/build_kit/`) yet **sourced** from this repo.

## Purpose
Getting a Godot game onto a tester's phone is a long chain of Apple-specific steps, and every link fails with an error that names the symptom rather than the fix — a wall of `xcodebuild` output, a Godot export that reports "configuration errors:" with nothing after the colon, an upload that dies because an App Store Connect app record nobody told you to create doesn't exist. Godot's own iOS pipeline does not close the gap: its built-in `.ipa` export can invoke `xcodebuild`, but that path is broken under Xcode 26 ([godot#111213](https://github.com/godotengine/godot/issues/111213)), it can only ride the Xcode GUI login session (no API-key auth, so no headless runs), and it stops at an `.ipa` — the classic uploader (`altool`) is deprecated and rotting.

Build Kit's premise is that **the tool's job is to tell you what to do**. Preflight names each broken link in plain language with the click-path to fix it (and a Fix button wherever the repair is mechanical); pipeline failures are matched against signatures observed in real runs and rendered as numbered next steps with open-in-browser links. The remaining one-time steps no tool can automate — Apple Developer Program membership, minting an API key, creating the app record — are walked through rather than assumed.

## Design notes
_No design notes._

## Components
- [BuildKitService](architecture:mtd8flef-000b-mb3r1t)
- [Exec — the detached process runner](architecture:mtd8fo30-000d-95y06b)
- [Classify — failure signatures to guidance](architecture:mtd8fqxf-000f-u66f5v)
- [asc_helper.py — the App Store Connect probe](architecture:mtd8fu4d-000h-d0j3uv)
- [Build Kit dock](architecture:mtd8fwzk-000j-qg9yzj)
- [Configuration & secrets](architecture:mtd8g028-000l-v4482a)

## Dependencies
- **depends-on** → [Editor Tool Kit](architecture:mql3ccsv-01q2-v81c5e) — ToolService / EditorToolPlugin / EditorToolUi bases + the self-update dock that manages it; must be vendored + enabled alongside.

## Code references
- class `BuildKitService — preflight + pipeline, headless-testable` in `addons/build_kit/build_kit_service.gd`
- file `detached process runner` in `addons/build_kit/exec.gd`
- file `failure signatures → guidance` in `addons/build_kit/classify.gd`
- file `App Store Connect API probe` in `addons/build_kit/asc_helper.py`
- file `the bottom-panel view` in `addons/build_kit/dock.gd`
- file `version + [update] marker (the ship signal)` in `addons/build_kit/plugin.cfg`
- file `headless verifier` in `tools/verify_build_kit.gd`

## Data model
Five scripts plus a Python helper, and two project-owned state files that live OUTSIDE the addon folder (self-update overwrites the folder):

- **`build_kit_service.gd`** (`extends ToolService`) — the headless-testable core: config + secrets, the preflight checks, the staged pipeline, the async App Store Connect probes, and the fixes.
- **`exec.gd`** — the detached process runner (log file + exit-code sentinel, poll / tail / kill-tree).
- **`classify.gd`** — ordered failure signatures → title + guidance + links.
- **`asc_helper.py`** — the stdlib-only App Store Connect API probe (ES256 JWT via `openssl`), spawned as `python3 -B`.
- **`dock.gd`** — the bottom-panel view; a pure observer of the service's signals.
- **`plugin.gd`** (`extends EditorToolPlugin`) — declares the pieces via `_config()`; the base mounts the dock beneath the enforced header.
- **`res://build_kit.config.json`** — committed shared settings (`ios.preset`, `ios.build_number`).
- **the repo `.env`** (`res://.env`, else `res://../.env`) — gitignored credentials (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`).

The iOS export preset in `res://export_presets.cfg` is the third piece of state: Build Kit reads the bundle id, Team ID, `export_project_only` flag and `export_path` from it, and every build path is derived from that `export_path`.

## Usage
Vendor `addons/build_kit/` (and `addons/editor_tool_kit/`) into a project and enable both in Project Settings → Plugins. Open the **Build Kit** bottom-panel tab: the left column is the preflight checklist (each failing row shows its fix inline, with a **Fix** button where the service can repair it, plus the inline forms for creating an iOS preset and adopting an ASC key); the right column is **▶ Build → TestFlight**, **Build .ipa only**, **✕ Cancel**, **TestFlight status**, a status line with next-step links, and the streaming pipeline log. See the Usage guides for the first-run walkthrough and the build loop.

## Invariants & constraints
- Editor-only: every script is @tool; the addon adds no runtime dependency to an exported game.
- macOS-only in practice — the whole pipeline is xcodebuild, PlistBuddy, devicectl and the macOS keychain.
- BuildKitService carries no Control / EditorInterface references, so its logic runs under godot --headless; the dock is a thin observer that re-renders on the service's signals.
- No external command ever blocks the editor thread: every long command is spawned detached and polled from _process(), and any stage can be cancelled (the runner kills the shell AND its children).
- No secret is ever written into a committed file: credentials go to the repo .env, the .p8 is copied to ~/private_keys/ (chmod 600), and saving a credential checks the .env is gitignored — adding the rule when it is missing.
- The iOS export preset's signing fields stay empty — Godot exports the Xcode project only (export_project_only=true) and Build Kit owns every signing decision.
- Project state lives outside addons/build_kit/ (res://build_kit.config.json and the repo .env), so a self-update never clobbers it.
- Nothing game-specific lives in the addon: the bundle id, team, preset name and build number all come from the project's own preset + config.

## Synced commit
1503c29
