# Getting started — install & enable

**Status:** active

## Body
UI Kit is generic, game-agnostic UI shell infrastructure for Godot 4.x, extracted from a shipped game. You get a stack-based navigation router with awaited transitions plus a semantic UI automation layer you can drive from an LLM / MCP `game_eval`-style hook. This page covers getting the addon into your project and turning it on.

## 1. Copy the addon in

UI Kit is vendored: a consuming project copies the addon folder into its own tree and commits it, so a fresh clone works offline. Copy the entire `addons/ui_kit/` directory from [github.com/thegoldenmule/godot-addons](https://github.com/thegoldenmule/godot-addons) into your project's `addons/` directory.

**Commit the .gd.uid files.** Each script ships with a `.gd.uid` sidecar; these travel with the addon and must be committed alongside the `.gd` files.

## 2. Enable the plugin

In the Godot editor, open Project → Project Settings → Plugins and enable "UI Kit". This activates the editor plugin, which mounts a "UI Kit" bottom-panel dock used for self-updating from the source repo.

## 3. Declare the autoloads

The addon does _not_ register its own autoloads — you declare them. Two scripts are meant to run as singletons. Add them under Project → Project Settings → Autoload (or directly in `project.godot`). The names below are conventional; the addon does not depend on them.

```ini
[autoload]

UiRouter="*res://addons/ui_kit/ui_router.gd"
UiDriver="*res://addons/ui_kit/ui_driver.gd"
```

**Why the names don't matter:** `UiRouter` joins the `ui_router` group on ready, and `UiDriver` resolves both the router and the UI host by group rather than by a global identifier. So the driver works regardless of the autoload names your project chose — it even runs in a hand-built headless tree.

## What you get

| File | What it is |
| --- | --- |
| `ui_router.gd` | UiRouter — an async stack-FSM router. The stack IS the nav history; Back = pop. Every lifecycle hook (enter/exit/suspend/resume) is awaited. Cover/reveal fade for hard cuts. Joins the ui_router group. |
| `ui_state.gd` | class_name UiState — base for one route in the stack. Override the awaited hooks. |
| `router_scene_state.gd` | Optional UiState base for the common 'load a scene, fade in/out, pop on a signal' route. |
| `ui_screen_scaffold.gd` | class_name UiScreenScaffold — a MarginContainer giving screens consistent padding + a centered max content width. |
| `ui_reg.gd` | class_name UiReg — control registration as a byproduct of construction. |
| `ui_driver.gd` | UiDriver — the automation layer. Knows no game specifics; sources all content from the host. |
| `plugin.gd` + `update/` | The editor plugin: a 'UI Kit' bottom-panel dock that self-updates from the source repo. |

Next, see Wiring a UI — router, scaffold, registration to boot the router and wire your shell.

## References
_None._

## Child pages
_None._
