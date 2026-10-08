extends SnapKitConfig

## SnapKitConfig with the cloud-save accessors pinned, so cloud-save tests do
## not depend on the config loader (agent A's core/). Online by construction.

var prefixes: PackedStringArray = PackedStringArray(["prog_"])
var blob: String = "save_v1"
var keys: PackedStringArray = PackedStringArray()
## Tests flip this to exercise offline behaviour (no state file writes).
var pretend_offline: bool = false


func cloud_save_prefixes() -> PackedStringArray:
	return prefixes


func cloud_save_blob_key() -> String:
	return blob


func cloud_save_keys() -> PackedStringArray:
	return keys


func is_offline() -> bool:
	return pretend_offline
