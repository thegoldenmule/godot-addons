# Self-update & distribution

**Status:** current

## Kind
subsystem

## Summary
The kit's **package manager**: an **"Editor Tool Kit"** bottom-panel tab that manages updates for *every* vendored addon that opts in with an `[update]` marker in its `plugin.cfg` (including etk itself). Each managed addon is a row — installed → upstream version, with a per-row Update plus Check-all / Update-all. Built on the kit's own framework — **`PackageRegistry`** (discovery), **`UpdateService`** (a `ToolService` manager), **`UpdatePanel`** (the dock), and **`update_reload_runner.gd`** (the detached extract/reload runner) — so the kit dogfoods the bases it ships, mirroring how the godot-ai plugin distributes itself.

## Purpose
Addons are committed into a consuming project (a fresh clone works offline) but their source of truth is this standalone repo. Consolidating updates into one manager means a single UI updates every addon in place without a manual re-vendor, and a managed addon ships NO update code of its own — it just declares an `[update]` marker. (A managed addon therefore requires editor_tool_kit vendored + enabled alongside it.)

## Design notes
PackageRegistry scans res://addons/*/plugin.cfg for an [update] marker (source/branch/prefix) and derives the raw-cfg + archive URLs per managed addon — all static + editor-free, so the verifier drives it headless.

update_reload_runner.gd is parented OUTSIDE the plugin so it survives set_plugin_enabled(false) — including etk disabling ITSELF. It disables every affected plugin, extracts each managed addons/<name>/ subtree from the one downloaded archive (atomic .tmp + rename per file with rollback; an anchored multi-prefix mapping that accepts a path directly or under one branch-archive wrapper segment but rejects deeper-nested copies; a duplicate-target abort; and a FAILED_MIXED guard that leaves the affected plugins DISABLED rather than load a half-installed tree), waits for a filesystem scan, then re-enables the plugins.

## Components
_No components._

## Dependencies
- **depends-on** → [ToolService](architecture:mql3cw8b-01r9-lncvao) — UpdateService is a ToolService; parse_remote_version / is_newer are static + headless-testable.
- **depends-on** → [EditorToolUi](architecture:mql3cys5-01rr-jroiua) — UpdatePanel is a dock built from the EditorToolUi builders.

## Code references
- class `UpdateService` in `addons/editor_tool_kit/update_service.gd`
- class `UpdatePanel` in `addons/editor_tool_kit/update_panel.gd`
- file `Detached extract → fs scan → plugin reload` in `addons/editor_tool_kit/update_reload_runner.gd`
- file `PackageRegistry — discovers managed addons from plugin.cfg [update] markers` in `addons/editor_tool_kit/package_registry.gd`

## Data model
_None._

## Usage
Open the **Editor Tool Kit** tab and press **Check all** (or leave *Check for updates when the editor opens* on). For each managed addon it compares the installed `plugin.cfg` `version` to the upstream `plugin.cfg` read RAW from that addon's tracked branch; where newer, the per-row **Update** or **Update all** downloads the branch-archive zip ONCE, extracts every stale addon's subtree in place, and reloads the affected plugins. Requires Godot 4.4+ for the in-editor reload.

## Invariants & constraints
- Version IS the ship signal: bump `version` in the repo's plugin.cfg and push to the default branch — no GitHub-release ceremony.
- An update clobbers local edits to the vendored copy — the repo is the source of truth; land changes there.
- The in-editor self-update writes ONLY the managed addons/<name>/ subtrees (anchored prefixes from each addon's [update] marker; overwrites + adds but never prunes), and on a failed install refuses to re-enable the affected plugins if rollback leaves a mixed old+new tree.
- A managed addon carries NO update machinery of its own — only an [update] marker in its plugin.cfg. etk is the package manager, so a managed addon requires etk vendored + enabled alongside it.

## Synced commit
33846ec
