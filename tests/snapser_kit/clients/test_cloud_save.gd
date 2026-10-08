extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitCloudSave: merge policy, type-faithful envelope, pull/push
## reconciliation across two simulated devices sharing one storage server,
## own-echo suppression, first-run merge, CAS conflicts, debounce.

const FakeTransport := preload("res://tests/snapser_kit/clients/fake_transport.gd")
const FakeStorageServer := preload("res://tests/snapser_kit/clients/fake_storage_server.gd")
const FakeSaveStore := preload("res://tests/snapser_kit/clients/fake_save_store.gd")
const FakeConfig := preload("res://tests/snapser_kit/clients/fake_config.gd")
const STATE_DIR := "user://snapkit_test_cloud_save"

var server: FakeStorageServer
var _n: int = 0


func before_each() -> void:
	server = FakeStorageServer.new()
	DirAccess.make_dir_recursive_absolute(STATE_DIR)
	_clean_state()


func after_each() -> void:
	_clean_state()


func _clean_state() -> void:
	var d := DirAccess.open(STATE_DIR)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)


## One simulated device: its own transport (same user), store and state file.
func _device(store: Object, debounce: float = 30.0) -> SnapKitCloudSave:
	var t: FakeTransport = add_node(FakeTransport.new())
	server.install(t)
	var cs: SnapKitCloudSave = add_node(SnapKitCloudSave.new())
	_n += 1
	cs.state_path = "%s/state_%d.json" % [STATE_DIR, _n]
	cs.debounce_s = debounce
	cs.setup(SnapKitStorage.new(t), store, FakeConfig.new())
	return cs


func _transport_of(cs: SnapKitCloudSave) -> FakeTransport:
	return cs.get("_storage").get("_transport")


func _remote() -> Dictionary:
	return SnapKitCloudSave.parse_envelope(server.value_of("user-1", "save_v1")).data


func _writes(cs: SnapKitCloudSave) -> int:
	var n := 0
	for c in _transport_of(cs).calls:
		if int(c.method) in [HTTPClient.METHOD_PUT, HTTPClient.METHOD_POST]:
			n += 1
	return n


# ---- pure ------------------------------------------------------------------

func test_default_merge() -> void:
	var local := {"a": 1, "b": [1, 2], "c": "x", "d": true, "l": 1, "n": 5}
	var remote := {"a": 3.5, "b": [2, 3], "c": "y", "d": false, "r": 2, "n": 3}
	var m := SnapKitCloudSave.default_merge(local, remote, true)
	check_eq(m.a, 3.5, "numbers: max")
	check_eq(m.n, 5, "numbers: max keeps int")
	check_eq(m.b, [1, 2, 3], "arrays: union, local order first")
	check_eq(m.c, "y", "else: newer (remote)")
	check_eq(m.d, true, "bool: OR (progress flag earned locally stays earned)")
	check(m.l == 1 and m.r == 2, "one-sided keys kept")
	m = SnapKitCloudSave.default_merge(local, remote, false)
	check_eq(m.c, "x", "else: newer (local)")
	check_eq(m.d, true, "bool: OR regardless of recency")
	check_eq(SnapKitCloudSave.default_merge({"f": false}, {"f": true}, false).f, true, "bool: remote-only true kept")
	check_eq(SnapKitCloudSave.default_merge({"f": false}, {"f": false}).f, false, "bool: both false")
	check_eq(SnapKitCloudSave.default_merge({"p": PackedInt32Array([1])}, {"p": PackedInt32Array([1, 4])}).p,
		PackedInt32Array([1, 4]), "packed arrays union")
	check_eq(local, {"a": 1, "b": [1, 2], "c": "x", "d": true, "l": 1, "n": 5}, "inputs untouched")


