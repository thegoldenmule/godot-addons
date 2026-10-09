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
## Only keys under SnapKitConfig.cloud_save_prefixes() (e.g. "sax_prog_") plus
## the exact names in cloud_save_keys() ("sync_keys", for legacy keys with no
## shared prefix) are synced; everything else (settings) stays local. Exact
## keys are imported one by one WITHOUT `replace`, so they never remove sibling
## keys that merely start with the same text; a pull adds/overwrites them but
## never deletes them.
##
## No files in offline / test runs: the state file (state_path) is written only
## while the config is online. Offline, the bookkeeping lives in memory; the
## first online pull treats unsynced local changes of unknown age as recent.
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
##   - PER-USER BOOKKEEPING (v0.2.2): the state (CAS token, version,
##     has_synced, synced hash) belongs to ONE Snapser user and records its
##     user_id. When the session user changes (switch_account, sign_out, a
##     different login) it is reset, so a new user never reuses the previous
##     user's CAS / version / has_synced. Only the device id survives.
##   - ACCOUNT WINS ON SWITCH (D36): adopt_account() — used by
##     SnapKitService.switch_account() after link_account() returned
##     "account_exists" — replaces local synced data with the existing
##     account's blob for every key, EXCEPT bools, which OR (achievements /
##     unlocks earned as a guest survive; a merge_policy of "remote" opts a
##     bool out). Guest-only non-bool keys are dropped. "Never discard local
##     progress" applies to the first sync and to linking a NEW provider
##     account, not to switching to an existing one.
##   - BOOLS ARE MONOTONIC PROGRESS FLAGS on EVERY pull path (v0.2.1): a `true`
##     on either side stays true, including when only the remote changed (the
##     "take remote" path) — a remote `false` / missing key never re-locks an
##     earned flag. When that keeps a local value, the result is pushed back.
##   - Per-key policy (config cloud_save.merge_policy, key or "prefix*"):
##     "max" (numbers), "or" (bools), "remote", "local". It applies on every
##     pull path after the merge and overrides the bool default — e.g.
##     {"sax_set_tutorial_seen": "remote"} opts a flag out of monotonic OR.
##   - default_merge(): per key — bools OR (progress flags), numbers take max,
##     arrays take union, anything
##     else takes the newer side's value (by updated_at vs the last local change).
##   - Sync bookkeeping (last CAS, revision, synced hash, last local change,
##     device id) persists at state_path (STATE_FILE under SnapKitConfig.data_root).
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
## A pull or merge wrote remote data into the local store. keys = the synced
## keys whose local value was added, changed or removed (sorted). Games refresh
## caches / registries from it (SnapKitService re-emits it as
## cloud_save_applied). Not emitted when the import changed nothing.
signal applied(keys: PackedStringArray)
signal _idle

const DEBOUNCE_S := 10.0
const BLOB_FORMAT_VERSION := 1
const STATE_FILE := "snapser_kit_cloud_save.json"
## Default location when SnapKitConfig.data_root is user:// (kept for reference).
const STATE_PATH := "user://snapser_kit_cloud_save.json"
const DEFAULT_BLOB_KEY := "save_v1"
const ENCODING := "godot_native"
const MAX_CAS_ATTEMPTS := 3

const APPLIED_NONE := "none"
const APPLIED_LOCAL := "local"
const APPLIED_REMOTE := "remote"
const APPLIED_MERGED := "merged"
## switch_account -> adopt_account(): the existing account's save won (D36).
const APPLIED_ACCOUNT := "account"

## func(local: Dictionary, remote: Dictionary) -> Dictionary over the `data`
## maps. An invalid/empty Callable (or a non-Dictionary return) means
## default_merge.
var merge_func: Callable
## Seconds of quiet after the last local change before an automatic push.
var debounce_s: float = DEBOUNCE_S
## Where sync bookkeeping persists (tests point it at a scratch file).
var state_path: String = SnapKitConfig.data_path(STATE_FILE)
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
## the config lists at least one sync prefix or exact sync key.
func is_enabled() -> bool:
	return _storage != null and _store != null and _store.has_method("export_prefix") \
		and _store.has_method("import_prefix") \
		and (not sync_prefixes().is_empty() or not sync_keys().is_empty())


