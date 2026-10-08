class_name SnapKitCloudSave
extends Node

## Local-first cloud save: mirrors the game's synced local keys to ONE private
## Storage json-blob per user (plan 02 §2.3 "Cloud-save model").
##
## Local store: a SaveService-style object (duck-typed — the kit does not depend
## on Hypercasual-Shared), the device's source of truth. Expected surface:
##   keys_with_prefix(prefix: String) -> PackedStringArray
##   export_prefix(prefix: String) -> Dictionary          # {full_key: value}
##   import_prefix(prefix: String, values: Dictionary, replace := false)
##   signal changed(key: String)                          # optional
## export_prefix / import_prefix are required (is_enabled() checks has_method);
## without the `changed` signal, cloud save still works but only pushes when
## asked (push(), pause / focus-out) — there is no debounce trigger.
## Only keys under SnapKitConfig.cloud_save_prefixes() are synced (e.g.
## "sax_prog_"); everything else (settings) stays local.
##
## Blob (key = SnapKitConfig.cloud_save_blob_key(), default "save_v1", access
## private):
##   {"format": 1, "encoding": "godot_native", "version": int (revision, +1 per
##    push), "updated_at": int (unix s), "device_id": String,
##    "data": {full_key: JSON.from_native(value)}}
## Values are TYPE-FAITHFUL: each one is encoded with JSON.from_native() and
## decoded with JSON.to_native(), so an int stays an int (a plain JSON round trip
## would turn it into a float), int64 keeps full precision, and Vector2 etc.
## survive. A blob without "encoding" is read as plain JSON values.
##
## Behaviour:
##   - pull() (the service calls it on start): fetch the blob and reconcile.
##       remote unchanged since last sync, local unchanged  -> "none"
##       remote unchanged, local changed                    -> push   -> "local"
##       remote changed, local unchanged                    -> import -> "remote"
##       both changed (incl. FIRST sync with pre-existing local progress, e.g.
##       TestFlight testers from before Snapser)            -> emit conflict(local,
##           remote) (notify-only), merged = merge_func(local, remote) (default
##           default_merge), import merged, push it          -> "merged"
##       no blob yet: push local if any                      -> "local" / "none"
##     "Changed" is tracked with the last-seen CAS token (remote) and a hash of
##     the synced keys at the last sync (local). Identical data on both sides is
##     never a conflict.
##   - push() is debounced: debounce_s (DEBOUNCE_S) after the last local change,
##     and forced on NOTIFICATION_APPLICATION_PAUSED / FOCUS_OUT /
##     WM_CLOSE_REQUEST. It skips the request when nothing changed since the last
##     sync, and uses SnapKitStorage.put_json_blob_cas() with the last-seen CAS; a
##     CAS conflict triggers pull-merge-push (at most MAX_CAS_ATTEMPTS). A push
##     before the first successful sync runs a pull instead (first-run rule).
##   - Own-echo suppression: import_prefix() emits changed(key) for every key it
##     writes; those are ignored while importing, so a pull never schedules a
##     push.
##   - pull() / push() are serialized (one at a time); concurrent callers wait.
##   - default_merge(): per key — numbers take max, arrays take union, anything
##     else takes the newer side's value (by updated_at vs the last local change).
##   - Sync bookkeeping (last CAS, revision, synced hash, last local change,
##     device id) persists at state_path (STATE_PATH).
##   - Offline: pull()/push() return the transport's {ok:false, error:"offline"};
##     local play is unaffected and the next pause / change retries.
##
## A Node because it owns the debounce Timer and receives app lifecycle
## notifications; SnapKitService adds it as a child.

## Both sides changed since the last sync. Informational; resolution is
## merge_func (SnapKitService wires it to its overridable _merge()).
signal conflict(local: Dictionary, remote: Dictionary)
## A pull or push completed successfully. direction: "pull" | "push".
signal synced(direction: String)
signal _idle

const DEBOUNCE_S := 10.0
const BLOB_FORMAT_VERSION := 1
const STATE_PATH := "user://snapser_kit_cloud_save.json"
const DEFAULT_BLOB_KEY := "save_v1"
const ENCODING := "godot_native"
const MAX_CAS_ATTEMPTS := 3

const APPLIED_NONE := "none"
const APPLIED_LOCAL := "local"
const APPLIED_REMOTE := "remote"
const APPLIED_MERGED := "merged"