func test_envelope_is_type_faithful() -> void:
	var data := {"prog_level": 7, "prog_big": 9007199254740993, "prog_ratio": 0.5, "prog_whole": 2.0,
		"prog_list": [1, 2.0, "x"], "prog_pos": Vector2(1, 2), "prog_flag": true, "prog_name": "x",
		"prog_dict": {"k": 3}}
	var env := SnapKitCloudSave.make_envelope(data, 4, "dev", 1760000000)
	check_eq(env.version, 4, "version")
	check_eq(env.encoding, SnapKitCloudSave.ENCODING, "encoding marker")
	# Through JSON text, as on the wire.
	var back := SnapKitCloudSave.parse_envelope(SnapKitJson.parse(JSON.stringify(env)))
	check_eq(back.version, 4, "version back")
	check_eq(back.updated_at, 1760000000, "updated_at back")
	check_eq(back.device_id, "dev", "device back")
	var d: Dictionary = back.data
	check_eq(typeof(d.prog_level), TYPE_INT, "int stays int")
	check_eq(d.prog_level, 7, "int value")
	check_eq(d.prog_big, 9007199254740993, "int64 precision")
	check_eq(typeof(d.prog_whole), TYPE_FLOAT, "float stays float")
	check_eq(typeof(d.prog_list[0]), TYPE_INT, "nested int stays int")
	check_eq(d.prog_pos, Vector2(1, 2), "Vector2 survives")
	check_eq(typeof(d.prog_dict.k), TYPE_INT, "nested dict int")
	check_eq(SnapKitCloudSave.data_hash(d), SnapKitCloudSave.data_hash(data), "hash equal after round trip")


func test_plain_blob_and_hash_order() -> void:
	var legacy := SnapKitCloudSave.parse_envelope({"version": 1, "data": {"prog_a": 1}})
	check_eq(legacy.data, {"prog_a": 1}, "no encoding -> plain values")
	check_eq(SnapKitCloudSave.parse_envelope(null).data, {}, "null -> empty")
	check_eq(SnapKitCloudSave.data_hash({"a": 1, "b": 2}), SnapKitCloudSave.data_hash({"b": 2, "a": 1}), "order independent")
	check(SnapKitCloudSave.data_hash({"a": 1}) != SnapKitCloudSave.data_hash({"a": 1.0}), "type aware")


# ---- reconciliation ----------------------------------------------------------

func test_two_devices_round_trip_keeps_ints_and_ignores_echo() -> void:
	var store_a := FakeSaveStore.new()
	store_a.set_value("prog_level", 7)
	store_a.set_value("prog_coins", 120)
	store_a.set_value("set_volume", 0.8)
	var a := _device(store_a)
	var r: Dictionary = await a.pull()
	check(r.ok, "A first sync ok")
	check_eq(r.applied, SnapKitCloudSave.APPLIED_LOCAL, "A uploads its progress")
	check_eq(_remote(), {"prog_level": 7, "prog_coins": 120}, "only synced prefix uploaded")

	var store_b := FakeSaveStore.new()
	var b := _device(store_b, 0.05)
	r = await b.pull()
	check(r.ok, "B pull ok")
	check_eq(r.applied, SnapKitCloudSave.APPLIED_REMOTE, "B takes remote")
	check_eq(typeof(store_b.get_value("prog_level")), TYPE_INT, "pulled int is an int, not a float")
	check_eq(store_b.get_value("prog_level"), 7, "value")
	check_eq(store_b.import_calls, 1, "imported once")
	check(not b.is_dirty(), "import echo did not mark dirty")
	check((b.get("_timer") as Timer).is_stopped(), "import echo did not start the push debounce")
	check_eq(int(b.get("_state").get("local_changed_at", 0)), 0, "import echo is not a local change")
	await wait(0.2)
	check_eq(_writes(b), 0, "no push after a pull (echo suppressed)")
	r = await b.push()
	check(r.ok and bool(r.get("skipped", false)), "nothing to push")


