# UiRouter

**Status:** current

## Kind
component

## Summary
**UiRouter** (`ui_router.gd`) — a `Node` autoload that is a *stack-based UI state machine*. The stack **is** the navigation history; Back = pop. Transitions (`push`/`pop`/`replace`/`reset`) are serialized behind a `_busy` flag, and every lifecycle hook (`enter`/`exit`/`suspend`/`resume`) is **awaited**, so a state may run an async transition before the router proceeds. It also owns a shared `cover`/`reveal` fade for hard cuts and routes the Android/system Back button through the stack.

## Purpose
It models navigation as a stack so common shells fall out naturally: `[ShellState]` on the shell, `[ShellState, MatchState]` in a match (shell suspended), `[ShellState, MatchState, Modal]` for a dialog over a match. Because every transition is awaited and serialized, callers — notably `UiDriver` — can `await` a navigation and know the destination is *actually live*, not merely requested. It joins the `ui_router` group so the driver can locate it without depending on the autoload name the project chose.

## Design notes
Transition order matters. push: suspend the state below (if any), push the new state, await its enter(), emit changed. pop: pop + await the leaving state's exit(), then await the new top's resume(), emit changed (no-op if stack <= 1). replace: pop + exit the top, push + enter the replacement. reset: exit every state from the top down, then push + enter the new root. Each sets _busy for its duration.

Android / system Back: _ready() calls get_tree().set_quit_on_go_back(false), and _notification(NOTIFICATION_WM_GO_BACK_REQUEST) pops one level when stack_depth > 1, or quits when already at the root (the shell). It returns early while _busy. This is distinct from ESC, which gameplay code may use for its own interactions.

```gdscript
func push(state, params: Dictionary = {}) -> void:
	if _busy:
		return
	_busy = true
	var below = top()
	if below != null:
		await below.suspend()
	_stack.push_back(state)
	await state.enter(params)
	changed.emit(state)
	_busy = false
```

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- file `UiRouter` in `addons/ui_kit/ui_router.gd`
- function `cover` in `addons/ui_kit/ui_router.gd`
- constant `ROUTER_GROUP` in `addons/ui_kit/ui_router.gd`

## Data model
State: `_stack: Array` (the routes, bottom-up), `_busy: bool` (a one-at-a-time transition lock), and `content_root: CanvasLayer` (`layer = 1`, named `RouterContent`) that states parent their screens into — kept off the boot scene's `current_scene`. A lazily built `_fade_layer` (CanvasLayer `layer = 200`) holds a full-rect black `ColorRect` `_fade` for the cover/reveal fade, sitting above match overlays.

Reads: `top()` (back of stack or null), `is_busy()`, `stack_depth()`, and `route_names()` — the bottom-up list of `state.state_name()` strings the driver maps to its route summary. Signal: `changed(top)` emitted after each transition. Constant: `ROUTER_GROUP := "ui_router"`.

## Usage
Declare it as an autoload (conventionally `UiRouter`) pointing at `ui_router.gd`, then boot it with a root state: `UiRouter.reset(MyShellState.new())`. Drive navigation with `await UiRouter.push(state, params)`, `await UiRouter.pop()`, `await UiRouter.replace(state, params)`, and `await UiRouter.reset(state, params)`. For hard cuts, a state awaits `UiRouter.cover()` before a swap and `UiRouter.reveal()` after (both default to `0.18s`). All four transition verbs no-op while `_busy` is true (and `pop`/`replace`/`reset` no-op on an empty-or-single stack as appropriate).

## Invariants & constraints
- Transitions are serialized: while _busy is true every push/pop/replace/reset (and the system-Back handler) returns immediately without mutating the stack.
- Every lifecycle hook (enter/exit/suspend/resume) is awaited, so the router does not proceed — and changed is not emitted — until the hook's coroutine finishes.
- The router joins the ui_router group on _ready so collaborators (UiDriver) resolve it by group, independent of the autoload name.
- pop/replace/reset never empty the stack below their guard: pop and the system-Back handler no-op when stack_depth <= 1; replace no-ops on an empty stack.

## Synced commit
_None._
