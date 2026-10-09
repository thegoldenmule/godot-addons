# build_kit: Android Build Support — Design Proposal

**Status:** Pre-implementation, **revised after review**. No code has been written
yet. This doc distills a planning conversation between a junior engineer (me) and
Claude Code; it has since been reviewed against the current `build_kit_service.gd`
/ `dock.gd`, the Godot 4.7.1 binary, and the installed export templates. Sections
carrying a **[revised]** marker changed as a result — see *Review findings* below
for the delta.

## Goal

Add Android build support to `build_kit`, deliberately mirroring the existing
iOS pipeline's patterns rather than inventing something new. **Scope for this
pass is Build → Device only**: preflight checks, then export a debug APK and
`adb install` it. AAB/Play Store upload and release-keystore handling are
explicitly deferred (see below) — this proposal scaffolds for them but does not
build them.

## Review findings (what changed, and why)

Everything the original draft cited was verified accurate: every line number,
the `load_config()` merge claim, the unused-but-present `TabContainer` theming,
and the reasoning that iOS's 4-stage split is an Xcode-26 workaround rather than
a template to copy. Two decisions did not survive review, and the open question
turned out to have three answers.

1. **§1 separated state in the wrong layer.** The doc specified UI separation,
   but every piece of state that needs separating lives in the *service*, which
   is single-pipeline with untagged signals and one flat `preflight_rows` array
   whose ids would collide across platforms. §1 now specifies the service change.
2. **§4's keystore plan was wrong on path, ownership, and prerequisite.** Godot
   generates the debug keystore itself, in the editor data dir, using a JDK we
   have not yet checked for. The proposed `keytool` Fix fails on exactly the
   fresh-Mac audience this tool targets. §4 is rewritten.
3. **The open question has answers** — the signing dependency is still there,
   just quieter; the toolchain paths live somewhere iOS has no analog for; and
   the gradle build template is a real preparation step with a scriptable
   installer. See *Answers to the open question*.

Three areas the draft did not mention at all are now covered: `classify.gd`
(§6), the headless verifier (§7), and the shared-vs-per-platform preflight rows
(§2).

## How build_kit is currently structured (for context)

- `plugin.gd` wires a `BuildKitService` (Node, the brains) and `BuildKitDock`
  (Control, the view) via the `editor_tool_kit` base plugin class. `_config()`
  wires **exactly one** service + dock pair — relevant to §1.
- Dock → service calls are synchronous and return a plain `{ok, error/message}`
  Dictionary — "did the request start OK," not "is it done."
- Service → dock communication for anything that unfolds over time is signals:
  `preflight_changed(rows)`, `stage_changed(stage)`, `log_line(text)`,
  `build_finished(result)`. The service's `_process()` polls detached shell
  processes (`exec.gd`) each frame and fires these. (`build_kit_service.gd:56-65`)
- Preflight rows are data-driven: `{id, label, status, detail, guidance,
  fixable, links}` (`build_kit_service.gd:644`). The dock renders this shape
  generically (`dock.gd:189`), with a couple of hardcoded per-`id` extras (an
  ASC-key credential form, a preset/team-picker form).
- The build pipeline is a queue of `{name, shell}` stages walked one at a time
  by `_next_stage()` (`build_kit_service.gd:477`); failures are run through
  `classify.gd`'s pattern rules to turn a raw log into a titled diagnosis + fix
  steps instead of a wall of xcodebuild output.

## Why the iOS pipeline has 4 stages

`start_build()` (`build_kit_service.gd:375`) queues:

1. **export** — Godot's headless export, but `export_project_only=true` so it
   only generates the Xcode *project*, not a built app. Per the code comment,
   this is because "Godot's internal Xcode build can't take API-key auth and is
   broken under Xcode 26" — Godot is deliberately kept out of the actual build.
2. **patch** — `PlistBuddy` sets the App Store encryption-compliance flag and
   stamps the build number into `Info.plist`, metadata Godot's export doesn't
   manage.
3. **archive** — `xcodebuild archive`, explicitly **unsigned**
   (`CODE_SIGNING_ALLOWED=NO`) — signing only matters at export time.
4. **upload / export_ipa** — `xcodebuild -exportArchive`, where the real
   signing happens, either uploading to App Store Connect or writing a local
   `.ipa`.

This is important context: **the 4-stage split is a workaround for a specific
Xcode-26 bug**, not a template to replicate for its own sake.

## Decisions for Android

