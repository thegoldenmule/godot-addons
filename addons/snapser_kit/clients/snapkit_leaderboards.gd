class_name SnapKitLeaderboards
extends RefCounted

## Client for the Snapser Leaderboards snap (leaderboards.swagger3.json).
##
##   PUT /v1/leaderboards/leaderboards/{leaderboard_name}/users/{user_id}/score
##       SetScore {score:double} -> {user_id, score, rank}
##   GET /v1/leaderboards/leaderboards/{leaderboard_name}?range=&count=&user_id=
##       GetScores -> {user_scores:[{user_id, score, rank, user_metadata}]}
##
## `board` arguments are SNAPSER leaderboard names; SnapKitService maps logical
## names through SnapKitConfig.leaderboard_id() before calling.
##
## Display names (D16 + identity spike §6): names shown on a board come from
## the Profiles snap, resolved per page with one BatchGetProfiles call and cached
## for the session (SnapKitProfiles.fetch_display_names). Leaderboard
## user_metadata is NEVER read for names and the kit never writes names into it:
## it is a client-written copy that an admin profile reset would not fix. A user
## with no Profiles name shows SnapKitProfiles.default_display_name(user_id).
## If the profile lookup fails the page is still returned (ok follows the
## GetScores call) with default names and names_resolved:false.
##
## Entry shape (parse_entries): {user_id:String, display_name:String,
## score:int, rank:int, is_me:bool}.
##
## Conventions: see SnapKitStats.

const BASE_PATH := "/v1/leaderboards/leaderboards"
const RANGE_TOP := "top"
const RANGE_AROUND_ME := "around_me"
const RANGE_BOTTOM := "bottom"
const MAX_COUNT := 100
## Snapser ErrLeaderboardNotFound (HTTP 404). Any other 404 on an around-me
## query means the user has no score on the board yet (ErrUserNotFound, 9004).
const SNAP_ERR_BOARD_NOT_FOUND := 9000

## Name resolver. The Profiles name cache is class-wide, so a private instance
## still sees renames made through the service's profiles client.
var profiles: SnapKitProfiles

var _transport: SnapKitTransport


## profiles_client is optional (additive to the v0.1 skeleton signature); pass
## one to share its name_filter / instance, or omit it for a private one.
func _init(transport: SnapKitTransport, profiles_client: SnapKitProfiles = null) -> void:
	_transport = transport
	profiles = profiles_client if profiles_client != null else SnapKitProfiles.new(transport)


## Path to a user's score on a board ("{user_id}" placeholder left in).
static func score_path(board: String) -> String:
	return "%s/%s/users/{user_id}/score" % [BASE_PATH, board.uri_encode()]


## Path (with query) for a page of scores.
## range_kind: "top" | "around_me" | "bottom". "around_me" becomes Snapser's
## range=around plus user_id={user_id} (the placeholder is expanded by the
## transport). count is clamped to 1..MAX_COUNT. Metadata is not requested.
static func scores_path(board: String, range_kind: String, count: int) -> String:
	var snap_range := "around" if range_kind == RANGE_AROUND_ME else range_kind
	var path := SnapKitTransport.with_query("%s/%s" % [BASE_PATH, board.uri_encode()], {
		"range": snap_range,
		"count": clampi(count, 1, MAX_COUNT),
	})
	if range_kind == RANGE_AROUND_ME:
		# Appended raw: with_query() would uri-encode the braces of the placeholder.
		path += "&user_id=" + SnapKitTransport.USER_ID_PLACEHOLDER
	return path


## SetScore body: the score only — never user_metadata (see class doc).
static func score_body(score: int) -> Dictionary:
	return {"score": score}


## Normalize a GetScores response into an Array of entry dicts (see class doc),
## in server order, with display_name "" (filled by apply_names). me_user_id
## marks is_me. Scores arrive as doubles and ranks as int64 (number or string);
## both are coerced leniently. user_metadata is ignored.
static func parse_entries(json: Variant, me_user_id: String = "") -> Array:
	var out: Array = []
	for us in SnapKitJson.get_array(json, "user_scores"):
		if not (us is Dictionary):
			continue
		var uid := SnapKitJson.get_str(us, "user_id")
		out.append({
			"user_id": uid,
			"display_name": "",
			"score": SnapKitJson.get_int(us, "score"),
			"rank": SnapKitJson.get_int(us, "rank"),
			"is_me": me_user_id != "" and uid == me_user_id,
		})
	return out


## Fill each entry's display_name from names {user_id: name}; missing or empty
## names get SnapKitProfiles.default_display_name(user_id).
static func apply_names(entries: Array, names: Dictionary) -> void:
	for e in entries:
		var uid: String = e.user_id
		var n := str(names.get(uid, ""))
		e["display_name"] = n if n != "" else SnapKitProfiles.default_display_name(uid)


## Unique user ids of a page of entries.
static func entry_user_ids(entries: Array) -> PackedStringArray:
	var ids := PackedStringArray()
	for e in entries:
		var uid: String = e.user_id
		if uid != "" and not (uid in ids):
			ids.append(uid)
	return ids


## Submit the user's score. -> {ok, status, json, error, rank:int, score:int}
func submit_score(board: String, score: int) -> Dictionary:
	if board == "":
		return _invalid({"rank": 0, "score": score})
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_PUT, score_path(board), score_body(score))
	res["rank"] = SnapKitJson.get_int(res.json, "rank") if res.ok else 0
	res["score"] = SnapKitJson.get_int(res.json, "score", score) if res.ok else score
	return res


## Top N. -> {..., entries:Array, names_resolved:bool}
func get_top(board: String, count: int = 10) -> Dictionary:
	return await _fetch(board, RANGE_TOP, count)


## N entries around the session user. A user without a score on the board is
## ok:true with entries [] (Snapser answers 404 ErrUserNotFound).
## -> {..., entries:Array, names_resolved:bool}
func get_around_me(board: String, count: int = 5) -> Dictionary:
	return await _fetch(board, RANGE_AROUND_ME, count)


func _fetch(board: String, range_kind: String, count: int) -> Dictionary:
	if board == "":
		return _invalid({"entries": [], "names_resolved": false})
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_GET, scores_path(board, range_kind, count))
	res["entries"] = []
	res["names_resolved"] = false
	if range_kind == RANGE_AROUND_ME and int(res.status) == 404 \
			and _snap_error_code(res.json) != SNAP_ERR_BOARD_NOT_FOUND:
		res.ok = true
		res.error = ""
		res.snap_code = 0
		res.names_resolved = true
		return res
	if not res.ok:
		return res
	var entries := parse_entries(res.json, _transport.user_id())
	var names: Dictionary = {}
	if not entries.is_empty():
		var nr: Dictionary = await profiles.fetch_display_names(entry_user_ids(entries))
		names = nr.get("names", {})
		res.names_resolved = bool(nr.ok)
	else:
		res.names_resolved = true
	apply_names(entries, names)
	res.entries = entries
	return res


## Snapser error code from an error body ({"api_error_code": n} as sent live,
## or {"error_code": n} / {"code": n}); 0
## when absent.
static func _snap_error_code(json: Variant) -> int:
	for k in ["api_error_code", "error_code", "code"]:
		var v := SnapKitJson.get_int(json, k, 0)
		if v != 0:
			return v
	return 0


static func _invalid(extra: Dictionary) -> Dictionary:
	var res := SnapKitTransport.error_result(SnapKitTransport.ERR_INVALID_ARGUMENT)
	res.merge(extra, true)
	return res
