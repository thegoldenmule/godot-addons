# Getting started — install & enable

**Status:** active

## Body
## Install

1. Copy `addons/editor_tool_kit/` into your project's `addons/` directory.
2. Enable **Editor Tool Kit** in Project → Project Settings → Plugins.
3. Commit the folder — including the `.gd.uid` files — so the addon travels with the project and a fresh clone works offline.

The addon is **editor-only**: it adds no runtime dependencies to an exported game. Godot **4.4+** is required (the in-editor self-update reload needs it; this repo targets 4.6).

## What enabling gives you

Enabling keeps the kit's `class_name` globals registered — `EditorToolPlugin`, `ToolService`, `ContentStore`, `EditorToolUi`, `EditorToolPalette`, `EditorToolTheme`, and `BridgeServer` — so any tool that subclasses them resolves. It also mounts the **Editor Tool Kit** bottom-panel tab, which checks the source repo and self-updates the addon in place.

The kit is mostly a framework; on its own it ships only the self-update tool. To build something with it, see Authoring a new tool — the three-piece recipe. For how the pieces fit together, see Editor Tool Kit.

## References
_None._

## Child pages
_None._
