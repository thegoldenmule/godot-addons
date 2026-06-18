extends Node

## UiDriver — semantic UI/navigation command layer for LLM/automation control.
##
## Drives the *shell*: navigate to any screen by name, press any registered control
## by stable id, and run deterministic ordered sequences — all via an eval hook
## (e.g. the godot-ai MCP `game_eval` command):
##
##     return UiDriver.state()
##     return UiDriver.actions()                      # every pressable id on this screen
##     return await UiDriver.goto("settings")         # awaited — returns when it's live
##     return UiDriver.press("settings.avatar")
##     return await UiDriver.run(["goto:settings", "press:settings.avatar",
##                            {set="settings.music", to=0.3}, "flow:open_store"])
##
## WHY IT'S DETERMINISTIC: the navigation layer (UiRouter) is an async stack-FSM
## whose push/pop await their lifecycle hooks + the cover/reveal fades — so
## `await goto(...)` returns only once the destination screen is actually live.
##
## GENERIC BY DESIGN: this script knows NO game-specific screens, modes, or flows.
## Everything game-specific is supplied by the host — a node in the "ui_nav_host"
## group (typically your app shell) implementing the UiNavHost contract below. The
## driver only provides the *mechanism* (live-tree catalog, control invocation,
## the step/flow runner, async settle); the host provides the *content*.
##
## CONTROL IDS come from UiReg (ui_reg.gd): screens build/adopt their actionable
## controls through it, which records each on the live tree. UiDriver walks that
## live tree to build its catalog — self-cleaning, no central state.
##
## ── UiNavHost contract (all but the first three are optional) ──────────────────
##   mcp_select_tab(id) -> bool          select a shell tab
##   mcp_current_tab_id() -> String      the active tab id
##   mcp_start_match(cfg) -> void        launch a mode/overlay (push a router state)
##   mcp_nav_tabs() -> Array             selectable tab ids        (default: [])
##   mcp_nav_modes() -> Array            launchable mode ids       (default: [])
##   mcp_mode_cfg(id) -> Dictionary      cfg passed to start_match (default: {"mode": id})
##   mcp_target_active(id) -> bool       is this goto target already current? (default: false)
##   mcp_exit_to_shell() -> awaitable    pop any overlay/match back to the shell
##   mcp_route_label(state_name)->String map a router state name to a label
##   mcp_wait_ready(target) -> awaitable post-navigation readiness wait
##   mcp_match_ready() -> bool           is gameplay interactable?
##   mcp_flows() -> Array                flow catalog [{name, params, summary}]
##   mcp_expand_flow(name, params)       expand a flow to run() steps, or null
##   mcp_step(verb, arg) -> Dictionary   handle a custom run() step verb (e.g. "swipe")

const UiReg := preload("res://addons/ui_kit/ui_reg.gd")

const HOST_GROUP := "ui_nav_host"
const ROUTER_GROUP := "ui_router"

const NOT_READY := {"ok": false, "reason": "not_ready",
	"message": "shell not live — mount a UI host (a node in the 'ui_nav_host' group) first"}


# ── host / router resolution ──────────────────────────────────────────────────
# Resolved by group (not a global identifier) so the driver works regardless of
# the autoload names the consuming project chose, and runs even in a hand-built
# headless tree.

func _router() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group(ROUTER_GROUP)

## The live UI host (navigation hub), or null when the shell isn't mounted.
func _host():
	var tree := get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group(HOST_GROUP)


# ── host capability accessors (each with a generic fallback) ──────────────────

func _nav_tabs(host) -> Array:
	return host.mcp_nav_tabs() if host != null and host.has_method("mcp_nav_tabs") else []

func _nav_modes(host) -> Array:
	return host.mcp_nav_modes() if host != null and host.has_method("mcp_nav_modes") else []

func _mode_cfg(host, t: String) -> Dictionary:
	if host != null and host.has_method("mcp_mode_cfg"):
		return host.mcp_mode_cfg(t)
	return {"mode": t}

func _target_active(host, t: String) -> bool:
	return host != null and host.has_method("mcp_target_active") and bool(host.mcp_target_active(t))

func _route_label(name: String) -> String:
	var host = _host()
	if host != null and host.has_method("mcp_route_label"):
		return str(host.mcp_route_label(name))
	return name.trim_suffix("State").to_lower()

func _overlay_active() -> bool:
	var r := _router()
	return r != null and r.stack_depth() > 1

