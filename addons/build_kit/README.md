# Build Kit

One-button builds from inside the Godot editor: **iOS → TestFlight**,
**Android → Device** and **itch.io** (Web/desktop channels via `butler`). An
[`editor_tool_kit`](../editor_tool_kit/README.md) tool: a headless-testable
`BuildKitService` + a bottom-panel dock, one tab per target.

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
3. `xcodebuild archive` — **unsigned** (`CODE_SIGNING_ALLOWED=NO`): skipping
   dev-signing removes the dev-profile requirement (Apple refuses to mint one
   for a team with no registered devices)
4. `codesign --force --sign - --entitlements <App>/<App>.entitlements` on the
   archived `.app` — an ad-hoc signature whose only job is to *declare* the
   entitlements Godot's export wrote (including the preset's
   `entitlements/additional`, e.g. Sign in with Apple). Without it the
   unsigned archive declares none, so export signing silently reuses a stale
   provisioning profile and drops those entitlements from the binary
5. `xcodebuild -exportArchive -allowProvisioningUpdates` with
   `method: app-store-connect`, `destination: export` — the distribution
   signing (cloud signing via the Xcode session or an App Manager API key);
   a profile missing a requested capability is regenerated here. The signed
   `.ipa` lands next to the Xcode project
6. **Entitlement check** — unzips the `.ipa`, reads the signed app's
   entitlements (`codesign --display --entitlements - --xml`) and **fails the
   build, uploading nothing,** if any entitlement in the `.entitlements` file
   is missing (or an array/bool/string value differs; `aps-environment` and
   other values signing rewrites are checked for presence only)
7. `xcodebuild -exportArchive -allowProvisioningUpdates` again with
   `destination: upload` — the same archive and the just-verified profile,
   uploaded straight to App Store Connect

"Build .ipa only" runs stages 1–6 and stops.

> **0.2.1:** before this, the archive was exported without its entitlements
> ever being declared, so a capability added to the App ID after its
> profile was first minted (Sign in with Apple, here) was missing from the
> uploaded build. If an older build of yours lacks one, rebuild with 0.2.1+.

Known failures (missing app record, signing conflicts, expired sessions, …)
are classified into plain-language guidance rather than raw xcodebuild logs —
see `classify.gd`.

### One-command release (CLI, 0.3.0+)

The whole TestFlight release, build-number commit included, from a terminal
(or an agent) with no editor open:

```sh
addons/build_kit/cli/release_ios.sh                 # from the project root
addons/build_kit/cli/release_ios.sh --project path/to/godot-project --no-push
```

```
release_ios.sh [--project <dir>] [--no-upload] [--no-commit] [--no-push] [--timeout <minutes>]
```

| Flag | Effect |
|---|---|
| `--project <dir>` | the directory holding `project.godot`; default: the project this addon is vendored in (`addons/build_kit/cli` → three levels up) |
| `--no-upload` | stop after the verified local `.ipa` (kept); no App Store Connect, commit or push |
| `--no-commit` | upload, write the next `build_number`, but leave it uncommitted (implies `--no-push`) |
| `--no-push` | commit locally, don't push |
| `--timeout <min>` | how long to wait for App Store Connect processing (default 20) |

Godot comes from `$GODOT`, else `/Applications/Godot.app/Contents/MacOS/Godot`.
The script runs `cli/release_ios.gd` headless, which drives this addon's own
`BuildKitService` (the same stages as the dock), in order:

1. **Preflight** — iOS preset present; an App Store Connect API key (needed to
   pick the build number and watch processing); and, unless `--no-commit`, a
   git work tree with **nothing staged**, `build_kit.config.json` not locally
   modified, and (unless `--no-push`) a branch with an upstream it isn't
   ahead of — so the push carries only the release commit. Checked *before*
   building, so it never uploads something it then can't record.
2. **Build number** — `max(ios.build_number, highest build of this version on
   App Store Connect + 1)` (`asc_helper.py build-numbers`). An upload whose
   bump never got committed is skipped over instead of colliding. The version
   is the preset's `application/short_version`, else
   `application/config/version` — and that same version is what the commit
   message and the processing poll use (the generated Info.plist only says
   `$(MARKETING_VERSION)`; the archived app's expanded value overrides it only
   when it is a real, different version).
3. **export → patch → archive → embed_entitlements → export_ipa →
   verify_entitlements → upload** — the pipeline above; a missing
   entitlement fails here, before anything is uploaded.
4. **Record** — writes `ios.build_number = uploaded + 1` into
   `build_kit.config.json` (only that value changes; the file's formatting is
   kept), `git add`s **only** that file and commits it as
   `build: iOS <version> (<build>) uploaded to TestFlight; next build_number <n>`
   (no trailers), then pushes to the branch's upstream. A rejected push gets
   one `git fetch` + rebase of just that commit and one retry; it never
   force-pushes. This runs as soon as the upload succeeds, so the number is
   recorded even if processing later fails or times out.
