# ADR-13: ADR-9: editor_tool_kit is the package manager; addons opt in via an [update] marker and ship no update machinery

**Status:** accepted

## Metadata
- **Date:** 2026-06-19
- **Scope:** editor_tool_kit
- **Deciders:** Benjamin Jordan

## Context
ui_kit and editor_tool_kit each shipped their own copy of the self-update machinery (service + dock + reload runner, ~700 lines) and their own bottom-panel dock, with per-addon repo constants (REPO_OWNER / REMOTE_CFG_URL / ADDON_REL_PREFIX) kept in sync by hand. As more addons land in the repo, that is N docks and N copies of identical update code, each a place to drift. The addons all ship from one repo, so a single branch-archive download already contains every addon's subtree.

## Decision
editor_tool_kit becomes the package manager for every vendored addon. An addon opts in by adding an [update] marker (source / branch / prefix) to its OWN plugin.cfg and ships NO update code of its own; PackageRegistry discovers it by scanning res://addons/*/plugin.cfg. The single 'Editor Tool Kit' dock lists each managed addon as a row (installed -> upstream) with a per-row Update plus Check-all / Update-all, downloads the shared branch archive ONCE, and the reload runner extracts every stale addon's subtree and reloads the affected plugins in one pass — including etk updating itself.

```ini
[update]
source = "thegoldenmule/godot-addons"
branch = "main"
prefix = "addons/<name>/"
```

This supersedes the per-addon-updater aspect of ADR-6. The vendored-but-sourced model and version-is-the-ship-signal (ADR-6) and the extract-only / never-prune / atomic-rollback / FAILED_MIXED safety (ADR-7) still hold — now generalized from one fixed addons/editor_tool_kit/ prefix to the set of managed prefixes.

## Consequences
One UI and one copy of the update code; making a new addon self-updating is just an [update] marker, not a copied-and-edited ~700-line updater.

A managed addon now DEPENDS on editor_tool_kit being vendored + enabled alongside it — it can no longer self-update standalone. (ui_kit's only consumer already vendored both, so the new dependency was already satisfied.)

The marker's prefix is folder-named and authoritative for both the version-check URL and the extracted subtree, so there are no hardcoded repo constants left to keep in sync; it survives a repo move.

An Update-all action assumes its addons share one archive (true for a single source repo); a future addon sourced from a different repo would need the manager to group stale addons by archive URL.

## Relations
_None._
