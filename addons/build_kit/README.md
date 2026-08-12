# Build Kit

One-button device builds from inside the Godot editor, starting with **iOS →
TestFlight**. An [`editor_tool_kit`](../editor_tool_kit/README.md) tool: a
headless-testable `BuildKitService` + a bottom-panel dock.

## What it does

**Preflight** — a live checklist that diagnoses the whole chain and tells you
exactly how to fix each broken link: Xcode, iOS export templates, the iOS
export preset, signed-in Xcode teams, an App Store Connect API key, whether
the **App Store Connect app record exists** for your bundle id, and paired
devices. Rows the service can repair itself get a **Fix** button (e.g. it
writes `export_project_only=true` and fills the Team ID into the preset).

**Build → TestFlight** — the staged pipeline, every stage a detached process
with its log streamed into the dock (cancellable, never blocks the editor):

1. `godot --headless --export-release` with `export_project_only` → Xcode project
2. `PlistBuddy` patch: `ITSAppUsesNonExemptEncryption=false` (no "Missing
   Compliance" stall in TestFlight) + `CFBundleVersion` from an auto-bumped
   build number
3. `xcodebuild archive` — automatic signing (`CODE_SIGN_STYLE=Automatic`,
   development identity; overrides the distribution identity Godot pins into
   the generated project, which otherwise conflicts)
4. `xcodebuild -exportArchive` with `method: app-store-connect`,
   `destination: upload` — signs with an Apple-managed distribution
   certificate (cloud signing; no local distribution cert ever needed) and
   uploads straight to App Store Connect

"Build .ipa only" runs the same pipeline with `destination: export`.

Known failures (missing app record, signing conflicts, expired sessions, …)
are classified into plain-language guidance rather than raw xcodebuild logs —
see `classify.gd`.

## Why not Godot's built-in .ipa export?

Godot 4.2+ can invoke xcodebuild itself, but (a) that path is broken under
Xcode 26 ([godot#111213](https://github.com/godotengine/godot/issues/111213)),
(b) it can't take App Store Connect API-key auth (it rides the Xcode GUI login
session), and (c) it stops at an `.ipa` — the classic uploader (`altool`) is
deprecated and rotting. Build Kit owns the xcodebuild steps instead; the
preset's signing fields stay **empty** and no secret ever lands in
`export_presets.cfg`.

## Setup

1. Copy `addons/build_kit/` into the project, enable it in Project Settings →
   Plugins.
2. Have an iOS export preset (Project → Export → iOS) with the bundle
   identifier set. Leave signing fields empty. Run the preflight **Fix** to
   set `export_project_only` + Team ID.
3. Optional but recommended — an **App Store Connect API key** (headless auth,
   proactive app-record checks, TestFlight status polling). The preflight row
   walks you through it: click **↗ Create API key** (＋ → role: App Manager →
   Generate → Download), then **drop the downloaded `.p8` on the panel** (or
   Browse…) — the key id and path are extracted from Apple's
   `AuthKey_<KEYID>.p8` filename and the file is copied to `~/private_keys/`
   (chmod 600, outside any repo) — and paste the **Issuer ID** from the top of
   that page into the field. All of that lands in `res://build_kit.config.json`
   (project root, NOT inside the addon — self-update overwrites this folder):

```json
{
	"ios": {
		"preset": "iOS",
		"build_number": 1,
		"asc_key_id": "ABC123DEFG",
		"asc_issuer_id": "12345678-abcd-...",
		"asc_key_path": "~/private_keys/AuthKey_ABC123DEFG.p8"
	}
}
```

`ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_PATH` in the environment or a repo
`.env` (`res://.env` or `res://../.env`) work as fallbacks. Without a key the
pipeline uses your signed-in Xcode session — fine interactively, but sessions
expire and the app-record check then only happens reactively at upload time.

One-time steps no tool can automate (the preflight walks you through them):
Apple Developer Program membership, creating the API key, and creating the
**app record** in App Store Connect (app creation is not in Apple's public
API; the bundle id appears in the New App dropdown because automatic signing
registers it on first archive).

## Files

| File | Role |
|---|---|
| `build_kit_service.gd` | preflight + pipeline state machine (headless-testable) |
| `exec.gd` | detached process runner (log file + exit sentinel, poll/kill) |
| `classify.gd` | failure signatures → plain-language guidance |
| `asc_helper.py` | App Store Connect API probe (stdlib-only; ES256 via openssl) |
| `dock.gd` | the bottom-panel view |

Headless check (from the repo root):
`godot --headless --path . --script res://tools/verify_build_kit.gd`
