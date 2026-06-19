# RemoteConfigService

**Status:** current

## Kind
service

## Summary
The headless-testable core (`remote_config_service.gd`, `class_name RemoteConfigService`, `extends ToolService`). It loads the project's manifest + content blobs, aggregates them into the publish document, validates the set, copies the payload to the clipboard, and runs the optional drift check by shelling out to a project-supplied comparator. The dock is a thin caller; the verifier drives this class directly under `godot --headless`.

## Purpose
Concentrate every decision that must be *correct* — aggregation order, validation, byte-faithful serialization, version-field lookup, path resolution, the drift compare — in a `Node` with no editor dependencies, so it is exercised by `tools/verify_remote_config_editor.gd` without a live editor. The two editor-only seams (`DisplayServer.clipboard_set`, `OS.execute`) are isolated to copy / check_sync and are harmless headless.

## Design notes
_No design notes._

## Components
_No components._

## Dependencies
- **depends-on** → [ToolService](architecture:mql3cw8b-01r9-lncvao) — extends ToolService — ok()/err(), dirty tracking, the headless-safe Node base.
- **depends-on** → [ContentStore](architecture:mql3cxi4-01rp-krcbbc) — ContentStore.load_json parses the manifest + each blob.

## Code references
- function `build_document_text() — the verbatim raw splice` in `addons/remote_config_editor/remote_config_service.gd`
- function `validate() — the publishable gate` in `addons/remote_config_editor/remote_config_service.gd`
- function `check_sync() — OS.execute drift compare` in `addons/remote_config_editor/remote_config_service.gd`

## Data model
State, loaded by `reload()` (production, via config) or `reload_from(manifest_abs, content_dir_abs, content_label)` (the verifier, via a temp dir):

- `config` — the merged consuming-project config (`DEFAULTS` + the file).
- `manifest` — `{ <doc_version_field>, entries: [{key, file, version_field, label}] }`.
- `blobs` — key → parsed blob (`{}` when missing); `blobs_raw` — key → **raw on-disk text**, published verbatim.
- `_content_dir` / `_content_label` / `_config_error` — abs dir, repo-relative label for messages, and a structural-config problem.

Pure reads the verifier asserts: `build_document()` (parsed `{key: blob}`, present-only, manifest order), `build_document_text()` (the verbatim raw splice — the published bytes), `versions()` (table rollup), `validate()` (problem list; `[]` ⇒ publishable), `app_config_version()` (reads the configured doc-version field). Editor-side seams: `copy_publish_payload()` (validate-gated clipboard) and `check_sync()` (`OS.execute` on the configured comparator).

## Usage
The dock calls `reload()` on open and on Reload, re-rendering its table + preview when the service emits `changed`. Copy calls `copy_publish_payload()`; Check Sync calls `check_sync()`. The verifier calls `reload_from(...)` against a temp manifest to assert the pure surface, plus a real `OS.execute` round-trip of `check_sync` via `/bin/cat` to confirm the `{root}` substitution and the stdout JSON scan.

## Invariants & constraints
- No Control / EditorInterface references — the class loads + runs under godot --headless.
- build_document_text() is the only path to the published bytes; it splices blobs_raw verbatim so numeric formatting survives. build_document() (the float-coerced parse) is used only for structure / key set / count.
- validate() runs first in copy_publish_payload(); a non-empty problem list aborts before the clipboard is touched.
- check_sync() parses only stdout lines beginning with a brace, so a comparator's log lines do not spam the editor console with JSON parse errors; it stops at the first object carrying a results array.

## Synced commit
d79675c