## func(local: Dictionary, remote: Dictionary) -> Dictionary over the `data`
## maps. An invalid/empty Callable (or a non-Dictionary return) means
## default_merge.
var merge_func: Callable
## Seconds of quiet after the last local change before an automatic push.
var debounce_s: float = DEBOUNCE_S
## Where sync bookkeeping persists (tests point it at a scratch file).
var state_path: String = STATE_PATH
## Storage access type of the blob.
var access: String = SnapKitStorage.ACCESS_PRIVATE
## Set just before merge_func is called: true when the remote blob's updated_at
## is at or after the last local change. A merge_func that wants the default
## policy should call default_merge(local, remote, last_remote_is_newer).
var last_remote_is_newer: bool = true

var _storage: SnapKitStorage
var _store: Object
var _config: SnapKitConfig
var _state: Dictionary = {}
var _timer: Timer
var _busy: bool = false
var _importing: bool = false
var _dirty: bool = false


## Wire dependencies. store may be null (cloud save then reports "disabled").
func setup(storage: SnapKitStorage, store: Object, config: SnapKitConfig) -> void:
	if _store != null and _store.has_signal("changed") and _store.is_connected("changed", _on_store_changed):
		_store.disconnect("changed", _on_store_changed)
	_storage = storage
	_store = store
	_config = config
	if _store != null and _store.has_signal("changed"):
		_store.connect("changed", _on_store_changed)
	_load_state()
	if _timer == null:
		_timer = Timer.new()
		_timer.name = "PushDebounce"
		_timer.one_shot = true
		_timer.timeout.connect(_on_debounce)
		add_child(_timer)


## True when storage and a store with export_prefix/import_prefix are wired and
## the config lists at least one sync prefix.
func is_enabled() -> bool:
	return _storage != null and _store != null and _store.has_method("export_prefix") \
		and _store.has_method("import_prefix") and not sync_prefixes().is_empty()


func sync_prefixes() -> PackedStringArray:
	return _config.cloud_save_prefixes() if _config != null else PackedStringArray()


func blob_key() -> String:
	var k := _config.cloud_save_blob_key() if _config != null else ""
	return k if k != "" else DEFAULT_BLOB_KEY


## True when a local change has not been pushed yet.
func is_dirty() -> bool:
	return _dirty


## This install's random device id (persisted).
func device_id() -> String:
	return str(_state.get("device_id", ""))


## Fetch the remote blob and reconcile with local (see class doc). COROUTINE.
## -> {ok, status, json, error, applied:String ("remote"|"local"|"merged"|"none")}
func pull() -> Dictionary:
	if not is_enabled():
		return _disabled({"applied": APPLIED_NONE})
	await _lock()
	var res: Dictionary = await _pull_locked(0)
	_unlock()
	return res


## Upload the current local synced keys with CAS. COROUTINE.
## -> {ok, status, json, error, conflict:bool, skipped?:bool, applied?:String}
## conflict is true when a CAS conflict was met (and resolved by a merge, when ok).
func push() -> Dictionary:
	if not is_enabled():
		return _disabled({"conflict": false})
	if _timer != null:
		_timer.stop()
	await _lock()
	var res: Dictionary
	var local := export_local()
	if not bool(_state.get("has_synced", false)):
		res = await _pull_locked(0)
	elif data_hash(local) == str(_state.get("synced_hash", "")):
		res = SnapKitTransport.ok_result()
		res["skipped"] = true
		_dirty = false
	else:
		res = await _push_locked(local, str(_state.get("cas", "")), int(_state.get("version", 0)), 0)
	if not res.has("conflict"):
		res["conflict"] = false
	_unlock()
	return res


## Note a local change; (re)starts the push debounce.
func mark_dirty() -> void:
	_dirty = true
	_state["local_changed_at"] = int(Time.get_unix_time_from_system())
	_save_state()
	if _timer != null and _timer.is_inside_tree() and is_enabled():
		_timer.start(maxf(0.001, debounce_s))


## The synced keys currently in the local store.
func export_local() -> Dictionary:
	var out := {}
	if _store == null or not _store.has_method("export_prefix"):
		return out
	for p in sync_prefixes():
		var part: Variant = _store.call("export_prefix", p)
		if part is Dictionary:
			out.merge(part, true)
	return out


