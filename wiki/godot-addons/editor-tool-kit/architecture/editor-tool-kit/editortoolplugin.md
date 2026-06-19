# EditorToolPlugin

**Status:** current

## Kind
component

## Summary
The per-tool **bootstrap** (`EditorPlugin` base). A tool's `plugin.gd` overrides only `_config()` to declare its pieces; the base constructs **service → (bridge) → dock**, injects the service into the bridge + dock, and mounts the dock beneath an **enforced header** in the bottom panel — reversing it all in `_exit_tree`.

## Purpose
Replaces the near-identical ~25–37 line `plugin.gd` every tool used to hand-write (enter/exit tree, construct, mount, teardown). The header — tool title on the left, the tool's own `plugin.cfg` `version` + a self-reload button on the right — comes for free; the dock builds none of it.

## Design notes
```gdscript
@tool
extends "res://addons/editor_tool_kit/editor_tool_plugin.gd"

const ServiceT := preload("res://addons/<tool>/<tool>_service.gd")
const DockT := preload("res://addons/<tool>/dock.gd")

func _config() -> Dictionary:
    return {
        "panel": "My Tool",          # bottom-panel tab title
        "service": ServiceT,
        "dock": DockT,
        # "bridge": BridgeT,          # optional
        "service_name": "MyService", # optional cosmetic node names
        "dock_name": "MyTool",
    }
```

## Components
_No components._

## Dependencies
- **owns** → [ToolService](architecture:mql3cw8b-01r9-lncvao) — Constructs the ToolService and injects it into the dock (and bridge).
- **depends-on** → [EditorToolUi](architecture:mql3cys5-01rr-jroiua) — Mounts the enforced header via EditorToolUi.tool_header.
- **depends-on** → [Styling — Palette & Theme](architecture:mql3d0n5-01sn-3lo7o1) — Assigns the cascaded EditorToolTheme to the panel root.

## Code references
- class `EditorToolPlugin` in `addons/editor_tool_kit/editor_tool_plugin.gd`

## Data model
_None._

## Usage
Override `_config()` to return a Dictionary: `panel` (bottom-panel tab title), `service` (a `ToolService` script), `dock` (a `Control` script), optional `bridge`, and cosmetic `service_name` / `dock_name`. Register the tool in `project.godot [editor_plugins]` and commit the `.gd.uid` files.

## Invariants & constraints
- Mounts the dock beneath an enforced header (title left; version + reload button right); `_exit_tree` reverses construction + mount.
- Assigns EditorToolTheme to the panel root, so the occult-arcade look cascades to every descendant of the header + dock.

## Synced commit
501411d
