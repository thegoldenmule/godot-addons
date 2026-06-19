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
Each addon ships a small bottom-panel dock that checks THIS repo for a newer
version and pulls it in place. The version in `plugin.cfg` on `main` **is the ship
signal** — bump it + push and consumers see the update. There is no GitHub-release
ceremony.

The dock downloads the whole-branch archive zip and extracts **only its own
`addons/<name>/` subtree** — it overwrites + adds but **never prunes**, and never
touches sibling addons. (See each addon's `update/…` or `update_*.gd`.)

> **LOAD-BEARING:** an addon must live at exactly `addons/<name>/` at the repo root.
> The extractor strips one archive-wrapper segment (`godot-addons-main/`) and keeps
> only paths under `addons/<name>/`. Nest it deeper and self-update silently no-ops.

## Self-update constant contract

Every self-updating addon carries its own copy of the update machinery (kept
per-addon on purpose — an addon folder must be copy-one-folder self-contained).
Its constants MUST point at this repo:

| Constant | Value |
|---|---|
| `REPO_OWNER` | `thegoldenmule` |
| `REPO_NAME` | `godot-addons` |
| `BRANCH` | `main` (also appears as a literal in the two URLs below) |
| `REPO_PAGE` | `https://github.com/thegoldenmule/godot-addons` |
| `REMOTE_CFG_URL` | `https://raw.githubusercontent.com/thegoldenmule/godot-addons/main/addons/<name>/plugin.cfg` |
| `ARCHIVE_URL` | `https://github.com/thegoldenmule/godot-addons/archive/refs/heads/main.zip` |
| `ADDON_REL_PREFIX` | `addons/<name>/` (folder-named, not repo-named — stays on any repo move) |

## Adding a new addon

1. Create `addons/<name>/` with `plugin.cfg` (start `version="0.1.0"`) + `plugin.gd`.
   Commit the `.gd.uid` files.
2. If it self-updates, give it the update machinery and set the constants above for
   its own `<name>`.
3. Add `res://addons/<name>/plugin.cfg` to `project.godot` `[editor_plugins]`
   `enabled` — prefer the editor's Plugins panel over hand-editing the array.
4. Add the addon's self-update staging dir to `.gitignore` (`<name>_update/`).
5. Add a row to the README Addons table, and author its docs in the wiki workspace
   (do NOT hand-write `wiki/**` — see below).

## Releasing an update

Bump `version` in the addon's `plugin.cfg`, commit, push to `main`. Done.

## Docs (`wiki/`) are emitted, never hand-edited

`wiki/**` is a read-only projection of the `godot-addons` Hotseat workspace
(`hotseat.config.json` holds the `workspaceId`; the `wiki` MCP at
`hotseat.thegoldenmule.com/mcp` is the authoring surface). Edit docs through the
Hotseat tooling (`hotseat wiki …` / the wiki MCP), then re-run the `wiki-mirror`
emitter — never by editing the markdown directly (it gets overwritten). Each addon
gets its own TOC under the workspace.