## Per-key default merge of two `data` maps (see class doc). `remote_is_newer`
## decides keys that are neither both numbers nor both arrays.
static func default_merge(local: Dictionary, remote: Dictionary, remote_is_newer: bool = true) -> Dictionary:
	var out := local.duplicate(true)
	for k in remote:
		var b: Variant = remote[k]
		if not out.has(k):
			out[k] = _copy(b)
			continue
		var a: Variant = out[k]
		if _is_number(a) and _is_number(b):
			out[k] = b if b > a else a
		elif typeof(a) == typeof(b) and _is_array_like(a):
			var merged: Variant = a.duplicate()
			for x in b:
				if not merged.has(x):
					merged.append(x)
			out[k] = merged
		elif remote_is_newer:
			out[k] = _copy(b)
	return out


## Wrap data in the blob envelope (values encoded type-faithfully).
static func make_envelope(data: Dictionary, version: int, device_id: String, updated_at: int) -> Dictionary:
	return {
		"format": BLOB_FORMAT_VERSION,
		"encoding": ENCODING,
		"version": version,
		"updated_at": updated_at,
		"device_id": device_id,
		"data": encode_data(data),
	}


## Unwrap a blob value -> {version:int, updated_at:int, device_id:String,
## data:Dictionary (decoded)}. Anything unusable reads as an empty envelope.
static func parse_envelope(value: Variant) -> Dictionary:
	var raw := SnapKitJson.get_dict({"v": value}, "v")
	return {
		"version": SnapKitJson.get_int(raw, "version"),
		"updated_at": SnapKitJson.get_int(raw, "updated_at"),
		"device_id": SnapKitJson.get_str(raw, "device_id"),
		"data": decode_data(SnapKitJson.get_dict(raw, "data"), SnapKitJson.get_str(raw, "encoding")),
	}


## {key: JSON.from_native(value)}.
static func encode_data(data: Dictionary) -> Dictionary:
	var out := {}
	for k in data:
		out[str(k)] = JSON.from_native(data[k])
	return out


## Inverse of encode_data for encoding ENCODING; other encodings pass values
## through unchanged.
static func decode_data(data: Dictionary, encoding: String = ENCODING) -> Dictionary:
	var out := {}
	for k in data:
		out[str(k)] = JSON.to_native(data[k]) if encoding == ENCODING else data[k]
	return out


## Stable content hash of a data map (key order independent, type-aware).
static func data_hash(data: Dictionary) -> String:
	var keys := data.keys()
	keys.sort()
	var rows: Array = []
	for k in keys:
		rows.append([str(k), JSON.from_native(data[k])])
	return JSON.stringify(rows).sha256_text()


# ---- internals ---------------------------------------------------------------

func _pull_locked(attempt: int) -> Dictionary:
	var got: Dictionary = await _storage.get_json_blob(blob_key(), access)
	if not got.ok:
		got["applied"] = APPLIED_NONE
		return got
	var local := export_local()
	var local_hash := data_hash(local)
	var has_synced := bool(_state.get("has_synced", false))
	var local_changed := (local_hash != str(_state.get("synced_hash", ""))) if has_synced else not local.is_empty()

	if not got.exists:
		if local.is_empty():
			_record_sync("", local_hash, 0)
			synced.emit("pull")
			return _with(got, {"applied": APPLIED_NONE})
		return _with(await _push_locked(local, "", 0, attempt), {"applied": APPLIED_LOCAL})

	var env := parse_envelope(got.value)
	var remote: Dictionary = env.data
	var remote_cas: String = got.cas
	var remote_changed := (not has_synced) or remote_cas != str(_state.get("cas", ""))

	if data_hash(remote) == local_hash:
		_record_sync(remote_cas, local_hash, env.version)
		synced.emit("pull")
		return _with(got, {"applied": APPLIED_NONE})
	if not remote_changed and not local_changed:
		synced.emit("pull")
		return _with(got, {"applied": APPLIED_NONE})
	if not remote_changed:
		return _with(await _push_locked(local, remote_cas, env.version, attempt), {"applied": APPLIED_LOCAL})
	if not local_changed:
		_import_local(remote)
		_record_sync(remote_cas, data_hash(export_local()), env.version)
		synced.emit("pull")
		return _with(got, {"applied": APPLIED_REMOTE})

	conflict.emit(local.duplicate(true), remote.duplicate(true))
	var remote_is_newer := int(env.updated_at) >= int(_state.get("local_changed_at", 0))
	_import_local(_resolve(local, remote, remote_is_newer))
	var merged := export_local()
	return _with(await _push_locked(merged, remote_cas, env.version, attempt), {"applied": APPLIED_MERGED})