### 1. UI shape: platform tabs — and a platform-aware service **[revised]**

Top-level `TabContainer` with "iOS" / "Android" tabs, each tab a self-contained
copy of the current layout (`Ui.split_root` — preflight left, build+log right).
Not a shared build/log panel with a platform switcher, because preflight rows
and build state are platform-specific and unrelated (an Android SDK check has
nothing to do with an iOS log stream).

This isn't a new pattern for the repo: `editor_tool_kit`'s `tool_palette.gd`
(`TAB_PAD`, line 41) and `tool_theme.gd::_apply_tabs()` (line 86) already
theme `TabContainer`/`TabBar` — fully built, currently unused by any addon.
Android would be the first consumer of an existing, intended idiom.

**The original draft stopped here, and that was the mistake.** Tabs separate the
*view*; all the state that needs separating lives in the service:

- `_stages`, `_stage`, `_proc`, `_upload`, `_context`, `_preset` are
  single-instance (`build_kit_service.gd:42-47`).
- All four signals are **untagged** (`:34-37`). Two tabs listening to the same
  signals means an Android build's `log_line` lands in the iOS log pane, and one
  `build_finished` writes both status labels.
- `preflight_rows` is one flat array, and `_set_row(id, …)` (`:958`) matches by
  bare id across all of it. Android's natural row ids — `templates`, `preset`,
  `devices` — **collide with iOS's**. `apply_fix(id, opts)` (`:1114`) has the
  same collision.

One root cause, three symptoms. Since `plugin.gd`'s `_config()` wires exactly one
service, keep one service and fix it at the source:

- **Namespace row ids**: `ios.templates` / `android.templates`. `_set_row()` and
  `apply_fix()` then dispatch unambiguously, and the dock filters rows by prefix
  to decide which tab renders them. Rows that are genuinely global (see §2) keep
  a bare id and render in both tabs.
- **Tag the signals**: add a `platform` field to the `stage_changed`,
  `log_line`, and `build_finished` payloads (and to `preflight_changed`'s rows,
  which the namespaced ids already carry). Each tab ignores what isn't its own.
- **Per-platform pipeline state**: `_pipelines := {"ios": {...}, "android": {...}}`
  keyed the way the single set of vars is today. If we'd rather keep one global
  build at a time, that's a legitimate simplification — but then say so
  explicitly and have `_on_stage_changed` disable **both** tabs' build buttons,
  because today's `is_busy()` guard (`:366`) would otherwise fail the second
  build with a confusing "A build is already running" while its buttons still
  look live.

### 2. Preflight depth: parity with iOS, minus the duplicated rows **[revised]**

iOS's `refresh_preflight()` (`build_kit_service.gd:628`) isn't purely
detect-only. It splits:

- **Detect-only, manual guidance** (no Fix button): Xcode installed
  (`_check_xcode`, :649), Xcode account signed in (`_check_account`, :776),
  distribution certificate in keychain (`_check_dist_cert`, :787), paired
  device (`_check_devices`, :847).
- **Detect + auto-Fix** (a Fix button does something automated, scoped to
  local file/config writes or scriptable downloads — never a big external
  toolchain install): export templates download+install (`_check_templates`,
  :684), ETC2/ASTC project-setting flip (`_check_etc2`, :701), export-preset
  field repair (`_check_preset`, :718), ASC app-record registration via API
  (`_check_app_record`, :827).

Applying the same line to Android, with three corrections the review turned up:

**Export templates are ONE pack, not two.** The installed template directory
(`~/Library/Application Support/Godot/export_templates/<version>/`) holds `ios.zip` *and*
`android_debug.apk`, `android_release.apk`, `android_source.zip` — all extracted
from the same `.tpz` that `_fix_templates()` (`:1151`) already downloads. A
separate "Android export templates" row with its own Fix would re-download ~1 GB
of byte-identical content. Make the templates row **global** (bare id, rendered
in both tabs) and vary only the probed filename per platform, or share the fix
and let two rows call it.

**ETC2/ASTC is one project setting, and Android reports it better than iOS.**
`rendering/textures/vram_compression/import_etc2_astc` is global. The Godot
binary carries an explicit Android message — *"ETC2/ASTC texture compression is
required for Android export."* — unlike the empty-error-list iOS case that
`_check_etc2` was written to compensate for (`:697-700`). This row is global
too; the guidance text can stay as-is.

