extends "res://tests/snapser_kit/snapkit_test_case.gd"

## SnapKitQuests: paths, int64-tolerant parsers, claimable rule, verbs.

const FakeTransport := preload("res://tests/snapser_kit/clients/fake_transport.gd")

const ACTIVE := {
	"quests": {
		"dm_win_3": {
			"status": "in_progress", "resets_at": "1760000000", "tags": ["daily_mission"],
			"tasks": {"win": {"completed": false, "current_progress_64": "2", "current_progress": 2, "goal_64": "3"}},
			"reward_currencies": [{"name": "coins", "count_64": "50"}, {"name": "coins", "count": 5}, {"name": "gems", "count": 1}],
		},
		"login": {"status": "unclaimed", "tasks": {"t": {"completed": true, "current_progress": 1, "goal": 1}}},
	},
	"updated_at": "1",
}

var t: FakeTransport
var quests: SnapKitQuests


func before_each() -> void:
	t = add_node(FakeTransport.new())
	quests = SnapKitQuests.new(t)


func test_paths() -> void:
	check_eq(SnapKitQuests.active_quests_path(),
		"/v1/quests/users/{user_id}/active_quests?include_reward_contents=true", "no tags")
	check_eq(SnapKitQuests.active_quests_path("daily mission"),
		"/v1/quests/users/{user_id}/active_quests?include_reward_contents=true&tags=daily%20mission", "tags")
	check_eq(SnapKitQuests.assign_path("q/1"), "/v1/quests/users/{user_id}/quests/q%2F1/assign", "assign")
	check_eq(SnapKitQuests.increment_path("q", "t 1"), "/v1/quests/users/{user_id}/quests/q/tasks/t%201", "increment")
	check_eq(SnapKitQuests.claim_path("q"), "/v1/quests/users/{user_id}/quests/q/claim_rewards", "claim")
	check_eq(SnapKitQuests.increment_body(4), {"delta": 4, "delta64": 4}, "increment body")


func test_parse_active_quests() -> void:
	var qs := SnapKitQuests.parse_active_quests(ACTIVE)
	check_eq(qs.size(), 2, "two quests")
	var q: Dictionary = qs[0]
	check_eq(q.name, "dm_win_3", "name")
	check_eq(q.resets_at, 1760000000, "resets_at from string")
	check_eq(q.tags, ["daily_mission"], "tags")
	check_eq(q.tasks, [{"name": "win", "completed": false, "progress": 2, "goal": 3}], "task with *_64")
	check_eq(q.reward, {"coins": 55, "gems": 1}, "rewards summed, int64 preferred")
	check_eq(SnapKitQuests.parse_active_quests(null), [], "null")
	check_eq(SnapKitQuests.parse_active_quests({"quests": []}), [], "wrong shape")


func test_parse_claim_and_claimable() -> void:
	check_eq(SnapKitQuests.parse_claim({"currencies_granted_64": {"coins": "9007199254740993"},
		"currencies_granted": {"coins": 1}, "xp_granted": {"xp": 2.0}}).reward,
		{"coins": 9007199254740993}, "prefers int64 map")
	check_eq(SnapKitQuests.parse_claim({"currencies_granted": {"coins": 5.0}}).reward, {"coins": 5}, "int32 fallback")
	check_eq(SnapKitQuests.parse_claim({"xp_granted": {"xp": 2.0}}).xp, {"xp": 2}, "xp")
	check_eq(SnapKitQuests.parse_claim(null), {"reward": {}, "xp": {}, "statistics": {}, "items": {}}, "null")
	var qs := SnapKitQuests.parse_active_quests(ACTIVE)
	check(not SnapKitQuests.is_claimable(qs[0]), "in progress not claimable")
	check(SnapKitQuests.is_claimable(qs[1]), "unclaimed claimable")
	check(not SnapKitQuests.is_claimable({"status": "completed", "tasks": [{"completed": true}]}), "completed = claimed")
	check(SnapKitQuests.is_claimable({"status": "", "tasks": [{"completed": true}]}), "task complete, no status")


func test_contract_verbs_and_results() -> void:
	t.respond(HTTPClient.METHOD_GET, "/v1/quests/users/{u}/active_quests", 200, ACTIVE)
	t.respond(HTTPClient.METHOD_POST, "/v1/quests/users/{u}/quests/{q}/assign", 200, ACTIVE.quests.dm_win_3)
	t.respond(HTTPClient.METHOD_PUT, "/v1/quests/users/{u}/quests/{q}/tasks/{t}", 200, ACTIVE.quests.dm_win_3)
	t.respond(HTTPClient.METHOD_POST, "/v1/quests/users/{u}/quests/{q}/claim_rewards", 200,
		{"currencies_granted_64": {"coins": "50"}})
	var r: Dictionary = await quests.fetch_active("daily_mission")
	check(r.ok and r.quests.size() == 2, "fetch")
	check_eq(t.calls[0].query, {"include_reward_contents": "true", "tags": "daily_mission"}, "query")
	r = await quests.assign("dm_win_3")
	check(r.ok, "assign ok")
	check_eq(r.quest.name, "dm_win_3", "assign parses quest")
	r = await quests.increment("dm_win_3", "win", 1)
	check(r.ok, "increment ok")
	check_eq(t.calls[2].body, {"delta": 1.0, "delta64": 1.0}, "increment body sent")
	check_eq(r.quest.tasks[0].progress, 2, "increment parses quest")
	r = await quests.claim("dm_win_3")
	check(r.ok, "claim ok")
	check_eq(r.reward, {"coins": 50}, "claim reward")
	check_eq(t.calls[1].method, HTTPClient.METHOD_POST, "assign is POST")
	check_eq(t.calls[3].method, HTTPClient.METHOD_POST, "claim is POST")
	check_eq(t.calls[3].path, "/v1/quests/users/user-1/quests/dm_win_3/claim_rewards", "claim path")


func test_errors() -> void:
	var r: Dictionary = await quests.assign("")
	check_eq(r.error, SnapKitTransport.ERR_INVALID_ARGUMENT, "empty quest")
	r = await quests.increment("q", "")
	check_eq(r.error, SnapKitTransport.ERR_INVALID_ARGUMENT, "empty task")
	check_eq(t.calls.size(), 0, "no requests")
	t.offline = true
	r = await quests.fetch_active()
	check_eq(r.error, "offline", "offline")
	check_eq(r.quests, [], "offline quests")
	r = await quests.claim("q")
	check_eq(r.reward, {}, "offline reward")