func test_first_run_merges_preexisting_local_progress() -> void:
	server.put_raw("user-1", "save_v1",
		SnapKitCloudSave.make_envelope({"prog_level": 5, "prog_unlocks": [1, 2]}, 3, "other", 100))
	var store := FakeSaveStore.new()
	store.set_value("prog_level", 3)
	store.set_value("prog_unlocks", [2, 3])
	store.set_value("prog_tutorial_done", true)
	var cs := _device(store)
	var conflicts: Array = []
	cs.conflict.connect(func(l: Dictionary, rm: Dictionary) -> void: conflicts.append([l, rm]))
	var r: Dictionary = await cs.pull()
	check(r.ok, "ok")
	check_eq(r.applied, SnapKitCloudSave.APPLIED_MERGED, "merged, not discarded")
	check_eq(conflicts.size(), 1, "conflict signalled (notify only)")
	check_eq(store.get_value("prog_level"), 5, "max level")
	check_eq(store.get_value("prog_unlocks"), [2, 3, 1], "unlocks union")
	check_eq(store.get_value("prog_tutorial_done"), true, "local-only key kept")
	check_eq(_remote(), store.export_prefix("prog_"), "merged result pushed")
	check_eq(SnapKitCloudSave.parse_envelope(server.value_of("user-1", "save_v1")).version, 4, "revision bumped")


func test_identical_data_is_not_a_conflict() -> void:
	server.put_raw("user-1", "save_v1", SnapKitCloudSave.make_envelope({"prog_level": 2}, 1, "x", 1))
	var store := FakeSaveStore.new()
	store.set_value("prog_level", 2)
	var cs := _device(store)
	var conflicts: Array = []
	cs.conflict.connect(func(l: Dictionary, rm: Dictionary) -> void: conflicts.append(1))
	var r: Dictionary = await cs.pull()
	check_eq(r.applied, SnapKitCloudSave.APPLIED_NONE, "none")
	check_eq(conflicts.size(), 0, "no conflict")
	check_eq(_writes(cs), 0, "no write")


func test_remote_newer_local_untouched_takes_remote_including_deletes() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_a", 1)
	store.set_value("prog_b", 1)
	var cs := _device(store)
	await cs.pull()
	server.put_raw("user-1", "save_v1", SnapKitCloudSave.make_envelope({"prog_a": 9}, 5, "other", 200))
	var r: Dictionary = await cs.pull()
	check_eq(r.applied, SnapKitCloudSave.APPLIED_REMOTE, "remote")
	check_eq(store.get_value("prog_a"), 9, "updated")
	check(not store.data.has("prog_b"), "key removed on the other device is removed here")


func test_local_change_remote_untouched_pushes() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_a", 1)
	var cs := _device(store)
	await cs.pull()
	store.set_value("prog_a", 2)
	check(cs.is_dirty(), "change marks dirty")
	var r: Dictionary = await cs.pull()
	check_eq(r.applied, SnapKitCloudSave.APPLIED_LOCAL, "local pushed")
	check_eq(_remote().prog_a, 2, "server updated")
	check(not cs.is_dirty(), "clean after push")


func test_both_changed_uses_merge_hook() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_level", 1)
	store.set_value("prog_name", "local")
	var cs := _device(store)
	await cs.pull()
	server.put_raw("user-1", "save_v1",
		SnapKitCloudSave.make_envelope({"prog_level": 10, "prog_name": "remote"}, 9, "other", 1))
	store.set_value("prog_level", 8)
	var r: Dictionary = await cs.pull()
	check_eq(r.applied, SnapKitCloudSave.APPLIED_MERGED, "merged")
	check_eq(store.get_value("prog_level"), 10, "default merge: max")
	check_eq(store.get_value("prog_name"), "local", "older remote loses the non-numeric key")

	server.put_raw("user-1", "save_v1", SnapKitCloudSave.make_envelope({"prog_level": 50}, 20, "other", 1))
	store.set_value("prog_level", 11)
	cs.merge_func = func(l: Dictionary, _rm: Dictionary) -> Dictionary: return l
	r = await cs.pull()
	check_eq(r.applied, SnapKitCloudSave.APPLIED_MERGED, "merged via hook")
	check_eq(store.get_value("prog_level"), 11, "game hook decided (local wins)")
	check_eq(_remote().prog_level, 11, "hook result pushed")