## The label of the top overlay (match/map/…), or "" when on the base shell.
func _overlay_label() -> String:
	var r := _router()
	if r == null or r.stack_depth() <= 1:
		return ""
	var top = r.top()
	return _route_label(top.state_name()) if top != null else ""


# ── readiness / situational reads ─────────────────────────────────────────────

## True when a navigation host is mounted (the analog of "the menu is up").
func is_ready() -> bool:
	return _host() != null

## The single situational read: where am I, what's on top, is a transition running.
func state() -> Dictionary:
	var host = _host()
	if host == null:
		return NOT_READY
	var router := _router()
	var route: Array = []
	if router != null:
		for n in router.route_names():
			route.append(_route_label(str(n)))
	var route_set := {}
	for r in route:
		route_set[r] = true
	var tab := str(host.mcp_current_tab_id()) if host.has_method("mcp_current_tab_id") else ""
	var active := _active_screen_ids()
	# A modal is any visible registered screen that is neither the current tab nor
	# one of the router-state screens — data-driven, no hardcoded modal names.
	var modals: Array = []
	for id in active:
		if id == tab or route_set.has(id):
			continue
		modals.append(id)
	var overlay := _overlay_label()
	return {
		"ok": true,
		"busy": router != null and router.is_busy(),
		"route": route,
		"route_depth": router.stack_depth() if router != null else 0,
		"tab": tab,
		"screen": overlay if overlay != "" else tab,
		"modal": modals[0] if not modals.is_empty() else "",
		"modals": modals,
		"match_ready": bool(host.mcp_match_ready()) if host.has_method("mcp_match_ready") else (overlay != ""),
	}

## The static catalog of goto() targets (sourced from the host).
func screens() -> Dictionary:
	var host = _host()
	return {
		"tabs": _nav_tabs(host),
		"modes": _nav_modes(host),
		"surfaces": ["shell", "back", "match"],
		"note": "goto(tab) selects a tab; goto(mode) launches it; goto('shell'/'back') returns to the shell.",
	}


# ── the live-tree registry walk ───────────────────────────────────────────────

## Every registered control, as {full_id: control}. A control belongs to its
## NEAREST screen-root ancestor, so a nested modal forms its own screen.
func _catalog() -> Dictionary:
	var out := {}
	var tree := get_tree()
	if tree == null:
		return out
	for c in tree.get_nodes_in_group(UiReg.CONTROL_GROUP):
		if not (c is Control) or not c.has_meta(UiReg.META_ID):
			continue
		var screen := _nearest_screen_id(c)
		if screen == "":
			continue
		out["%s.%s" % [screen, str(c.get_meta(UiReg.META_ID))]] = c
	return out

func _nearest_screen_id(node: Node) -> String:
	var n: Node = node.get_parent()
	while n != null:
		if n.has_meta(UiReg.META_SCREEN):
			return str(n.get_meta(UiReg.META_SCREEN))
		n = n.get_parent()
	return ""

## Screen ids whose root is currently visible in the tree.
func _active_screen_ids() -> Array:
	var ids: Array = []
	var tree := get_tree()
	if tree == null:
		return ids
	for root in tree.get_nodes_in_group(UiReg.GROUP):
		if root.has_meta(UiReg.META_SCREEN) and _visible(root):
			ids.append(str(root.get_meta(UiReg.META_SCREEN)))
	return ids

## Visible accounting for BOTH Control and CanvasLayer ancestors (a Control under a
## hidden CanvasLayer still reports is_visible_in_tree()==true, since a CanvasLayer
## breaks the CanvasItem chain).
func _visible(node: Node) -> bool:
	if node == null or not node.is_inside_tree():
		return false
	var n: Node = node
	while n != null:
		if n is CanvasItem and not (n as CanvasItem).visible:
			return false
		if n is CanvasLayer and not (n as CanvasLayer).visible:
			return false
		n = n.get_parent()
	return true


# ── actions(): the discovery surface ──────────────────────────────────────────

## Every pressable thing on the live screen(s), by stable id. Filtered to
## visible+in-tree unless `all`. Each: {id, kind, enabled, + value/on/text}.
func actions(all: bool = false) -> Array:
	var out: Array = []
	var cat := _catalog()
	var ids := cat.keys()
	ids.sort()
	for id in ids:
		var c: Control = cat[id]
		if not all and not _visible(c):
			continue
		out.append(_describe(id, c))
	return out

