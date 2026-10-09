# Building to TestFlight

**Status:** active

## Body
With preflight green, **▶ Build → TestFlight** is the whole loop. The build runs as four detached stages with their output streaming into the log; the editor stays responsive and **✕ Cancel** stops the current stage (and its children) at any point.

## The four stages

1. **export** — `godot --headless --export-release <preset> <out>`. Because the preset has `export_project_only`, this produces an **Xcode project**, not an `.ipa`.
2. **patch** — `PlistBuddy` writes `ITSAppUsesNonExemptEncryption=false` (so TestFlight does not stall on "Missing Compliance") and sets `CFBundleVersion` from the auto-bumped build number.
3. **archive** — `xcodebuild archive` with `CODE_SIGNING_ALLOWED=NO`. The archive is deliberately unsigned; only the next stage signs.
4. **upload** — `xcodebuild -exportArchive` with `method: app-store-connect`, `destination: upload`. This signs with a distribution certificate (cloud signing via your Xcode session, or an App Manager API key) and uploads straight to App Store Connect.

The log's first line names the auth in use — `ASC API key <id>` or `Xcode session (teams: …)`. A signed-in session is preferred when one exists; the key flags are added only when there is none.

A successful upload increments `ios.build_number` in `build_kit.config.json`. **Build .ipa only** runs the identical pipeline with `destination: export` and leaves the signed `.ipa` in the build directory — it does not bump the build number.

## After the upload

Apple processes the build for a few minutes. Press **TestFlight status** to poll:

- **still processing** — check again shortly.
- **Ready to Test** — the first time, open the TestFlight tab → Internal Testing → **＋** → add a group with yourself as a tester. Later builds land in that group automatically.
- **anything else** — Apple rejected the binary in post-processing; the details were emailed to your developer-account address.

On your phone: install the TestFlight app, sign in with the same Apple ID, and the build appears.

(Status polling needs an API key. Without one, App Store Connect's own email is your notification.)

## When a stage fails

The pipeline stops at the first non-zero exit and the log is matched against known failure signatures, so what you see is a diagnosis and numbered next steps — with open-in-browser buttons — rather than raw `xcodebuild` output. The full log is still above it, and its path is in the result.

The signatures cover, among others:

- **No App Store Connect app record for this bundle id** — the one-time New App walkthrough.
- **No distribution certificate in the keychain** — the Manage Certificates click-path.
- **The API key can't manage signing (role too low)** — mint an App Manager key, or just stay signed into Xcode.
- **The managed profile predates your certificate** — build again; with working auth it regenerates.
- **Godot rejected the export configuration** — Godot hides the reasons in headless runs (often an empty list). Refresh preflight: the known causes appear there with a Fix.

If nothing matches, the fallback points you at the first `error:` line in the log.

## Releasing an updated addon

Build Kit follows the repo's model: bump `version` in `addons/build_kit/plugin.cfg`, commit, push to `main`. Consuming projects see it in the **Editor Tool Kit** dock and update in place.

## References
_None._

## Child pages
_None._