func test_merge_hook_can_use_recency() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_name", "a")
	var cs := _device(store)
	await cs.pull()
	cs.merge_func = func(l: Dictionary, rm: Dictionary) -> Dictionary:
		return SnapKitCloudSave.default_merge(l, rm, cs.last_remote_is_newer)
	# Remote written "in the future" relative to the local change: remote newer.
	server.put_raw("user-1", "save_v1",
		SnapKitCloudSave.make_envelope({"prog_name": "remote"}, 5, "o", 4102444800))
	store.set_value("prog_name", "local")
	await cs.pull()
	check(cs.last_remote_is_newer, "remote newer")
	check_eq(store.get_value("prog_name"), "remote", "newer remote wins")
	# Remote stamped long ago: local newer.
	server.put_raw("user-1", "save_v1", SnapKitCloudSave.make_envelope({"prog_name": "old"}, 9, "o", 1))
	store.set_value("prog_name", "mine")
	await cs.pull()
	check(not cs.last_remote_is_newer, "local newer")
	check_eq(store.get_value("prog_name"), "mine", "newer local wins")


func test_push_cas_conflict_pull_merge_push() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_level", 1)
	store.set_value("prog_unlocks", [1])
	var cs := _device(store)
	await cs.pull()
	server.put_raw("user-1", "save_v1",
		SnapKitCloudSave.make_envelope({"prog_level": 4, "prog_unlocks": [9]}, 7, "other", 1))
	store.set_value("prog_unlocks", [1, 2])
	var r: Dictionary = await cs.push()
	check(r.ok, "resolved")
	check(r.conflict, "conflict reported")
	check_eq(r.applied, SnapKitCloudSave.APPLIED_MERGED, "pull-merge-push")
	check_eq(_remote(), {"prog_level": 4, "prog_unlocks": [1, 2, 9]}, "no silent overwrite")
	check_eq(store.export_prefix("prog_"), _remote(), "local matches server")


func test_debounced_push_and_prefix_filter() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_level", 1)
	var cs := _device(store, 0.05)
	await cs.pull()
	var writes := _writes(cs)
	store.set_value("set_volume", 0.1)
	check(not cs.is_dirty(), "non-synced key ignored")
	store.set_value("prog_level", 2)
	store.set_value("prog_level", 3)
	check_eq(_writes(cs), writes, "not pushed immediately")
	await wait(0.25)
	check_eq(_writes(cs), writes + 1, "one debounced push")
	check_eq(_remote().prog_level, 3, "latest value")
	check(not cs.is_dirty(), "clean")


func test_push_before_first_sync_pulls_first() -> void:
	server.put_raw("user-1", "save_v1", SnapKitCloudSave.make_envelope({"prog_level": 9}, 1, "o", 1))
	var store := FakeSaveStore.new()
	store.set_value("prog_level", 2)
	var cs := _device(store)
	var r: Dictionary = await cs.push()
	check(r.ok, "ok")
	check_eq(r.applied, SnapKitCloudSave.APPLIED_MERGED, "first push reconciles instead of overwriting")
	check_eq(_remote().prog_level, 9, "remote progress kept")


func test_serialized_operations() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_level", 1)
	var cs := _device(store)
	_transport_of(cs).frames = 3
	cs.pull()
	var r2: Dictionary = await cs.pull()
	check(r2.ok, "second ok")
	check_eq(r2.applied, SnapKitCloudSave.APPLIED_NONE, "second ran after the first finished")
	check_eq(SnapKitCloudSave.parse_envelope(server.value_of("user-1", "save_v1")).version, 1, "single upload")


func test_disabled_offline_and_failures() -> void:
	var cs := _device(null)
	var r: Dictionary = await cs.pull()
	check_eq(r.error, SnapKitTransport.ERR_DISABLED, "no store -> disabled")
	r = await cs.push()
	check_eq(r.error, SnapKitTransport.ERR_DISABLED, "push disabled")

	var store := FakeSaveStore.new()
	store.set_value("prog_level", 1)
	var off := _device(store)
	_transport_of(off).offline = true
	r = await off.pull()
	check_eq(r.error, "offline", "offline pull")
	check_eq(r.applied, SnapKitCloudSave.APPLIED_NONE, "nothing applied")
	check_eq(store.get_value("prog_level"), 1, "local untouched")

	var store2 := FakeSaveStore.new()
	store2.set_value("prog_level", 1)
	var cs2 := _device(store2)
	await cs2.pull()
	store2.set_value("prog_level", 2)
	server.fail_writes = 1
	r = await cs2.push()
	check(not r.ok, "server error surfaces")
	check_eq(r.error, "http_500", "http_500")
	check(cs2.is_dirty(), "still dirty for the next attempt")
	r = await cs2.push()
	check(r.ok, "retry succeeds")
	check_eq(_remote().prog_level, 2, "pushed")


