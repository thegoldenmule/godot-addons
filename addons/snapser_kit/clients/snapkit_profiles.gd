class_name SnapKitProfiles
extends RefCounted

## Client for the Snapser Profiles snap (profiles.swagger3.json): the player's
## display name, which leaderboards show (D16).
##
##   GET   /v1/profiles/user/{user_id}             GetProfile       -> {profile:object}
##   PUT   /v1/profiles/user/{user_id}             UpsertProfile    {profile} (full replace)
##   PATCH /v1/profiles/user/{user_id}             PatchProfile     {profile} -> {profile}
##   GET   /v1/profiles/batch/profiles?user_id=a&user_id=b   BatchGetProfiles -> {profiles:{uid: object}}
##
## The attribute keys are configured on the snapend; the kit uses only
## ATTR_DISPLAY_NAME ("display_name"). set_display_name() PATCHes so it never
## wipes other attributes, falling back to a PUT upsert when the user has no
## profile yet (404).
##
## Names are NOT unique (D33): several players may share a display name, and
## leaderboards tell them apart by user id. There is no server-side filter
## (identity spike §6), so the client does:
##   - sanitize_display_name(): strip control / zero-width chars, collapse
##     whitespace, trim, clamp to NAME_MAX_LEN;
##   - is_valid_display_name(): NAME_MIN_LEN..NAME_MAX_LEN, no markup-ish
##     characters (DISALLOWED_CHARS), and the word filter;
##   - the word filter: blocked_words (whole words after leetspeak folding) and
##     blocked_fragments (anywhere, punctuation removed). Both are static vars a
##     game may extend; a game may also set `name_filter` on the instance (a
##     Callable(name: String) -> bool, true = allowed) for its own rules.
## Admin resets happen server-side (api-key PUT, tools/snapser runbook).
##
## Names on leaderboards come from here, never from leaderboard user_metadata
## (a client-written copy that a reset would not fix): fetch_display_names()
## batch-resolves user ids and caches them for the session. The cache is
## class-wide (static, keyed by user id), so every SnapKitProfiles instance in
## the process — e.g. the service's profiles client and the one inside
## SnapKitLeaderboards — sees set_display_name()'s update of the session user.
##
## default_display_name() derives a stable auto-generated name (e.g.
## "Player 4F2A") from a seed (the user id) for players without a name.
##
## Conventions: see SnapKitStats.

const NAME_MIN_LEN := 3
const NAME_MAX_LEN := 16
const ATTR_DISPLAY_NAME := "display_name"
const PROFILE_PATH := "/v1/profiles/user/{user_id}"
const BATCH_PATH := "/v1/profiles/batch/profiles"
## User ids per BatchGetProfiles request (keeps the query string short).
const BATCH_MAX := 50
const DEFAULT_NAME_PREFIX := "Player"
## Characters never allowed in a display name.
const DISALLOWED_CHARS := "<>{}[]\\|`\"^~"

## Lower-case words rejected as a whole word of a name (after leetspeak folding).
## Deliberately short: this is a courtesy filter, not moderation.
static var blocked_words: PackedStringArray = PackedStringArray([
	"fuck", "fucker", "fucking", "shit", "cunt", "bitch", "whore", "slut", "rape", "rapist",
	"nigger", "nigga", "faggot", "fag", "retard", "nazi", "hitler", "admin", "moderator",
])
## Lower-case fragments rejected anywhere in the name with spaces/punctuation
## removed (catches "f u c k", "xXfuckXx"). Only fragments with no common
## innocent superstring belong here.
static var blocked_fragments: PackedStringArray = PackedStringArray([
	"fuck", "nigger", "nigga", "faggot",
])

## Optional extra filter: Callable(name: String) -> bool (true = allowed). Runs
## after the built-in checks.
var name_filter: Callable

## user_id -> display name ("" = the user has no name set). Process lifetime,
## shared by all instances (see class doc).
static var _name_cache: Dictionary = {}

var _transport: SnapKitTransport


func _init(transport: SnapKitTransport) -> void:
	_transport = transport


## "/v1/profiles/user/{user_id}".
static func profile_path() -> String:
	return PROFILE_PATH


## "/v1/profiles/batch/profiles?user_id=<a>&user_id=<b>...".
static func batch_path(user_ids: PackedStringArray) -> String:
	return SnapKitTransport.with_query(BATCH_PATH, {"user_id": Array(user_ids)})


## {profile: attrs}.
static func profile_body(attrs: Dictionary) -> Dictionary:
	return {"profile": attrs}


## Profile attributes Dictionary from a GetProfile response ({} if none).
static func parse_profile(json: Variant) -> Dictionary:
	return SnapKitJson.get_dict(json, "profile")


## BatchGetProfiles response -> {user_id: display_name} for every profile
## returned ("" when it has no name). Tolerates each entry being the attribute
## object itself or wrapped as {profile: {...}}.
static func parse_batch_names(json: Variant) -> Dictionary:
	var out := {}
	var profiles := SnapKitJson.get_dict(json, "profiles")
	for uid in profiles:
		var p: Variant = profiles[uid]
		if p is Dictionary and (p as Dictionary).get("profile") is Dictionary:
			p = p["profile"]
		out[str(uid)] = SnapKitJson.get_str(p, ATTR_DISPLAY_NAME)
	return out


