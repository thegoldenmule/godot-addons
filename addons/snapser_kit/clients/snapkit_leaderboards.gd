class_name SnapKitLeaderboards
extends RefCounted

## Client for the Snapser Leaderboards snap (leaderboards.swagger3.json).
##
##   PUT /v1/leaderboards/leaderboards/{leaderboard_name}/users/{user_id}/score  SetScore
##   GET /v1/leaderboards/leaderboards/{leaderboard_name}                        GetScores
##
## `board` arguments are SNAPSER leaderboard names; SnapKitService maps logical
## names through SnapKitConfig.leaderboard_id() before calling. Display names
## shown on boards come from the Profiles snap (D16); entries carry whatever name
## the response provides, else "".
##
## Entry shape (parse_entries): {user_id:String, display_name:String,
## score:int, rank:int, is_me:bool}.
##
## Conventions: see SnapKitStats.
##
## SKELETON (owner: kit-clients agent): signatures final for v0.1; bodies stubbed.

var _transport: SnapKitTransport


func _init(transport: SnapKitTransport) -> void:
	_transport = transport


## Path to a user's score on a board ("{user_id}" placeholder left in).
static func score_path(board: String) -> String:
	return ""


## Path (with query) for a page of scores.
## range_kind: "top" | "around_me" (exact query params per swagger).
static func scores_path(board: String, range_kind: String, count: int) -> String:
	return ""


## Normalize a GetScores response into an Array of entry dicts (see class doc).
## me_user_id marks is_me.
static func parse_entries(json: Variant, me_user_id: String = "") -> Array:
	return []


## Submit the user's score. -> {ok, status, json, error, rank?:int}
func submit_score(board: String, score: int) -> Dictionary:
	return SnapKitTransport.not_implemented()


## Top N. -> {..., entries:Array}
func get_top(board: String, count: int = 10) -> Dictionary:
	return SnapKitTransport.not_implemented()


## N entries around the session user. -> {..., entries:Array}
func get_around_me(board: String, count: int = 5) -> Dictionary:
	return SnapKitTransport.not_implemented()
