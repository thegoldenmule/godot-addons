# Editor Tool Kit

**Status:** current

## Kind
package

## Summary
**Editor Tool Kit** (`addons/editor_tool_kit/`) — shared, **editor-only** base classes for building in-editor authoring tools in Godot 4.4+ (GDScript). A new tool is a *service + a view*: persistence, layout, the occult-arcade styling, status feedback, and optional MCP/CLI access are all inherited from the bases. The kit is mostly a **framework** — enabling the plugin keeps the `class_name` globals registered for the tools that subclass them — plus one tool of its own: an **"Editor Tool Kit"** bottom-panel tab that acts as the **package manager** for every vendored addon, self-updating each one that opts in with an `[update]` marker (including etk itself) from its source repo. It is **vendored** into a consuming project (committed under `addons/editor_tool_kit/`, so a fresh clone works offline) yet **sourced** from this standalone repo.

## Purpose
Two costs motivate the framework. **Duplication** — each authoring tool otherwise hand-rolls the same plugin bootstrap, bottom-panel mount/teardown, pure-code `HSplitContainer` layout, JSON load / atomic write / post-write `EditorInterface` rescan, and `{ok, error}` status plumbing. **Untestability** — a tool that fuses its logic into a `Control` only runs inside a live editor, so none of its mutation / serialize / atomic-write logic can run under the headless verifier loop. The kit makes the **service layer mandatory** (a `Node` with no editor deps, headless-safe) and the editor-only **view optional**, so the next tool — a settings editor, a data-table editor, an asset browser — is ~a service + a view, inheriting the rest for free.

## Design notes
_No design notes._

## Components
- [EditorToolPlugin](architecture:mql3cuyc-01r5-981udt)
- [ToolService](architecture:mql3cw8b-01r9-lncvao)
- [ContentStore](architecture:mql3cxi4-01rp-krcbbc)
- [EditorToolUi](architecture:mql3cys5-01rr-jroiua)
- [Styling — Palette & Theme](architecture:mql3d0n5-01sn-3lo7o1)
- [BridgeServer](architecture:mql3d1vp-01sv-7f02zx)
- [Self-update & distribution](architecture:mql3d2pq-01t1-8jz0dr)

## Dependencies
_No dependencies._

## Code references
- file `EditorToolKitPlugin (mounts the self-update panel)` in `addons/editor_tool_kit/plugin.gd`
- file `The full recipe + per-primitive reference` in `addons/editor_tool_kit/README.md`
- file `version (the ship signal)` in `addons/editor_tool_kit/plugin.cfg`

## Data model
The kit is **five primitives** plus a **package manager**:

- **`EditorToolPlugin`** (`editor_tool_plugin.gd`) — `EditorPlugin` base; the per-tool bootstrap.
- **`ToolService`** (`tool_service.gd`) — `Node` state base with `ok()`/`err()` + dirty tracking, no `Control`/`EditorInterface` deps (headless-safe).
- **`ContentStore`** (`content_store.gd`) — static load → validate → atomic N-target write → rescan, with version-bump rollback.
- **`EditorToolUi`** (`editor_tool_ui.gd`) — static layout builders (`split_root`, `tool_header`, `form_row`, `section`, `status_label`, …).
- **`EditorToolPalette`** + **`EditorToolTheme`** (`tool_palette.gd`, `tool_theme.gd`) — the cascaded occult-arcade look.
- optional **`BridgeServer`** (`bridge_server.gd`) — localhost HTTP base.
- **Package manager** — `PackageRegistry` + `UpdateService` + `UpdatePanel` + `update_reload_runner.gd`: discovers every addon carrying an `[update]` marker (including etk) and self-updates them from one shared archive, the kit dogfooding its own bases.

## Usage
A tool is three small files, each subclassing a base: `plugin.gd` (`extends EditorToolPlugin`, overrides `_config()` to declare the pieces) → `<tool>_service.gd` (`extends ToolService`, state + signals, headless-safe) → `dock.gd` (a `Control` view built with `EditorToolUi`). An optional `bridge.gd` (`extends BridgeServer`) exposes the tool over localhost HTTP for an MCP/CLI shim. `EditorToolPlugin` constructs service → (bridge) → dock, injects the service, mounts the dock beneath an enforced header (title left; version + reload button right) in the bottom panel, and reverses it all in `_exit_tree`. See the **Usage** guides for the full recipe.

## Invariants & constraints
- Editor-only: the addon adds no runtime dependencies to an exported game; all primitives live under `@tool`.
- A tool's logic lives in a ToolService Node with no Control / EditorInterface deps, so it runs under `godot --headless`; the dock is a thin observer.
- Every service method returns a `{ok, error?}` Dictionary; the dock never throws or asserts — it surfaces failures in a single status Label.
- The kit is vendored/committed but sourced from github.com/thegoldenmule/godot-addons; land changes in this repo, never in a consumer's vendored copy (self-update clobbers local edits).

## Synced commit
33846ec
