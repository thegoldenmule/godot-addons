# remote_config_editor

An **editor-only** authoring tool for backends whose "remote config" is a single
JSON document published by hand (e.g. a console paste). It aggregates several
committed content blobs — one per feature — into the **one** document, previews +
copies the whole publish payload (so a paste can never silently drop a sibling
key), and optionally checks live drift against the running backend.

It is **game-agnostic**: everything project-specific (where the manifest + blobs
live, what command verifies drift, the labels in the dock) comes from a config
file the consuming project owns. The addon ships no game-specific code.

Built on [`editor_tool_kit`](../editor_tool_kit/README.md) — a *service + a view*
(`RemoteConfigService` + `dock.gd`), so the aggregation logic is headless-testable
and the styling/header/self-update are inherited. `editor_tool_kit` must be
vendored + enabled alongside this addon.

## The model

1. A **manifest** lists the document's keys, one entry per feature:

   ```json
   {
     "app_config_version": "v1",
     "entries": [
       { "key": "story_catalog", "file": "story_catalog.json", "version_field": "catalog_version", "label": "Story catalog" },
       { "key": "daily_login",   "file": "daily_login.json",   "version_field": "version",         "label": "Daily Login" }
     ]
   }
   ```

2. Each entry points at a committed JSON **blob**.
3. The tool aggregates them — in manifest order — into one document
   `{ "<key>": <blob>, … }`, the exact payload you publish. Each blob is spliced
   **verbatim** from disk, so integers, 64-bit IDs, and formatting survive
   byte-for-byte (re-serializing through Godot's JSON would coerce every integer to
   a float and lose precision past 2^53).
4. **Copy publish payload** puts that whole document on the clipboard (gated on
   validation, so a structurally-broken document never reaches it).
5. **Check sync** (optional) shells out to a comparator *you* configure and shows
   per-key drift (match / drift / absent).

`version_field` per entry and the top-level document-version field
(`doc_version_field`, default `app_config_version`) are surfaced in the table so an
operator sees at a glance what version each block is at.

## Setup

1. Vendor `addons/remote_config_editor/` (and `addons/editor_tool_kit/`) into your
   project's `addons/` and enable both in Project → Project Settings → Plugins.
2. Create **`res://remote_config_editor.config.json`** (NOT inside the addon
   folder — a self-update overwrites the addon, never this file). Start from
   [`config.example.json`](config.example.json):

   | field | meaning |
   |---|---|
   | `root` | base every relative path resolves against. `"res://"` for a flat project, `"res://.."` when your Godot project is nested one level under its repo root (so a sibling dir holds the content). |
   | `manifest` | path (relative to `root`) of the manifest JSON. **Required.** |
   | `content_dir` | dir (relative to `root`) holding the content blobs. **Required.** |
   | `doc_version_field` | manifest field naming the document version (default `app_config_version`). |
   | `document_label` | noun used in the dock's messages (e.g. `"app-config document"`). |
   | `publish_target` | where the operator pastes the payload (e.g. `"the Snapser console App Config"`). |
   | `sync` | **optional** drift-check command — omit it and the Check Sync button disappears. |

   `sync` is `{ "program", "args", "hint" }`. `args` are passed verbatim to the
   program, with `{root}` replaced by the resolved root dir. The command must print
   one JSON object on stdout carrying a `results` array of
   `{ key, status, committed_version, live_version }` (`status` ∈ `match` / `drift`
   / `absent`); other stdout lines are treated as logs. `hint` is the shell command
   shown to the operator when the program can't be run.

3. Open the **Remote Config** bottom-panel tab.

A flat project with everything under `res://` and no live check needs only:

```json
{ "manifest": "content/app.manifest.json", "content_dir": "content" }
```

## Verifying

The aggregation core is headless-testable (no editor). From the addon repo:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
    --script res://tools/verify_remote_config_editor.gd
```