## Strip control / zero-width characters, collapse whitespace runs to one space,
## trim, and clamp to NAME_MAX_LEN.
static func sanitize_display_name(raw_name: String) -> String:
	var out := ""
	var pending_space := false
	for ch in raw_name:
		var c := ch.unicode_at(0)
		if c == 32 or c == 9 or c == 10 or c == 13 or c == 0x3000 or c == 0xA0:
			pending_space = out != ""
			continue
		if c < 32 or c == 127 or (c >= 0x80 and c < 0xA0) \
				or c in [0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2028, 0x2029, 0x2060, 0xFEFF, 0xFFFD]:
			continue
		if pending_space:
			out += " "
			pending_space = false
		out += ch
	if out.length() > NAME_MAX_LEN:
		out = out.substr(0, NAME_MAX_LEN).strip_edges()
	return out


## True when the name is already sanitized (no change), within
## NAME_MIN_LEN..NAME_MAX_LEN, has no DISALLOWED_CHARS, and passes the word
## filter. (Static: the instance `name_filter` is applied by set_display_name.)
static func is_valid_display_name(display_name: String) -> bool:
	var s := sanitize_display_name(display_name)
	if s != display_name or s.length() < NAME_MIN_LEN or s.length() > NAME_MAX_LEN:
		return false
	for ch in s:
		if DISALLOWED_CHARS.contains(ch):
			return false
	return not contains_blocked_word(s)


## True when the (folded) name contains a blocked word or fragment.
static func contains_blocked_word(display_name: String) -> bool:
	var folded := _fold(display_name)
	var compact := ""
	var words := PackedStringArray()
	var cur := ""
	for ch in folded:
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			cur += ch
			compact += ch
		elif cur != "":
			words.append(cur)
			cur = ""
	if cur != "":
		words.append(cur)
	for w in words:
		if w in blocked_words:
			return true
	for f in blocked_fragments:
		if compact.contains(f):
			return true
	return false


## Stable default name derived from seed; same seed -> same name.
## "Player " + 4 upper-case hex chars of sha256(seed); "Player" for "".
static func default_display_name(seed: String) -> String:
	if seed == "":
		return DEFAULT_NAME_PREFIX
	return "%s %s" % [DEFAULT_NAME_PREFIX, seed.sha256_text().substr(0, 4).to_upper()]


## Full name check used by set_display_name: static rules + name_filter.
func accepts_display_name(display_name: String) -> bool:
	if not is_valid_display_name(display_name):
		return false
	if name_filter.is_valid() and not bool(name_filter.call(display_name)):
		return false
	return true


## -> {ok, status, json, error, profile:Dictionary, display_name:String}
## A missing profile (404) is ok:true with profile {} and display_name "".
func fetch_profile() -> Dictionary:
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_GET, profile_path())
	if int(res.status) == 404:
		res.ok = true
		res.error = ""
		res.snap_code = 0
	var profile := parse_profile(res.json) if res.ok else {}
	res["profile"] = profile
	res["display_name"] = SnapKitJson.get_str(profile, ATTR_DISPLAY_NAME)
	if res.ok and _transport.user_id() != "":
		_name_cache[_transport.user_id()] = res.display_name
	return res


## Sanitize (trim, length-limit), validate (filter), then store. Invalid names
## -> ERR_INVALID_ARGUMENT with no request. Names are not unique (D33).
## -> {..., display_name:String (as stored; "" on failure)}
func set_display_name(display_name: String) -> Dictionary:
	var clean := sanitize_display_name(display_name)
	if not accepts_display_name(clean):
		var bad := SnapKitTransport.error_result(SnapKitTransport.ERR_INVALID_ARGUMENT)
		bad["display_name"] = ""
		return bad
	var body := profile_body({ATTR_DISPLAY_NAME: clean})
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_PATCH, profile_path(), body)
	if int(res.status) == 404:
		res = await _transport.request(HTTPClient.METHOD_PUT, profile_path(), body)
	var stored := SnapKitJson.get_str(parse_profile(res.json), ATTR_DISPLAY_NAME, clean)
	res["display_name"] = stored if res.ok else ""
	if res.ok and _transport.user_id() != "":
		_name_cache[_transport.user_id()] = stored
	return res


## Resolve display names for user ids via BatchGetProfiles, using the session
## cache; only uncached ids are requested (in chunks of BATCH_MAX). Users with no
## profile or no name map to "". refresh = true ignores the cache.
## -> {ok, status, json, error, names:{user_id: String}} — names holds every
## requested id that could be resolved (cached or fetched), even when a chunk
## failed (ok:false then carries that chunk's error).
func fetch_display_names(user_ids: PackedStringArray, refresh: bool = false) -> Dictionary:
	var missing := PackedStringArray()
	for uid in user_ids:
		if uid != "" and (refresh or not _name_cache.has(uid)) and not (uid in missing):
			missing.append(uid)
	var res := SnapKitTransport.ok_result()
	var i := 0
	while i < missing.size():
		var chunk := missing.slice(i, i + BATCH_MAX)
		i += BATCH_MAX
		var r: Dictionary = await _transport.request(HTTPClient.METHOD_GET, batch_path(chunk))
		if not r.ok:
			res = r
			continue
		var names := parse_batch_names(r.json)
		for uid in chunk:
			_name_cache[uid] = str(names.get(uid, ""))
	var out := {}
	for uid in user_ids:
		if _name_cache.has(uid):
			out[uid] = _name_cache[uid]
	res["names"] = out
	return res


## The cached name for a user id ("" if unknown or unset). Not a coroutine.
static func cached_display_name(user_id: String) -> String:
	return str(_name_cache.get(user_id, ""))


## Drop cached names (all, or one user id).
static func clear_name_cache(user_id: String = "") -> void:
	if user_id == "":
		_name_cache.clear()
	else:
		_name_cache.erase(user_id)


## Lower-case and fold common leetspeak digits/symbols to letters.
static func _fold(s: String) -> String:
	var out := ""
	var map := {"0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s", "!": "i"}
	for ch in s.to_lower():
		out += map.get(ch, ch)
	return out
