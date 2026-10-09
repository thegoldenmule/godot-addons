# BuildKitService

**Status:** current

## Kind
service

## Summary
`build_kit_service.gd` — the headless-testable `ToolService` core, and the whole tool minus its pixels. It owns two halves that share one state model: **preflight** (nine checks over the local Apple toolchain and the remote App Store Connect state, each row carrying its own fix) and the **pipeline** (a four-stage build advanced from `_process()`). Around them sit config + secret handling, three async App Store Connect probes, and the repair actions behind the dock's Fix buttons.

## Purpose
Concentrating every decision here — what is broken, how to repair it, which stage runs next, what a failure means — keeps the dock a pure view and keeps the interesting logic reachable from `godot --headless` (see `tools/verify_build_kit.gd`, which exercises the static helpers: quoting, preset parsing, path derivation, the export-options plist, `.env` parsing/upsert, team parsing, version tags, template URLs, bundle-id validation and preset creation).

## Design notes
Preflight fixes the service performs itself, behind apply_fix(id, opts): 'preset' writes export_project_only=true, backfills any missing base keys Godot's preset loader reads with no default, and fills the Team ID (from the picker, or automatically when exactly one Xcode team is signed in); 'templates' downloads the official export-template pack for the running Godot version and dittos it into place; 'etc2' enables rendering/textures/vram_compression/import_etc2_astc and saves project.godot; 'app_record' registers the preset's App ID on the developer portal through the API key, so the New App dialog's Bundle ID dropdown has something to pick.

create_ios_preset(bundle_id, team_id) writes a complete, ready-to-build preset from scratch — including every base key an editor-created preset carries. Godot's preset loader get_value()s those keys with NO default, so a leaner generated preset hard-errors at export time; preset_base_defaults() is the single list, used both when generating a preset and when healing one.

The ETC2/ASTC check exists because iOS export hard-requires those texture imports and Godot reports the violation with an EMPTY error list in headless runs — 'due to configuration errors:' and nothing after the colon. Preflight is the only place a user ever learns the actual cause.

check_testflight_status() polls App Store Connect for the app's recent builds and reports the latest one's state (VALID → 'Ready to Test' with the add-a-tester walkthrough, PROCESSING → check again shortly, anything else → Apple rejected it in post-processing). Every exit path emits build_finished: the dock's status line is written ONLY by that signal, so a bare return would leave the previous poll's verdict on screen as a stale, green-checked answer.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- function `start_build(upload) — validate, choose auth, queue the four stages` in `addons/build_kit/build_kit_service.gd`
- function `refresh_preflight() — rebuild the nine-row checklist` in `addons/build_kit/build_kit_service.gd`
- function `apply_fix(id, opts) — preset / templates / etc2 / app_record` in `addons/build_kit/build_kit_service.gd`
- function `_handle_team_info() — gate the app-record probe on a matching team` in `addons/build_kit/build_kit_service.gd`
- function `derive_paths(), make_export_options_xml(), parse_ios_preset_text() — the pure helpers the verifier covers` in `addons/build_kit/build_kit_service.gd`
- file `headless coverage of the static helpers` in `tools/verify_build_kit.gd`

## Data model
**Signals** (the dock's only inputs): `preflight_changed(rows)`, `stage_changed(stage)`, `log_line(text)`, `build_finished(result)`.

**Preflight rows** are plain dictionaries — `{id, label, status, detail, guidance, fixable, links}` — with `status` one of `ok` / `warn` / `fail` / `busy`. `refresh_preflight()` rebuilds the whole array synchronously and emits it; the async ASC probes later patch individual rows in place via `_set_row()` and re-emit. The nine rows are `xcode`, `templates`, `etc2`, `preset`, `account`, `dist_cert`, `asc_key`, `app_record`, `devices`.

**The pipeline** is a queue of `{name, shell}` dicts drained one at a time. `start_build(upload)` validates the preset, writes the export-options plist, picks the auth mode, builds the four stages and starts the first; `_poll_pipeline()` tails the active log, and on a non-zero exit hands the whole log to `classify.gd` and stops. The stages:

1. **export** — `godot --headless --export-release <preset> <out>` with `export_project_only`, producing an Xcode project.
2. **patch** — `PlistBuddy` sets `ITSAppUsesNonExemptEncryption=false` (no "Missing Compliance" stall in TestFlight) and `CFBundleVersion` from the auto-bumped build number.
3. **archive** — `xcodebuild archive` with `CODE_SIGNING_ALLOWED=NO`.
4. **upload** / **export_ipa** — `xcodebuild -exportArchive -allowProvisioningUpdates` against the generated options plist (`destination: upload` → TestFlight, `destination: export` → a local `.ipa`).

A successful **upload** increments `ios.build_number` and saves the config; `.ipa`-only runs do not.

**Async probes**, each a detached `asc_helper.py` run polled from `_process()`: `_asc_proc` (a two-phase `team-info` → `check-app` chain, 60 s timeout), `_builds_proc` (`check_testflight_status()`), and `_fix_proc` (a running Fix — template download or bundle-id registration).

## Usage
_None._

## Invariants & constraints
- Service methods return an {ok, error} / {ok, ...} Dictionary (the ToolService contract) rather than throwing; the dock renders whatever comes back.
- Only one long-running job of each kind exists at a time: is_busy() rejects a second build, and both the ASC probe and the Fix runner refuse to start while one is in flight.
- The pipeline aborts on the first non-zero stage exit — the remaining stages are dropped and the log is classified into guidance.
- ios.build_number is bumped only after a successful UPLOAD, and kept an int (JSON numbers parse as floats, and CFBundleVersion must read "2", not "2.0").
- Every exit path of the TestFlight-status poll emits build_finished, so the dock's verdict is never a stale carry-over from an earlier poll.
- The app-record probe runs only after the API key's team is confirmed to match the preset's team — a wrong-team key answers every query truthfully about the wrong team.

## Synced commit
1503c29