func sync_prefixes() -> PackedStringArray:
	return _config.cloud_save_prefixes() if _config != null else PackedStringArray()


## Exact key names synced alongside the prefixes ("sync_keys").
func sync_keys() -> PackedStringArray:
	return _config.cloud_save_keys() if _config != null else PackedStringArray()


## True when `key` is synced (under a prefix or an exact sync key).
func is_synced_key(key: String) -> bool:
	if sync_keys().has(key):
		return true
	for p in sync_prefixes():
		if key.begins_with(p):
			return true
	return false


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
	bind_user(_storage.user_id())
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
	bind_user(_storage.user_id())
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
	for k in sync_keys():
		if out.has(k):
			continue
		# The duck-typed store only exports by prefix: keep the exact key only.
		var one: Variant = _store.call("export_prefix", k)
		if one is Dictionary and (one as Dictionary).has(k):
			out[k] = one[k]
	return out


## The config's per-key merge policies ({} when none).
func merge_policies() -> Dictionary:
	if _config == null or not _config.has_method("cloud_save_merge_policy"):
		return {}
	return _config.cloud_save_merge_policy()


## Policy for `key`: an exact entry wins, else the longest matching "prefix*"
## entry, else "".
static func policy_for(key: String, policies: Dictionary) -> String:
	if policies.has(key):
		return str(policies[key])
	var best := ""
	var best_len := -1
	for p in policies:
		var ps := str(p)
		if ps.ends_with("*"):
			var pre := ps.trim_suffix("*")
			if key.begins_with(pre) and pre.length() > best_len:
				best = str(policies[p])
				best_len = pre.length()
	return best


## Apply monotonic bools and per-key policies on top of `base` (the result a
## pull path chose: the remote data, or the merge). For every key on either
## side:
##   "local" / "remote": that side's value (absent there -> key removed);
##   "max": larger number (one-sided -> that side);
##   "or" / no policy: if either side holds bool `true` (and the other side is
##     a bool or absent) the key is `true`.
## Other keys keep `base`'s value. Inputs are not modified.
static func apply_policies(base: Dictionary, local: Dictionary, remote: Dictionary, policies: Dictionary = {}) -> Dictionary:
	var out := base.duplicate(true)
	var keys := {}
	for k in local:
		keys[k] = true
	for k in remote:
		keys[k] = true
	for k in keys:
		var hl := local.has(k)
		var hr := remote.has(k)
		var lv: Variant = local.get(k)
		var rv: Variant = remote.get(k)
		match policy_for(str(k), policies):
			"local":
				if hl:
					out[k] = _copy(lv)
				else:
					out.erase(k)
			"remote":
				if hr:
					out[k] = _copy(rv)
				else:
					out.erase(k)
			"max":
				if hl and hr and _is_number(lv) and _is_number(rv):
					out[k] = rv if rv > lv else lv
				elif hl and not hr and _is_number(lv):
					out[k] = lv
				elif hr and not hl and _is_number(rv):
					out[k] = rv
			_:
				var lb := hl and typeof(lv) == TYPE_BOOL
				var rb := hr and typeof(rv) == TYPE_BOOL
				if (lb or not hl) and (rb or not hr) and ((lb and lv) or (rb and rv)):
					out[k] = true
	return out