func _describe(id: String, c: Control) -> Dictionary:
	var kind := _kind(c)
	var info := {"id": id, "kind": kind, "enabled": not _disabled(c), "visible": _visible(c)}
	match kind:
		"slider":
			info["value"] = (c as Range).value
		"toggle":
			info["on"] = (c as BaseButton).button_pressed
		"text":
			info["text"] = (c as LineEdit).text
		_:
			if _has_prop(c, "text"):
				info["text"] = str(c.get("text"))
	return info

func _kind(c: Control) -> String:
	if c is Range:
		return "slider"
	if c is CheckButton or c is CheckBox:
		return "toggle"
	if c is LineEdit:
		return "text"
	if c is TextureButton:
		return "texture_button"
	if c is BaseButton:
		return "button"
	return "control"

func _disabled(c: Control) -> bool:
	if c is BaseButton:
		return (c as BaseButton).disabled
	if c is Range:
		return not (c as Range).editable
	if c is LineEdit:
		return not (c as LineEdit).editable
	return false

func _has_prop(o: Object, prop: String) -> bool:
	for p in o.get_property_list():
		if p.get("name", "") == prop:
			return true
	return false


# ── navigation (awaited) ──────────────────────────────────────────────────────

## Navigate to any screen by name, fully awaited. Tabs + modes (from the host),
## and the generic surfaces "shell"/"back"/"match". Returns state().
func goto(target: String) -> Dictionary:
	var host = _host()
	if host == null:
		return NOT_READY
	var t := target.to_lower()
	await _settle()

	var tabs := _nav_tabs(host)
	var modes := _nav_modes(host)

	# Validate BEFORE any side effect: an unknown target must leave the UI
	# untouched (exiting an overlay below would tear down its result state).
	var known := t == "shell" or t == "back" or t == "match" or tabs.has(t) or modes.has(t)
	if not known:
		return {"ok": false, "reason": "unknown_target",
			"message": "unknown screen '%s'; see screens()" % target}

	# Already where we want to be (host decides: tab selected / overlay shown).
	if _target_active(host, t):
		if host.has_method("mcp_wait_ready"):
			await host.mcp_wait_ready(t)
		return state()

	# Leave any active overlay/match before navigating elsewhere.
	if _overlay_active() and t != "match":
		await _exit_to_shell()

	if t == "match":
		if not _overlay_active():
			return {"ok": false, "reason": "no_mode",
				"message": "goto('match') needs an active match; start one with a mode (see screens())"}
		return state()

	if t == "shell" or t == "back":
		return state()

	if tabs.has(t):
		host.mcp_select_tab(t)
		await _settle()
		return state()

	# A mode/surface launched via the host (pushes a router state).
	host.mcp_start_match(_mode_cfg(host, t))
	await _settle()
	if host.has_method("mcp_wait_ready"):
		await host.mcp_wait_ready(t)
	return state()

## Pop any active overlay/match back to the shell, awaited.
func _exit_to_shell() -> void:
	var host = _host()
	if host != null and host.has_method("mcp_exit_to_shell"):
		await host.mcp_exit_to_shell()
		await _settle()
		return
	# Generic fallback: pop the router stack down to the base shell.
	var r := _router()
	while r != null and r.stack_depth() > 1 and not r.is_busy():
		r.pop()
		await _settle()


# ── control invocation ────────────────────────────────────────────────────────

## Activate a button/toggle/texture-button by id. NOTE: this does not await router
## transitions (a launcher push, a match exit) — use goto()/run() for those.
func press(id: String, force: bool = false) -> Dictionary:
	var c = _resolve(id)
	if c == null:
		return _unknown(id)
	if _disabled(c) and not force:
		return {"ok": false, "reason": "disabled", "id": id}
	if c is BaseButton:
		if (c as BaseButton).toggle_mode:
			(c as BaseButton).button_pressed = true
		c.emit_signal("pressed")
		return {"ok": true, "status": "pressed", "id": id, "visible": _visible(c)}
	return {"ok": false, "reason": "not_pressable", "id": id,
		"message": "kind=%s — use set_value/set_text/toggle" % _kind(c)}