**The toolchain rows are new, and one of them earns a Fix.** Godot resolves the
Android toolchain from **EditorSettings**, not from PATH or the project — the
binary's own errors are *"A valid Android SDK path is required in Editor
Settings."* and *"A valid Java SDK path is required in Editor Settings."* The
relevant keys are `export/android/android_sdk_path`, `export/android/java_sdk_path`,
`export/android/debug_keystore{,_user,_pass}`. So:

- **`android.sdk`** — read `export/android/android_sdk_path`. If unset **but an
  SDK exists at the conventional location** (`~/Library/Android/sdk`), that's a
  Fix: writing an editor setting is the same category of action as
  `_fix_etc2()` writing a project setting. Only the *install* stays
  manual-guidance-only. (Note: this machine has neither the setting nor the SDK,
  so the "not installed" path is the one to get right first.)
- **`android.jdk`** — read `export/android/java_sdk_path`, same shape. Manual
  guidance for the install; Fix only to point at an already-present JDK.
- **`android.devices`** — `adb` device listing. Detect-only, as iOS's is. See
  §3 for how `adb` is located.
- **`android.build_template`** — only meaningful once "Use Gradle Build" is on
  (deferred, §8), but note for later that it **is** auto-fixable: Godot ships
  `--install-android-build-template` as a CLI flag.

**`android.preset`** gets the same auto-Fix treatment as its iOS counterpart —
this one is a straight port. Note that `parse_ios_preset_text()` (`:291`) is
hardcoded to `platform == "iOS"`; generalize it to take a platform argument
rather than writing a second near-copy.

### 3. Build → Device pipeline: 2 stages, but signing is not free **[revised]**

- **export** — `godot --headless --path <root> --export-debug <preset> <out.apk>`
- **install** — `adb install -r <out.apk>` (plus `-s <serial>`, below)

`--path <root>` matters: the existing export stage passes it (`:418-422`) and
headless export without it is position-dependent. `--export-debug` is a real
Godot 4.7 flag (confirmed in `--help`).

No patch/archive stages, and that part of the original reasoning holds: there's
no external build tool analogous to `xcodebuild` that has to run afterward, and
nothing analogous to the Info.plist patch (a debug install needs no stamped
build number).

**But the claim that Godot "produces a *signed* APK directly" is conditional,
and the failure mode is nasty.** Godot signs via `apksigner` from the Android
SDK's `build-tools`, and when it can't find it the binary emits:

> `'apksigner' could not be found. Please check that the command is available in
> the Android SDK build-tools directory. **The resulting APK is unsigned.**`

That is a *warning*, not an error. The export stage exits 0, writes an unsigned
APK, and the install stage then fails with something that reads as unrelated.
Structurally this is the same trap as the iOS signing mess — an external-tool
signing dependency hiding behind "Godot does it in one step" — except iOS at
least fails loudly at the archive stage. Two consequences:

- The export stage must not treat exit 0 as sufficient. Scan its log for the
  apksigner warnings (`'apksigner' could not be found`, `'apksigner' returned
  with error`, `'apksigner' verification of APK failed`, `All 'apksigner' tools
  located in Android SDK 'build-tools' directory failed`) and fail the pipeline
  there with a real diagnosis, rather than letting `adb install` deliver it.
- `classify.gd` needs the corresponding rules (§6).

**Device targeting**: unlike iOS (whose device preflight row is purely
informational — TestFlight/`.ipa` export never installs to a specific
physical device), `adb install` errors out if 2+ devices/emulators are
connected and no target is specified. Mirrors the existing **team picker**
pattern (`_make_team_picker()`, `dock.gd:252`) exactly: `list_adb_devices()`
on the service (role of `list_teams()`, `build_kit_service.gd:771`), a
dropdown attached to the preflight `android.devices` row shown only when 2+
devices are present, selection persisted in a dock-side `_selected_device` var,
fed into the install stage as `-s <serial>`. 0 devices → row stays warn/fail
with guidance as today; exactly 1 → used silently, no picker shown.

**Locating `adb`**: don't assume PATH. `Exec.run()` uses `/bin/zsh -lc` so a
login-shell PATH applies, but `adb` is not on PATH on a default macOS install
(verified — absent on this machine). Resolve it from
`export/android/android_sdk_path` + `/platform-tools/adb`, falling back to PATH.
That also keeps the tool consistent with whatever SDK Godot itself will export
against, which a stray PATH `adb` would not guarantee.

### 4. Keystore: Godot owns the debug one **[revised — the original plan was wrong]**