func test_state_persists_device_id_and_cas() -> void:
	var store := FakeSaveStore.new()
	store.set_value("prog_level", 1)
	var cs := _device(store)
	await cs.pull()
	var dev := cs.device_id()
	check_eq(dev.length(), 16, "random device id")
	var again: SnapKitCloudSave = add_node(SnapKitCloudSave.new())
	again.state_path = cs.state_path
	again.setup(SnapKitStorage.new(_transport_of(cs)), store, FakeConfig.new())
	check_eq(again.device_id(), dev, "device id persisted")
	var r: Dictionary = await again.pull()
	check_eq(r.applied, SnapKitCloudSave.APPLIED_NONE, "restored CAS + hash: nothing to do")


## A store with exactly the amendment-6 surface: import_prefix(prefix, data),
## no optional `replace` argument (the live smoke store crashed the kit here).
class StrictStore extends RefCounted:
	signal changed(key: String)
	var data := {}
	func keys_with_prefix(prefix: String) -> PackedStringArray:
		return PackedStringArray(data.keys().filter(func(k: String) -> bool: return k.begins_with(prefix)))
	func export_prefix(prefix: String) -> Dictionary:
		var out := {}
		for k in data:
			if str(k).begins_with(prefix):
				out[k] = data[k]
		return out
	func import_prefix(_prefix: String, incoming: Dictionary) -> void:
		for k in incoming:
			data[k] = incoming[k]
			changed.emit(k)


func test_two_arg_import_prefix_store_is_supported() -> void:
	server.put_raw("user-1", "save_v1",
		SnapKitCloudSave.make_envelope({"prog_remote": 9}, 2, "other", 100))
	var store := StrictStore.new()
	store.data["prog_local"] = 1
	var cs := _device(store)
	var r: Dictionary = await cs.pull()
	check(r.ok, "pull ok")
	check_eq(r.applied, SnapKitCloudSave.APPLIED_MERGED, "merged")
	check_eq(store.data.get("prog_remote"), 9, "remote key imported through 2-arg import_prefix")
	check_eq(store.data.get("prog_local"), 1, "local key kept")


func test_applied_signal_lists_changed_keys() -> void:
	server.put_raw("user-1", "save_v1",
		SnapKitCloudSave.make_envelope({"prog_level": 5, "prog_new": true, "prog_same": 1}, 2, "other", 100))
	var store := FakeSaveStore.new()
	store.set_value("prog_level", 3)
	store.set_value("prog_same", 1)
	var cs := _device(store)
	var got := []
	cs.applied.connect(func(keys: PackedStringArray) -> void: got.append(keys))
	var r: Dictionary = await cs.pull()
	check(r.ok, "pull ok")
	check_eq(got, [PackedStringArray(["prog_level", "prog_new"])], "only changed keys, sorted")
	got.clear()
	r = await cs.pull()
	check_eq(got, [], "nothing imported -> no signal")


func test_changed_keys() -> void:
	check_eq(SnapKitCloudSave.changed_keys({"a": 1, "b": 2, "c": 3}, {"a": 1, "b": 5, "d": 1}),
		PackedStringArray(["b", "c", "d"]), "changed, removed, added")
	check_eq(SnapKitCloudSave.changed_keys({"a": 1}, {"a": 1.0}), PackedStringArray(["a"]), "type change counts")
	check_eq(SnapKitCloudSave.changed_keys({"c": 3}, {}, false), PackedStringArray(), "removals optional")