## Set a toggle (CheckButton/CheckBox) on/off by id.
func toggle(id: String, on: bool = true) -> Dictionary:
	var c = _resolve(id)
	if c == null:
		return _unknown(id)
	if not (c is BaseButton) or not (c as BaseButton).toggle_mode:
		return {"ok": false, "reason": "not_toggle", "id": id}
	(c as BaseButton).button_pressed = on
	return {"ok": true, "status": "toggled", "id": id, "on": on}

## Set a slider (Range) value by id.
func set_value(id: String, value: float) -> Dictionary:
	var c = _resolve(id)
	if c == null:
		return _unknown(id)
	if not (c is Range):
		return {"ok": false, "reason": "not_a_slider", "id": id}
	(c as Range).value = value
	return {"ok": true, "status": "set", "id": id, "value": (c as Range).value}

## Set a text field (LineEdit) by id; optionally submit (fires text_submitted).
func set_text(id: String, text: String, submit: bool = false) -> Dictionary:
	var c = _resolve(id)
	if c == null:
		return _unknown(id)
	if not (c is LineEdit):
		return {"ok": false, "reason": "not_a_text_field", "id": id}
	(c as LineEdit).text = text
	if submit:
		c.emit_signal("text_submitted", text)
	return {"ok": true, "status": "text_set", "id": id, "text": text, "submitted": submit}

func _resolve(id: String):
	return _catalog().get(id, null)

func _unknown(id: String) -> Dictionary:
	return {"ok": false, "reason": "unknown_id", "id": id,
		"message": "no control '%s'; see actions()" % id}


# ── sequences ─────────────────────────────────────────────────────────────────

## Run an ordered list of steps, awaiting each. A step is a string ("goto:settings",
## "press:home.story", "exit", "wait:0.5", "flow:open_store") or a dict ({goto=},
## {press=}, {set=,to=}, {text=,to=,submit=}, {toggle=,on=}, {wait=}, {flow=,params=}).
## Any other verb is handed to the host's mcp_step (e.g. "swipe:up"). Returns a
## per-step trace; stops on first error unless opts.continue_on_error.
func run(steps: Array, opts: Dictionary = {}) -> Array:
	var trace: Array = []
	var cont := bool(opts.get("continue_on_error", false))
	for step in steps:
		var r: Dictionary = await _do_step(step)
		var st := state()
		r["screen_after"] = str(st.get("screen", "")) if st.get("ok", false) else "?"
		trace.append(r)
		if not bool(r.get("ok", false)) and not cont:
			break
	return trace

func _do_step(step) -> Dictionary:
	if step is String:
		return await _do_string_step(step)
	if step is Dictionary:
		return await _do_dict_step(step)
	return {"ok": false, "step": step, "error": "bad_step_type"}

func _do_string_step(s: String) -> Dictionary:
	var verb := s
	var arg := ""
	var ci := s.find(":")
	if ci >= 0:
		verb = s.substr(0, ci)
		arg = s.substr(ci + 1)
	match verb:
		"goto", "tab", "start":
			var r := await goto(arg)
			return _wrap(s, r)
		"exit":
			var r := await goto("shell")
			return _wrap(s, r)
		"press":
			var r := press(arg)
			await _settle()  # covers a launcher push (goes busy synchronously)
			return _wrap(s, r)
		"toggle":
			return _wrap(s, toggle(arg, true))
		"wait":
			await _wait_seconds(float(arg) if arg != "" else 0.0)
			return {"ok": true, "step": s}
		"flow":
			var sub := await flow(arg)
			return {"ok": _all_ok(sub), "step": s, "sub": sub}
		_:
			return _host_step(s, verb, arg)

func _do_dict_step(d: Dictionary) -> Dictionary:
	if d.has("goto"):
		return _wrap(d, await goto(str(d["goto"])))
	if d.has("press"):
		var r := press(str(d["press"]), bool(d.get("force", false)))
		await _settle()
		return _wrap(d, r)
	if d.has("set"):
		return _wrap(d, set_value(str(d["set"]), float(d.get("to", 0.0))))
	if d.has("text"):
		return _wrap(d, set_text(str(d["text"]), str(d.get("to", "")), bool(d.get("submit", false))))
	if d.has("toggle"):
		return _wrap(d, toggle(str(d["toggle"]), bool(d.get("on", true))))
	if d.has("wait"):
		await _wait_seconds(float(d["wait"]))
		return {"ok": true, "step": d}
	if d.has("flow"):
		var sub := await flow(str(d["flow"]), d.get("params", {}))
		return {"ok": _all_ok(sub), "step": d, "sub": sub}
	if d.has("step"):
		return _wrap(d, _host_step_call(str(d["step"]), d.get("arg", "")))
	# A single-key custom verb dict, e.g. {"swipe": "up"} -> host.mcp_step.
	if d.size() == 1:
		var k = d.keys()[0]
		return _wrap(d, _host_step_call(str(k), d[k]))
	return {"ok": false, "step": d, "error": "unknown_dict_step"}

