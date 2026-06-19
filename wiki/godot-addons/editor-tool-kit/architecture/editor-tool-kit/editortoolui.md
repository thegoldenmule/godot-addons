# EditorToolUi

**Status:** current

## Kind
component

## Summary
Static **layout builders** — the idioms every dock reinvents, with no state: `split_root`, `tool_header` (the enforced title/version/reload bar the plugin mounts), `label_wrap`, `form_row`, `button`, `button_bar`, `spin`, `status_label`, `section` (a violet-bordered, captioned group frame), and `restyle_selected`. Colors and metrics come from `EditorToolPalette`.

## Purpose
Replaces the pure-code `HSplitContainer` layout with min-size floors, label/row builders, and the one-line status `Label` driven from `{ok, error}` that each tool used to hand-roll. Pure construction, no state — adopt incrementally; a tool can use one builder or all of them.

## Design notes
_No design notes._

## Components
_No components._

## Dependencies
- **depends-on** → [Styling — Palette & Theme](architecture:mql3d0n5-01sn-3lo7o1) — Colors + metrics come from EditorToolPalette.

## Code references
- class `EditorToolUi` in `addons/editor_tool_kit/editor_tool_ui.gd`

## Data model
_None._

## Usage
Call the builders from the dock's `_ready` to assemble the view, hold the returned control refs + interaction state, and re-render when the service emits its change signal. The status `Label` from `status_label` is fed the `{ok, error}` Dictionary returned by service calls.

## Invariants & constraints
- Pure construction with no state; per-control overrides still win locally over the cascaded theme.

## Synced commit
501411d
