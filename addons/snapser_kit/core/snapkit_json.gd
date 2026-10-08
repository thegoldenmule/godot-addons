@tool
class_name SnapKitJson
extends RefCounted

## Lenient JSON helpers shared by every Snapser Kit client and parser.
##
## Snapser responses are not uniform about numbers: int64 values usually arrive
## as STRINGS (often in a parallel `<field>_64` key), int32 values arrive as JSON
## numbers (which Godot parses as float), and fields may be missing or null.
## These helpers never throw and never push errors — they return the supplied
## default when a value is absent or the wrong shape. Parsers in clients/ should
## use them instead of raw `dict[key]` access.
##
## Fully implemented in the skeleton (pure, no dependencies) so clients/ can rely
## on it immediately.


## Parse JSON text without logging. Returns null for empty or invalid text.
static func parse(text: String) -> Variant:
	if text.strip_edges() == "":
		return null
	var j := JSON.new()
	if j.parse(text) != OK:
		return null
	return j.data


## Coerce int / float / numeric String / bool to int. Strings keep full int64
## precision ("9007199254740993" -> 9007199254740993). Anything else -> fallback.
static func to_int(v: Variant, fallback: int = 0) -> int:
	match typeof(v):
		TYPE_INT:
			return v
		TYPE_FLOAT:
			return int(v)
		TYPE_BOOL:
			return 1 if v else 0
		TYPE_STRING, TYPE_STRING_NAME:
			var s := String(v).strip_edges()
			if s.is_valid_int():
				return s.to_int()
			if s.is_valid_float():
				return int(s.to_float())
	return fallback


## Coerce to float; numeric strings accepted.
static func to_float(v: Variant, fallback: float = 0.0) -> float:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			return float(v)
		TYPE_BOOL:
			return 1.0 if v else 0.0
		TYPE_STRING, TYPE_STRING_NAME:
			var s := String(v).strip_edges()
			if s.is_valid_float():
				return s.to_float()
	return fallback


## Coerce to bool; accepts "true"/"false"/"1"/"0" strings and numbers.
static func to_bool(v: Variant, fallback: bool = false) -> bool:
	match typeof(v):
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return v != 0
		TYPE_STRING, TYPE_STRING_NAME:
			var s := String(v).strip_edges().to_lower()
			if s in ["true", "1", "yes"]:
				return true
			if s in ["false", "0", "no"]:
				return false
	return fallback


## d[key] as int when d is a Dictionary, else fallback.
static func get_int(d: Variant, key: String, fallback: int = 0) -> int:
	if d is Dictionary and (d as Dictionary).has(key):
		return to_int(d[key], fallback)
	return fallback


## Snapser int64 convention: prefer `key64` (usually a string), fall back to
## `key`, then fallback. e.g. get_int64(q, "progress_64", "progress").
static func get_int64(d: Variant, key64: String, key: String, fallback: int = 0) -> int:
	if d is Dictionary:
		var dict := d as Dictionary
		if dict.has(key64) and dict[key64] != null and str(dict[key64]) != "":
			return to_int(dict[key64], fallback)
		if dict.has(key):
			return to_int(dict[key], fallback)
	return fallback


static func get_float(d: Variant, key: String, fallback: float = 0.0) -> float:
	if d is Dictionary and (d as Dictionary).has(key):
		return to_float(d[key], fallback)
	return fallback


static func get_bool(d: Variant, key: String, fallback: bool = false) -> bool:
	if d is Dictionary and (d as Dictionary).has(key):
		return to_bool(d[key], fallback)
	return fallback


## d[key] as String (null -> fallback; numbers stringified without ".0" for
## integral floats).
static func get_str(d: Variant, key: String, fallback: String = "") -> String:
	if not (d is Dictionary) or not (d as Dictionary).has(key):
		return fallback
	var v: Variant = d[key]
	if v == null:
		return fallback
	if typeof(v) == TYPE_FLOAT and is_equal_approx(v, floorf(v)) and absf(v) < 9.0e15:
		return str(int(v))
	return str(v)


## d[key] if it is a Dictionary, else an empty Dictionary.
static func get_dict(d: Variant, key: String) -> Dictionary:
	if d is Dictionary and (d as Dictionary).get(key) is Dictionary:
		return d[key]
	return {}


## d[key] if it is an Array, else an empty Array.
static func get_array(d: Variant, key: String) -> Array:
	if d is Dictionary and (d as Dictionary).get(key) is Array:
		return d[key]
	return []


## Walk a path of keys (String) / indices (int) through nested
## Dictionaries/Arrays. Returns fallback on any miss.
##   SnapKitJson.dig(json, ["user", "id"], "")
static func dig(v: Variant, path: Array, fallback: Variant = null) -> Variant:
	var cur: Variant = v
	for step in path:
		if cur is Dictionary and (cur as Dictionary).has(step):
			cur = cur[step]
		elif cur is Array and typeof(step) == TYPE_INT and step >= 0 and step < (cur as Array).size():
			cur = cur[step]
		else:
			return fallback
	return cur