## Hand an unrecognized verb to the host (custom gameplay steps like "swipe").
func _host_step(step, verb: String, arg) -> Dictionary:
	var host = _host()
	if host != null and host.has_method("mcp_step"):
		var res: Dictionary = host.mcp_step(verb, arg)
		return {"ok": bool(res.get("ok", false)), "step": step, "result": res}
	return {"ok": false, "step": step, "error": "unknown_verb: %s" % verb}

func _host_step_call(verb: String, arg) -> Dictionary:
	var host = _host()
	if host != null and host.has_method("mcp_step"):
		return host.mcp_step(verb, arg)
	return {"ok": false, "reason": "no_host_step", "verb": verb}

func _wrap(step, result: Dictionary) -> Dictionary:
	return {"ok": bool(result.get("ok", false)), "step": step, "result": result}

func _all_ok(trace: Array) -> bool:
	for r in trace:
		if not bool(r.get("ok", false)):
			return false
	return true


# ── named flows (sourced from the host) ───────────────────────────────────────

## The catalog of named flows — the discovery surface for flow(), as screens() is
## for goto() and actions() is for press(). Each entry: {name, params, summary,
## steps} where `steps` is the expansion with default/empty params (a shape
## preview); pass the listed params to flow(name, params).
func flows() -> Array:
	var host = _host()
	if host == null or not host.has_method("mcp_flows"):
		return []
	var out: Array = []
	for f in host.mcp_flows():
		out.append({
			"name": f["name"],
			"params": f.get("params", []),
			"summary": f.get("summary", ""),
			"steps": _expand_flow(str(f["name"]), {}),
		})
	return out

## Expand + run a named flow (see flows()). Returns the run() trace.
func flow(name: String, params: Dictionary = {}) -> Array:
	var steps = _expand_flow(name, params)
	if steps == null:
		return [{"ok": false, "error": "unknown_flow: %s" % name}]
	return await run(steps)

func _expand_flow(name: String, params: Dictionary):
	var host = _host()
	if host != null and host.has_method("mcp_expand_flow"):
		return host.mcp_expand_flow(name, params)
	return null


# ── async helpers ─────────────────────────────────────────────────────────────

## Yield frames while the router is mid-transition (it no-ops calls while busy).
func _settle() -> void:
	var tree := get_tree()
	if tree == null:
		return
	await tree.process_frame
	var router := _router()
	while router != null and router.is_busy():
		await tree.process_frame

## Await frames until cond() is true or `timeout` seconds elapse.
func _wait_until(cond: Callable, timeout: float) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var waited := 0.0
	while not bool(cond.call()) and waited < timeout:
		await tree.process_frame
		waited += tree.root.get_process_delta_time() if tree.root else 0.016

func _wait_seconds(secs: float) -> void:
	var tree := get_tree()
	if tree == null or secs <= 0.0:
		return
	await tree.create_timer(secs).timeout


# ── utility ───────────────────────────────────────────────────────────────────

func help() -> String:
	var host = _host()
	var flow_names: Array = []
	if host != null and host.has_method("mcp_flows"):
		for f in host.mcp_flows():
			flow_names.append(str(f["name"]))
	return """UiDriver — semantic UI/navigation control (call via an eval hook).
  reads     : state() screens() actions(all=false) flows() is_ready()
  navigate  : await goto(target)   # tabs: %s ; modes: %s ; or 'shell'/'back'
  controls  : press(id) toggle(id,on) set_value(id,v) set_text(id,s,submit=false)
  sequence  : await run([steps], opts)  # \"goto:settings\" \"press:home.story\" \"exit\" \"wait:0.5\" \"flow:name\" / {set=\"settings.music\",to=0.3}
  flows     : await flow(name, params)  # catalog via flows(): %s
  custom    : any other step verb is handed to the host's mcp_step (e.g. \"swipe:up\")""" % [str(_nav_tabs(host)), str(_nav_modes(host)), " ".join(flow_names)]
