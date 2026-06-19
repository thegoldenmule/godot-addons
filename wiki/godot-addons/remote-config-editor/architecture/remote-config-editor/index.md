# Remote Config Editor

**Status:** current

## Kind
package

## Summary
**Remote Config Editor** (`addons/remote_config_editor/`) — an **editor-only** authoring tool for backends whose "remote config" is one JSON document published by hand (e.g. a Snapser App Config console paste). It aggregates several committed content blobs — one per feature, named by a project-supplied manifest — into the **one** document, previews and copies the whole publish payload (so a paste can never silently drop a sibling key), and optionally checks live drift against the running backend. It is **game-agnostic**: every project-specific value — where the manifest and blobs live, the drift-check command, the dock labels — comes from a `res://remote_config_editor.config.json` the consuming project owns; the addon ships no game-specific code. Built on `editor_tool_kit` as a *service + a view* and managed by etk's self-update dock. **Vendored** into a consuming project (committed under `addons/remote_config_editor/`, so a fresh clone works offline) yet **sourced** from the standalone repo.

## Purpose
Some backends (Snapser Remote Config, Firebase Remote Config, …) have no write API: "publishing" is a manual paste of one JSON document into a console. When that document is assembled from several committed feature blobs, two things go wrong by hand — a paste of a single feature silently **drops its sibling keys**, and re-typing or re-serializing the document **corrupts values** (large IDs, int-vs-float). This tool makes the committed blobs the single source of truth: it aggregates them in manifest order into the exact document, gates the copy on validation so a structurally-broken document never reaches the clipboard, and (when configured) verifies the live document against the committed blobs. The original lived inside one game; extracting it forced every game-specific assumption out into config so any project can adopt it.

## Design notes
_No design notes._

## Components
- [RemoteConfigService](architecture:mql8q3t4-02fs-vycbv8)
- [RemoteConfig dock](architecture:mql8q586-02fu-h64en9)
- [Configuration & path resolution](architecture:mql8q6ta-02fw-hmsrub)

## Dependencies
- **depends-on** → [Editor Tool Kit](architecture:mql3ccsv-01q2-v81c5e) — ToolService / EditorToolPlugin / EditorToolUi bases + the self-update dock that manages it; must be vendored + enabled alongside.

## Code references
- class `RemoteConfigService — the headless ToolService core` in `addons/remote_config_editor/remote_config_service.gd`
- file `the bottom-panel view` in `addons/remote_config_editor/dock.gd`
- file `version + [update] marker (the ship signal)` in `addons/remote_config_editor/plugin.cfg`
- file `config template / schema by example` in `addons/remote_config_editor/config.example.json`
- file `headless verifier` in `tools/verify_remote_config_editor.gd`

## Data model
The addon is **three files** plus a project-owned config:

- **`RemoteConfigService`** (`remote_config_service.gd`) — the headless-testable `ToolService` core: loads the manifest + blobs, builds the document (parsed for structure, raw-spliced for publish), validates, copies, and runs the drift check.
- **`dock.gd`** — the `Control` view (a bottom-panel **Remote Config** tab): a key / file / version / present table, the publish-payload preview, and Reload / Copy / Check Sync buttons.
- **`plugin.gd`** (`extends EditorToolPlugin`) — declares the pieces via `_config()`; the base mounts the dock beneath the enforced header (title + version + reload).
- **`res://remote_config_editor.config.json`** — the consuming project's config (`root`, `manifest`, `content_dir`, `doc_version_field`, labels, optional `sync`), living OUTSIDE the addon folder so a self-update never clobbers it. `config.example.json` ships as a template.

## Usage
Vendor `addons/remote_config_editor/` (and `addons/editor_tool_kit/`) into a project, enable both, and author `res://remote_config_editor.config.json` from `config.example.json`. Open the **Remote Config** bottom-panel tab: the table shows each manifest key with its file, version, and presence; the preview shows the exact bytes that will be published; **Copy publish payload** puts them on the clipboard (gated on validation); **Check sync** (shown only when a `sync` command is configured) reports per-key drift. See the Usage guides for the config schema and the publish/verify loop.

## Invariants & constraints
- Editor-only: every script is @tool; the addon adds no runtime dependency to an exported game.
- RemoteConfigService carries no Control / EditorInterface references, so it runs under `godot --headless` — the dock is a thin observer that re-renders on the `changed` signal.
- The published text is each blob's raw on-disk JSON spliced verbatim — never a re-serialization of the parsed form, which would coerce integers to floats and lose precision past 2^53.
- Copy is gated on validate(): a structurally-broken document (missing/duplicate key, missing blob, missing version field, or an unconfigured content_dir) never reaches the clipboard.
- Nothing game-specific lives in the addon; all project specifics come from res://remote_config_editor.config.json, which sits outside the addon folder so self-update never clobbers it.
- editor_tool_kit must be vendored + enabled alongside it — it supplies the ToolService / EditorToolPlugin / EditorToolUi bases and the self-update dock that manages this addon.

## Synced commit
d79675c
