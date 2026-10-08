extends SnapKitConfig

## SnapKitConfig with the cloud-save accessors pinned, so cloud-save tests do
## not depend on the config loader (agent A's core/). Online by construction.

var prefixes: PackedStringArray = PackedStringArray(["prog_"])
var blob: String = "save_v1"


func cloud_save_prefixes() -> PackedStringArray:
	return prefixes


func cloud_save_blob_key() -> String:
	return blob


func is_offline() -> bool:
	return false
