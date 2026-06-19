# Configuration & path resolution

**Status:** current

## Kind
component

## Summary
The config seam that makes the addon game-agnostic: `res://remote_config_editor.config.json` (read into `RemoteConfigService.config` over `DEFAULTS`), plus the `_resolve()` path resolver and the `{root}` argument substitution that let one tool serve flat and nested project layouts and any drift-check command.

## Purpose
Push every project-specific value out of the code and into a file the consuming project owns — and keep that file OUTSIDE the addon folder so a self-update (which overwrites the addon subtree but never prunes the rest of the project) can never clobber it.

## Design notes
_No design notes._

## Components
_No components._

## Dependencies
- **depends-on** → [RemoteConfigService](architecture:mql8q3t4-02fs-vycbv8) — config is loaded, merged, and resolved by RemoteConfigService.

## Code references
- constant `DEFAULTS / load_config()` in `addons/remote_config_editor/remote_config_service.gd`
- function `_resolve() / _read_text()` in `addons/remote_config_editor/remote_config_service.gd`
- file `annotated template (every field populated)` in `addons/remote_config_editor/config.example.json`

## Data model
Config keys, merged over `DEFAULTS`:

- `root` — base every relative path resolves against (`res://` for a flat project, `res://..` when the Godot project is nested one level under its repo root).
- `manifest`, `content_dir` — relative paths to the manifest JSON + the blob dir (required).
- `doc_version_field` — manifest field naming the document version (default `app_config_version`).
- `document_label`, `publish_target` — nouns shown in the dock's messages.
- `sync` — optional `{program, args, hint}`; omit it and the drift check disappears.

`_resolve(path)`: `res://` / `user://` are globalized; an already-absolute path is kept; anything else is joined onto the project dir. `check_sync()` replaces `{root}` in each arg with the resolved root, so the comparator path travels with the project.

## Usage
`load_config()` merges the file over `DEFAULTS` (a missing file ⇒ pure defaults ⇒ the dock shows a configure-me prompt). `reload()` resolves `root` + the relative paths and calls `reload_from(...)`. A configured manifest with no `content_dir` is flagged as a clear config error rather than leaking an absolute path into a file-not-found message.

## Invariants & constraints
- The config file lives at res:// root, NOT inside the addon folder — self-update overwrites the addon subtree but never this file.
- A missing config degrades to defaults (is_configured() false) so a fresh install shows a configure-me prompt instead of erroring.
- Paths resolve identically headless — the resolver uses only ProjectSettings.globalize_path, no editor APIs.

## Synced commit
d79675c
