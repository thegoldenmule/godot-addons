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
autoload / wiring it needs. The addon's bottom-panel dock checks this repo for
newer versions and pulls them in place.

## Adding an addon

This repo is the home for extracted, game-agnostic addons. To add one, drop it at
`addons/<name>/` (sibling to the others — the self-update extractor requires that
exact path), wire it up, and ship by bumping its `plugin.cfg` `version` on `main`.
See [`CLAUDE.md`](CLAUDE.md) for the full new-addon checklist and the self-update
constant contract every addon must satisfy to source from this repo.
