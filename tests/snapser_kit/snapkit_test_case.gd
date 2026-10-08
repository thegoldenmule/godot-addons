extends RefCounted

## Base for snapser_kit test files. A test file is any
## res://tests/snapser_kit/**/test_*.gd that extends this script:
##
##   extends "res://tests/snapser_kit/snapkit_test_case.gd"
##   func test_parses_scores() -> void:
##       check_eq(SnapKitLeaderboards.parse_entries({...}).size(), 2, "two entries")
##
## Every method named test_* runs once, in declaration order; it may be a
## coroutine (await freely). before_each()/after_each() wrap each test.
## Nodes added with add_node() are freed after each test.
##
## Network rule: tests never reach the network. Build configs with
## SnapKitConfig.from_dict() (which ignores env / override) and route traffic to
## a SnapKitMockGateway.

## The running SceneTree (set by the runner).
var tree: SceneTree
## Failure messages for the current test (the runner reads and clears it).
var failures: PackedStringArray = PackedStringArray()

var _nodes: Array[Node] = []
var _mocks: Array = []


func before_each() -> void:
	pass


func after_each() -> void:
	pass


func check(cond: bool, label: String) -> void:
	if not cond:
		failures.append(label)


func check_eq(actual: Variant, expected: Variant, label: String) -> void:
	if typeof(actual) != typeof(expected) or actual != expected:
		failures.append("%s: expected %s (%s), got %s (%s)" % [label, var_to_str(expected),
			type_string(typeof(expected)), var_to_str(actual), type_string(typeof(actual))])


## Add a node under the tree root; it is freed after the current test.
func add_node(n: Node) -> Node:
	tree.root.add_child(n)
	_nodes.append(n)
	return n


## Wait `seconds` of real time (process frames keep running).
func wait(seconds: float) -> void:
	await tree.create_timer(seconds).timeout


## A fresh path for this test under the kit's sandbox root (never user://;
## the runner sets SnapKitConfig.data_root to a scratch dir). File removed if it
## exists.
func temp_path(file_name: String) -> String:
	var dir := SnapKitConfig.data_root.path_join("snapkit_tests")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var p := dir.path_join(file_name)
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	return p


## An online config pointing at a mock gateway (never a real host).
func mock_config(extra: Dictionary = {}) -> SnapKitConfig:
	var d := {"game_id": "kit_test", "gateway_url": "http://mock.invalid"}
	d.merge(extra, true)
	return SnapKitConfig.from_dict(d)


## Transport + auth wired to `mock`, added to the tree, session file in a temp
## path, retries without backoff. Returns {transport, auth}.
func mock_stack(mock: SnapKitMockGateway, cfg: SnapKitConfig = null) -> Dictionary:
	if cfg == null:
		cfg = mock_config()
	var transport := SnapKitTransport.new()
	var auth := SnapKitAuth.new()
	add_node(transport)
	add_node(auth)
	transport.setup(cfg, auth)
	auth.setup(cfg, transport)
	auth.session_path = temp_path("session_%d.json" % randi())
	transport.use_mock_gateway(track_mock(mock))
	transport.backoff_scale = 0.0
	return {"transport": transport, "auth": auth}


## Reset `mock` after the test (route lambdas that capture the mock form a
## reference cycle; reset() breaks it).
func track_mock(mock: SnapKitMockGateway) -> SnapKitMockGateway:
	_mocks.append(mock)
	return mock


## Called by the runner after after_each().
func _free_nodes() -> void:
	for m in _mocks:
		m.reset()
	_mocks.clear()
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