## Per-key default merge of two `data` maps (see class doc): bools OR, numbers
## max, arrays union; `remote_is_newer` decides everything else. Override
## SnapKitService._merge() for a different policy (call this for the rest).
static func default_merge(local: Dictionary, remote: Dictionary, remote_is_newer: bool = true) -> Dictionary:
	var out := local.duplicate(true)
	for k in remote:
		var b: Variant = remote[k]
		if not out.has(k):
			out[k] = _copy(b)
			continue
		var a: Variant = out[k]
		if typeof(a) == TYPE_BOOL and typeof(b) == TYPE_BOOL:
			# Progress flags (achievements, unlocks): earned on either device
			# stays earned.
			out[k] = a or b
		elif _is_number(a) and _is_number(b):
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
	if bool(_state.get("has_synced", false)) and local_hash != str(_state.get("synced_hash", "")) \
			and int(_state.get("local_changed_at", 0)) <= int(_state.get("synced_at", 0)):
		# Local changed since the last sync but its time was not persisted (an
		# offline run writes no state file): treat the change as just made.
		_state["local_changed_at"] = int(Time.get_unix_time_from_system())
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
		# Remote-only change: take remote, but monotonic bools and explicit
		# per-key policies still apply (an earned flag is never re-locked).
		var taken := apply_policies(remote, local, remote, merge_policies())
		_import_local(taken)
		if data_hash(export_local()) == data_hash(remote):
			_record_sync(remote_cas, data_hash(export_local()), env.version)
			synced.emit("pull")
			return _with(got, {"applied": APPLIED_REMOTE})
		# Local kept something the remote lacks: push the merged result.
		return _with(await _push_locked(export_local(), remote_cas, env.version, attempt), {"applied": APPLIED_MERGED})

	conflict.emit(local.duplicate(true), remote.duplicate(true))
	var remote_is_newer := int(env.updated_at) >= int(_state.get("local_changed_at", 0))
	_import_local(apply_policies(_resolve(local, remote, remote_is_newer), local, remote, merge_policies()))
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


## drop_exact: also remove exact sync_keys that `data` lacks (switch_account).
## Needs a store whose import_prefix accepts `replace`; the key's siblings
## (other keys starting with the same text) are re-imported unchanged, so only
## the exact key goes.
func _import_local(data: Dictionary, drop_exact: bool = false) -> void:
	var before := export_local()
	var can_replace := _import_arity() >= 3
	_importing = true
	for p in sync_prefixes():
		var part := {}
		for k in data:
			if str(k).begins_with(p):
				part[k] = data[k]
		# Agent D's SaveService takes an optional third `replace` arg (drop local
		# keys missing from `part`); the duck-typed contract only promises
		# (prefix, data), so pass `replace` only when the store accepts it.
		if can_replace:
			_store.call("import_prefix", p, part, true)
		else:
			_store.call("import_prefix", p, part)
	for k in sync_keys():
		if not data.has(k) or _under_prefix(k):
			continue
		# Exact keys: never `replace` (it would drop siblings sharing the text).
		if can_replace:
			_store.call("import_prefix", k, {k: data[k]}, false)
		else:
			_store.call("import_prefix", k, {k: data[k]})
	if drop_exact and can_replace:
		for k in sync_keys():
			if data.has(k) or _under_prefix(k) or not before.has(k):
				continue
			var siblings: Variant = _store.call("export_prefix", k)
			var keep := {}
			if siblings is Dictionary:
				keep = (siblings as Dictionary).duplicate()
				keep.erase(k)
			_store.call("import_prefix", k, keep, true)
	_importing = false
	var keys := changed_keys(before, export_local())
	if not keys.is_empty():
		applied.emit(keys)


## Keys whose value differs between `before` and `after` (added or changed; also
## removed when `include_removed`), sorted.
static func changed_keys(before: Dictionary, after: Dictionary, include_removed: bool = true) -> PackedStringArray:
	var out := PackedStringArray()
	for k in after:
		if not before.has(k) or not _same(before[k], after[k]):
			out.append(str(k))
	if include_removed:
		for k in before:
			if not after.has(k):
				out.append(str(k))
	out.sort()
	return out


static func _same(a: Variant, b: Variant) -> bool:
	return typeof(a) == typeof(b) and a == b


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