Android has two keystores, not equally in scope:

- **Debug keystore** — signs debug builds (what `adb install` needs). The
  original draft proposed detecting `~/.android/debug.keystore` and running
  `keytool -genkey` ourselves. **All three parts of that are wrong:**
  - *Wrong path.* Godot's own debug keystore lives at
    `keystores/debug.keystore` under the **editor data dir**, not `~/.android`.
  - *Wrong owner.* The Godot binary contains
    `_create_editor_debug_keystore_if_needed` and the log string *"Updated
    editor debug keystore to"* — Godot generates it itself. (The mechanism and
    destination are confirmed from the binary; the exact trigger point should be
    confirmed during implementation before deciding a Fix has any work left.)
  - *Wrong prerequisite.* Godot invokes `bin/keytool` resolved from the
    configured **Java SDK path**. A `keytool` Fix of our own would fail on
    exactly the fresh-Mac audience this tool targets: on stock macOS
    `/usr/bin/keytool` exists but is a stub, and `/usr/libexec/java_home`
    answers *"Unable to locate a Java Runtime."* — so the Fix button would hand
    the user a confusing stub error, which is the failure mode build_kit exists
    to prevent.

  **Revised plan:** the actionable preflight row is **`android.jdk`** (§2), not
  a keystore row. Keep a detect-only `android.debug_keystore` row that surfaces
  Godot's own state (`export/android/debug_keystore` set, or the editor-data-dir
  file present) with the two Godot error strings as guidance — *"Debug keystore
  not configured in the Editor Settings nor in the preset."* and *"Either Debug
  Keystore, Debug User AND Debug Password settings must be configured OR none of
  them."* No Fix button unless implementation shows Godot won't generate it on
  its own.

- **Release keystore** — the real signing identity for a Play Store AAB: a
  private file + store password + key alias + key password, never committed.
  This is the actual analog to iOS's ASC `.p8` key (drop-on-panel → copied
  outside the repo → gitignored `.env`, see `adopt_asc_key()`,
  `build_kit_service.gd:1068`). **Out of scope for this pass.**

### 5. Config schema: `android` as a sibling key

`build_kit.config.json` gains a top-level `"android"` key alongside the
existing `"ios"` one — `{"ios": {...}, "android": {...}}`. `load_config()`'s
merge logic already operates key-by-key over top-level dict entries
(`build_kit_service.gd:81-96`), so this needs no new plumbing, just a new
entry in `default_config()`. **Verified — this claim holds.**

One caveat the draft missed: `load_config()` hardcodes an int-coercion for
`config["ios"]["build_number"]` at `:89` (JSON numbers parse as floats).
Harmless today, but the moment the android block gains a numeric field — a
`version_code`, when AAB support lands — it needs the same treatment. Worth
generalizing the coercion rather than adding a second hardcoded line.

Considered a separate file per platform instead, but rejected it: `build_kit`
specifically handles *device-build* pipelines (toolchain preflight + store
upload) — the case that needs this whole dance is mobile, which means the
ceiling here is two platforms (iOS, Android), both already known, not an
open-ended set. Splitting one file into two for a fixed set of two would add
real plumbing (a second config path, a second load/save target) for no
functional gain, and breaks the "understand one, understand both" property
the single-file shape has for free.

### 6. `classify.gd` needs platform scoping and Android rules **[new]**

The draft didn't mention `classify.gd`, but it's half the value of the tool and
it is currently **entirely iOS-shaped**: a flat static `rules()` list with no
platform field. Two problems:

- **It would misfire.** The `no_export_templates` rule matches the bare pattern
  `"export templates"`, and its guidance text literally says *"the **iOS**
  export templates"*. An Android template failure would get iOS instructions.
  Lower-risk but real: `network` matches `"timed out"` and `asc_auth` matches
  `"401"`, both of which can appear in unrelated Android output.
