class_name SnapKitStats
extends RefCounted

## Client for the Snapser Statistics snap (statistics.swagger3.json): per-user
## integer stats.
##
##   PUT   /v1/statistics/user-stats/{user_id}/{key}   SetUserStatistic
##   PATCH /v1/statistics/user-stats/{user_id}/{key}   IncrementUserStatistic
##   GET   /v1/statistics/user-stats/{user_id}/{key}   GetUserStatistic
##   GET   /v1/statistics/settings/user-stats/{user_id} GetUserStatistics
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
##     parsed fields; they never throw.
##
## SKELETON (owner: kit-clients agent): signatures final for v0.1; bodies stubbed.

const KEY_PATTERN := "^[a-z0-9_]+$"

var _transport: SnapKitTransport


func _init(transport: SnapKitTransport) -> void:
	_transport = transport


## True when key matches KEY_PATTERN.
static func is_valid_key(key: String) -> bool:
	return false


## "/v1/statistics/user-stats/{user_id}/<key>" (placeholder left for transport).
static func stat_path(key: String) -> String:
	return ""


## Set a stat to an absolute value. -> {ok, status, json, error, value:int}
func set_stat(key: String, value: int) -> Dictionary:
	return SnapKitTransport.not_implemented()


## Atomically add delta (may be negative). -> {..., value:int} (new total)
func increment_stat(key: String, delta: int = 1) -> Dictionary:
	return SnapKitTransport.not_implemented()


## Read one stat. -> {..., value:int}
func get_stat(key: String) -> Dictionary:
	return SnapKitTransport.not_implemented()


## Read all of the user's stats. -> {..., stats:{key:int}}
func get_stats() -> Dictionary:
	return SnapKitTransport.not_implemented()
