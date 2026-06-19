# Self-update & distribution

**Status:** current

## Kind
subsystem

## Summary
The kit's **own tool**: an **"Editor Tool Kit"** bottom-panel tab that checks the source repo and pulls a newer copy of the addon in place. Three pieces built on the kit's own framework — **`UpdateService`** (a `ToolService`), **`UpdatePanel`** (the dock), and **`update_reload_runner.gd`** (the detached extract/reload runner) — so the kit dogfoods the bases it ships, mirroring how the godot-ai plugin distributes itself.

## Purpose
The addon is committed into a consuming project (a fresh clone works offline) but its source of truth is this standalone repo. The panel lets a consumer pull updates in place without a manual re-vendor, and proves the framework is enough to build a real tool on.

## Design notes
update_reload_runner.gd is parented OUTSIDE the plugin so it survives set_plugin_enabled(false). It disables the plugin, extracts ONLY the archive's addons/editor_tool_kit/ subtree (atomic .tmp + rename per file with rollback; an anchored-prefix mapping that accepts the path directly or under one branch-archive wrapper segment but rejects deeper-nested copies; a duplicate-target abort; and a FAILED_MIXED guard that leaves the plugin DISABLED rather than load a half-installed tree), waits for a filesystem scan, then re-enables the plugin.

## Components
_No components._

## Dependencies
- **depends-on** → [ToolService](architecture:mql3cw8b-01r9-lncvao) — UpdateService is a ToolService; parse_remote_version / is_newer are static + headless-testable.
- **depends-on** → [EditorToolUi](architecture:mql3cys5-01rr-jroiua) — UpdatePanel is a dock built from the EditorToolUi builders.

## Code references
- class `UpdateService` in `addons/editor_tool_kit/update_service.gd`
- class `UpdatePanel` in `addons/editor_tool_kit/update_panel.gd`
- file `Detached extract → fs scan → plugin reload` in `addons/editor_tool_kit/update_reload_runner.gd`

## Data model
_None._

## Usage
Open the **Editor Tool Kit** tab and press **Check for updates** (or leave *Check for updates when the editor opens* on). It compares the installed `plugin.cfg` `version` to the repo's `plugin.cfg` read RAW from the default branch; if newer, **Update now** downloads the branch-archive zip, replaces `addons/editor_tool_kit/` in place, and reloads the plugin. Requires Godot 4.4+ for the in-editor reload.

## Invariants & constraints
- Version IS the ship signal: bump `version` in the repo's plugin.cfg and push to the default branch — no GitHub-release ceremony.
- The in-editor self-update writes ONLY the archive's addons/editor_tool_kit/ subtree (anchored prefix; overwrites + adds but never prunes), and on a failed install refuses to re-enable the plugin if rollback leaves a mixed old+new tree.
- An update clobbers local edits to the vendored copy — the repo is the source of truth; land changes there.

## Synced commit
501411d
