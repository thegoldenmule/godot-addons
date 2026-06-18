extends Node
## UiRouter (autoload): a stack-based UI state machine. The stack IS the navigation
## history; Back = pop. Transitions are serialized behind _busy, and every lifecycle
## hook (enter/exit/suspend/resume) is awaited, so a state can run an async
## transition before the router proceeds.
##
##   [ShellState]                     -> on the shell (Home / other tabs)
##   [ShellState, MatchState]         -> in a match (shell suspended, nav hidden)
##   [ShellState, MatchState, Modal]  -> a dialog over a match
##
## Part of the ui_kit addon (github.com/thegoldenmule/godot-addons). Declare it as
## an autoload (any name; "UiRouter" by convention) pointing at this script. It
## joins the "ui_router" group so the UiDriver can find it without depending on the
## autoload name.

signal changed(top)

const ROUTER_GROUP := "ui_router"

var _stack: Array = []
var _busy: bool = false

## States parent their screens into this CanvasLayer — kept off the boot scene's
## current_scene. The match's own CanvasLayers + the cover overlay sit above it.
var content_root: CanvasLayer


func _ready() -> void:
	add_to_group(ROUTER_GROUP)
	content_root = CanvasLayer.new()
	content_root.name = "RouterContent"
	content_root.layer = 1
	add_child(content_root)
	# Own the Android/system Back button: route it through the stack instead of
	# letting it quit the app outright.
	get_tree().set_quit_on_go_back(false)


## Android system Back (NOTIFICATION_WM_GO_BACK_REQUEST): pop one level, or quit
## when already at the root (the shell). Distinct from ESC, which gameplay code may
## use to cancel its own interactions.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if _busy:
			return
		if _stack.size() > 1:
			pop()
		else:
			get_tree().quit()


func top():
	return _stack.back() if not _stack.is_empty() else null


func is_busy() -> bool:
	return _busy


func stack_depth() -> int:
	return _stack.size()


## The state names from the bottom of the stack up (e.g. ["ShellState", "MatchState"]).
## The UiDriver maps these to its route summary.
func route_names() -> Array:
	var names: Array = []
	for s in _stack:
		names.append(s.state_name())
	return names


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


func pop() -> void:
	if _busy or _stack.size() <= 1:
		return
	_busy = true
	var leaving = _stack.pop_back()
	await leaving.exit()
	var t = top()
	if t != null:
		await t.resume()
	changed.emit(t)
	_busy = false


func replace(state, params: Dictionary = {}) -> void:
	if _busy or _stack.is_empty():
		return
	_busy = true
	var leaving = _stack.pop_back()
	await leaving.exit()
	_stack.push_back(state)
	await state.enter(params)
	changed.emit(state)
	_busy = false


func reset(state, params: Dictionary = {}) -> void:
	if _busy:
		return
	_busy = true
	while not _stack.is_empty():
		await _stack.pop_back().exit()
	_stack.push_back(state)
	await state.enter(params)
	changed.emit(state)
	_busy = false


# ── shared cover/reveal fade for hard cuts (match load/unload) ──────────────────
# On its own CanvasLayer ABOVE the match's countdown/glitch overlays (layer=100).
var _fade_layer: CanvasLayer
var _fade: ColorRect


func _ensure_fade() -> void:
	if _fade != null and is_instance_valid(_fade):
		return
	_fade_layer = CanvasLayer.new()
	_fade_layer.name = "RouterFade"
	_fade_layer.layer = 200
	add_child(_fade_layer)
	_fade = ColorRect.new()
	_fade.color = Color.BLACK
	_fade.modulate.a = 0.0
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade_layer.add_child(_fade)


## Fade to black (and swallow input) — call before a hard swap. Awaited.
func cover(duration: float = 0.18) -> void:
	_ensure_fade()
	_fade.mouse_filter = Control.MOUSE_FILTER_STOP
	var t := create_tween()
	t.tween_property(_fade, "modulate:a", 1.0, duration)
	await t.finished


## Fade back from black. Awaited.
func reveal(duration: float = 0.18) -> void:
	_ensure_fade()
	var t := create_tween()
	t.tween_property(_fade, "modulate:a", 0.0, duration)
	await t.finished
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
