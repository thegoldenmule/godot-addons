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

## Using an addon

Copy `addons/<name>/` into your project's `addons/`, enable it in
Project → Project Settings → Plugins, and follow that addon's README for any
autoload / wiring it needs. The addon's bottom-panel dock checks this repo for
newer versions and pulls them in place.

## Related

- [`godot-editor-tk`](https://github.com/thegoldenmule/godot-editor-tk) — shared
  base classes for in-editor authoring tools (same self-update convention).
