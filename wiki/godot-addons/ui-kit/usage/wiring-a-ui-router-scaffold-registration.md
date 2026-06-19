# Wiring a UI — router, scaffold, registration

**Status:** active

## Body
UI Kit splits a UI shell into three cooperating parts: the `UiRouter` (an async stack-FSM that drives navigation), screens built from `UiState` / `UiScreenScaffold` with their controls registered via `UiReg`, and a `UiNavHost` your game supplies to feed game-specific content to the `UiDriver`. This page is the wiring recipe. (See Getting started — install & enable for install + autoloads first.)

## 1. Define screens / states

Each route on the navigation stack is a `UiState` (`class_name UiState`). Subclass it and override the awaited lifecycle hooks — `enter(params)`, `exit()`, `suspend()`, `resume()`. Because the router awaits each hook, a state can run an async transition (load a scene, fade) before the router proceeds. For the common 'load a scene, fade in/out, pop on a signal' route, subclass the optional `router_scene_state.gd` base instead.

The stack itself encodes nav history. A typical layering:

```text
[ShellState]                     -> on the shell (Home / other tabs)
[ShellState, MatchState]         -> in a match (shell suspended, nav hidden)
[ShellState, MatchState, Modal]  -> a dialog over a match
```

For each screen's layout, add a `UiScreenScaffold` (a `MarginContainer`) as a child of the screen root and put the screen's single content node inside it. It gives every screen the same horizontal padding, fixed top/bottom breathing room, and a centered maximum content width (`MAX_CONTENT_WIDTH = 480`) on wide displays. Bespoke hero/centered layouts can opt out by simply not using it.

## 2. Register actionable controls via UiReg

Registration is a **byproduct of construction**, not a separate bookkeeping step. `UiReg` is a pure static utility (no node/scene state). Its factories — `button`, `check`, `slider`, `line_edit`, `texture_button` — build the bare control, attach it under a parent, and stamp a `ui_id` meta on it (joining the `ui_control` group). Mark the screen root with `screen(root, id)`, which sets a `ui_screen` meta and joins the `ui_screen` group. For a pre-built .tscn or code node, `adopt(control, id)` is the escape hatch.

```gdscript
const Reg := preload("res://addons/ui_kit/ui_reg.gd")

func _ready() -> void:
    Reg.screen(self, "settings")                 # this Control is the "settings" screen
    var save := Reg.button("save", self, "Save")  # discoverable as "settings.save"
    # keep styling/wiring save yourself; Reg only built + registered it
```

Everything is recorded on the live tree, so the registry is self-cleaning: when a screen (e.g. a freed match scene) leaves the tree, its controls simply stop appearing. A control belongs to its _nearest_ screen-root ancestor, so a modal nested under another screen (an avatar picker under Settings) forms its own screen. The full control id is `<screen id>.<control id>` (e.g. `settings.save`).

## 3. Supply a UiNavHost

The driver provides the _mechanism_; your game provides the _content_ via a `UiNavHost` — a node (typically your app shell) placed in the `ui_nav_host` group. The driver finds it by group, so autoload names don't matter. Only the first three methods are required; everything else has a generic fallback.

| Method | Purpose | Default |
| --- | --- | --- |
| `mcp_select_tab(id) -> bool` | select a shell tab | _required_ |
| `mcp_current_tab_id() -> String` | the active tab id | _required_ |
| `mcp_start_match(cfg) -> void` | launch a mode/overlay (push a router state) | _required_ |
| `mcp_nav_tabs() -> Array` | selectable tab ids | `[]` |
| `mcp_nav_modes() -> Array` | launchable mode ids | `[]` |
| `mcp_mode_cfg(id) -> Dictionary` | cfg passed to start_match | `{"mode": id}` |
| `mcp_target_active(id) -> bool` | is this goto target already current? | `false` |
| `mcp_exit_to_shell() -> awaitable` | pop any overlay/match back to the shell | generic stack pop |
| `mcp_route_label(state_name) -> String` | map a router state name to a label | strip 'State', lowercase |
| `mcp_wait_ready(target) -> awaitable` | post-navigation readiness wait | — |
| `mcp_match_ready() -> bool` | is gameplay interactable? | overlay active? |
| `mcp_flows() -> Array` | flow catalog [{name, params, summary}] | `[]` |
| `mcp_expand_flow(name, params)` | expand a flow to run() steps, or null | `null` |
| `mcp_step(verb, arg) -> Dictionary` | handle a custom run() step verb (e.g. 'swipe') | unknown_verb |

## 4. Boot the router

Start the stack with your root state. `reset` clears any existing stack (awaiting each `exit`) and enters the new root:

```gdscript
func _ready() -> void:
    UiRouter.reset(MyShellState.new())
```

From there the router's stack operations — `push(state, params)`, `pop()`, `replace(state, params)`, `reset(state, params)` — drive navigation. Transitions are serialized behind a `_busy` flag (calls made mid-transition no-op), and each emits `changed(top)`. The router also owns the Android/system Back button: it routes Back through the stack (pop one level, or quit at the root) instead of letting it quit outright. States parent their screens into the router's `content_root` CanvasLayer, and `cover(duration)` / `reveal(duration)` provide an awaited fade-to-black for hard cuts.

## 5. Drive it from your eval hook

With the host mounted and controls registered, `UiDriver` exposes a semantic command surface. Navigation is awaited — because the router awaits its lifecycle hooks plus the cover/reveal fades, `await goto(...)` returns only once the destination screen is actually live.

```gdscript
await UiDriver.goto("settings")     # awaited — returns when the screen is live
UiDriver.actions()                  # every pressable id on the live screen
UiDriver.press("settings.save")
await UiDriver.run(["goto:home", "flow:start_game", "swipe:up", "exit"])
```

Reads: `state()` (where am I / what's on top / is a transition running), `screens()` (goto targets), `actions(all=false)` (every pressable id), `flows()`. Controls: `press(id)`, `toggle(id, on)`, `set_value(id, v)`, `set_text(id, s, submit)`. Sequencing: `run([steps], opts)` and `flow(name, params)`. A `swipe:up` step is not built in — it is an example of a custom verb routed to your host's `mcp_step("swipe", "up")`.

## References
_None._

## Child pages
_None._
