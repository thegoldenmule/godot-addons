# UI Kit

Generic, game-agnostic UI shell infrastructure for Godot 4.x, extracted from a
shipped game. Drop it in `addons/ui_kit/`, declare two autoloads, and implement a
small host contract — you get a stack-based navigation router with awaited
transitions and a semantic UI automation layer you can drive from an LLM / MCP
`game_eval`-style hook.

## What's in the box

| File | What it is |
|---|---|
| `ui_router.gd` | `UiRouter` — an async stack-FSM router. The stack IS the nav history; Back = pop. Every lifecycle hook (`enter/exit/suspend/resume`) is awaited. Cover/reveal fade for hard cuts. Joins the `ui_router` group. |
| `ui_state.gd` | `class_name UiState` — base for one route in the stack. Override the awaited hooks. |
| `router_scene_state.gd` | Optional `UiState` base for the common "load a scene, fade in/out, pop on a signal" route. |
| `ui_screen_scaffold.gd` | `class_name UiScreenScaffold` — a `MarginContainer` that gives screens consistent padding + a centered max content width. |
| `ui_reg.gd` | `class_name UiReg` — control registration as a byproduct of construction. Factories (`button/check/slider/line_edit/texture_button`) + `screen()/adopt()` stamp `ui_id`/`ui_screen` metadata on the live tree. |
| `ui_driver.gd` | `UiDriver` — the automation layer: `state()/screens()/actions()/goto()/press()/toggle()/set_value()/set_text()/run()/flow()`. Knows no game specifics; sources all content from the host. |
| `plugin.gd` + `update/` | The editor plugin: a "UI Kit" bottom-panel dock that self-updates from `github.com/thegoldenmule/godot-addons`. |

## Wiring (consuming project)

1. Copy `addons/ui_kit/` into your project and enable the plugin
   (Project → Project Settings → Plugins → "UI Kit").
2. Declare two autoloads (any names; these are conventional):

   ```
   UiRouter="*res://addons/ui_kit/ui_router.gd"
   UiDriver="*res://addons/ui_kit/ui_driver.gd"
   ```

3. Boot the router with your root state:

   ```gdscript
   func _ready() -> void:
       UiRouter.reset(MyShellState.new())
   ```

4. Make your shell a **UiNavHost**: put it in the `ui_nav_host` group and
   implement the contract below. The driver finds it by group, so the autoload
   names don't matter.

## The UiNavHost contract

The driver provides the *mechanism*; the host provides the *game content*. Only the
first three are required — everything else has a generic fallback.

```
mcp_select_tab(id) -> bool          select a shell tab
mcp_current_tab_id() -> String      the active tab id
mcp_start_match(cfg) -> void        launch a mode/overlay (push a router state)

mcp_nav_tabs() -> Array             selectable tab ids        (default: [])
mcp_nav_modes() -> Array            launchable mode ids       (default: [])
mcp_mode_cfg(id) -> Dictionary      cfg passed to start_match (default: {"mode": id})
mcp_target_active(id) -> bool       is this goto target already current? (default: false)
mcp_exit_to_shell() -> awaitable    pop any overlay/match back to the shell
mcp_route_label(state_name)->String map a router state name to a label
mcp_wait_ready(target) -> awaitable post-navigation readiness wait
mcp_match_ready() -> bool           is gameplay interactable?
mcp_flows() -> Array                flow catalog [{name, params, summary}]
mcp_expand_flow(name, params)       expand a flow to run() steps, or null
mcp_step(verb, arg) -> Dictionary   handle a custom run() step verb (e.g. "swipe")
```

Register actionable controls through `UiReg` so the driver can discover them:

```gdscript
const Reg := preload("res://addons/ui_kit/ui_reg.gd")

func _ready() -> void:
    Reg.screen(self, "settings")                 # this Control is the "settings" screen
    var save := Reg.button("save", self, "Save")  # discoverable as "settings.save"
```

Then drive it from your eval hook:

```gdscript
await UiDriver.goto("settings")     # awaited — returns when the screen is live
UiDriver.actions()                  # every pressable id on the live screen
UiDriver.press("settings.save")
await UiDriver.run(["goto:home", "flow:start_game", "swipe:up", "exit"])
```

`swipe:up` is not built in — it's an example of a custom verb routed to your
host's `mcp_step("swipe", "up")`.

## Self-update

Versioning is the `version` field in `plugin.cfg`. To ship an update: bump it,
commit, and push to `main` of `github.com/thegoldenmule/godot-addons`. Consuming
projects see it via the "UI Kit" dock (Check for updates → Update now), which
downloads the branch archive and replaces only the `addons/ui_kit/` subtree in
place (atomic per-file, with rollback). It overwrites + adds but never prunes, so
a file removed upstream must be deleted by hand.
