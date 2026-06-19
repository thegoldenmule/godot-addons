# UiDriver

**Status:** current

## Kind
component

## Summary
**UiDriver** (`ui_driver.gd`) — a `Node` autoload that is the *semantic UI/navigation automation layer* for LLM/automation control. It drives the **shell**: read where you are (`state`/`screens`/`actions`/`flows`), navigate to any screen by name (`goto`), invoke any registered control by stable id (`press`/`toggle`/`set_value`/`set_text`), and run deterministic ordered sequences (`run`/`flow`) — all via an eval hook (e.g. the godot-ai MCP `game_eval` command). It knows **no** game specifics; all content comes from the host.

## Purpose
It is the automation surface over the shell. Determinism is the point: because the navigation layer (`UiRouter`) is an async stack-FSM whose push/pop await their lifecycle hooks and the cover/reveal fades, `await goto(...)` returns only once the destination screen is actually live. The driver provides only the *mechanism* — a live-tree control catalog, control invocation, the step/flow runner, async settle — while the host (a node in the `ui_nav_host` group implementing the *UiNavHost* contract) provides the *content* (screens, modes, flows, custom step verbs). Resolving the router and host **by group** (not autoload name) lets the driver work regardless of the project's naming, and even in a hand-built headless tree.

## Design notes
UiNavHost contract — the host supplies game content; only the first three are required, everything else has a generic fallback: mcp_select_tab(id)->bool, mcp_current_tab_id()->String, mcp_start_match(cfg)->void; then mcp_nav_tabs()->Array, mcp_nav_modes()->Array, mcp_mode_cfg(id)->Dictionary, mcp_target_active(id)->bool, mcp_exit_to_shell()->awaitable, mcp_route_label(state_name)->String, mcp_wait_ready(target)->awaitable, mcp_match_ready()->bool, mcp_flows()->Array, mcp_expand_flow(name,params), mcp_step(verb,arg)->Dictionary.

goto() validates BEFORE any side effect: an unknown target returns {ok:false, reason:'unknown_target'} and leaves the UI untouched (exiting an overlay first would tear down its result state). If already on target (host's mcp_target_active) it just awaits mcp_wait_ready. Otherwise it exits any active overlay (unless target is 'match'), then: 'shell'/'back' return to shell; a host tab is selected via mcp_select_tab; a mode is launched via mcp_start_match(mcp_mode_cfg(t)) which pushes a router state; 'match' requires an already-active overlay. Each path awaits _settle (and mcp_wait_ready when present).

_settle() is the determinism primitive: it awaits one process frame, then keeps yielding frames while the router reports is_busy() — so awaited calls resume only after the in-flight transition (and its fades) finish. run() awaits each step and records a per-step trace with screen_after; it stops on first failure unless opts.continue_on_error. press() deliberately does NOT await router transitions (a launcher push / match exit) — use goto()/run() for those; the 'press' step in run() calls _settle after to cover a launcher push that goes busy synchronously.

state() derives modals data-drivenly: a modal is any visible registered screen that is neither the current tab nor one of the router-state screens — no hardcoded modal names. Each control's kind is inferred from its class (Range=slider, CheckButton/CheckBox=toggle, LineEdit=text, TextureButton=texture_button, other BaseButton=button), and 'enabled' from disabled/editable.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- file `UiDriver` in `addons/ui_kit/ui_driver.gd`
- function `goto` in `addons/ui_kit/ui_driver.gd`
- function `_catalog` in `addons/ui_kit/ui_driver.gd`
- function `_settle` in `addons/ui_kit/ui_driver.gd`

## Data model
Constants: `HOST_GROUP := "ui_nav_host"`, `ROUTER_GROUP := "ui_router"`, a preloaded `UiReg`, and a `NOT_READY` result. Resolution: `_router()`/`_host()` return the first node in those groups (or null).

The catalog is built by walking the live tree, not from stored state: `_catalog()` iterates the `ui_control` group, keeps `Control`s carrying the `ui_id` meta, resolves each to its nearest `ui_screen`-meta ancestor (`_nearest_screen_id`), and keys it as `"<screen>.<ui_id>"`. `_active_screen_ids()` walks the `ui_screen` group for visible roots; `_visible()` accounts for **both** `CanvasItem` and `CanvasLayer` ancestors (a Control under a hidden CanvasLayer still reports `is_visible_in_tree()==true`).

Public surface:
- **reads** — `is_ready()`, `state()` (route, depth, tab, screen, modals, busy, match_ready), `screens()` (tabs/modes/surfaces catalog), `actions(all=false)` (every pressable id on the live screen, each `{id, kind, enabled, visible, +value/on/text}`), `flows()`, `help()`.
- **navigate** — `goto(target)` (awaited).
- **controls** — `press(id, force=false)`, `toggle(id, on=true)`, `set_value(id, value)`, `set_text(id, text, submit=false)`.
- **sequences** — `run(steps, opts={})`, `flow(name, params={})`.

## Usage
Declare it as an autoload (conventionally `UiDriver`) pointing at `ui_driver.gd` and call it from an eval hook: `UiDriver.state()`, `UiDriver.actions()`, `await UiDriver.goto("settings")`, `UiDriver.press("settings.avatar")`, `await UiDriver.run(["goto:settings", "press:settings.avatar", {set="settings.music", to=0.3}, "flow:open_store"])`. A `run` step is a string (`"goto:settings"`, `"press:home.story"`, `"exit"`, `"wait:0.5"`, `"flow:name"`) or a dict (`{goto=}`, `{press=}`, `{set=,to=}`, `{text=,to=,submit=}`, `{toggle=,on=}`, `{wait=}`, `{flow=,params=}`); any *other* verb is handed to the host's `mcp_step` (e.g. `"swipe:up"`). The shell must be mounted (a node in the `ui_nav_host` group) or reads/navigation return the `not_ready` result.

## Invariants & constraints
- Knows no game specifics: every screen/mode/flow/custom-step comes from the host via the UiNavHost contract. The driver supplies only mechanism (catalog, invocation, runner, settle).
- Router and host are resolved by group (ui_router / ui_nav_host), never by autoload name — so the driver works under any naming, and even in a hand-built headless tree.
- goto() validates the target before any side effect: an unknown target leaves the UI untouched and returns reason 'unknown_target'.
- await goto()/run()/_settle() resume only once the router is no longer busy — _settle yields frames while UiRouter.is_busy(), giving deterministic 'returns when the screen is live' semantics.
- The control catalog is derived from the live tree on each call (walking the ui_control group + ui_id meta), so it reflects exactly what is currently mounted and visible — no stale central state.

## Synced commit
_None._
