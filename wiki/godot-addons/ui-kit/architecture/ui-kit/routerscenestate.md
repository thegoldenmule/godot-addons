# RouterSceneState

**Status:** current

## Kind
component

## Summary
**RouterSceneState** (`router_scene_state.gd`) — an optional `UiState` subclass (`extends "res://addons/ui_kit/ui_state.gd"`) for the common case of a route that *loads a single scene*, parents it under the router's `content_root`, and uses the shared cover/reveal fade for a hard cut in and out. It pops itself when the loaded scene emits a configured exit signal.

## Purpose
Most routes do the same thing: instantiate a scene, fade in, and pop when the scene says it's done (e.g. a level emitting `"exited"`). RouterSceneState captures that pattern so a route is just a constructor call, while leaving `on_enter`/`on_exit` hooks for subclasses that need to seed or read shared state around the load.

## Design notes
It depends on the router's content_root, cover(), reveal(), and pop() — so the router node is passed into _init explicitly rather than resolved by name. The exit-signal wiring is optional and guarded by _scene.has_signal(_exit_signal); without it the route must be popped by other means (e.g. the system Back button).

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `RouterSceneState` in `addons/ui_kit/router_scene_state.gd`
- function `enter` in `addons/ui_kit/router_scene_state.gd`
- function `_on_exit_requested` in `addons/ui_kit/router_scene_state.gd`

## Data model
Constructed with `_init(router, scene_path, exit_signal := "", label := "SceneState")`, storing `_router`, `_scene_path`, `_exit_signal`, `_label`, and (once loaded) `_scene`.

- **`enter(params)`** — calls `on_enter(params)`, loads + instantiates `_scene_path`, adds it under `_router.content_root`, connects `_exit_signal` to `_on_exit_requested` (when the scene has it), awaits one process frame, then awaits `_router.reveal()`.
- **`exit()`** — awaits `_router.cover()`, frees `_scene` if valid, then calls `on_exit()`.
- **`on_enter(_params)` / `on_exit()`** — empty hooks for subclasses to seed shared state from `params` before the scene loads / capture results after teardown.
- **`_on_exit_requested(_result=null)`** — calls `_router.pop()`.
- **`state_name()`** — returns `_label`.

## Usage
Construct with the router node and scene path (optionally an exit-signal name and a label), then push it: `var s := RouterSceneState.new(UiRouter, "res://scenes/level.tscn", "exited"); UiRouter.push(s, {"level": 3})`. Subclass and override `on_enter`/`on_exit` (not the lifecycle hooks) when the route needs to read/seed shared state around the scene's life.

## Invariants & constraints
- It is an optional convenience subclass of UiState — routes that don't fit the load-scene/fade/pop-on-signal pattern subclass UiState directly instead.
- enter() always reveals and exit() always covers via the router's shared fade, giving a consistent hard cut; the loaded scene is freed in exit() only when still valid.
- Subclasses customize via on_enter/on_exit hooks rather than overriding enter/exit, preserving the load + fade + connect + pop wiring.

## Synced commit
_None._