func _push_locked(data: Dictionary, cas: String, base_version: int, attempt: int) -> Dictionary:
	var now := int(Time.get_unix_time_from_system())
	var version := base_version + 1
	var env := make_envelope(data, version, device_id(), now)
	var res: Dictionary = await _storage.put_json_blob_cas(blob_key(), env, cas, access)
	if res.ok:
		_record_sync(str(res.get("cas", "")), data_hash(data), version)
		synced.emit("push")
		res["conflict"] = bool(res.get("conflict", false))
		return res
	if bool(res.get("conflict", false)) and attempt + 1 < MAX_CAS_ATTEMPTS:
		var again: Dictionary = await _pull_locked(attempt + 1)
		again["conflict"] = true
		return again
	return res


func _resolve(local: Dictionary, remote: Dictionary, remote_is_newer: bool) -> Dictionary:
	last_remote_is_newer = remote_is_newer
	if merge_func.is_valid():
		var m: Variant = merge_func.call(local.duplicate(true), remote.duplicate(true))
		if m is Dictionary:
			return m
	return default_merge(local, remote, remote_is_newer)


func _import_local(data: Dictionary) -> void:
	_importing = true
	for p in sync_prefixes():
		var part := {}
		for k in data:
			if str(k).begins_with(p):
				part[k] = data[k]
		# Agent D's SaveService takes an optional third `replace` arg (drop local
		# keys missing from `part`); the duck-typed contract only promises
		# (prefix, data), so pass `replace` only when the store accepts it.
		if _import_arity() >= 3:
			_store.call("import_prefix", p, part, true)
		else:
			_store.call("import_prefix", p, part)
	_importing = false


func _import_arity() -> int:
	if _store == null or not _store.has_method("import_prefix"):
		return 0
	return _store.get_method_argument_count("import_prefix")


func _record_sync(cas: String, content_hash: String, version: int) -> void:
	_state["cas"] = cas
	_state["synced_hash"] = content_hash
	_state["version"] = version
	_state["has_synced"] = true
	_state["synced_at"] = int(Time.get_unix_time_from_system())
	_dirty = false
	_save_state()


func _on_store_changed(key: String) -> void:
	if _importing:
		return
	for p in sync_prefixes():
		if key.begins_with(p):
			mark_dirty()
			return


func _on_debounce() -> void:
	if _dirty and is_enabled():
		push()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT \
			or what == NOTIFICATION_WM_CLOSE_REQUEST:
		if _dirty and is_enabled():
			push()


func _lock() -> void:
	while _busy:
		await _idle
	_busy = true


func _unlock() -> void:
	_busy = false
	_idle.emit()


func _load_state() -> void:
	_state = {}
	if FileAccess.file_exists(state_path):
		var parsed: Variant = SnapKitJson.parse(FileAccess.get_file_as_string(state_path))
		if parsed is Dictionary:
			_state = {
				"device_id": SnapKitJson.get_str(parsed, "device_id"),
				"cas": SnapKitJson.get_str(parsed, "cas"),
				"synced_hash": SnapKitJson.get_str(parsed, "synced_hash"),
				"version": SnapKitJson.get_int(parsed, "version"),
				"has_synced": SnapKitJson.get_bool(parsed, "has_synced"),
				"synced_at": SnapKitJson.get_int(parsed, "synced_at"),
				"local_changed_at": SnapKitJson.get_int(parsed, "local_changed_at"),
			}
	if str(_state.get("device_id", "")) == "":
		_state["device_id"] = Crypto.new().generate_random_bytes(8).hex_encode()
		_save_state()


func _save_state() -> void:
	var f := FileAccess.open(state_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_state))
	f.close()


static func _with(res: Dictionary, extra: Dictionary) -> Dictionary:
	res.merge(extra, true)
	return res


static func _disabled(extra: Dictionary) -> Dictionary:
	var res := SnapKitTransport.error_result(SnapKitTransport.ERR_DISABLED)
	res.merge(extra, true)
	return res


static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


static func _is_array_like(v: Variant) -> bool:
	return typeof(v) in [TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY,
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY,
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY,
		TYPE_PACKED_VECTOR4_ARRAY]


static func _copy(v: Variant) -> Variant:
	if v is Array or v is Dictionary:
		return v.duplicate(true)
	return v
