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


## Called by the runner after after_each().
func _free_nodes() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