- **It needs Android rules.** Add a `platforms` field to each rule (defaulting
  to both, so existing rules need no churn) and have `classify()` take the
  platform. The Android rules worth writing, in priority order:

  | Signature | Diagnosis / fix |
  |---|---|
  | `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Existing install signed with a different key — `adb uninstall <package>`, then retry. **The single most common real-world debug-install failure.** |
  | `'apksigner' could not be found` (+ the three sibling apksigner strings) | APK is unsigned; SDK build-tools missing — see the SDK preflight row. |
  | `device unauthorized` / `unauthorized` | Accept the RSA fingerprint prompt on the device. |
  | `no devices/emulators found` | Plug in / enable USB debugging; see the devices row. |
  | `INSTALL_FAILED_INSUFFICIENT_STORAGE` | Free space on the device. |
  | `INSTALL_FAILED_VERSION_DOWNGRADE` | Installed build is newer; uninstall first. |
  | `A valid Android SDK path is required in Editor Settings.` | Point at the SDK preflight row (it has a Fix when the SDK is present). |
  | `A valid Java SDK path is required in Editor Settings.` | Same, for the JDK row. |
  | `Android build template is missing` / `Android build template not installed in the project.` | Gradle build is on — install the template (`--install-android-build-template`). |

  All of these strings are verified present in the Godot 4.7.1 binary or are
  standard `adb` output.

### 7. Extend `tools/verify_build_kit.gd` **[new]**

The draft didn't mention it, but `tools/verify_build_kit.gd` exists and covers
exactly the static helpers this work touches — shell quoting, classify, preset
parsing, path derivation, config defaults — and `CLAUDE.md` requires a headless
run after touching this code:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
    --script res://tools/verify_build_kit.gd
```

New cases to add alongside the code, not after it: Android preset parsing (once
`parse_ios_preset_text` is generalized), `parse_adb_devices()` against fixture
`adb devices -l` output including the 0/1/2-device cases, the namespaced-row-id
dispatch in `_set_row`/`apply_fix`, Android APK path derivation, and the new
classify rules including a case asserting an Android log does **not** match the
iOS-only rules.

### 8. Deferred (explicitly out of scope this pass)

- **Build → AAB / Play Console upload** — the analog to "Build → TestFlight."
  Note for whoever picks this up: it requires "Use Gradle Build", which in turn
  requires the Android build template in `res://android/build/` and a JDK. The
  binary gates a lot behind that flag (*"Export AAB is only valid when Use
  Gradle Build is enabled"*, plus min/target SDK overrides, custom themes, and
  plugins).
- **Build .apk-only (local export)** — the analog to "Build .ipa only."
- **Release keystore ingestion / secret management.**

These will exist as visibly disabled buttons on the Android tab (signaling
intent rather than leaving the user wondering why a feature isn't there), each
with a single-line `# TODO:` comment pointing at its iOS analog. Deliberately
**not** scattering TODOs through the service/config for these — we don't yet
know their shape (e.g. how release-keystore ingestion should work), so a
breadcrumb anywhere but the button itself risks being wrong or stale by the
time we build it.

## Answers to the open question

> *Anything about the Xcode-26-bug-driven 4-stage iOS shape that actually does
> have a non-obvious Android analog we're missing?*

Yes — three, none of which is an extra pipeline stage, which is why the 2-stage
decision survives even though the reasoning behind it was incomplete.

1. **The signing dependency didn't go away, it went quiet.** iOS's stages 3-4
   exist because signing is a separate, external, failure-prone step. Android
   has the same external dependency (`apksigner` from the SDK build-tools) —
   Godot just calls it inline and **warns instead of failing** when it's
   missing, producing an unsigned APK that dies one stage later. Same class of
   problem, worse ergonomics. Handled in §3.
2. **The toolchain config lives in EditorSettings, and iOS has no counterpart.**
   Xcode is found via `xcode-select`; the Android SDK and JDK are found via
   user-global editor settings that a fresh checkout will not have. That's a
   whole preflight category with no iOS analog to copy — and it's the *first*
   thing a new machine will hit. Handled in §2.
3. **The gradle build template is Android's real "preparation stage."** It's the
   closest thing to iOS's export-project-only step: a materialized build
   scaffold that must exist before the real build runs. It's out of scope this
   pass (it's only required once "Use Gradle Build" is on), but it's worth
   knowing now that it exists, that it gates all of the deferred AAB work, and
   that Godot ships `--install-android-build-template` — so when we do need it,
   it's an auto-Fix, not a manual-guidance row.

## Verification basis

Claims in this doc were checked against: `addons/build_kit/*.gd` at the cited
line numbers; `project.godot` (Godot 4.6 features, 4.7.1.stable toolchain);
`/Applications/Godot.app` (`--help` flags, embedded EditorSettings keys and
error strings); the installed export templates at
`~/Library/Application Support/Godot/export_templates/4.7.1.stable/`; and the
absence of `adb`, an Android SDK, and a Java runtime on the development machine.
