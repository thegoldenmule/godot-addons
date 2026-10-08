extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitLeaderboards: paths, parsing, Profiles-based names (never
## user_metadata), around-me semantics.

const FakeTransport := preload("res://tests/snapser_kit/clients/fake_transport.gd")
const BOARD := "/v1/leaderboards/leaderboards/{board}"
const BATCH := "/v1/profiles/batch/profiles"

const PAGE := {"user_scores": [
	{"user_id": "u-a", "score": 300.0, "rank": "1", "user_metadata": {"name": "SPOOFED", "display_name": "SPOOFED"}},
	{"user_id": "user-1", "score": 250, "rank": 2},
	{"user_id": "u-c", "score": 1.0e2, "rank": 3.0},
]}

var t: FakeTransport
var lb: SnapKitLeaderboards


func before_each() -> void:
	t = add_node(FakeTransport.new())
	lb = SnapKitLeaderboards.new(t)
	SnapKitProfiles.clear_name_cache()


func _serve_names(names: Dictionary) -> void:
	t.route(HTTPClient.METHOD_GET, BATCH, func(req: Dictionary) -> Dictionary:
		var ids: Variant = req.query.user_id
		if not (ids is Array):
			ids = [ids]
		var ps := {}
		for id in ids:
			if names.has(id):
				ps[id] = {"display_name": names[id]}
		return {"status": 200, "json": {"profiles": ps}})


func test_paths_and_body() -> void:
	check_eq(SnapKitLeaderboards.score_path("career wins"),
		"/v1/leaderboards/leaderboards/career%20wins/users/{user_id}/score", "score path")
	check_eq(SnapKitLeaderboards.scores_path("b", "top", 10), "/v1/leaderboards/leaderboards/b?range=top&count=10", "top")
	check_eq(SnapKitLeaderboards.scores_path("b", "around_me", 500),
		"/v1/leaderboards/leaderboards/b?range=around&count=100&user_id={user_id}", "around_me, clamped")
	check_eq(SnapKitLeaderboards.scores_path("b", "top", 0), "/v1/leaderboards/leaderboards/b?range=top&count=1", "min 1")
	check_eq(SnapKitLeaderboards.score_body(12), {"score": 12}, "no user_metadata ever")


func test_parse_entries_ignores_metadata() -> void:
	var e := SnapKitLeaderboards.parse_entries(PAGE, "user-1")
	check_eq(e.size(), 3, "three")
	check_eq(e[0], {"user_id": "u-a", "display_name": "", "score": 300, "rank": 1, "is_me": false}, "first")
	check_eq(e[1].is_me, true, "me marked")
	check_eq(e[2].rank, 3, "float rank")
	check_eq(e[2].score, 100, "float score")
	check_eq(SnapKitLeaderboards.parse_entries(null), [], "null")
	check_eq(SnapKitLeaderboards.parse_entries({"user_scores": ["junk"]}), [], "junk rows skipped")


func test_submit_score_sends_no_name() -> void:
	t.respond(HTTPClient.METHOD_PUT, BOARD + "/users/{u}/score", 200, {"user_id": "user-1", "score": 99.0, "rank": "4"})
	var r: Dictionary = await lb.submit_score("weekly", 99)
	check(r.ok, "ok")
	check_eq(r.rank, 4, "rank")
	check_eq(r.score, 99, "score")
	check_eq(t.calls[0].path, "/v1/leaderboards/leaderboards/weekly/users/user-1/score", "path")
	check_eq(t.calls[0].body, {"score": 99.0}, "body has no user_metadata")
	r = await lb.submit_score("", 1)
	check_eq(r.error, SnapKitTransport.ERR_INVALID_ARGUMENT, "empty board")


func test_top_resolves_names_from_profiles_and_caches() -> void:
	t.respond(HTTPClient.METHOD_GET, BOARD, 200, PAGE)
	_serve_names({"u-a": "Alice", "user-1": "Me"})
	var r: Dictionary = await lb.get_top("weekly", 3)
	check(r.ok, "ok")
	check(r.names_resolved, "names resolved")
	check_eq(r.entries[0].display_name, "Alice", "profile name, not user_metadata")
	check_eq(r.entries[1].display_name, "Me", "own name")
	check_eq(r.entries[2].display_name, SnapKitProfiles.default_display_name("u-c"), "no name -> default")
	var batch := t.calls_to(BATCH)
	check_eq(batch.size(), 1, "one batch call")
	check_eq(batch[0].query.user_id, ["u-a", "user-1", "u-c"], "page ids")
	r = await lb.get_top("weekly", 3)
	check_eq(t.calls_to(BATCH).size(), 1, "second page served from cache")
	check_eq(r.entries[0].display_name, "Alice", "cached name")


func test_shared_profiles_cache_sees_rename() -> void:
	var profiles := SnapKitProfiles.new(t)
	lb = SnapKitLeaderboards.new(t, profiles)
	check(lb.profiles == profiles, "shared profiles client")
	t.respond(HTTPClient.METHOD_GET, BOARD, 200, PAGE)
	_serve_names({"user-1": "Old"})
	t.respond(HTTPClient.METHOD_PATCH, "/v1/profiles/user/{u}", 200, {"profile": {"display_name": "New Name"}})
	var r: Dictionary = await lb.get_top("weekly")
	check_eq(r.entries[1].display_name, "Old", "before rename")
	await profiles.set_display_name("New Name")
	r = await lb.get_top("weekly")
	check_eq(r.entries[1].display_name, "New Name", "after rename (cache updated)")


func test_private_resolver_sees_rename_through_service_profiles() -> void:
	# The service builds SnapKitLeaderboards.new(transport) (private profiles
	# instance) and renames through its own profiles client.
	var service_profiles := SnapKitProfiles.new(t)
	t.respond(HTTPClient.METHOD_GET, BOARD, 200, PAGE)
	_serve_names({"user-1": "Old"})
	t.respond(HTTPClient.METHOD_PATCH, "/v1/profiles/user/{u}", 200, {"profile": {"display_name": "Renamed"}})
	var r: Dictionary = await lb.get_top("weekly")
	check_eq(r.entries[1].display_name, "Old", "before")
	await service_profiles.set_display_name("Renamed")
	r = await lb.get_top("weekly")
	check_eq(r.entries[1].display_name, "Renamed", "class-wide cache sees the rename")


func test_names_failure_still_returns_page() -> void:
	t.respond(HTTPClient.METHOD_GET, BOARD, 200, PAGE)
	t.respond(HTTPClient.METHOD_GET, BATCH, 503)
	var r: Dictionary = await lb.get_top("weekly")
	check(r.ok, "page ok")
	check_eq(r.names_resolved, false, "names not resolved")
	check_eq(r.entries[0].display_name, SnapKitProfiles.default_display_name("u-a"), "default, not metadata")


func test_around_me() -> void:
	t.respond(HTTPClient.METHOD_GET, BOARD, 200, PAGE)
	_serve_names({})
	var r: Dictionary = await lb.get_around_me("weekly", 5)
	check(r.ok, "ok")
	check_eq(t.calls[0].query, {"range": "around", "count": "5", "user_id": "user-1"}, "around query")
	t.respond(HTTPClient.METHOD_GET, BOARD, 404, {"error_code": 9004})
	r = await lb.get_around_me("weekly")
	check(r.ok, "not ranked -> ok")
	check_eq(r.entries, [], "no entries")
	t.respond(HTTPClient.METHOD_GET, BOARD, 404, {"error_code": 9000})
	r = await lb.get_around_me("weekly")
	check_eq(r.error, SnapKitErrors.NOT_FOUND, "missing board stays an error (9000 -> not_found)")
	r = await lb.get_top("weekly")
	check_eq(r.error, SnapKitErrors.NOT_FOUND, "top 404 is an error")


func test_empty_page_and_offline() -> void:
	t.respond(HTTPClient.METHOD_GET, BOARD, 200, {"user_scores": []})
	var r: Dictionary = await lb.get_top("weekly")
	check(r.ok and r.entries.is_empty(), "empty page")
	check_eq(t.calls_to(BATCH).size(), 0, "no batch call for empty page")
	t.offline = true
	r = await lb.get_top("weekly")
	check_eq(r.error, "offline", "offline")
	check_eq(r.entries, [], "offline entries")
	r = await lb.submit_score("weekly", 5)
	check_eq(r.error, "offline", "offline submit")
