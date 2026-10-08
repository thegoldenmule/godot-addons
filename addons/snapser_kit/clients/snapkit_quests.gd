class_name SnapKitQuests
extends RefCounted

## Client for the Snapser Quests snap (quests.swagger3.json). Optional: the
## service only constructs it when SnapKitConfig.quests_enabled().
##
##   GET  /v1/quests/users/{user_id}/active_quests?tags=&include_reward_contents=true  GetActiveQuests
##   POST /v1/quests/users/{user_id}/quests/{quest}/assign                            AssignQuest
##   PUT  /v1/quests/users/{user_id}/quests/{quest}/tasks/{task}  {delta, delta64}    IncrementTaskProgress
##   POST /v1/quests/users/{user_id}/quests/{quest}/claim_rewards                     ClaimQuestRewards
## (Verbs per the swagger; assign and claim are POST, so the transport does not
## retry them.) Lifted from the studio quests client, rebased onto the transport.
##
## Normalized quest shape (parse_active_quests / parse_quest):
##   {name, status, resets_at:int (unix s), tags:Array[String],
##    tasks:[{name, completed:bool, progress:int, goal:int}],
##    reward:{<currency>:int}}
##
## Snapser quest status (verified live in the studio client): "unclaimed" = tasks
## done, reward waiting; "completed" = reward already claimed. is_claimable()
## matches these exactly ("claimed" is a substring of "unclaimed").
##
## Conventions: see SnapKitStats.

const BASE_PATH := "/v1/quests/users/{user_id}"
const STATUS_UNCLAIMED := "unclaimed"
const STATUS_COMPLETED := "completed"

var _transport: SnapKitTransport


func _init(transport: SnapKitTransport) -> void:
	_transport = transport


## GetActiveQuests path. Reward contents always ride along; tags "" = all.
static func active_quests_path(tags: String = "") -> String:
	return SnapKitTransport.with_query(BASE_PATH + "/active_quests", {
		"include_reward_contents": true,
		"tags": tags if tags != "" else null,
	})


static func assign_path(quest: String) -> String:
	return "%s/quests/%s/assign" % [BASE_PATH, quest.uri_encode()]


static func increment_path(quest: String, task: String) -> String:
	return "%s/quests/%s/tasks/%s" % [BASE_PATH, quest.uri_encode(), task.uri_encode()]


static func claim_path(quest: String) -> String:
	return "%s/quests/%s/claim_rewards" % [BASE_PATH, quest.uri_encode()]


## IncrementTaskProgress body: both delta (int32) and delta64 (int64), as the
## swagger request schema lists both.
static func increment_body(delta: int) -> Dictionary:
	return {"delta": delta, "delta64": delta}


## questsUserQuests {quests:{name: questsUserQuest}} -> Array of normalized
## quests (see class doc), in the map's order.
static func parse_active_quests(json: Variant) -> Array:
	var out: Array = []
	var quests := SnapKitJson.get_dict(json, "quests")
	for qname in quests:
		if quests[qname] is Dictionary:
			out.append(parse_quest(str(qname), quests[qname]))
	return out


## One questsUserQuest -> normalized quest. The name is the map key (or, for
## assign/increment responses, the quest the caller named).
static func parse_quest(quest_name: String, q: Variant) -> Dictionary:
	var tasks: Array = []
	var raw_tasks := SnapKitJson.get_dict(q, "tasks")
	for tname in raw_tasks:
		var t: Variant = raw_tasks[tname]
		if not (t is Dictionary):
			continue
		tasks.append({
			"name": str(tname),
			"completed": SnapKitJson.get_bool(t, "completed"),
			"progress": SnapKitJson.get_int64(t, "current_progress_64", "current_progress"),
			"goal": SnapKitJson.get_int64(t, "goal_64", "goal"),
		})
	var tags: Array = []
	for tg in SnapKitJson.get_array(q, "tags"):
		tags.append(str(tg))
	return {
		"name": quest_name,
		"status": SnapKitJson.get_str(q, "status"),
		"resets_at": SnapKitJson.get_int(q, "resets_at"),
		"tags": tags,
		"tasks": tasks,
		"reward": _sum_currencies(SnapKitJson.get_array(q, "reward_currencies")),
	}


## ClaimQuestRewards response -> {reward:{<currency>:int}, xp:{..}, statistics:{..},
## items:{..}}. Currencies prefer the int64 map (currencies_granted_64) over the
## deprecated int32 one.
static func parse_claim(json: Variant) -> Dictionary:
	var currencies := SnapKitJson.get_dict(json, "currencies_granted_64")
	if currencies.is_empty():
		currencies = SnapKitJson.get_dict(json, "currencies_granted")
	return {
		"reward": _int_map(currencies),
		"xp": _int_map(SnapKitJson.get_dict(json, "xp_granted")),
		"statistics": _int_map(SnapKitJson.get_dict(json, "statistics_granted")),
		"items": _int_map(SnapKitJson.get_dict(json, "items_granted")),
	}


## A quest is claimable when its reward is waiting: status "unclaimed", or (for
## responses without a status) any completed task — never when "completed".
static func is_claimable(quest: Dictionary) -> bool:
	var status := str(quest.get("status", "")).to_lower()
	if status == STATUS_COMPLETED:
		return false
	if status == STATUS_UNCLAIMED:
		return true
	for t in quest.get("tasks", []):
		if t is Dictionary and bool(t.get("completed", false)):
			return true
	return false


## -> {ok, status, json, error, quests:Array}
func fetch_active(tags: String = "") -> Dictionary:
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_GET, active_quests_path(tags))
	res["quests"] = parse_active_quests(res.json) if res.ok else []
	return res


## Assign an (auto-assign-off) quest to the session user.
## -> {..., quest:Dictionary (normalized; {} on failure)}
func assign(quest: String) -> Dictionary:
	if quest == "":
		return _invalid({"quest": {}})
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_POST, assign_path(quest))
	res["quest"] = parse_quest(quest, res.json) if res.ok else {}
	return res


## Advance a counter task by delta. -> {..., quest:Dictionary}
func increment(quest: String, task: String, delta: int = 1) -> Dictionary:
	if quest == "" or task == "":
		return _invalid({"quest": {}})
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_PUT, increment_path(quest, task),
		increment_body(delta))
	res["quest"] = parse_quest(quest, res.json) if res.ok else {}
	return res


## Claim a completed quest's rewards (granted server-side by the snap).
## -> {..., reward:Dictionary, xp, statistics, items}
func claim(quest: String) -> Dictionary:
	if quest == "":
		return _invalid(parse_claim(null))
	var res: Dictionary = await _transport.request(HTTPClient.METHOD_POST, claim_path(quest))
	res.merge(parse_claim(res.json if res.ok else null), true)
	return res


static func _sum_currencies(arr: Array) -> Dictionary:
	var out := {}
	for c in arr:
		var nm := SnapKitJson.get_str(c, "name")
		if nm != "":
			out[nm] = int(out.get(nm, 0)) + SnapKitJson.get_int64(c, "count_64", "count")
	return out


static func _int_map(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d:
		out[str(k)] = SnapKitJson.to_int(d[k])
	return out


static func _invalid(extra: Dictionary) -> Dictionary:
	var res := SnapKitTransport.error_result(SnapKitTransport.ERR_INVALID_ARGUMENT)
	res.merge(extra, true)
	return res
