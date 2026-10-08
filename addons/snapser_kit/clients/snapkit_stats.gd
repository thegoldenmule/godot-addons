class_name SnapKitStats
extends RefCounted

## Client for the Snapser Statistics snap (statistics.swagger3.json): per-user
## integer stats.
##
##   PUT   /v1/statistics/user-stats/{user_id}/{key}   SetUserStatistic       {"value": "<int as string>"}
##   PATCH /v1/statistics/user-stats/{user_id}/{key}   IncrementUserStatistic {"delta": <int64>}
##   GET   /v1/statistics/user-stats/{user_id}/{key}   GetUserStatistic
##   GET   /v1/statistics/settings/user-stats/{user_id} GetUserStatistics
## All four answer a statisticsUserStatistic {key, user_id, value:String} (or a
## list of them under "user_statistics"); value is an int64 carried as a string.
##
## Keys must match KEY_PATTERN (^[a-z0-9_]+$ — no dots, no game prefix; each game
## has its own snapend). Invalid keys are rejected locally with
## SnapKitTransport.ERR_INVALID_ARGUMENT and no request is made.
##
## Client conventions (all clients/):
##   - Constructed by SnapKitService: SnapKitStats.new(transport).
##   - All HTTP via transport.request(); paths use the "{user_id}" placeholder.
##   - Path builders and parsers are static and network-free (unit-testable).
##   - Methods are COROUTINES returning the transport result dict augmented with
##     parsed fields; they never throw. Offline -> the transport's
##     {ok:false, error:"offline"} plus the parsed fields at their defaults.

const KEY_PATTERN := "^[a-z0-9_]+$"
const BASE_PATH := "/v1/statistics/user-stats/{user_id}"
const ALL_STATS_PATH := "/v1/statistics/settings/user-stats/{user_id}"

static var _key_re: RegEx

var _transport: SnapKitTransport


func _init(transport: SnapKitTransport) -> void:
	_transport = transport


## True when key matches KEY_PATTERN.
static func is_valid_key(key: String) -> bool:
	if _key_re == null:
		_key_re = RegEx.create_from_string(KEY_PATTERN)
	return _key_re.search(key) != null


## "/v1/statistics/user-stats/{user_id}/<key>" (placeholder left for transport).
static func stat_path(key: String) -> String:
	return "%s/%s" % [BASE_PATH, key.uri_encode()]


## "/v1/statistics/settings/user-stats/{user_id}" — every stat of the user.
static func all_stats_path() -> String:
	return ALL_STATS_PATH


## SetUserStatistic body: the swagger types `value` as a string (int64).
static func set_body(value: int) -> Dictionary:
	return {"value": str(value)}


## IncrementUserStatistic body.
static func increment_body(delta: int) -> Dictionary:
	return {"delta": delta}


## statisticsUserStatistic -> its integer value (fallback when absent).
static func parse_value(json: Variant, fallback: int = 0) -> int:
	return SnapKitJson.get_int(json, "value", fallback)


## statisticsGetUserStatisticsResponse -> {key: int}.
static func parse_stats(json: Variant) -> Dictionary:
	var out := {}
	for s in SnapKitJson.get_array(json, "user_statistics"):
		var key := SnapKitJson.get_str(s, "key")
		if key != "":
			out[key] = SnapKitJson.get_int(s, "value")
	return out


## Set a stat to an absolute value. -> {ok, status, json, error, value:int}
func set_stat(key: String, value: int) -> Dictionary:
	if not is_valid_key(key):
		return _invalid({"value": 0})
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_PUT, stat_path(key), set_body(value))
	res["value"] = parse_value(res.json, value) if res.ok else 0
	return res


## Atomically add delta (may be negative). -> {..., value:int} (new total, or 0
## when the response carried none). PATCH is not retried by the transport, so a
## timeout never double-counts.
func increment_stat(key: String, delta: int = 1) -> Dictionary:
	if not is_valid_key(key):
		return _invalid({"value": 0})
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_PATCH, stat_path(key), increment_body(delta))
	res["value"] = parse_value(res.json) if res.ok else 0
	return res


## Read one stat. -> {..., value:int, exists:bool}. A stat the user has never
## written (HTTP 404) is ok:true, exists:false, value 0.
func get_stat(key: String) -> Dictionary:
	if not is_valid_key(key):
		return _invalid({"value": 0, "exists": false})
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_GET, stat_path(key))
	if int(res.status) == 404:
		res.ok = true
		res.error = ""
		res["value"] = 0
		res["exists"] = false
		return res
	res["value"] = parse_value(res.json) if res.ok else 0
	res["exists"] = res.ok
	return res


## Read all of the user's stats. -> {..., stats:{key:int}}
func get_stats() -> Dictionary:
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_GET, all_stats_path())
	res["stats"] = parse_stats(res.json) if res.ok else {}
	return res


static func _invalid(extra: Dictionary) -> Dictionary:
	var res := SnapKitTransport.error_result(SnapKitTransport.ERR_INVALID_ARGUMENT)
	res.merge(extra, true)
	return res
