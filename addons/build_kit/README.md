# Build Kit

One-button device builds from inside the Godot editor: **iOS → TestFlight**
and **Android → Device**. An [`editor_tool_kit`](../editor_tool_kit/README.md)
tool: a headless-testable `BuildKitService` + a bottom-panel dock, one tab per
platform.

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
3. `xcodebuild archive` — **unsigned** (`CODE_SIGNING_ALLOWED=NO`): the export
   stage does the only signing that matters, and skipping dev-signing here
   removes the dev-profile requirement (Apple refuses to mint one for a team
   with no registered devices)
4. `xcodebuild -exportArchive` with `method: app-store-connect`,
   `destination: upload` — signs everything with a distribution certificate
   (cloud signing via the Xcode session or an App Manager API key) and
   uploads straight to App Store Connect

"Build .ipa only" runs the same pipeline with `destination: export`.

Known failures (missing app record, signing conflicts, expired sessions, …)
are classified into plain-language guidance rather than raw xcodebuild logs —
see `classify.gd`.

### Android

**Preflight** — a second checklist for the Android toolchain: the Android SDK
and Java SDK paths (read from the editor's own `EditorSettings`; **Fix**
points them at an already-installed SDK/JDK if one exists at the conventional
location — it never installs one for you), the Android export preset (Fix
backfills a missing `export_path`, which the Editor's Export dialog leaves
blank by default), the debug keystore Godot generates and signs debug builds
with (detect-only — no Fix; the actionable row is the JDK one, since that's
what Godot's own keystore generation needs), export templates (shared with
iOS — one download, two rows), the ETC2/ASTC project setting Android export
requires, and any `adb`-connected device.

**Build → Device** — two stages, both detached and cancellable:

1. `godot --headless --export-debug <preset> <out.apk>` — Godot signs the APK
   itself via `apksigner` (from the Android SDK's `build-tools`). If it can't
   find `apksigner` it emits a *warning*, not an error, and ships an
   **unsigned** APK while still exiting 0 — Build Kit scans the export log
   for that warning and fails the pipeline there instead of letting
   `adb install` deliver a confusing, unrelated-looking error.
2. `adb install -r <out.apk>` (`-s <serial>` when more than one device is
   connected — a picker appears on the Device preflight row; with exactly one
   device it's used silently, with zero the row stays red).

Known Android failures (an install signed with a different key, an
unauthorized or missing device, low storage, a missing SDK/JDK path, …) get
the same plain-language `classify.gd` treatment as iOS's, scoped so an
Android failure never gets iOS's guidance text or vice versa.

**Not yet built** — visible-but-disabled buttons on the Android tab signal
the intent without hiding it: Build → Play Console (AAB upload) and Build
.apk-only (local export) both need "Use Gradle Build" turned on, which this
pass deliberately doesn't do; release-keystore ingestion is independent of
that but has no ingestion UI yet either.

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

### iOS

1. Have an iOS export preset (Project → Export → iOS) with the bundle
   identifier set. Leave signing fields empty. Run the preflight **Fix** to
   set `export_project_only` + Team ID.
2. Optional but recommended — an **App Store Connect API key** (headless auth,
   proactive app-record checks, TestFlight status polling). The preflight row
   walks you through it: click **↗ Create API key** (＋ → role: App Manager →
   Generate → Download), then **drop the downloaded `.p8` on the panel** (or
   Browse…) — the key id and path are extracted from Apple's
   `AuthKey_<KEYID>.p8` filename and the file is copied to `~/private_keys/`
   (chmod 600, outside any repo) — and paste the **Issuer ID** from the top of
   that page into the field.

### Android

1. In Editor Settings (Editor → Editor Settings → Export → Android), point
   **Android SDK Path** and **Java SDK Path** at your installs. Preflight's
   **Fix** can point either setting at an SDK/JDK it finds at the
   conventional location, but it never installs one — that step stays manual.
2. Have an Android export preset (Project → Export → Android) with a unique
   package name. Preflight's **Fix** backfills a missing `export_path`
   (`build/android/<AppName>.apk`) if the preset was hand-created via the
   Export dialog, which leaves that field blank.
3. Connect a device over USB with debugging enabled (or start an emulator)
   and accept the RSA fingerprint prompt on first connect — the Device row
   goes green once `adb` reports it authorized. Godot generates its own debug
   keystore automatically; there's nothing to set up for that.

### Where the two kinds of state live

Build Kit splits its state by whether it is safe to commit:

| | File | Committed? | Holds |
|---|---|---|---|
| Shared settings | `res://build_kit.config.json` | **yes** | `ios.preset`, `ios.build_number`, `android.preset`, `android.version_code` |
| Credentials | repo `.env` (`res://.env`, else `res://../.env`) | **no** — gitignored | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH` (iOS only) |

```json
{
	"ios": {
		"preset": "iOS",
		"build_number": 1
	},
	"android": {
		"preset": "Android",
		"version_code": 1
	}
}
```

`android.version_code` isn't read or written by anything yet — it's a home
for the Play Console upload path to auto-bump, the same way `build_number`
bumps on every TestFlight upload, once that pipeline exists.

```sh
# .env — written for you when you drop the .p8 / save the Issuer ID
ASC_KEY_ID=ABC123DEFG
ASC_ISSUER_ID=12345678-abcd-...
ASC_KEY_PATH=~/private_keys/AuthKey_ABC123DEFG.p8
```

The key path is stored home-relative so it still resolves on another machine.
Saving a credential also checks that the `.env` is gitignored and adds the rule
if it is missing — writing a secret into a tracked file would only relocate the
leak. `ASC_*` in the process environment works too, and takes precedence over
the `.env`.

> **Upgrading from ≤ 0.1.7:** those versions wrote the three `asc_*` fields into
> `build_kit.config.json`, which is committed. On first load 0.1.8+ moves any it
> finds into the `.env` and drops them from the config — so the next commit
> removes them. They are *identifiers*, not the private key (the `.p8` was always
> kept outside the repo), so this is hygiene rather than an incident; but if the
> config was pushed to a public repo, treat the pairing as disclosed.

Without a key the pipeline uses your signed-in Xcode session — fine
interactively, but sessions expire and the app-record check then only happens
reactively at upload time.

One-time steps no tool can automate (the preflight walks you through them):
Apple Developer Program membership, creating the API key, and creating the
**app record** in App Store Connect (app creation is not in Apple's public
API; the bundle id appears in the New App dropdown because automatic signing
registers it on first archive).

## Files

| File | Role |
|---|---|
| `build_kit_service.gd` | preflight + pipeline state machine (headless-testable) |
| `exec.gd` | detached process runner (log file + exit sentinel, poll/kill) — cmd.exe on Windows, `/bin/zsh` on macOS, `/bin/sh` on Linux |
| `classify.gd` | failure signatures → plain-language guidance |
| `asc_helper.py` | App Store Connect API probe (stdlib-only; ES256 via openssl) |
| `dock.gd` | the bottom-panel view |

Headless check (from the repo root):
`godot --headless --path . --script res://tools/verify_build_kit.gd`
