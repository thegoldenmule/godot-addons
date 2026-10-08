class_name SnapKitQuests
extends RefCounted

## Client for the Snapser Quests snap (quests.swagger3.json). Optional: the
## service only constructs it when SnapKitConfig.quests_enabled().
##
##   GET /v1/quests/users/{user_id}/active_quests            GetActiveQuests
##   PUT /v1/quests/users/{user_id}/quests/{quest}/assign     AssignQuest
##   PUT /v1/quests/users/{user_id}/quests/{quest}/tasks/{task} IncrementTaskProgress
##   PUT /v1/quests/users/{user_id}/quests/{quest}/claim_rewards ClaimQuestRewards
## (Verify verbs against the swagger; donor: Hypercasual-Shared SaxQuestsClient.)
##
## Normalized quest shape (parse_active_quests):
##   {name, status, resets_at:int (unix s), tags:Array[String],
##    tasks:[{name, completed:bool, progress:int, goal:int}],
##    reward:{<currency>:int}}
##
## Conventions: see SnapKitStats.
##
## SKELETON (owner: kit-clients agent): signatures final for v0.1; bodies stubbed.

var _transport: SnapKitTransport


func _init(transport: SnapKitTransport) -> void:
	_transport = transport


static func active_quests_path(tags: String = "") -> String:
	return ""


static func assign_path(quest: String) -> String:
	return ""


static func increment_path(quest: String, task: String) -> String:
	return ""


static func claim_path(quest: String) -> String:
	return ""


## -> Array of normalized quest dicts (see class doc).
static func parse_active_quests(json: Variant) -> Array:
	return []


## -> {reward:{<currency>:int}, ...} from a ClaimQuestRewards response.
static func parse_claim(json: Variant) -> Dictionary:
	return {}


## -> {ok, status, json, error, quests:Array}
func fetch_active(tags: String = "") -> Dictionary:
	return SnapKitTransport.not_implemented()


func assign(quest: String) -> Dictionary:
	return SnapKitTransport.not_implemented()


func increment(quest: String, task: String, delta: int = 1) -> Dictionary:
	return SnapKitTransport.not_implemented()


## -> {..., reward:Dictionary}
func claim(quest: String) -> Dictionary:
	return SnapKitTransport.not_implemented()
