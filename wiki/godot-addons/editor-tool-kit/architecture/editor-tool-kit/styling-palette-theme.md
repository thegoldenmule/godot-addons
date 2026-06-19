# Styling — Palette & Theme

**Status:** current

## Kind
component

## Summary
The shared **occult-arcade theme**, applied with **no per-dock styling code** via Godot's `Control.theme` cascade. **`EditorToolPalette`** (`tool_palette.gd`, static consts) is the single source of truth for colors + metrics; **`EditorToolTheme`** (`tool_theme.gd`) `build() -> Theme` assembles the look with full state coverage, which `EditorToolPlugin` assigns to the panel root so it cascades to every descendant.

## Purpose
Both docks read as one cohesive surface without duplicating styling. One violet accent (`#b400ff`, hover `#d24bff`) on near-black, green `#44ff88` for selection, white for peak emphasis — defined once. A new tool inherits the look for free; the palette is the single place to change it.

## Design notes
_No design notes._

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `EditorToolPalette` in `addons/editor_tool_kit/tool_palette.gd`
- class `EditorToolTheme` in `addons/editor_tool_kit/tool_theme.gd`

## Data model
_None._

## Usage
Tools never load a theme themselves — `EditorToolPlugin` assigns `EditorToolTheme.build()` to `_panel_root` and the cascade does the rest. For a local exception, set a per-control override (e.g. a brighter preview panel, or `restyle_selected` on a selected row); it wins over the cascade. `build()` returns a plain `Theme` Resource, so it is constructible + assertable under `godot --headless`.

## Invariants & constraints
- EditorToolTheme.build() returns a plain Theme Resource (no editor deps), so the look is constructible and assertable under `godot --headless`.
- EditorToolPalette is owned by the kit and never loads a host project's theme; values are duplicated by intent so the kit and any host UI stay aligned yet fully decoupled.

## Synced commit
501411d
