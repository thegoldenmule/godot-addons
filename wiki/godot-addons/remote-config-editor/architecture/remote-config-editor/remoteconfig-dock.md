# RemoteConfig dock

**Status:** current

## Kind
component

## Summary
The bottom-panel view (`dock.gd`, a plain `Control`) over RemoteConfigService — a key / file / version / present table on top, the publish-payload preview below (a draggable `VSplitContainer`), and a Reload / Copy / Check Sync button row, all built with the `EditorToolUi` builders. The enforced header (title + version + reload) is mounted above it by EditorToolPlugin, not by the dock.

## Purpose
Hold only view state (control refs) and render; all logic stays in the service. Every label that was once game-specific — the keys caption, the paste-target message, the document noun — is pulled from the service's config, so the view is game-agnostic. The Check Sync section + button exist only when the project configured a `sync` command.

## Design notes
_No design notes._

## Components
_No components._

## Dependencies
- **depends-on** → [RemoteConfigService](architecture:mql8q3t4-02fs-vycbv8) — thin view over the service; the EditorToolPlugin base injects `service`.
- **depends-on** → [EditorToolUi](architecture:mql3cys5-01rr-jroiua) — EditorToolUi section / button / status_label / button_bar builders.

## Code references
- function `_build_ui() / _refresh_preview()` in `addons/remote_config_editor/dock.gd`
- function `_on_copy() / _on_check_sync()` in `addons/remote_config_editor/dock.gd`

## Data model
Control refs built in `_build_ui()`: `_table` (a 4-column `Tree`), `_preview` (a read-only `TextEdit`), and `_sync` + `_status` (wrapping status `Label`s). The Sync section is conditional on `service.has_sync()`; the keys caption and status messages interpolate `service.config` / `service.document_label()` / `service.publish_target()`.

## Usage
`_ready()` calls `service.reload()` BEFORE `_build_ui()` (so the layout knows whether to add the Sync section), connects `changed` with a method callable (auto-disconnects on free), then renders. `_refresh_preview()` shows `service.build_document_text()` — the exact bytes Copy will write. Button handlers surface results in the status / sync labels.

## Invariants & constraints
- Pure view: no aggregation / validation / IO — it re-renders on the service's changed signal and forwards button presses.
- All user-facing strings come from the service config (document_label, publish_target, manifest path), so nothing game-specific is hardcoded in the view.
- Signals are bound with method callables (not lambdas) so a hot-reload / late async signal can't fire into a freed view.

## Synced commit
d79675c
