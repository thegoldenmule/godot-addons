# editor_tool_kit

Shared, **editor-only** base classes for in-editor authoring tools. A new tool is
a *service + a view* — persistence, layout, status, and optional MCP/CLI access
are inherited. The kit is mostly a **framework**: enabling it keeps the
`class_name` globals registered for the tools that subclass them.

It is **vendored** into this project but **sourced** from a standalone repo
([github.com/thegoldenmule/godot-addons](https://github.com/thegoldenmule/godot-addons)) —
so its own `plugin.gd` mounts one small thing of its own: an **"Editor Tool Kit"**
bottom-panel tab that checks that repo for a newer version and self-updates in
place (see [Self-update](#self-update)), mirroring how the godot-ai plugin
distributes itself. That panel is built on the kit's *own* framework (its
`UpdateService` is a `ToolService`, its `UpdatePanel` is the dock), so the kit
dogfoods the bases it ships.

A consuming tool is a *service + a view* (see the recipe below); a tool that wants
MCP/CLI access adds a `BridgeServer`. The kit's own self-update panel is built the
same way, so it dogfoods the bases it ships.

## The three-piece recipe

A tool is three small files that each subclass a base:

```
addons/<tool>/
  plugin.gd          extends EditorToolPlugin   → _config() declares the pieces
  <tool>_service.gd  extends ToolService        → state + signals, ok()/err(), headless-safe
  dock.gd            extends Control            → the view; binds the service, renders
  (bridge.gd         extends BridgeServer)      → OPTIONAL: localhost HTTP for an MCP/CLI shim
```

1. **`plugin.gd`** — override `_config()` only:

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
           # "bridge": BridgeT,         # optional
           "service_name": "MyService", # optional cosmetic node names
           "dock_name": "MyTool",
       }
   ```

   `EditorToolPlugin` constructs `service` → (`bridge`) → `dock` (injecting the
   service into the bridge + dock), mounts the dock **beneath an enforced header**
   (tool title left; version + a self-reload button right) in the bottom panel,
   and reverses it all in `_exit_tree`. The version is read from the tool's own
   `plugin.cfg` and the reload button disable→enables the plugin, so a tool gets
   both for free — the dock builds none of it. Register the tool in
   `project.godot [editor_plugins]` and commit the `.gd.uid` files.

2. **`<tool>_service.gd`** — the headless-testable core (`ToolService`):

   - owns the tool's state, declares its own change signals;
   - returns `ok(data := {})` / `err(msg, code := 0)` for the `{ok, error?}`
     contract, and tracks `mark_dirty()` / `is_dirty()`;
   - **carries NO `Control` / `EditorInterface` references** so it loads and runs
     under `godot --headless` — which is what makes the tool's logic verifiable
     without the editor. Bind its signals from the dock with **method callables**
     (not lambdas) so a hot-reload / late async signal can't fire into a freed
     view.

3. **`dock.gd`** — a `Control` with a `service` property (the base injects it).
   Pure view: build with the `EditorToolUi` builders, hold control refs +
   interaction state, and re-render when the service emits its change signal.

## Styling — the shared occult-arcade theme

Both docks read as one cohesive surface with **no per-dock styling code**, via
Godot's `Control.theme` cascade:

- **`EditorToolPalette`** (`tool_palette.gd`, static consts) — the single source of
  truth for colors + metrics: one violet accent (`#b400ff`, hover `#d24bff`) on
  near-black, green `#44ff88` for selection, white for peak emphasis. **Owned by
  the tool kit** — it never loads a host project's theme; the values are duplicated
  by intent so the kit and any host UI stay visually aligned yet fully decoupled. `tool_header`, `restyle_selected`, `section`, the theme, and both
  docks all reference it, so the look has exactly one place to change.
- **`EditorToolTheme`** (`tool_theme.gd`) — `build() -> Theme` assembles the look
  from the palette with full state coverage (Button/OptionButton, Tab*, Panel*,
  separators, Label, and the input controls LineEdit/TextEdit/SpinBox/Tree/ItemList/
  PopupMenu). `EditorToolPlugin` assigns it to `_panel_root`, so it **cascades to
  every descendant of the header + dock** — a new tool inherits the look for free.
  Per-control overrides (e.g. a tool's preview panel; selection markers via
  `restyle_selected`; `section`'s brighter frame) still win locally over the cascade.
  `build()` returns a plain `Theme` Resource, so it is constructible + assertable
  under `godot --headless`.

## The other primitives

- **`ContentStore`** (static) — `load_json(path)`, atomic N-target write
  `save_all(targets, validate, scan := true)` (validate-then-write-all, editor
  rescan), and `bump_then(struct, key, do_save, when := true)` (version bump that
  rolls back if the save fails). The canonical serializer stays per-tool (field
  order is domain-specific).
- **`EditorToolUi`** (static) — `split_root`, `tool_header` (the enforced
  title/version/reload bar the plugin mounts), `label_wrap`, `form_row`,
  `button`, `button_bar`, `spin`, `status_label`, `section` (a violet-bordered,
  captioned group frame), `restyle_selected`. Pure construction, no state; adopt
  incrementally. Colors/metrics come from `EditorToolPalette`.
- **`BridgeServer`** — optional localhost HTTP base (TCPServer poll loop +
  Content-Length framing + async dispatch + headless skip). A subclass overrides
  `_resolve_port()` and `_route(method, path, query, body) -> {code, payload}`.
  Opt-in per tool.

## Self-update

The kit is committed into the project (a fresh clone works offline) but is
*sourced* from `github.com/thegoldenmule/godot-addons`. The **"Editor Tool
Kit"** bottom-panel tab checks that repo and pulls a newer copy in place:

- **`update_service.gd`** (`ToolService`) — owns the version check + download.
  `parse_remote_version` / `is_newer` are **static + headless-testable** (the
  verifier drives them with no editor or network).
- **`update_panel.gd`** (the dock) — status line, a *Check for updates* /
  *Update now* button pair, and a Settings group (an auto-check-on-open toggle,
  the source repo). Pure view over the service.
- **`update_reload_runner.gd`** — a node parented **outside** the plugin (so it
  survives `set_plugin_enabled(false)`); disables the plugin, extracts the
  archive's `addons/editor_tool_kit/` subtree (atomic `.tmp` + rename per file,
  with rollback on any failure), waits for a filesystem scan, then re-enables
  the plugin. Adapted from godot-ai's runner.

**Version is the ship signal.** The source of truth is `plugin.cfg`'s `version`
on the repo's default branch — checked raw at
`raw.githubusercontent.com/.../addons/editor_tool_kit/plugin.cfg`. To release an
update: bump `version` here, copy the addon into the repo, and push. The panel
compares dotted versions and lights up *Update now* when upstream is newer.

Notes / limits: the install **overwrites + adds** files but never **prunes**, so
a file removed upstream lingers until deleted by hand. An update **clobbers local
edits** to the vendored copy — treat the repo as the source of truth and land
changes there. Only Godot ≥ 4.4 is supported for the in-editor reload (the
project ships 4.6).

## Verifying

Headless, no editor:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path <project> \
    --script res://tools/verify_editor_tool_kit.gd      # the bases + the self-update version helpers
```
