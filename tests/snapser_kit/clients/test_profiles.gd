extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitProfiles: name policy (sanitize / length / word filter / custom
## filter), default names, name_taken mapping, batch name resolution + cache.

const FakeTransport := preload("res://tests/snapser_kit/clients/fake_transport.gd")
const PROFILE := "/v1/profiles/user/{uid}"
const BATCH := "/v1/profiles/batch/profiles"

var t: FakeTransport
var profiles: SnapKitProfiles
var _saved_words: PackedStringArray


func before_each() -> void:
	t = add_node(FakeTransport.new())
	profiles = SnapKitProfiles.new(t)
	SnapKitProfiles.clear_name_cache()
	_saved_words = SnapKitProfiles.blocked_words.duplicate()


func after_each() -> void:
	SnapKitProfiles.blocked_words = _saved_words


func test_sanitize() -> void:
	check_eq(SnapKitProfiles.sanitize_display_name("  Ada   Lovelace \n"), "Ada Lovelace", "trim + collapse")
	check_eq(SnapKitProfiles.sanitize_display_name("A" + char(1) + "d" + char(0x200B) + "a" + char(7) + char(0xFFFD)), "Ada", "control + zero-width stripped")
	check_eq(SnapKitProfiles.sanitize_display_name("abcdefghijklmnopqrstuvwxyz"), "abcdefghijklmnop", "clamped to 16")
	check_eq(SnapKitProfiles.sanitize_display_name("abcdefghijklmno  z"), "abcdefghijklmno", "clamp then trim")
	check_eq(SnapKitProfiles.sanitize_display_name(""), "", "empty")


func test_validity_and_word_filter() -> void:
	for ok_name in ["Ada", "Player One", "Scunthorpe FC", "Assassin", "Grapefruit", "Dr. Who", "Zoë"]:
		check(SnapKitProfiles.is_valid_display_name(ok_name), "valid: " + ok_name)
	for bad in ["", "ab", "  Ada", "a\nb c", "abcdefghijklmnopq", "<script>", "a{b}c",
			"fuck you", "F.U.C.K", "xXfuckXx", "sh1t head", "n1gger", "admin", "The Admin"]:
		check(not SnapKitProfiles.is_valid_display_name(bad), "invalid: '%s'" % bad)


func test_word_list_is_overridable() -> void:
	check(SnapKitProfiles.is_valid_display_name("Banana"), "allowed by default")
	SnapKitProfiles.blocked_words.append("banana")
	check(not SnapKitProfiles.is_valid_display_name("Banana"), "game-added word blocked")


func test_default_display_name() -> void:
	var a := SnapKitProfiles.default_display_name("user-123")
	check_eq(a, SnapKitProfiles.default_display_name("user-123"), "stable")
	check(a.begins_with("Player ") and a.length() == 11, "shape: " + a)
	check(a != SnapKitProfiles.default_display_name("user-124"), "differs per seed")
	check_eq(SnapKitProfiles.default_display_name(""), "Player", "empty seed")
	check(SnapKitProfiles.is_valid_display_name(a), "default passes the filter")


func test_paths_and_parsers() -> void:
	check_eq(SnapKitProfiles.profile_path(), "/v1/profiles/user/{user_id}", "profile path")
	check_eq(SnapKitProfiles.batch_path(PackedStringArray(["a", "b c"])),
		"/v1/profiles/batch/profiles?user_id=a&user_id=b%20c", "batch path repeats user_id")
	check_eq(SnapKitProfiles.parse_profile({"profile": {"display_name": "X"}}), {"display_name": "X"}, "profile")
	check_eq(SnapKitProfiles.parse_profile({"profile": null}), {}, "null profile")
	check_eq(SnapKitProfiles.parse_batch_names({"profiles": {
		"u1": {"display_name": "One"}, "u2": {"profile": {"display_name": "Two"}}, "u3": {}, "u4": "junk"}}),
		{"u1": "One", "u2": "Two", "u3": "", "u4": ""}, "batch names (plain + wrapped)")


func test_fetch_profile() -> void:
	t.respond(HTTPClient.METHOD_GET, PROFILE, 404, {"error_code": 14011})
	var r: Dictionary = await profiles.fetch_profile()
	check(r.ok, "404 -> ok")
	check_eq(r.profile, {}, "empty profile")
	check_eq(r.display_name, "", "no name")
	t.respond(HTTPClient.METHOD_GET, PROFILE, 200, {"profile": {"display_name": "Ada", "avatar_id": "3"}})
	r = await profiles.fetch_profile()
	check_eq(r.display_name, "Ada", "name")
	check_eq(SnapKitProfiles.cached_display_name("user-1"), "Ada", "own name cached")


func test_set_display_name_patch_then_upsert() -> void:
	t.respond(HTTPClient.METHOD_PATCH, PROFILE, 404, {"error_code": 14011})
	t.route(HTTPClient.METHOD_PUT, PROFILE, func(req: Dictionary) -> Dictionary:
		return {"status": 200, "json": {}})
	var r: Dictionary = await profiles.set_display_name("  Ada   L ")
	check(r.ok, "ok via upsert")
	check_eq(r.display_name, "Ada L", "sanitized name stored")
	check_eq(t.calls.size(), 2, "PATCH then PUT")
	check_eq(t.calls[0].method, HTTPClient.METHOD_PATCH, "PATCH first")
	check_eq(t.calls[1].body, {"profile": {"display_name": "Ada L"}}, "PUT body")
	check_eq(SnapKitProfiles.cached_display_name("user-1"), "Ada L", "cache updated")


func test_set_display_name_rejections() -> void:
	var r: Dictionary = await profiles.set_display_name("ab")
	check_eq(r.error, SnapKitTransport.ERR_INVALID_ARGUMENT, "too short")
	r = await profiles.set_display_name("fuck")
	check_eq(r.error, SnapKitTransport.ERR_INVALID_ARGUMENT, "word filter")
	profiles.name_filter = func(n: String) -> bool: return not n.to_lower().contains("bob")
	r = await profiles.set_display_name("Bobby")
	check_eq(r.error, SnapKitTransport.ERR_INVALID_ARGUMENT, "custom filter")
	check_eq(r.display_name, "", "no name")
	check_eq(t.calls.size(), 0, "no requests")


func test_set_display_name_taken() -> void:
	t.respond(HTTPClient.METHOD_PATCH, PROFILE, 409, {"error_code": 14012, "message": "Unique violation"})
	var r: Dictionary = await profiles.set_display_name("Ada")
	check(not r.ok, "not ok")
	check_eq(r.error, SnapKitProfiles.ERR_NAME_TAKEN, "name_taken")
	check_eq(r.display_name, "", "no name")
	check_eq(SnapKitProfiles.cached_display_name("user-1"), "", "cache untouched")


func test_fetch_display_names_batches_and_caches() -> void:
	t.route(HTTPClient.METHOD_GET, BATCH, func(req: Dictionary) -> Dictionary:
		var ids: Variant = req.query.user_id
		if not (ids is Array):
			ids = [ids]
		var ps := {}
		for id in ids:
			if id != "ghost":
				ps[id] = {"display_name": "N-" + id}
		return {"status": 200, "json": {"profiles": ps}})
	var ids := PackedStringArray()
	for i in 60:
		ids.append("u%d" % i)
	ids.append("ghost")
	var r: Dictionary = await profiles.fetch_display_names(ids)
	check(r.ok, "ok")
	check_eq(t.calls.size(), 2, "61 ids -> 2 chunks")
	check_eq(r.names.u7, "N-u7", "resolved")
	check_eq(r.names.ghost, "", "no profile -> ''")
	check_eq(r.names.size(), 61, "all ids")
	r = await profiles.fetch_display_names(PackedStringArray(["u1", "u2"]))
	check_eq(t.calls.size(), 2, "cached: no new request")
	check_eq(r.names, {"u1": "N-u1", "u2": "N-u2"}, "from cache")
	r = await profiles.fetch_display_names(PackedStringArray(["u1"]), true)
	check_eq(t.calls.size(), 3, "refresh re-fetches")


func test_fetch_display_names_failure() -> void:
	t.respond(HTTPClient.METHOD_GET, BATCH, 500)
	var r: Dictionary = await profiles.fetch_display_names(PackedStringArray(["a"]))
	check(not r.ok, "not ok")
	check_eq(r.error, "http_500", "error")
	check_eq(r.names, {}, "nothing resolved")
	t.offline = true
	r = await profiles.fetch_display_names(PackedStringArray(["a"]))
	check_eq(r.error, "offline", "offline")