func _under_prefix(key: String) -> bool:
	for p in sync_prefixes():
		if key.begins_with(p):
			return true
	return false


func _on_store_changed(key: String) -> void:
	if _importing:
		return
	if is_synced_key(key):
		mark_dirty()


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


## Bind the bookkeeping to `uid` (the current session user). A different
## non-empty user than the one recorded resets everything but the device id;
## "" (signed out) resets too. A state with no recorded user (written before
## 0.2.2) is adopted by the first user seen. Returns true when it reset.
func bind_user(uid: String) -> bool:
	var recorded := str(_state.get("user_id", ""))
	if uid == recorded:
		return false
	if recorded == "" and uid != "":
		_state["user_id"] = uid
		_save_state()
		return false
	reset_state(uid)
	return true


## Forget all sync bookkeeping (CAS, version, has_synced, hashes, times) and
## record `uid` as the owner. The device id is kept. Persists when online.
func reset_state(uid: String = "") -> void:
	var device := str(_state.get("device_id", ""))
	_state = {"device_id": device, "user_id": uid}
	_dirty = false
	_save_state()


## The Snapser user these bookkeeping fields belong to ("" = none yet).
func state_user_id() -> String:
	return str(_state.get("user_id", ""))


## SWITCH TO AN EXISTING ACCOUNT (D36): the account's remote save wins for
## every key except bools, which OR (unless merge_policy says "remote" for that
## key). Resets the bookkeeping to the current session user first, imports the
## result (replacing guest data), records the account's CAS / version, and
## pushes back only if OR-ed flags changed the data. No blob on the account ->
## only the guest's `true` flags are kept. COROUTINE.
## -> {ok, status, json, error, applied:"account", dropped:PackedStringArray}
func adopt_account() -> Dictionary:
	if not is_enabled():
		return _disabled({"applied": APPLIED_NONE})
	await _lock()
	reset_state(_storage.user_id())
	var got: Dictionary = await _storage.get_json_blob(blob_key(), access)
	if not got.ok:
		_unlock()
		got["applied"] = APPLIED_NONE
		return got
	var local := export_local()
	var remote: Dictionary = parse_envelope(got.value).data if got.exists else {}
	var version: int = parse_envelope(got.value).version if got.exists else 0
	var result := account_wins(local, remote, merge_policies())
	var dropped := PackedStringArray()
	for k in local:
		if not result.has(k):
			dropped.append(str(k))
	dropped.sort()
	_import_local(result, true)
	var res: Dictionary
	var now_local := export_local()
	if got.exists and data_hash(now_local) == data_hash(remote):
		_record_sync(str(got.cas), data_hash(now_local), version)
		synced.emit("pull")
		res = got
	else:
		res = await _push_locked(now_local, str(got.cas) if got.exists else "", version, 0)
	_unlock()
	return _with(res, {"applied": APPLIED_ACCOUNT, "dropped": dropped})


## D36 rule as a pure function: `remote` (the account) for every key; bools
## OR across both sides (a guest `true` survives, also when the account lacks
## the key) unless policies[key] (exact or "prefix*") is "remote".
static func account_wins(local: Dictionary, remote: Dictionary, policies: Dictionary = {}) -> Dictionary:
	var out := remote.duplicate(true)
	for k in local:
		var lv: Variant = local[k]
		if typeof(lv) != TYPE_BOOL or not lv:
			continue
		if policy_for(str(k), policies) == "remote":
			continue
		if not remote.has(k) or typeof(remote[k]) == TYPE_BOOL:
			out[k] = true
	return out


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
				"user_id": SnapKitJson.get_str(parsed, "user_id"),
			}
	if str(_state.get("device_id", "")) == "":
		_state["device_id"] = Crypto.new().generate_random_bytes(8).hex_encode()
		_save_state()


func _save_state() -> void:
	# Offline / test runs write nothing under user:// (kept in memory instead).
	if _config == null or _config.is_offline():
		return
	SnapKitConfig.ensure_dir_for(state_path)
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
