# Authoring a new tool — the three-piece recipe

**Status:** active

## Body
A tool is three small files that each subclass a base — plus an optional fourth for outside access. The kit supplies persistence, layout, styling, status, and self-update; you write the tool's domain logic and view.

```text
addons/<tool>/
  plugin.gd          extends EditorToolPlugin   -> _config() declares the pieces
  <tool>_service.gd  extends ToolService        -> state + signals, headless-safe
  dock.gd            extends Control            -> the view; binds the service, renders
  (bridge.gd         extends BridgeServer)      -> OPTIONAL: localhost HTTP for an MCP/CLI shim
```

## 1. plugin.gd — declare the pieces

Override `_config()` only. The base constructs service → (bridge) → dock, injects the service, mounts the dock beneath the enforced header (title left; version + reload button right), and tears it all down in `_exit_tree`. Register the tool in `project.godot [editor_plugins]` and commit the `.gd.uid` files.

```gdscript
@tool
extends "res://addons/editor_tool_kit/editor_tool_plugin.gd"

const ServiceT := preload("res://addons/<tool>/<tool>_service.gd")
const DockT := preload("res://addons/<tool>/dock.gd")

func _config() -> Dictionary:
    return {
        "panel": "My Tool",
        "service": ServiceT,
        "dock": DockT,
        # "bridge": BridgeT,   # optional
    }
```

## 2. <tool>_service.gd — the headless core

`class_name FooService extends ToolService`: own the in-memory model + config, expose domain methods returning `{ok, error, ...}`, and emit change signals. Carry _no_ `Control` / `EditorInterface` references so it runs under `godot --headless`. Persist through `ContentStore` (validate → atomic multi-target write → rescan, with version-bump rollback).

## 3. dock.gd — the view

A `Control` with a `service` property (the base injects it). Build the layout with the `EditorToolUi` static builders, hold control refs + interaction state, and re-render when the service emits its change signal. Bind signals with **method callables (not lambdas)** so a plugin hot-reload can't fire a late signal into a freed view.

## Optional: bridge.gd — MCP / CLI access

To drive the tool from outside the editor, add `class_name FooBridge extends BridgeServer`, override `_resolve_port()` and `_route(method, path, query, body)`, and declare it under `bridge` in `_config()`. It is opt-in and a no-op under headless, so verifiers and CLI runs never bind a port.

## Verify headless

Because the service has no editor deps, cover it with a `verify_<tool>.gd` script run with no editor:

```bash
godot --headless --path <project> --script res://tools/verify_<tool>.gd
```

For the primitives each piece builds on, see Editor Tool Kit.

## References
_None._

## Child pages
_None._