5. **Processing** — polls App Store Connect every 30 s
   (`asc_helper.py build-status`: `GET /v1/builds` filtered by the app, the
   build number and the version) until the build is `VALID`;
   `FAILED`/`INVALID` fails the run. The timeout, a permanent query error, or
   5 consecutive failed queries (e.g. HTTP 500s) stop the poll with a `WARN`
   and exit `3`: the build is uploaded and recorded, only processing is
   unconfirmed — check TestFlight rather than re-running.
6. **Cleanup** — removes the build outputs it created (Xcode project, archive,
   `.ipa`, check files) and keeps `logs/` next to them.

Output is one line per stage plus a final summary, e.g.

```
[verify_entitlements] ok — 4s
[upload] ok — 95s
[config] ok — build_kit.config.json build_number → 43
[commit] ok — 1a2b3c4d5e6f
[push] ok — origin/main
[processing] ok — build 42 is VALID (ready to test) after 610s
release_ios: OK  version=1.0 build=42 asc=VALID entitlements=verified commit=1a2b3c4d5e6f
```

Exit status: `0` success (build `VALID`), `1` any failed stage, `2` usage
error, `3` uploaded and recorded but processing unconfirmed (summary line
`release_ios: UNCONFIRMED …`). Credentials
use the same resolution as the dock (process env → `.env`) and are never
printed: the stage command lines (which carry API-key flags) stay in the
logs, and everything echoed is redacted.

**Claude Code** — allow exactly this script, so an agent can cut a release
without blanket shell access (`.claude/settings.json` → `permissions.allow`):

```
Bash(*addons/build_kit/cli/release_ios.sh*)
```

### Android

**Preflight** — a second checklist for the Android toolchain: the Android SDK
and Java SDK paths (read from the editor's own `EditorSettings`; **Fix**
points them at an already-installed SDK/JDK if one exists at the conventional
location — it never installs one for you), the Android export preset (Fix
backfills a missing `export_path`, which the Editor's Export dialog leaves
blank by default), the debug keystore Godot generates and signs debug builds
with (detect-only — no Fix; the actionable row is the JDK one, since that's
what Godot's own keystore generation needs), export templates (shared with
iOS and itch.io — one download, a row on each tab), the ETC2/ASTC project setting Android export
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

### itch.io

**Preflight** — a third checklist, on the **itch.io** tab:

