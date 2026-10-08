extends RefCounted

## In-memory stand-in for the Hypercasual-Shared SaveService prefix API
## (keys_with_prefix / export_prefix / import_prefix(prefix, values, replace) /
## signal changed(key)), with the same semantics: writes that do not change a
## value (including its type) emit nothing; import_prefix refuses keys outside
## its prefix and emits changed once per key it touched, after the import.

signal changed(key: String)

var data: Dictionary = {}
## Number of import_prefix calls (tests assert on echo behaviour).
var import_calls: int = 0


func set_value(key: String, value: Variant) -> void:
	if _differs(key, value):
		data[key] = _copy(value)
		changed.emit(key)


func get_value(key: String, default_value: Variant = null) -> Variant:
	return data.get(key, default_value)


func keys_with_prefix(prefix: String) -> PackedStringArray:
	var out := PackedStringArray()
	for k in data:
		if str(k).begins_with(prefix):
			out.append(k)
	out.sort()
	return out


func export_prefix(prefix: String) -> Dictionary:
	var out := {}
	for k in keys_with_prefix(prefix):
		out[k] = _copy(data[k])
	return out


func import_prefix(prefix: String, values: Dictionary, replace: bool = false) -> int:
	import_calls += 1
	var touched: Array = []
	var incoming := {}
	for raw_key in values:
		var key := str(raw_key)
		incoming[key] = true
		if not key.begins_with(prefix):
			continue
		if _differs(key, values[raw_key]):
			data[key] = _copy(values[raw_key])
			touched.append(key)
	if replace:
		for key in keys_with_prefix(prefix):
			if not incoming.has(key):
				data.erase(key)
				touched.append(key)
	for key in touched:
		changed.emit(key)
	return touched.size()


func _differs(key: String, value: Variant) -> bool:
	if not data.has(key):
		return true
	var old: Variant = data[key]
	return typeof(old) != typeof(value) or old != value


static func _copy(v: Variant) -> Variant:
	if v is Array or v is Dictionary:
		return v.duplicate(true)
	return v
