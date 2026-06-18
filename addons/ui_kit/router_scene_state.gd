extends "res://addons/ui_kit/ui_state.gd"

## RouterSceneState — an optional UiState base for the common case of a route that
## loads a single scene, parents it under the router's content_root, and uses the
## shared cover/reveal fade for a hard cut on the way in and out.
##
## Construct with the scene path (and the router node), optionally a signal name
## the loaded scene emits to request a pop (e.g. "exited"). Subclass to override
## the lifecycle if you need to seed/read shared state around enter()/exit().
##
##     var s := RouterSceneState.new(UiRouter, "res://scenes/level.tscn", "exited")
##     UiRouter.push(s, {"level": 3})
##
## Part of the ui_kit addon (github.com/thegoldenmule/godot-addons).

var _router: Node
var _scene_path: String
var _exit_signal: String
var _scene: Node
var _label: String


func _init(router: Node, scene_path: String, exit_signal: String = "", label: String = "SceneState") -> void:
	_router = router
	_scene_path = scene_path
	_exit_signal = exit_signal
	_label = label


func enter(params: Dictionary) -> void:
	on_enter(params)
	_scene = load(_scene_path).instantiate()
	_router.content_root.add_child(_scene)
	if _exit_signal != "" and _scene.has_signal(_exit_signal):
		_scene.connect(_exit_signal, _on_exit_requested)
	await Engine.get_main_loop().process_frame
	await _router.reveal()


func exit() -> void:
	await _router.cover()
	if is_instance_valid(_scene):
		_scene.queue_free()
	on_exit()


## A hook for subclasses to seed shared state from `params` before the scene loads.
func on_enter(_params: Dictionary) -> void:
	pass

## A hook for subclasses to capture results after the scene is torn down.
func on_exit() -> void:
	pass


func _on_exit_requested(_result = null) -> void:
	_router.pop()


func state_name() -> String:
	return _label
