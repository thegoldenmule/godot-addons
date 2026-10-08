class_name SnapKitCloudSave
extends Node

## Local-first cloud save: mirrors the game's synced local keys to ONE private
## Storage json-blob per user (plan 02 §2.3 "Cloud-save model").
##
## Local store: a SaveService-style object (duck-typed), the device's source of
## truth. Expected surface (Hypercasual-Shared SaveService additions, agent D):
##   export_prefix(prefix: String) -> Dictionary   # {full_key: value} under prefix
##   import_prefix(data: Dictionary) -> void       # write keys back (full keys)
##   signal changed(key: String)                   # any local write
## Only keys under SnapKitConfig.cloud_save_prefixes() are synced (e.g.
## "sax_prog_*"); everything else (settings) stays local.
##
## Blob (key = SnapKitConfig.cloud_save_blob_key(), default "save_v1"):
##   {"version": int, "updated_at": int (unix s), "device_id": String,
##    "data": {full_key: value}}
##
## Behaviour:
##   - pull() on start: remote newer and local untouched since last sync -> take
##     remote; both changed -> emit `conflict(local, remote)` then apply
##     merge_func(local, remote) and push the result; first sync with pre-existing
##     local progress -> merge, never discard.
##   - push() is debounced DEBOUNCE_S after the last local change, and forced on
##     NOTIFICATION_APPLICATION_PAUSED / FOCUS_OUT / WM_CLOSE_REQUEST. It uses
##     SnapKitStorage.put_json_blob_cas() with the last-seen CAS; a CAS conflict
##     triggers pull-merge-push (bounded attempts).
##   - default_merge(): per key — numbers take max, arrays take union, anything
##     else takes the newer side's value.
##   - Sync bookkeeping (last CAS, last synced hash/time, device id) persists at
##     STATE_PATH.
##   - Offline: pull()/push() return {ok:false, error:"offline"}; local play is
##     unaffected.
##
## A Node because it owns the debounce Timer and receives app lifecycle
## notifications; SnapKitService adds it as a child.
##
## SKELETON (owner: kit-clients agent): signatures final for v0.1; bodies stubbed.

## Both sides changed since the last sync. Informational; resolution is
## merge_func (SnapKitService wires it to its overridable _merge()).
signal conflict(local: Dictionary, remote: Dictionary)
## A pull or push completed successfully. direction: "pull" | "push".
signal synced(direction: String)

const DEBOUNCE_S := 10.0
const BLOB_FORMAT_VERSION := 1
const STATE_PATH := "user://snapser_kit_cloud_save.json"

## func(local: Dictionary, remote: Dictionary) -> Dictionary over the `data`
## maps. An invalid/empty Callable means default_merge.
var merge_func: Callable

var _storage: SnapKitStorage
var _store: Object
var _config: SnapKitConfig


## Wire dependencies. store may be null (cloud save then reports "disabled").
func setup(storage: SnapKitStorage, store: Object, config: SnapKitConfig) -> void:
	_storage = storage
	_store = store
	_config = config


## True when a store is wired and the config lists at least one sync prefix.
func is_enabled() -> bool:
	return false


## Fetch the remote blob and reconcile with local (see class doc). COROUTINE.
## -> {ok, status, json, error, applied:String ("remote"|"local"|"merged"|"none")}
func pull() -> Dictionary:
	return SnapKitTransport.not_implemented()


## Upload the current local synced keys with CAS. COROUTINE.
## -> {ok, status, json, error, conflict:bool}
func push() -> Dictionary:
	return SnapKitTransport.not_implemented()


## Note a local change; (re)starts the push debounce.
func mark_dirty() -> void:
	pass


## Per-key default merge of two `data` maps (see class doc). `remote_is_newer`
## decides non-numeric, non-array keys.
static func default_merge(local: Dictionary, remote: Dictionary, remote_is_newer: bool = true) -> Dictionary:
	return {}


## Wrap data in the blob envelope.
static func make_envelope(data: Dictionary, version: int, device_id: String, updated_at: int) -> Dictionary:
	return {}