| Row | Checks | Fix |
|---|---|---|
| `itch.butler` | `butler version` runs (managed copy → the itch app's own copy → `butler` on `PATH`) | **Fix** downloads butler from itch's broth CDN into the managed location (below) |
| `itch.auth` | an API key in the process env or `.env` (`BUTLER_API_KEY`), or the creds file `butler login` writes; then `butler status` confirms it | **Sign in with browser** runs `butler login`: it opens itch.io in your browser, you approve butler, and the credentials are saved for every project on the machine. Or paste a key into the inline field (**↗ Open API keys** opens itch's settings page) — saved to the gitignored `.env`, never echoed |
| `itch.target` | `itch.user` / `itch.game` are valid slugs, and `butler status` can see the game | Paste the game's URL (`https://<user>.itch.io/<game>`) or `<user>/<game>` into the inline field. The game page must already exist — **↗ Create new project** opens itch's creation form |
| `itch.channels` | at least one enabled channel, each naming an existing export preset, with unique, valid channel names | **Fix** writes the auto-discovered channels into `build_kit.config.json` so you can edit them |
| `itch.templates` | the release export templates each enabled channel's platform needs | **Fix** — the same template download the iOS/Android rows use |
| `itch.web` | warns when the Web preset has **thread support** on (needs SharedArrayBuffer, i.e. cross-origin isolation on itch's side) | **Fix** turns `variant/thread_support` off in `export_presets.cfg`; or keep threads and enable SharedArrayBuffer on the itch page (see Setup) |
| `itch.version` | warns when `application/config/version` is empty (the push then carries no `--userversion`) | Type a version into the inline field — it's written to Project Settings |

`itch.auth` and `itch.target` show as busy while a background `butler status`
runs, then resolve to green/red from its output.

**Build → itch.io** — every stage detached and cancellable, logs streamed into
the dock:

1. For each enabled channel: `godot --headless --export-release "<preset>"`
   into `build/itch/<channel>/` (Web → `index.html`; desktop → the preset's
   export file name, else the app name + `.exe` / `.x86_64` / `.zip`). Each
   channel dir is wiped and recreated first, so a push never carries stale
   files. The Web export is then checked against itch's HTML5 limits (an
   `index.html` at the top, ≤ 1000 files, ≤ 200 MB per file, ≤ 500 MB total).
2. Only once **every** export has succeeded:
   `butler push build/itch/<channel> <user>/<game>:<channel> --userversion <version> --if-changed`
   per channel. The API key reaches butler through the process environment,
   never the command line, so it never appears in the echoed log.

The staging dir gets its own `.gdignore` (Godot won't import the exports) and
`.gitignore` (`*`), so nothing under it is ever committed.

A channel picker narrows a run to one channel. Alongside the main button:

- **Export only** — stage 1 only; nothing is uploaded.
- **Dry run** — exports, then `butler push --dry-run` (reports what would be
  uploaded).
- **itch status** — `butler status <user>/<game>`: each channel's latest
  build and version.

butler failures (no butler, bad/expired key, unknown game, invalid channel
name, network errors) get the same `classify.gd` treatment, scoped to itch.io.

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

### itch.io

1. Create the game page on itch.io first (Dashboard → Create new project) —
   butler can push to an existing project but can't create one. Paste its URL
   into the `itch.target` row.
2. Have an export preset per platform you ship (Web, Windows Desktop, macOS,
   Linux). With no `itch.channels` configured they're auto-discovered:
   **Web → `html5`**, **Windows Desktop → `windows`**, **macOS → `mac`**,
   **Linux → `linux`**.
3. Sign in: press **Sign in with browser** on the `itch.auth` row and approve
   butler on itch.io (once per machine). Or paste an API key from
   [itch.io → Settings → API keys](https://itch.io/user/settings/api-keys)
   into that row (saved as `BUTLER_API_KEY` in `.env`), or export
   `BUTLER_API_KEY` in your shell. Lookup order: process env → `.env` →
   `butler login`'s creds file. butler only runs its browser sign-in when it
   has a terminal, so on macOS/Linux the button runs it under `script` (a
   pseudo-terminal).
4. butler itself: **Fix** on `itch.butler` installs a managed copy into the OS
   user data dir — `~/Library/Application Support/build_kit/butler/` (macOS),
   `~/.local/share/build_kit/butler/` (Linux), `%APPDATA%\build_kit\butler\`
   (Windows). Outside any repo, shared by every project on the machine.
5. **First HTML5 push only** — itch can't infer this, so on the game's edit
   page after the first `html5` push: set **Kind of project = HTML**, tick
   **"This file will be played in the browser"** on the `html5` upload, set the
   **viewport size** to your game's resolution, and — only if the Web preset
   has thread support on — enable **SharedArrayBuffer support** under
   Embed options. Later pushes keep these settings.

### Where the two kinds of state live

Build Kit splits its state by whether it is safe to commit:

| | File | Committed? | Holds |
|---|---|---|---|
| Shared settings | `res://build_kit.config.json` | **yes** | `ios.preset`, `ios.build_number`, `android.preset`, `android.version_code`, `itch.user`, `itch.game`, `itch.output_dir`, `itch.channels` |
| Credentials | repo `.env` (`res://.env`, else `res://../.env`) | **no** — gitignored | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH` (iOS); `BUTLER_API_KEY` (itch.io) |

```json
{
	"ios": {
		"preset": "iOS",
		"build_number": 1
	},
	"android": {
		"preset": "Android",
		"version_code": 1
	},
	"itch": {
		"user": "<your-itch-user>",
		"game": "<your-game-slug>",
		"output_dir": "build/itch",
		"channels": [
			{ "preset": "Web", "channel": "html5", "enabled": true },
			{ "preset": "Windows Desktop", "channel": "windows", "enabled": true }
		]
	}
}
```

`itch.channels` may be left empty (`[]`) — every Web / Windows Desktop /
macOS / Linux preset is then pushed to its default channel (`html5` /
`windows` / `mac` / `linux`). List entries to rename a channel, disable one
(`"enabled": false`), or skip a preset. `itch.output_dir` must be a relative
path inside the project.

`android.version_code` isn't read or written by anything yet — it's a home
for the Play Console upload path to auto-bump, the same way `build_number`
bumps on every TestFlight upload, once that pipeline exists. (The dock's
upload saves the bump; `cli/release_ios.sh` also commits and pushes it.)

```sh
# .env — written for you when you drop the .p8 / save the Issuer ID
ASC_KEY_ID=ABC123DEFG
ASC_ISSUER_ID=12345678-abcd-...
ASC_KEY_PATH=~/private_keys/AuthKey_ABC123DEFG.p8
BUTLER_API_KEY=<your-itch-api-key>
```

The key path is stored home-relative so it still resolves on another machine.
Saving a credential also checks that the `.env` is gitignored and adds the rule
if it is missing — writing a secret into a tracked file would only relocate the
leak. `ASC_*` / `BUTLER_API_KEY` in the process environment work too, and
take precedence over the `.env`.

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
| `itch.gd` | itch.io helpers (static): channel discovery, butler args/URLs, status parsing, HTML5 bundle limits, the `itch.*` preflight rows |
| `asc_helper.py` | App Store Connect API probe (stdlib-only; ES256 via openssl) |
| `cli/release_ios.sh` | one-command iOS release entry point (stable path — see the permission rule above) |
| `cli/release_ios.gd` | the headless runner it launches: drives `BuildKitService`, ASC, git |
| `cli/release_core.gd` | the runner's pure halves: args, build-number pick, config write, commit message, git commit/push |
| `dock.gd` | the bottom-panel view |

Headless check (from the repo root):
`godot --headless --path . --script res://tools/verify_build_kit.gd`
