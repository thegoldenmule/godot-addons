# UI Kit

**Status:** current

## Kind
package

## Summary
**UI Kit** (`addons/ui_kit/`) — generic, game-agnostic UI shell infrastructure for Godot 4.x, extracted from a shipped game. It is a small set of runtime classes: an async stack-FSM navigation router (`UiRouter`), an awaitable per-route base (`UiState`) plus an optional scene-loading subclass (`RouterSceneState`), a layout frame (`UiScreenScaffold`), control-registration factories (`UiReg`), and a semantic UI/navigation automation layer (`UiDriver`). The kit knows *no* game specifics — screens, modes, and flows are all supplied by the consuming project's host. It is **vendored** (copied + committed under the consumer's `addons/ui_kit/` so a fresh clone works offline) yet **self-updates** in place from `github.com/thegoldenmule/godot-addons` via a bottom-panel "UI Kit" dock.

## Purpose
The kit factors out the parts of a UI shell that every game re-implements: a navigation history that is really a *stack* (Back = pop), transitions that must be *awaited* (so an LLM/automation hook can know when a screen is actually live), a consistent screen margin, and a way to discover + drive controls by stable id without central bookkeeping. Pairing the async stack-FSM router with a host-driven `UiDriver` yields a *deterministic* automation surface: `await goto(...)` returns only once the destination is live, because push/pop await their lifecycle hooks and the cover/reveal fades. The router and driver are deliberately decoupled from the autoload names the consuming project chooses — they find each other (and the host) by group, so the kit drops in regardless of naming.

## Design notes
Wiring recipe (consuming project): 1) copy addons/ui_kit/ in and enable the "UI Kit" plugin; 2) declare the two autoloads (any names — driver/router resolve by group, not by autoload name); 3) boot with UiRouter.reset(root_state) in _ready(); 4) put the shell in the ui_nav_host group and implement the UiNavHost contract; 5) build/adopt controls via UiReg so the driver can discover them.

Self-update: the version field in plugin.cfg on main is the ship signal — bump it, commit, push. Consumers see it via the "UI Kit" dock (Check for updates -> Update now), which downloads the branch archive and replaces only the addons/ui_kit/ subtree in place (atomic per-file, with rollback). It overwrites + adds but never prunes, so a file removed upstream must be deleted by hand.

## Components
- [UiRouter](architecture:mql3d118-01sp-n0xqb4)
- [UiState](architecture:mql3d1wn-01sx-jfas5y)
- [UiScreenScaffold](architecture:mql3d2sr-01t3-4sjuck)
- [UiReg](architecture:mql3d4tc-01tb-lwz3ka)
- [UiDriver](architecture:mql3d5op-01tf-20iper)
- [RouterSceneState](architecture:mql3d6r0-01tj-mcglp1)

## Dependencies
_No dependencies._

## Code references
- file `Wiring + host contract + self-update` in `addons/ui_kit/README.md`
- file `UI Kit editor plugin (registers no autoloads)` in `addons/ui_kit/plugin.gd`

## Data model
The addon is a handful of `.gd` files under `addons/ui_kit/`, plus `plugin.gd` + an `update/` folder for the editor-side self-update dock:

- **`ui_router.gd`** — `UiRouter`, a `Node` autoload: an async stack-FSM router. The stack *is* the nav history; every lifecycle hook is awaited; cover/reveal fade for hard cuts. Joins the `ui_router` group.
- **`ui_state.gd`** — `class_name UiState extends RefCounted`: the base for one route, with awaitable `enter/exit/suspend/resume`.
- **`router_scene_state.gd`** — an optional `UiState` subclass for the "load a scene, fade in/out, pop on a signal" route.
- **`ui_screen_scaffold.gd`** — `class_name UiScreenScaffold extends MarginContainer`: shared screen padding + centered max content width.
- **`ui_reg.gd`** — `class_name UiReg extends RefCounted`: static factories that build + register actionable controls on the live tree (no central registry).
- **`ui_driver.gd`** — `UiDriver`, a `Node` autoload: the automation layer (`state/screens/actions/goto/press/toggle/set_value/set_text/run/flow`). Joins nothing; finds the router by the `ui_router` group and the host by the `ui_nav_host` group.
- **`plugin.gd` + `update/`** — the `@tool` `EditorPlugin`: mounts the "UI Kit" bottom-panel dock and self-updates the addon. It registers **no autoloads**.

## Usage
A consuming project copies `addons/ui_kit/` in, enables the plugin, and declares **two autoloads of its own choosing** (conventionally `UiRouter="*res://addons/ui_kit/ui_router.gd"` and `UiDriver="*res://addons/ui_kit/ui_driver.gd"`) — the kit registers no autoloads, so the project owns their names. It boots the router with a root state (`UiRouter.reset(MyShellState.new())`), makes its shell a *UiNavHost* (a node in the `ui_nav_host` group implementing the host contract), and registers actionable controls through `UiReg` (`Reg.screen(self, "settings")`, `Reg.button("save", self, "Save")`). It can then drive the shell from an eval hook: `await UiDriver.goto("settings")`, `UiDriver.actions()`, `UiDriver.press("settings.save")`, `await UiDriver.run([...])`. See the component pages for each piece.

## Invariants & constraints
- The kit registers NO autoloads — the consuming project declares UiRouter + UiDriver itself (any names). The router/driver/host find each other by group (ui_router / ui_nav_host), never by a global identifier.
- Game-agnostic: no script in the kit names a game-specific screen, mode, or flow. All content is supplied by the host (a node in the ui_nav_host group implementing the UiNavHost contract).
- Vendored but sourced from github.com/thegoldenmule/godot-addons: land changes in that repo, never in a consumer's vendored copy — self-update overwrites addons/ui_kit/ in place (and never prunes).

## Synced commit
_None._
