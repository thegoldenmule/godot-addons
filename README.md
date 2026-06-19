# godot-addons

Reusable, game-agnostic Godot 4.x addons by The Golden Mule. Each addon lives
under `addons/<name>/`, is committed into consuming projects (so a fresh clone
works offline), and self-updates in place from this repo (bump `plugin.cfg`
`version`, push to `main`).

This repo is itself a minimal Godot project so the addons can be opened, edited,
and tested in isolation.

## Addons

| Addon | What it is |
|---|---|
| [`ui_kit`](addons/ui_kit/README.md) | Generic UI shell infrastructure: an async stack-FSM router (`UiRouter`), `UiState`, `UiScreenScaffold`, control registration (`UiReg`), and a semantic UI/navigation automation driver (`UiDriver`). |
| [`editor_tool_kit`](addons/editor_tool_kit/README.md) | Editor-only base classes for in-editor authoring tools (`EditorToolPlugin`, `ToolService`, `ContentStore`, `EditorToolUi`, `BridgeServer`): a new tool is a *service + a view*, with the occult-arcade styling, persistence, and optional MCP/CLI access inherited from the bases. |

## Using an addon

Copy `addons/<name>/` into your project's `addons/`, enable it in
Project → Project Settings → Plugins, and follow that addon's README for any
autoload / wiring it needs. Updates are managed by **`editor_tool_kit`**, which
acts as the package manager: its "Editor Tool Kit" bottom-panel dock lists every
managed addon (any addon carrying an `[update]` marker, including etk itself),
checks this repo for newer versions, and pulls them in place — one UI for all
addons. A managed addon therefore needs `editor_tool_kit` vendored alongside it.

## Adding an addon

This repo is the home for extracted, game-agnostic addons. To add one, drop it at
`addons/<name>/` (sibling to the others — the extractor requires that exact path),
wire it up, add an `[update]` marker to its `plugin.cfg` to make it self-update,
and ship by bumping that `version` on `main`. See [`CLAUDE.md`](CLAUDE.md) for the
full new-addon checklist and the self-update marker contract.
