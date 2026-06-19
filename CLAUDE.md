# godot-addons — agent guide

The home for **reusable, game-agnostic Godot 4.x addons** by The Golden Mule.
This repo is the **distribution source of truth**: each addon is committed into
consuming games (so a fresh clone works offline) *and* self-updates in place from
here. The repo is itself a minimal Godot project so the addons can be opened,
edited, and tested in isolation.

## Layout

```
addons/<name>/        one addon per folder, AT THE REPO ROOT (load-bearing — see below)
  plugin.cfg          name/description/author/version + script=plugin.gd
  plugin.gd           the EditorPlugin
  <addon files>.gd    + their .gd.uid (commit the .uid files; they travel with the addon)
project.godot         minimal; [editor_plugins] enables every addon here
wiki/                 EMITTED docs (Hotseat workspace -> markdown). Never hand-edit; see below.
```

Currently: `ui_kit` (UI shell infra) and `editor_tool_kit` (editor-tool base classes).

## The vendoring + self-update model

A consuming game **copies** `addons/<name>/` into its own `addons/` and commits it.
The version in `plugin.cfg` on `main` **is the ship signal** — bump it + push and
consumers see the update. There is no GitHub-release ceremony.

**`editor_tool_kit` is the package manager.** It carries the only update
machinery + the only update dock, and updates *every* managed addon — including
itself. An addon opts in to being managed simply by adding an `[update]` marker to
its own `plugin.cfg` (see below); it ships **no** update code of its own. The "Editor
Tool Kit" bottom-panel dock lists each managed addon as a row with its installed →
upstream version and a per-row Update (plus Check-all / Update-all).

Update downloads the whole-branch archive zip **once** and extracts **only the
managed `addons/<name>/` subtrees** — it overwrites + adds but **never prunes**,
and touches nothing else in the consuming project. (See
`addons/editor_tool_kit/update_*.gd` + `package_registry.gd`.)

> **DEPENDENCY:** a managed addon's self-update now requires `editor_tool_kit` to
> be vendored + enabled alongside it. (ui_kit's only consumer, `../moveborne-godot`,
> already vendors both; `../war` vendors only etk.) The two addons still copy as
> self-contained folders — the dependency is "etk must also be present," not "etk
> files live inside the other addon."

> **LOAD-BEARING:** an addon must live at exactly `addons/<name>/` at the repo root,
> and its marker's `prefix` must equal `addons/<name>/`. The extractor strips one
> archive-wrapper segment (`godot-addons-main/`) and keeps only paths under a managed
> `prefix`. Nest it deeper and self-update silently no-ops.

## Self-update marker contract

A managed addon declares itself with one section in its own `plugin.cfg`. This is
the whole contract — it replaces the per-addon update constants the old model used:

```ini
[update]
source = "thegoldenmule/godot-addons"   # GitHub owner/repo it ships from
branch = "main"                         # tracked branch (defaults to "main")
prefix = "addons/<name>/"               # the addon subtree — LOAD-BEARING
```

`prefix` is authoritative for both the raw-cfg URL (the version source of truth)
and which archive subtree the install runner extracts; it is folder-named (not
repo-named), so it survives a repo move. `editor_tool_kit` derives every URL it
needs from `source` + `branch` + `prefix` — there are no hardcoded repo constants
to keep in sync anymore.

## Adding a new addon

1. Create `addons/<name>/` with `plugin.cfg` (start `version="0.1.0"`) + `plugin.gd`.
   Commit the `.gd.uid` files.
2. To make it self-update, add the `[update]` marker above to its `plugin.cfg` with
   its own `prefix`. Give it **no** update machinery — etk's dock manages it. (etk
   must be vendored alongside it in the consuming project.)
3. Add `res://addons/<name>/plugin.cfg` to `project.godot` `[editor_plugins]`
   `enabled` — prefer the editor's Plugins panel over hand-editing the array.
4. No per-addon `.gitignore` entry needed — etk stages every addon's update under
   its single `editor_tool_kit_update/` dir.
5. Add a row to the README Addons table, and author its docs in the wiki workspace
   (do NOT hand-write `wiki/**` — see below).

The static, editor-free helpers (version compare, discovery + URL building, the
runner's archive-path map + traversal guard) are covered by
`tools/verify_editor_tool_kit.gd` — run it headless after touching the update code:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
    --script res://tools/verify_editor_tool_kit.gd
```

## Releasing an update

Bump `version` in the addon's `plugin.cfg`, commit, push to `main`. Done.

## Docs (`wiki/`) are emitted, never hand-edited

`wiki/**` is a read-only projection of the `godot-addons` Hotseat workspace
(`hotseat.config.json` holds the `workspaceId`; the `wiki` MCP at
`hotseat.thegoldenmule.com/mcp` is the authoring surface). Edit docs through the
Hotseat tooling (`hotseat wiki …` / the wiki MCP), then re-run the `wiki-mirror`
emitter — never by editing the markdown directly (it gets overwritten). Each addon
gets its own TOC under the workspace.
